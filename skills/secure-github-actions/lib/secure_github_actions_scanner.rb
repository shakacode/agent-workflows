# frozen_string_literal: true

require "date"
require "find"
require "yaml"

module SecureGitHubActions
  class UnsafeFileError < StandardError; end

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
      root_stat = File.lstat(@root)
      raise ArgumentError, "consumer root must resolve to a real directory" unless root_stat.directory?

      @root_identity = file_identity(root_stat)
    end

    def self.acceptable_action_reference?(reference)
      return false unless reference.is_a?(String)

      return reference.split("/").none? { |segment| segment == ".." } if reference.start_with?("./")
      return true if reference.match?(%r{\Adocker://[^\s@]+@sha256:[0-9a-fA-F]{64}\z})

      reference.match?(%r{\A[^\s@/]+/[^\s@/]+(?:/[^\s@/]+)*@[0-9a-f]{40}\z})
    end

    def scan
      return unsafe_root_result unless bound_root?

      input_types = workflow_entries.to_h { |path, type| [path, type] }
      action_entries.each { |path, type| input_types[path] ||= type }
      return unsafe_root_result unless bound_root?

      inputs = input_types.sort_by(&:first)
      findings = inputs.flat_map do |path, type|
        case type
        when :workflow then scan_workflow(path)
        when :action then scan_action(path)
        else [unsafe_file(path)]
        end
      end
      findings.sort_by! do |finding|
        location = finding.fetch("location")
        [location.fetch("file"), location.fetch("symbol"), finding.fetch("rule_id")]
      end
      return unsafe_root_result unless bound_root?

      Result.new(root: @root, files: inputs.map { |path, _type| relative_path(path) }, findings: findings)
    end

    private

    def bound_root?
      root_stat = File.lstat(@root)
      root_stat.directory? && !root_stat.symlink? && file_identity(root_stat) == @root_identity
    rescue SystemCallError
      false
    end

    def unsafe_root_result
      Result.new(root: @root, files: ["."], findings: [unsafe_file(@root)])
    end

    def workflow_entries
      github_directory = File.join(@root, ".github")
      return [] unless path_entry_exists?(github_directory)
      return [[github_directory, :unsafe]] unless real_directory?(github_directory)

      workflows_directory = File.join(github_directory, "workflows")
      return [] unless path_entry_exists?(workflows_directory)
      return [[workflows_directory, :unsafe]] unless real_directory?(workflows_directory)

      Dir.children(workflows_directory).sort.filter_map do |name|
        next unless name.match?(/\.ya?ml\z/)

        [File.join(workflows_directory, name), :workflow]
      end
    rescue SystemCallError
      [[workflows_directory || github_directory, :unsafe]]
    end

    def action_entries
      entries = []
      last_path = @root
      Find.find(@root, ignore_error: false) do |path|
        last_path = path
        next if path == @root

        relative = relative_path(path)
        first_part = relative.split("/", 2).first
        stat = File.lstat(path)
        if %w[.codex .git .tmp tmp].include?(first_part)
          Find.prune if stat.directory? || stat.symlink?
          next
        end

        if stat.symlink?
          if directory_target?(path)
            entries << [path, :unsafe]
            Find.prune
          elsif action_filename?(path)
            entries << [path, :action]
          end
          next
        end

        if stat.directory?
          if action_filename?(path)
            entries << [path, :unsafe]
            Find.prune
          end
          next
        end
        next unless action_filename?(path)

        entries << [path, :action]
      rescue SystemCallError
        entries << [path, :unsafe]
        Find.prune
      end
      entries.sort_by(&:first)
    rescue SystemCallError
      entries << [last_path, :unsafe]
      entries.sort_by(&:first)
    end

    def scan_workflow(path)
      workflow = load_yaml(path)
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
    rescue UnsafeFileError
      [unsafe_file(path)]
    rescue Psych::Exception, EncodingError
      [invalid_yaml(path)]
    end

    def scan_action(path)
      action = load_yaml(path)
      return [invalid_structure(path, "<document>", "a mapping")] unless action.is_a?(Hash)

      runs = action["runs"]
      return [invalid_structure(path, "runs", "a mapping")] unless runs.is_a?(Hash)
      return [] unless runs.key?("steps")
      return [invalid_structure(path, "runs.steps", "an array")] unless runs["steps"].is_a?(Array)

      scan_steps(path, runs["steps"], "runs.steps")
    rescue UnsafeFileError
      [unsafe_file(path)]
    rescue Psych::Exception, EncodingError
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

    def unsafe_file(path)
      finding(
        rule_id: "secure-github-actions/unsafe-file",
        path: path,
        symbol: "<document>",
        title: "GitHub Actions input is outside the safe file boundary",
        body: "Use a real regular file beneath real consumer-root directories before relying on the scan."
      )
    end

    def load_yaml(path)
      source = safely_read(path)
      YAML.safe_load(
        source,
        permitted_classes: YAML_TIMESTAMP_CLASSES,
        permitted_symbols: [],
        aliases: true,
        filename: path
      )
    end

    def safely_read(path)
      validate_ancestor_chain!(path)
      path_stat = File.lstat(path)
      raise UnsafeFileError unless path_stat.file? && !path_stat.symlink?

      path_identity = file_identity(path_stat)

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
      File.open(path, flags) do |file|
        opened_stat = file.stat
        raise UnsafeFileError unless opened_stat.file?
        raise UnsafeFileError unless file_identity(opened_stat) == path_identity

        current_stat = File.lstat(path)
        raise UnsafeFileError unless current_stat.file? && !current_stat.symlink?
        raise UnsafeFileError unless file_identity(current_stat) == path_identity

        validate_ancestor_chain!(path)
        file.read
      end
    rescue SystemCallError
      raise UnsafeFileError
    end

    def validate_ancestor_chain!(path)
      relative = relative_path(path)
      raise UnsafeFileError if relative == path || relative.empty?
      raise UnsafeFileError unless bound_root?

      current = @root
      relative.split("/")[0...-1].each do |part|
        current = File.join(current, part)
        stat = File.lstat(current)
        raise UnsafeFileError unless stat.directory? && !stat.symlink?
      end
    rescue SystemCallError
      raise UnsafeFileError
    end

    def real_directory?(path)
      stat = File.lstat(path)
      stat.directory? && !stat.symlink?
    rescue SystemCallError
      false
    end

    def path_entry_exists?(path)
      File.lstat(path)
      true
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    rescue SystemCallError
      true
    end

    def directory_target?(path)
      File.directory?(path)
    rescue SystemCallError
      false
    end

    def action_filename?(path)
      %w[action.yml action.yaml].include?(File.basename(path))
    end

    def file_identity(stat)
      [stat.dev, stat.ino]
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
      return "." if path == @root

      prefix = "#{@root}/"
      return path.delete_prefix(prefix) if path.start_with?(prefix)

      path
    end
  end
end
