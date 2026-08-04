# frozen_string_literal: true

require "date"
require "yaml"

module SecureGitHubActions
  Result = Struct.new(:root, :files, :findings, keyword_init: true) do
    def clean?
      findings.empty?
    end

    def document
      {
        "schema" => "review-finding-v0",
        "scan" => {
          "name" => "secure-github-actions-scan",
          "version" => 1,
          "root" => root,
          "files_scanned" => files
        },
        "review_findings" => findings
      }
    end
  end

  class Scanner
    YAML_TIMESTAMP_CLASSES = [Date, Time].freeze
    EXPRESSION_PATTERN = /\$\{\{.*?\}\}/m

    def initialize(root)
      expanded_root = File.expand_path(root)
      raise ArgumentError, "consumer root must be a directory" unless File.directory?(expanded_root)

      @root = File.realpath(expanded_root)
    end

    def self.acceptable_action_reference?(reference)
      return false unless reference.is_a?(String)

      return true if reference.start_with?("./")
      return true if reference.match?(%r{\Adocker://[^\s@]+@sha256:[0-9a-fA-F]{64}\z})

      reference.match?(%r{\A[^\s@/]+/[^\s@/]+(?:/[^\s@/]+)*@[0-9a-f]{40}\z})
    end

    def scan
      input_types = workflow_paths.to_h { |path| [path, :workflow] }
      action_paths.each { |path| input_types[path] ||= :action }
      inputs = input_types.sort_by(&:first)
      findings = inputs.flat_map do |path, type|
        type == :workflow ? scan_workflow(path) : scan_action(path)
      end
      findings.sort_by! do |finding|
        location = finding.fetch("location")
        [location.fetch("file"), location.fetch("symbol"), finding.fetch("rule_id")]
      end

      Result.new(root: @root, files: inputs.map { |path, _type| relative_path(path) }, findings: findings)
    end

    private

    def workflow_paths
      Dir.glob(File.join(@root, ".github/workflows/*.{yml,yaml}")).sort
    end

    def action_paths
      Dir.glob(File.join(@root, "**/action.{yml,yaml}"), File::FNM_DOTMATCH).reject do |path|
        first_part = relative_path(path).split("/", 2).first
        %w[.codex .git .tmp tmp].include?(first_part)
      end.sort
    end

    def scan_workflow(path)
      workflow = YAML.safe_load_file(path, permitted_classes: YAML_TIMESTAMP_CLASSES, aliases: true)
      return [invalid_structure(path, "<document>", "a mapping")] unless workflow.is_a?(Hash)

      jobs = workflow["jobs"]
      return [invalid_structure(path, "jobs", "a mapping")] unless jobs.is_a?(Hash)

      jobs.flat_map do |job_name, job|
        prefix = "jobs.#{job_name}"
        next [invalid_structure(path, prefix, "a mapping")] unless job.is_a?(Hash)

        findings = scan_uses(path, job["uses"], "#{prefix}.uses") if job.key?("uses")
        findings ||= []
        findings += scan_reusable_workflow_secrets(path, job, prefix)
        if job.key?("steps")
          findings << invalid_structure(path, "#{prefix}.steps", "an array") unless job["steps"].is_a?(Array)
          findings += scan_steps(path, job["steps"], "#{prefix}.steps") if job["steps"].is_a?(Array)
        end
        findings
      end
    rescue Psych::Exception, SystemCallError, EncodingError
      [invalid_yaml(path)]
    end

    def scan_action(path)
      action = YAML.safe_load_file(path, permitted_classes: YAML_TIMESTAMP_CLASSES, aliases: true)
      return [invalid_structure(path, "<document>", "a mapping")] unless action.is_a?(Hash)

      runs = action["runs"]
      return [invalid_structure(path, "runs", "a mapping")] unless runs.is_a?(Hash)
      return [] unless runs.key?("steps")
      return [invalid_structure(path, "runs.steps", "an array")] unless runs["steps"].is_a?(Array)

      scan_steps(path, runs["steps"], "runs.steps")
    rescue Psych::Exception, SystemCallError, EncodingError
      [invalid_yaml(path)]
    end

    def scan_reusable_workflow_secrets(path, job, prefix)
      return [] unless job.key?("uses") && job.key?("secrets")
      return [] if job["secrets"].is_a?(Hash)
      unless job["secrets"] == "inherit"
        return [invalid_structure(path, "#{prefix}.secrets", "a mapping or the exact string inherit")]
      end

      [finding(
        rule_id: "secure-github-actions/secrets-inherit",
        path: path,
        symbol: "#{prefix}.secrets",
        title: "Reusable workflow inherits every available secret",
        body: "Pass only the named secrets required by the called workflow."
      )]
    end

    def scan_steps(path, steps, prefix)
      steps.each_with_index.flat_map do |step, index|
        step_prefix = "#{prefix}.#{index}"
        next [invalid_structure(path, step_prefix, "a mapping")] unless step.is_a?(Hash)

        findings = step.key?("uses") ? scan_uses(path, step["uses"], "#{step_prefix}.uses") : []
        value = step["run"]
        if step.key?("run") && !value.is_a?(String)
          findings << invalid_structure(path, "#{step_prefix}.run", "a string")
          next findings
        end
        next findings unless value.is_a?(String) && value.match?(EXPRESSION_PATTERN)

        findings << finding(
          rule_id: "secure-github-actions/expression-in-run",
          path: path,
          symbol: "#{step_prefix}.run",
          title: "GitHub expression is interpolated into a shell script",
          body: "Move untrusted expression data into an environment variable before the run step."
        )
        findings
      end
    end

    def scan_uses(path, reference, symbol)
      return [invalid_structure(path, symbol, "a string")] unless reference.is_a?(String)
      return [] if self.class.acceptable_action_reference?(reference)

      [finding(
        rule_id: "secure-github-actions/unpinned-external-use",
        path: path,
        symbol: symbol,
        title: "External GitHub Action reference is not pinned to a full commit SHA",
        body: "Pin external actions and reusable workflows to an exact 40-character lowercase commit SHA."
      )]
    end

    def invalid_structure(path, symbol, expected)
      finding(
        rule_id: "secure-github-actions/invalid-structure",
        path: path,
        symbol: symbol,
        title: "GitHub Actions YAML has an invalid value shape",
        body: "Expected #{symbol} to be #{expected}; repair the structure before relying on the scan."
      )
    end

    def invalid_yaml(path)
      finding(
        rule_id: "secure-github-actions/invalid-yaml",
        path: path,
        symbol: "<document>",
        title: "GitHub Actions YAML could not be parsed safely",
        body: "Repair the malformed or unreadable YAML before relying on the security scan."
      )
    end

    def finding(rule_id:, path:, symbol:, title:, body:)
      relative = relative_path(path)
      {
        "id" => "#{rule_id}:#{relative}:#{symbol}",
        "rule_id" => rule_id,
        "deterministic" => true,
        "source" => "secure-github-actions",
        "target" => { "root" => @root },
        "severity" => "P1",
        "disposition" => "must_fix",
        "title" => title,
        "body" => body,
        "verification" => { "status" => "verified", "current_head_state" => "not_applicable" },
        "location" => { "file" => relative, "symbol" => symbol }
      }
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end
  end
end
