# frozen_string_literal: true

require "open3"
require "psych"

module SecureGitHubActions
  EXCLUDED_ACTION_ROOTS = %w[.codex .git .tmp tmp].freeze

  def self.excluded_action_root?(root, relative, lstat: File.method(:lstat))
    return false if relative.empty? || relative == "."

    root_segment = relative.split("/", 2).first
    return true if EXCLUDED_ACTION_ROOTS.include?(root_segment)

    normalized = root_segment.downcase
    return false unless EXCLUDED_ACTION_ROOTS.include?(normalized)

    resolved_root = File.realpath(root)
    begin
      normalized_path = File.join(resolved_root, normalized)
      normalized_stat = lstat.call(normalized_path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      return false
    end
    return false unless normalized_stat.directory? && !normalized_stat.symlink?

    candidate_path = File.join(resolved_root, root_segment)
    candidate_stat = lstat.call(candidate_path)
    return false unless candidate_stat.directory? && !candidate_stat.symlink?

    normalized_canonical = File.realpath(normalized_path)
    candidate_canonical = File.realpath(candidate_path)
    return false unless File.dirname(normalized_canonical) == resolved_root
    return false unless File.dirname(candidate_canonical) == resolved_root

    candidate_canonical == normalized_canonical
  rescue SystemCallError
    true
  end

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
    ACTION_DESCRIPTORS = %w[action.yml action.yaml].freeze
    PATH_ENCODING = Encoding::UTF_8
    DIRECTORY_ENUMERATION_PERMISSIONS = [0o500, 0o050, 0o005].freeze
    DESCRIPTOR_REVIEWABLE = :reviewable
    DESCRIPTOR_NOT_REVIEWABLE = :not_reviewable
    DESCRIPTOR_MEMBERSHIP_UNSTABLE = :membership_unstable

    def initialize(root)
      @root = File.realpath(root).dup.force_encoding(PATH_ENCODING)
      raise ArgumentError, "consumer root path has invalid encoding" unless @root.valid_encoding?
      raise ArgumentError, "consumer root must be a directory" unless File.directory?(@root)

      @root_parent = File.realpath(File.dirname(@root))
      @root_name = File.basename(@root)
      root_stat = File.lstat(File.join(@root_parent, @root_name))
      @root_identity = [root_stat.dev, root_stat.ino]
    end

    def scan
      unless root_entry_bound?
        return Result.new(root: @root, files: [], findings: [unsafe_action_discovery_finding(@root)])
      end

      workflow_boundary_findings = input_boundary_findings
      workflow_paths = if workflow_boundary_findings.empty?
                         Dir.glob(
                           ".github/workflows/*.{yml,yaml}", File::FNM_DOTMATCH, base: @root
                         ).map { |relative| File.join(@root, relative) }
                       else
                         []
                       end
      action_paths, action_discovery_findings = discover_action_paths
      paths = (workflow_paths + action_paths).uniq.sort
      @scan_queue = paths.dup
      @queued_paths = paths.to_h { |path| [path, true] }
      scanned_paths = []
      @trusted_actions, policy_findings = load_trusted_actions
      findings = policy_findings + workflow_boundary_findings + action_discovery_findings
      until @scan_queue.empty?
        path = @scan_queue.shift
        scanned_paths << path
        findings.concat(scan_workflow(path))
      end
      findings.uniq! { |finding| finding.fetch("id") }
      Result.new(root: @root, files: scanned_paths.map { |path| relative_path(path) }.sort, findings: findings)
    end

    private

    def root_entry_bound?
      resolved_parent = File.realpath(File.dirname(@root))
      return false unless resolved_parent == @root_parent

      entry_path = File.join(resolved_parent, @root_name)
      resolved_entry = File.realpath(entry_path)
      return false unless File.dirname(resolved_entry) == resolved_parent

      stat = File.lstat(entry_path)
      stat.directory? && !stat.symlink? && [stat.dev, stat.ino] == @root_identity
    rescue SystemCallError
      false
    end

    def input_boundary_findings
      [".github", ".github/workflows"].each do |relative|
        path = File.join(@root, relative)
        next unless File.exist?(path) || File.symlink?(path)

        stat = File.lstat(path)
        if stat.directory? && !stat.symlink?
          safe_permissions = if relative == ".github/workflows"
                               directory_enumerable?(path, stat)
                             else
                               File.executable?(path)
                             end
          next if safe_permissions
        end

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

    def directory_enumerable?(path, stat)
      permission_bits = stat.mode
      explicit_enumeration_permission = DIRECTORY_ENUMERATION_PERMISSIONS.any? do |permission|
        (permission_bits & permission) == permission
      end
      explicit_enumeration_permission && File.readable?(path) && File.executable?(path)
    end

    def discover_action_paths
      paths = []
      reviewable_paths = git_reviewable_paths
      findings = if reviewable_paths
                   reviewable_paths.fetch(:identity_errors).map do |relative|
                     unsafe_action_discovery_finding(File.join(@root, relative))
                   end
                 else
                   []
                 end
      directories = [@root]
      until directories.empty?
        directory = directories.shift
        begin
          relative = relative_path(directory)
          next if directory != @root && excluded_action_root?(relative)

          stat = File.lstat(directory)
          unless stat.directory? && !stat.symlink?
            findings << unsafe_action_discovery_finding(directory)
            next
          end

          unless directory_enumerable?(directory, stat)
            findings << unsafe_action_discovery_finding(directory)
            next
          end

          entries = Dir.children(directory).filter_map do |entry|
            normalized_entry = normalize_path_encoding(entry)
            if normalized_entry
              normalized_entry
            else
              findings << unsafe_action_discovery_finding(directory)
              nil
            end
          end.sort
          entries.each do |entry|
            path = File.join(directory, entry)
            begin
              child_relative = relative_path(path)
              next if excluded_action_root?(child_relative)

              child_stat = File.lstat(path)
              if reviewable_directory_path?(reviewable_paths, child_relative, child_stat) &&
                 (!child_stat.directory? || child_stat.symlink?)
                findings << unsafe_action_discovery_finding(path)
                next
              end

              if child_stat.directory? && !child_stat.symlink?
                next if ignored_unreviewable_directory?(reviewable_paths, child_relative, child_stat)

                directories << path
              else
                descriptor_state = reviewable_descriptor_state(
                  reviewable_paths, child_relative, directory, stat, entries, entry, child_stat
                )
                if descriptor_state == DESCRIPTOR_MEMBERSHIP_UNSTABLE
                  findings << unsafe_action_descriptor_finding(path)
                  next
                end
                reviewable_descriptor = descriptor_state == DESCRIPTOR_REVIEWABLE
                next unless ACTION_DESCRIPTORS.include?(entry) || reviewable_descriptor
                next if reviewable_paths && !reviewable_descriptor && git_ignored_path?(child_relative)

                if child_stat.file? && !child_stat.symlink?
                  paths << path
                else
                  findings << unsafe_action_descriptor_finding(path)
                end
              end
            rescue SystemCallError
              findings << unsafe_action_discovery_finding(path)
            end
          end
        rescue SystemCallError
          findings << unsafe_action_discovery_finding(directory)
        end
      end
      [paths, findings]
    end

    def git_reviewable_paths
      stdout, _stderr, status = Open3.capture3(
        "git", "-C", @root, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--",
        binmode: true
      )
      return nil unless status.success?

      descriptors = {}
      directories = {}
      invalid_path_encoding = false
      stdout.split("\0").each do |raw_relative|
        next if raw_relative.empty?

        relative = normalize_path_encoding(raw_relative)
        unless relative
          invalid_path_encoding = true
          next
        end
        next if relative.start_with?("../") || relative.start_with?("/")

        descriptors[relative] = true if ACTION_DESCRIPTORS.include?(File.basename(relative))
        directory = File.dirname(relative)
        until directory == "."
          directories[directory] = true
          parent = File.dirname(directory)
          break if parent == directory

          directory = parent
        end
      end
      paths = { descriptors: descriptors, directories: directories }
      directory_identities = {}
      descriptor_names_by_parent = Hash.new { |entries, identity| entries[identity] = [] }
      identity_errors = invalid_path_encoding ? ["."] : []
      directories.each_key do |relative|
        stat = reviewable_path_lstat(relative)
        directory_identities[[stat.dev, stat.ino]] = true if stat
      rescue Errno::ENOENT, Errno::ENOTDIR
        next
      rescue SystemCallError
        identity_errors << relative
      end
      descriptors.each_key do |relative|
        basename = File.basename(relative)
        parent = File.dirname(relative)
        begin
          stat = reviewable_path_lstat(parent)
          next unless stat&.directory? && !stat.symlink?

          descriptor_names_by_parent[[stat.dev, stat.ino]] << basename
        rescue Errno::ENOENT, Errno::ENOTDIR
          next
        rescue SystemCallError
          identity_errors << relative
        end
      end
      paths.merge(
        directory_identities: directory_identities,
        descriptor_names_by_parent: descriptor_names_by_parent.transform_values { |names| names.uniq.freeze },
        identity_errors: identity_errors.uniq
      )
    rescue SystemCallError
      nil
    end

    def normalize_path_encoding(path)
      normalized = path.dup.force_encoding(@root.encoding)
      normalized if normalized.valid_encoding?
    end

    def reviewable_path_lstat(relative)
      current = @root
      segments = relative.split("/")
      segments.each_with_index do |segment, index|
        current = File.join(current, segment)
        stat = File.lstat(current)
        return stat if index == segments.length - 1
        return nil unless stat.directory? && !stat.symlink?
      end
      nil
    end

    def reviewable_directory_path?(reviewable_paths, relative, stat)
      return false unless reviewable_paths
      return true if reviewable_paths.fetch(:directories)[relative]

      reviewable_paths.fetch(:directory_identities)[[stat.dev, stat.ino]]
    end

    def reviewable_descriptor_state(reviewable_paths, relative, directory, directory_stat, entries, entry, stat)
      return DESCRIPTOR_NOT_REVIEWABLE unless reviewable_paths
      return DESCRIPTOR_REVIEWABLE if reviewable_paths.fetch(:descriptors)[relative]

      names = reviewable_paths.fetch(:descriptor_names_by_parent)[[directory_stat.dev, directory_stat.ino]]
      return DESCRIPTOR_NOT_REVIEWABLE unless names

      mismatched_candidate = false
      names.each do |name|
        return DESCRIPTOR_REVIEWABLE if name == entry
        next if entries.include?(name)

        listed_stat = File.lstat(File.join(directory, name))
        return DESCRIPTOR_REVIEWABLE if [listed_stat.dev, listed_stat.ino] == [stat.dev, stat.ino]

        mismatched_candidate = true
      rescue Errno::ENOENT, Errno::ENOTDIR
        next
      end
      mismatched_candidate ? DESCRIPTOR_MEMBERSHIP_UNSTABLE : DESCRIPTOR_NOT_REVIEWABLE
    end

    def ignored_unreviewable_directory?(reviewable_paths, relative, stat)
      return false unless reviewable_paths
      return false if reviewable_directory_path?(reviewable_paths, relative, stat)

      git_ignored_path?(relative)
    end

    def git_ignored_path?(relative)
      _stdout, _stderr, status = Open3.capture3(
        "git", "-C", @root, "check-ignore", "--quiet", "--", relative,
        binmode: true
      )
      status.success?
    rescue SystemCallError
      false
    end

    def unsafe_action_discovery_finding(path)
      finding(
        rule_id: "secure-github-actions/unsafe-file",
        path: path,
        symbol: "<directory>",
        line: 1,
        title: "Local action discovery boundary could not be enumerated safely",
        body: "Use readable, traversable, non-symlink repository directories so composite actions cannot be omitted from the security scan."
      )
    end

    def unsafe_action_descriptor_finding(path)
      finding(
        rule_id: "secure-github-actions/unsafe-file",
        path: path,
        symbol: "<document>",
        line: 1,
        title: "Local action descriptor is outside the safe file boundary",
        body: "Use a regular, non-symlink action.yml or action.yaml file within real repository directories."
      )
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
      when Psych::Nodes::Alias
        yaml_indirection_findings(node, path, keys)
      when Psych::Nodes::Mapping
        node.children.each_slice(2).flat_map do |key, value|
          unless key.is_a?(Psych::Nodes::Scalar)
            key_name = "<non-scalar-key@#{key.start_line + 1}:#{key.start_column + 1}>"
            symbol = (keys + [key_name]).join(".")
            key_findings = unsupported_mapping_key_findings(key, path, symbol)
            next key_findings + scan_node(value, path, keys + [key_name], lines)
          end

          key_name = key.value
          symbol = (keys + [key_name]).join(".")
          if sensitive_yaml_merge?(key_name, keys)
            next yaml_indirection_findings(key, path, keys + [key_name])
          end

          findings = if sensitive_position?(key_name, keys)
                       shape_findings(key_name, value, path, symbol) +
                         scalar_findings(key_name, value, path, symbol, lines, keys)
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

    def unsupported_mapping_key_findings(node, path, symbol)
      [finding(
        rule_id: "secure-github-actions/unsupported-yaml-mapping-key",
        path: path,
        symbol: symbol,
        line: node.start_line + 1,
        title: "GitHub Actions YAML uses a non-scalar mapping key",
        body: "Replace alias, sequence, or mapping keys with explicit scalar keys so security-sensitive fields cannot be hidden."
      )]
    end

    def yaml_indirection_findings(node, path, keys)
      return [] unless sensitive_alias_destination?(keys)

      [finding(
        rule_id: "secure-github-actions/unsupported-yaml-alias",
        path: path,
        symbol: keys.join("."),
        line: node.start_line + 1,
        title: "YAML indirection enters a security-sensitive GitHub Actions boundary",
        body: "Expand the aliased or merged job or step mapping explicitly so run, uses, and secrets checks remain destination-bound."
      )]
    end

    def sensitive_yaml_merge?(key_name, keys)
      key_name == "<<" && sensitive_alias_destination?(keys + [key_name])
    end

    def sensitive_alias_destination?(keys)
      return true if keys.first == "<<"
      return true if [["jobs"], ["runs"]].include?(keys)

      if keys.first == "jobs"
        return true if keys[1] == "<<"
        return true if keys.length == 2
        return true if keys.length >= 3 && keys[2] == "<<"
        return true if keys.length == 3 && keys[2] == "steps"
        return true if keys.length == 4 && keys[2] == "steps" && keys[3].is_a?(Integer)
        return true if keys.length >= 5 && keys[2] == "steps" && keys[3].is_a?(Integer) && keys[4] == "<<"
      end

      return false unless keys.first == "runs"
      return true if keys[1] == "<<"
      return true if keys.length == 2 && keys[1] == "steps"
      return true if keys.length == 3 && keys[1] == "steps" && keys[2].is_a?(Integer)

      keys.length >= 4 && keys[1] == "steps" && keys[2].is_a?(Integer) && keys[3] == "<<"
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

    def scalar_findings(key_name, value, path, symbol, lines, keys)
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
         (!safe_local_use?(value.value) || !safe_local_target?(value.value, keys))
        findings << finding(
          rule_id: "secure-github-actions/unsafe-local-use",
          path: path,
          symbol: symbol,
          line: value.start_line + 1,
          title: "Local GitHub Actions reference is outside its safe input boundary",
          body: "Use a regular local workflow file for job-level uses, or a regular action directory and descriptor for step-level uses; excluded roots, traversal, missing targets, and symlinks are rejected."
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
      return true if reference == "./"
      return false unless reference.match?(%r{\A\./[^\s@\\]+\z})

      reference.split("/").drop(1).none? { |segment| segment.empty? || %w[. ..].include?(segment) }
    end

    def safe_local_target?(reference, keys)
      relative = reference.delete_prefix("./")
      return false if excluded_action_root?(relative)

      segments = relative.split("/")
      if job_level_use_position?(keys)
        safe_local_workflow_file?(reference, segments)
      else
        safe_local_action_directory?(segments)
      end
    rescue SystemCallError
      false
    end

    def job_level_use_position?(keys)
      keys.length == 2 && keys[0] == "jobs"
    end

    def safe_local_workflow_file?(reference, segments)
      return false unless reference.match?(%r{\A\./\.github/workflows/[^/]+\.ya?ml\z})

      current = safe_directory_path(segments[0...-1])
      return false unless current

      stat = File.lstat(File.join(current, segments.last))
      stat.file? && !stat.symlink?
    end

    def safe_local_action_directory?(segments)
      directory = safe_directory_path(segments)
      return false unless directory

      descriptors = ACTION_DESCRIPTORS.map { |name| File.join(directory, name) }
                                      .select { |path| File.exist?(path) || File.symlink?(path) }
      return false if descriptors.empty?

      safe = descriptors.all? do |path|
        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      end
      descriptors.each { |path| enqueue_scan_path(path) } if safe
      safe
    end

    def enqueue_scan_path(path)
      return if @queued_paths[path]

      @queued_paths[path] = true
      @scan_queue << path
    end

    def safe_directory_path(segments)
      current = @root
      segments.each do |segment|
        current = File.join(current, segment)
        stat = File.lstat(current)
        return nil unless stat.directory? && !stat.symlink?
      end
      current
    end

    def excluded_action_root?(relative)
      SecureGitHubActions.excluded_action_root?(@root, relative)
    end

    def external_use?(reference)
      !reference.start_with?("./") && !reference.start_with?("docker://")
    end

    def readable_version_comment?(node, lines)
      suffix = lines.fetch(node.end_line, "")[node.end_column..].to_s
      suffix.match?(/\A(?:[ \t]*[},\]])*[ \t]+#[ \t]*[A-Za-z0-9][^\r\n]*\z/)
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
      return invalid_trusted_actions(path) if policy_indirection?(root)
      return invalid_trusted_actions(path) unless root.children.each_slice(2).all? do |key, _value|
        key.is_a?(Psych::Nodes::Scalar)
      end

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
      return invalid_trusted_actions(path) unless valid

      normalized = entries.map { |entry| entry.value.downcase }
      return invalid_trusted_actions(path) unless normalized.uniq.length == normalized.length

      [normalized.freeze, []]
    rescue Psych::Exception, EncodingError, SystemCallError, UnsafeFileError
      invalid_trusted_actions(path)
    end

    def policy_indirection?(node)
      return true if node.is_a?(Psych::Nodes::Alias)

      return true if node.is_a?(Psych::Nodes::Mapping) &&
                     node.children.each_slice(2).any? { |key, _value| yaml_merge_key?(key) }

      node.respond_to?(:children) && node.children&.any? { |child| policy_indirection?(child) }
    end

    def yaml_merge_key?(node)
      node.is_a?(Psych::Nodes::Scalar) &&
        (node.tag == "tag:yaml.org,2002:merge" || (node.plain && node.value == "<<"))
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
      return "." if path == @root

      path.delete_prefix("#{@root}/")
    end
  end
end
