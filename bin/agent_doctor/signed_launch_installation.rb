# frozen_string_literal: true

require "json"

module AgentDoctor
  module SignedLaunchInstallation
    METADATA_FILE = ".agent-workflows-install.json"
    METADATA_KEYS = %w[
      delivery_mode host installed_at mode source source_branch source_remote source_revision version
    ].freeze

    module_function

    def resolve(helper_path:, relative_helper_path:)
      lexical_helper = File.expand_path(helper_path)
      physical_helper = File.realpath(helper_path)
      lexical_root = root_for(lexical_helper, relative_helper_path)
      physical_root = root_for(physical_helper, relative_helper_path)
      return unless lexical_root && physical_root
      return unless File.realpath(lexical_root) == lexical_root

      root_stat = File.lstat(lexical_root)
      return unless safe_directory_stat?(root_stat, root_stat.uid)

      return unless lexical_helper == physical_helper ||
                    valid_symlink_install?(
                      root: lexical_root,
                      physical_root:,
                      relative_helper_path:,
                      owner_uid: root_stat.uid
                    )

      { "root" => lexical_root, "owner_uid" => root_stat.uid }
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

    def valid_symlink_install?(root:, physical_root:, relative_helper_path:, owner_uid:)
      components = relative_helper_path.split("/")
      return false unless components.first == "skills" && components.length >= 4

      skill_name = components.fetch(1)
      skills_root = File.join(root, "skills")
      bin_root = File.join(root, "bin")
      agents_root = File.join(root, ".agents")
      return false unless [skills_root, bin_root, agents_root].all? do |directory|
        safe_directory?(directory, owner_uid)
      end

      skill_link = File.join(skills_root, skill_name)
      doctor_link = File.join(bin_root, "agent_doctor")
      return false unless exact_symlink?(skill_link, File.join(physical_root, "skills", skill_name))
      return false unless exact_symlink?(doctor_link, File.join(physical_root, "bin", "agent_doctor"))

      metadata = read_metadata(File.join(root, METADATA_FILE), owner_uid)
      metadata &&
        metadata.keys.sort == METADATA_KEYS &&
        metadata["mode"] == "symlink" &&
        metadata["delivery_mode"] == "flat" &&
        %w[codex claude].include?(metadata["host"]) &&
        metadata["source"].is_a?(String) &&
        File.absolute_path(metadata["source"]) == metadata["source"] &&
        File.realpath(metadata["source"]) == physical_root
    end
    private_class_method :valid_symlink_install?

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
