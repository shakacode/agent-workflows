# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "securerandom"

require_relative "errors"

module AgentWorkflowsOperation
  module SecurePaths
    PLATFORM_DIRECTORY_ALIASES = {
      "/tmp" => "/private/tmp",
      "/var" => "/private/var"
    }.freeze

    module_function

    def prepare_state_root!(target)
      target = File.expand_path(target)
      verify_target_ancestors!(target)
      root = File.join(target, ".agent-workflows-operation-state")
      ensure_private_directory!(root)
      %w[quarantine store staging operations].each do |name|
        ensure_private_directory!(File.join(root, name))
      end
      root
    end

    def verify_target_ancestors!(target)
      raise PathError, "provider target is not a directory: #{target}" unless File.directory?(target)

      components = target.split(File::SEPARATOR).reject(&:empty?)
      current = File::SEPARATOR
      components.each_with_index do |component, index|
        current = File.join(current, component)
        stat = File.lstat(current)
        if stat.symlink?
          next if platform_directory_alias?(current, index)

          raise PathError, "provider target traverses a symlink: #{current}"
        end
        raise PathError, "provider target ancestor is not a directory: #{current}" unless stat.directory?
        next if safe_ancestor?(stat)

        raise PathError, "provider target ancestor has unsafe ownership or mode: #{current}"
      end
      stat = File.lstat(target)
      raise PathError, "provider target must be owned by uid #{Process.uid}: #{target}" unless stat.uid == Process.uid
      raise PathError, "provider target must not be group/world writable: #{target}" unless (stat.mode & 0o022).zero?
    rescue SystemCallError => e
      raise PathError, "unable to validate provider target: #{e.message}"
    end

    def safe_ancestor?(stat)
      return true if [0, Process.uid].include?(stat.uid) && (stat.mode & 0o022).zero?

      stat.uid.zero? && (stat.mode & 0o1000).positive?
    end

    def platform_directory_alias?(path, index, link_target = File.readlink(path))
      index.zero? &&
        PLATFORM_DIRECTORY_ALIASES[path] == File.expand_path(link_target, File.dirname(path))
    end

    def ensure_private_directory!(path)
      unless File.exist?(path) || File.symlink?(path)
        begin
          Dir.mkdir(path, 0o700)
        rescue Errno::EEXIST
          # A concurrent creator may win the race; verify the directory it created.
        end
      end

      verify_private_directory!(path)
      path
    rescue SystemCallError => e
      raise PathError, "unable to create private state directory #{path}: #{e.message}"
    end

    def verify_private_directory!(path)
      stat = File.lstat(path)
      raise PathError, "private state path is a symlink: #{path}" if stat.symlink?
      raise PathError, "private state path is not a directory: #{path}" unless stat.directory?
      raise PathError, "private state path has wrong owner: #{path}" unless stat.uid == Process.uid
      raise PathError, "private state directory must have mode 0700: #{path}" unless (stat.mode & 0o777) == 0o700

      stat
    rescue SystemCallError => e
      raise PathError, "unable to validate private state directory #{path}: #{e.message}"
    end

    def verify_private_file!(path, mode:)
      stat = File.lstat(path)
      raise PathError, "private state file is a symlink: #{path}" if stat.symlink?
      raise PathError, "private state path is not a file: #{path}" unless stat.file?
      raise PathError, "private state file has wrong owner: #{path}" unless stat.uid == Process.uid
      unless (stat.mode & 0o777) == mode
        raise PathError, "private state file must have mode #{format('%04o', mode)}: #{path}"
      end

      stat
    rescue SystemCallError => e
      raise PathError, "unable to validate private state file #{path}: #{e.message}"
    end

    def write_json!(path, payload, mode: 0o600)
      parent = File.dirname(path)
      verify_private_directory!(parent)
      temporary = File.join(parent, ".#{File.basename(path)}.#{SecureRandom.hex(12)}")
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(temporary, flags, mode) do |file|
        file.write(JSON.pretty_generate(payload))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.chmod(mode, temporary)
      File.rename(temporary, path)
      verify_private_file!(path, mode: mode)
    rescue SystemCallError => e
      FileUtils.rm_f(temporary) if defined?(temporary)
      raise PathError, "unable to publish private state file #{path}: #{e.message}"
    end

    def owned_identity(path)
      stat = File.lstat(path)
      [stat.dev, stat.ino, stat.uid, stat.ftype]
    end

    def cleanup_owned_directory!(path, identity)
      current = owned_identity(path)
      unless current == identity && current[2] == Process.uid && current[3] == "directory"
        raise CleanupError, "refusing cleanup because staging identity changed: #{path}"
      end

      Find.find(path) do |entry|
        stat = File.lstat(entry)
        next if stat.symlink?

        File.chmod(stat.directory? ? 0o700 : 0o600, entry)
      end
      FileUtils.remove_entry_secure(path)
    rescue Errno::ENOENT
      nil
    rescue CleanupError
      raise
    rescue SystemCallError => e
      raise CleanupError, "unable to clean owned staging directory #{path}: #{e.message}"
    end

    def safe_relative_path!(path, label:)
      unless path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.include?("\0")
        raise RegistryError, "#{label} must be a nonempty relative path"
      end

      components = path.split("/")
      if components.any? { |component| component.empty? || component == "." || component == ".." }
        raise RegistryError, "#{label} contains traversal or empty components: #{path}"
      end

      path
    end
  end
end
