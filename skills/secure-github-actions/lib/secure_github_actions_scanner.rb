# frozen_string_literal: true

require "psych"

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
    EXPRESSION_PATTERN = /\$\{\{.*?\}\}/m

    def initialize(root)
      @root = File.realpath(root)
      raise ArgumentError, "consumer root must be a directory" unless File.directory?(@root)
    end

    def scan
      workflow_paths = Dir.glob(File.join(@root, ".github/workflows/*.{yml,yaml}"))
      action_paths = Dir.glob(File.join(@root, "**/action.{yml,yaml}"), File::FNM_DOTMATCH).reject do |path|
        %w[.codex .git .tmp tmp].include?(relative_path(path).split("/", 2).first)
      end
      paths = (workflow_paths + action_paths).uniq.sort
      @trusted_actions, policy_findings = load_trusted_actions
      findings = policy_findings + input_boundary_findings + paths.flat_map { |path| scan_workflow(path) }
      Result.new(root: @root, files: paths.map { |path| relative_path(path) }, findings: findings)
    end

    private

    def input_boundary_findings
      [".github", ".github/workflows"].each do |relative|
        path = File.join(@root, relative)
        next unless File.exist?(path) || File.symlink?(path)

        stat = File.lstat(path)
        next if stat.directory? && !stat.symlink?

        return [finding(
          rule_id: "secure-github-actions/unsafe-file",
          path: path,
          symbol: "<directory>",
          line: 1,
          title: "GitHub Actions input is outside the safe file boundary",
          body: "Use a regular, non-symlink directory within the repository for GitHub Actions inputs."
        )]
      rescue SystemCallError
        return [finding(
          rule_id: "secure-github-actions/unsafe-file",
          path: path,
          symbol: "<directory>",
          line: 1,
          title: "GitHub Actions input boundary could not be verified",
          body: "Repair the repository directory boundary before relying on the security scan."
        )]
      end

      []
    end

    def scan_workflow(path)
      source = safely_read(path)
      document = Psych.parse_stream(source, filename: path)
      scan_node(document, path, [], source.lines(chomp: true))
    rescue UnsafeFileError
      [finding(
        rule_id: "secure-github-actions/unsafe-file",
        path: path,
        symbol: "<document>",
        line: 1,
        title: "GitHub Actions input is outside the safe file boundary",
        body: "Use a regular, non-symlink file beneath real repository directories."
      )]
    rescue Psych::Exception, EncodingError
      [finding(
        rule_id: "secure-github-actions/invalid-yaml",
        path: path,
        symbol: "<document>",
        line: 1,
        title: "GitHub Actions YAML could not be parsed safely",
        body: "Repair the malformed workflow before relying on the security scan."
      )]
    end

    def safely_read(path)
      relative = relative_path(path)
      raise UnsafeFileError if relative == path || relative.empty?

      current = @root
      relative.split("/")[0...-1].each do |part|
        current = File.join(current, part)
        stat = File.lstat(current)
        raise UnsafeFileError unless stat.directory? && !stat.symlink?
      end

      entry_stat = File.lstat(path)
      raise UnsafeFileError unless entry_stat.file? && !entry_stat.symlink?

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
      File.open(path, flags, encoding: "UTF-8") do |file|
        opened_stat = file.stat
        unless opened_stat.file? && [opened_stat.dev, opened_stat.ino] == [entry_stat.dev, entry_stat.ino]
          raise UnsafeFileError
        end

        file.read
      end
    rescue SystemCallError
      raise UnsafeFileError
    end

    def scan_node(node, path, keys, lines)
      case node
      when Psych::Nodes::Mapping
        node.children.each_slice(2).flat_map do |key, value|
          key_name = key.is_a?(Psych::Nodes::Scalar) ? key.value : "<key>"
          symbol = (keys + [key_name]).join(".")
          findings = if sensitive_position?(key_name, keys)
                       shape_findings(key_name, value, path, symbol) +
                         scalar_findings(key_name, value, path, symbol, lines)
                     else
                       []
                     end
          findings + scan_node(value, path, keys + [key_name], lines)
        end
      when Psych::Nodes::Sequence
        node.children.each_with_index.flat_map do |child, index|
          scan_node(child, path, keys + [index], lines)
        end
      else
        if node.respond_to?(:children) && node.children
          node.children.flat_map { |child| scan_node(child, path, keys, lines) }
        else
          []
        end
      end
    end

    def sensitive_position?(key_name, keys)
      step_value = lambda do
        (keys.length == 4 && keys[0] == "jobs" && keys[2] == "steps" && keys[3].is_a?(Integer)) ||
          (keys.length == 3 && keys[0] == "runs" && keys[1] == "steps" && keys[2].is_a?(Integer))
      end

      return step_value.call if key_name == "run"
      return step_value.call || (keys.length == 2 && keys[0] == "jobs") if key_name == "uses"
      return keys.length == 2 && keys[0] == "jobs" if key_name == "secrets"

      false
    end

    def shape_findings(key_name, value, path, symbol)
      valid = if %w[run uses].include?(key_name)
                value.is_a?(Psych::Nodes::Scalar)
              elsif key_name == "secrets"
                value.is_a?(Psych::Nodes::Mapping) ||
                  (value.is_a?(Psych::Nodes::Scalar) && value.value == "inherit")
              else
                true
              end
      return [] if valid

      [finding(
        rule_id: "secure-github-actions/invalid-structure",
        path: path,
        symbol: symbol,
        line: value.respond_to?(:start_line) ? value.start_line + 1 : 1,
        title: "Security-sensitive workflow field has an invalid value shape",
        body: "Use a scalar for run/uses and an explicit mapping for reusable-workflow secrets."
      )]
    end

    def scalar_findings(key_name, value, path, symbol, lines)
      return [] unless value.is_a?(Psych::Nodes::Scalar)

      findings = []
      if key_name == "run" && value.value.match?(EXPRESSION_PATTERN)
        findings << finding(
          rule_id: "secure-github-actions/expression-in-run",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "GitHub expression is interpolated into a shell script",
          body: "Move expression data into an environment variable before the run step."
        )
      elsif key_name == "secrets" && value.value == "inherit"
        findings << finding(
          rule_id: "secure-github-actions/secrets-inherit",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "Reusable workflow inherits every available secret",
          body: "Pass only the named secrets required by the called workflow."
        )
      end

      if key_name == "uses" && local_use?(value.value) &&
         (!safe_local_use?(value.value) || !safe_local_target?(value.value))
        findings << finding(
          rule_id: "secure-github-actions/unsafe-local-use",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "Local action reference escapes its repository boundary",
          body: "Use an existing repository-relative action directory without empty, dot, parent, or symlink segments."
        )
      elsif key_name == "uses" && !immutable_use?(value.value)
        findings << finding(
          rule_id: "secure-github-actions/unpinned-external-use",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "External action reference is mutable",
          body: "Pin external actions and reusable workflows to an exact lowercase 40-character commit SHA."
        )
      elsif key_name == "uses" && external_use?(value.value) && !readable_version_comment?(value, lines)
        findings << finding(
          rule_id: "secure-github-actions/missing-version-comment",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "Pinned external action lacks a readable version comment",
          body: "Add the human-readable action version after the full commit SHA, for example # v4.2.2."
        )
      end

      if key_name == "uses" && external_use?(value.value) && !trusted_use?(value.value)
        findings << finding(
          rule_id: "secure-github-actions/untrusted-external-use",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "External action is absent from the closed trusted-actions allowlist",
          body: "Add the exact owner/repository only after maintainer review; wildcards and tag-based exceptions are not allowed."
        )
      end

      findings
    end

    def immutable_use?(reference)
      return safe_local_use?(reference) if local_use?(reference)
      return true if reference.match?(%r{\Adocker://[^\s@]+@sha256:[0-9a-fA-F]{64}\z})

      reference.match?(%r{\A[^\s@/]+/[^\s@/]+(?:/[^\s@/]+)*@[0-9a-f]{40}\z})
    end

    def local_use?(reference)
      reference.start_with?("./")
    end

    def safe_local_use?(reference)
      return false unless reference.match?(%r{\A\./[^\s@]+\z})

      reference.split("/").drop(1).none? { |segment| segment.empty? || %w[. ..].include?(segment) }
    end

    def safe_local_target?(reference)
      current = @root
      reference.delete_prefix("./").split("/").each do |segment|
        current = File.join(current, segment)
        stat = File.lstat(current)
        return false unless stat.directory? && !stat.symlink?
      end

      true
    rescue SystemCallError
      false
    end

    def external_use?(reference)
      !reference.start_with?("./") && !reference.start_with?("docker://")
    end

    def readable_version_comment?(node, lines)
      suffix = lines.fetch(node.end_line, "")[node.end_column..].to_s
      suffix.match?(/\A[ \t]+#[ \t]*[A-Za-z0-9][^\r\n]*\z/)
    end

    def trusted_use?(reference)
      identity = reference.split("@", 2).first.split("/").first(2).join("/").downcase
      @trusted_actions.include?(identity)
    end

    def load_trusted_actions
      path = File.join(@root, ".agents/agent-workflow.yml")
      return [[], []] unless File.exist?(path) || File.symlink?(path)

      stream = Psych.parse_stream(safely_read(path), filename: path)
      return invalid_trusted_actions(path) unless stream.children.length == 1

      root = stream.children.first&.children&.first
      return invalid_trusted_actions(path) unless root.is_a?(Psych::Nodes::Mapping)

      values = root.children.each_slice(2).filter_map do |key, value|
        value if key.is_a?(Psych::Nodes::Scalar) && key.value == "trusted_actions"
      end
      return [[], []] if values.empty?
      return invalid_trusted_actions(path) unless values.length == 1 && values.first.is_a?(Psych::Nodes::Sequence)

      entries = values.first.children
      valid = entries.all? do |entry|
        entry.is_a?(Psych::Nodes::Scalar) &&
          (entry.tag.nil? || entry.tag == "tag:yaml.org,2002:str") &&
          entry.value.match?(%r{\A[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\z})
      end
      normalized = entries.map { |entry| entry.value.downcase }
      valid &&= normalized.uniq.length == normalized.length
      return invalid_trusted_actions(path) unless valid

      [normalized.freeze, []]
    rescue Psych::Exception, EncodingError, SystemCallError, UnsafeFileError
      invalid_trusted_actions(path)
    end

    def invalid_trusted_actions(path)
      [[], [finding(
        rule_id: "secure-github-actions/invalid-trusted-actions-policy",
        path: path,
        symbol: "trusted_actions",
        line: 1,
        title: "Trusted-actions policy is not a closed exact allowlist",
        body: "Use a unique YAML sequence of exact owner/repository entries; wildcards, refs, paths, UNKNOWN, and aliases are invalid."
      )]]
    end

    def finding(rule_id:, path:, symbol:, line:, title:, body:)
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
        "location" => { "file" => relative, "line" => line, "symbol" => symbol }
      }
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end
  end
end
