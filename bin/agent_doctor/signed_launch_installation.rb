# frozen_string_literal: true

require "json"

module AgentDoctor
  module SignedLaunchInstallation
    METADATA_FILE = ".agent-workflows-install.json"
    METADATA_KEYS = %w[
      delivery_mode host installed_at mode source source_branch source_remote source_revision version
    ].freeze
    HOSTS = %w[codex claude].freeze

    module_function

    def resolve(helper_path:, relative_helper_path:, environment: ENV)
      lexical_helper = File.expand_path(helper_path)
      physical_helper = File.realpath(helper_path)
      lexical_root = root_for(lexical_helper, relative_helper_path)
      physical_root = root_for(physical_helper, relative_helper_path)
      return unless lexical_root && physical_root
      return unless File.realpath(lexical_root) == lexical_root

      root_stat = File.lstat(lexical_root)
      return unless safe_directory_stat?(root_stat, root_stat.uid)

      direct_helper = lexical_helper == physical_helper
      metadata = validated_flat_metadata(root: lexical_root, owner_uid: root_stat.uid, direct_helper:)
      companion = validated_plugin_companion(source_root: physical_root, environment:) if direct_helper && !metadata
      return companion if companion
      return unless direct_helper || valid_symlink_install?(
        root: lexical_root, physical_root:, relative_helper_path:, owner_uid: root_stat.uid, metadata:
      )

      { "root" => lexical_root, "owner_uid" => root_stat.uid,
        "host" => metadata&.fetch("host", nil), "delivery_mode" => metadata&.fetch("delivery_mode", nil) }
    rescue ArgumentError, JSON::ParserError, SystemCallError
      nil
    end

    def root_owner_uid(root)
      root = File.expand_path(root)
      return unless File.realpath(root) == root

      stat = File.lstat(root)
      stat.uid if safe_directory_stat?(stat, stat.uid)
    rescue ArgumentError, TypeError, SystemCallError
      nil
    end

    def root_for(path, relative_path)
      components = relative_path.split("/")
      return unless components.all? { |component| !component.empty? && component != "." && component != ".." }

      root = components.length.times.reduce(path) { |current, _index| File.dirname(current) }
      root if File.join(root, relative_path) == path
    end
    private_class_method :root_for

    def valid_symlink_install?(root:, physical_root:, relative_helper_path:, owner_uid:, metadata:)
      components = relative_helper_path.split("/")
      return false unless components.first == "skills" && components.length >= 4

      skill_name = components.fetch(1)
      skills_root = File.join(root, "skills")
      bin_root = File.join(root, "bin")
      return false unless [skills_root, bin_root, File.join(root, ".agents")].all? do |directory|
        safe_directory?(directory, owner_uid)
      end

      skill_link = File.join(skills_root, skill_name)
      doctor_link = File.join(bin_root, "agent_doctor")
      return false unless exact_symlink?(skill_link, File.join(physical_root, "skills", skill_name))
      return false unless exact_symlink?(doctor_link, File.join(physical_root, "bin", "agent_doctor"))

      metadata && metadata["mode"] == "symlink" && File.realpath(metadata["source"]) == physical_root
    end
    private_class_method :valid_symlink_install?

    def validated_flat_metadata(root:, owner_uid:, direct_helper:)
      metadata = read_metadata(File.join(root, METADATA_FILE), owner_uid)
      return unless metadata && metadata.keys.sort == METADATA_KEYS
      return unless HOSTS.include?(metadata["host"])
      return unless metadata["delivery_mode"] == "flat"
      return unless %w[copy symlink].include?(metadata["mode"])
      return unless metadata["source"].is_a?(String) &&
                    File.absolute_path(metadata["source"]) == metadata["source"]

      expected_mode = direct_helper ? "copy" : "symlink"
      return unless metadata["mode"] == expected_mode

      metadata
    rescue ArgumentError
      nil
    end
    private_class_method :validated_flat_metadata

    def validated_plugin_companion(source_root:, environment:)
      companions = HOSTS.filter_map do |host|
        validated_plugin_companion_for_host(host:, root: companion_root_for(host, environment), source_root:)
      end
      companions.one? ? companions.first : nil
    end
    private_class_method :validated_plugin_companion

    def validated_plugin_companion_for_host(host:, root:, source_root:)
      root = File.expand_path(root)
      return unless File.realpath(root) == root

      root_stat = File.lstat(root)
      owner_uid = root_stat.uid
      return unless safe_directory_stat?(root_stat, owner_uid)
      return unless safe_directory?(File.join(root, ".agents"), owner_uid)

      metadata = read_metadata(File.join(root, METADATA_FILE), owner_uid)
      return unless metadata && metadata.keys.sort == METADATA_KEYS
      return unless metadata["host"] == host
      return unless metadata["delivery_mode"] == "plugin-companion"
      return unless %w[copy symlink].include?(metadata["mode"])
      return unless metadata["source"].is_a?(String) &&
                    File.absolute_path(metadata["source"]) == metadata["source"] &&
                    File.realpath(metadata["source"]) == source_root

      { "root" => root, "owner_uid" => owner_uid, "host" => host,
        "delivery_mode" => metadata.fetch("delivery_mode") }
    rescue ArgumentError, SystemCallError
      nil
    end
    private_class_method :validated_plugin_companion_for_host

    def companion_root_for(host, environment)
      variable = host == "codex" ? "CODEX_HOME" : "CLAUDE_HOME"
      configured_root = environment[variable]
      return configured_root unless configured_root.nil? || configured_root.empty?

      File.join(environment.fetch("HOME", Dir.home), ".#{host}")
    end
    private_class_method :companion_root_for

    def safe_directory?(path, owner_uid)
      safe_directory_stat?(File.lstat(path), owner_uid)
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end
    private_class_method :safe_directory?

    def safe_directory_stat?(stat, owner_uid)
      stat.directory? && !stat.symlink? && stat.uid == owner_uid && (stat.mode & 0o022).zero?
    end
    private_class_method :safe_directory_stat?

    def exact_symlink?(path, expected_target)
      File.lstat(path).symlink? && File.realpath(path) == File.realpath(expected_target)
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end
    private_class_method :exact_symlink?

    def read_metadata(path, owner_uid)
      return unless File.const_defined?(:NOFOLLOW)

      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        next unless stat.file? && stat.uid == owner_uid && (stat.mode & 0o022).zero?

        contents = file.read.force_encoding("UTF-8")
        next unless contents.valid_encoding?

        record = JSON.parse(contents)
        record if record.is_a?(Hash)
      end
    rescue JSON::ParserError, SystemCallError
      nil
    end
    private_class_method :read_metadata
  end
end
