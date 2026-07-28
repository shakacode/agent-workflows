# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

require_relative "errors"
require_relative "secure_paths"

module AgentWorkflowsOperation
  class State
    HANDLE_PATTERN = /\A[0-9a-f]{64}\z/

    attr_reader :root, :target

    def initialize(target:)
      @target = File.expand_path(target)
      @root = SecurePaths.prepare_state_root!(@target)
    end

    def publish_operation!(snapshot:, registry:, provider:, freshness:)
      staging_parent = File.join(root, "staging")
      operations = File.join(root, "operations")
      SecurePaths.verify_private_directory!(staging_parent)
      SecurePaths.verify_private_directory!(operations)
      handle = unique_handle(operations)
      stage = File.join(staging_parent, ".operation-#{SecureRandom.hex(24)}")
      Dir.mkdir(stage, 0o700)
      identity = SecurePaths.owned_identity(stage)
      published = false
      begin
        runtime = File.join(stage, "runtime")
        capabilities = File.join(stage, "capabilities")
        Dir.mkdir(runtime, 0o700)
        Dir.mkdir(capabilities, 0o700)
        runtime_state = copy_runtime!(snapshot, runtime)
        launcher_path = File.join(stage, "launcher")
        copy_private_executable!(
          File.join(snapshot.tree, "bin/agent-workflows-operation-launcher"),
          launcher_path
        )
        capability_state = registry.capabilities.to_h do |name, capability|
          [name, copy_capability_bundle!(snapshot, capabilities, capability)]
        end
        interpreter = external_executable_identity!(RbConfig.ruby, "Ruby interpreter")
        environment = external_executable_identity!(trusted_env_executable!, "environment launcher")
        tools = {
          "git" => external_executable_identity!(store_git_executable, "Git executable")
        }
        if provider["gh_executable"]
          tools["gh"] = external_executable_identity!(provider.fetch("gh_executable"), "gh executable")
        end
        metadata = {
          "schema_version" => 1,
          "operation" => handle,
          "revision" => snapshot.revision,
          "freshness" => freshness,
          "provider" => provider,
          "interpreter" => interpreter,
          "environment" => environment,
          "tools" => tools,
          "launcher" => executable_identity(launcher_path),
          "runtime" => runtime_state,
          "capabilities" => capability_state
        }
        SecurePaths.write_json!(File.join(stage, "operation.json"), metadata)
        destination = File.join(operations, handle)
        File.rename(stage, destination)
        published = true
        load_operation!(handle)
        operation_result(
          handle, snapshot, registry, freshness, provider.fetch("profile"), provider.fetch("host"),
          interpreter:, environment:, capability_state:
        )
      ensure
        SecurePaths.cleanup_owned_directory!(stage, identity) unless published
      end
    rescue SystemCallError => e
      raise ResolverError, "unable to publish operation: #{e.message}"
    end

    def load_operation!(handle)
      raise RunnerError, "operation handle must be an opaque 64-hex value" unless handle.to_s.match?(HANDLE_PATTERN)

      operation_root = File.join(root, "operations", handle)
      SecurePaths.verify_private_directory!(root)
      SecurePaths.verify_private_directory!(File.join(root, "operations"))
      SecurePaths.verify_private_directory!(operation_root)
      SecurePaths.verify_private_directory!(File.join(operation_root, "runtime"))
      SecurePaths.verify_private_directory!(File.join(operation_root, "capabilities"))
      metadata_path = File.join(operation_root, "operation.json")
      SecurePaths.verify_private_file!(metadata_path, mode: 0o600)
      metadata = JSON.parse(File.binread(metadata_path))
      unless metadata.is_a?(Hash) && metadata["schema_version"] == 1 && metadata["operation"] == handle
        raise RunnerError, "operation metadata does not bind the requested handle"
      end

      [operation_root, metadata]
    rescue PathError, JSON::ParserError => e
      raise RunnerError, "operation state is invalid: #{e.message}"
    end

    private

    def unique_handle(operations)
      loop do
        handle = SecureRandom.hex(32)
        return handle unless File.exist?(File.join(operations, handle)) || File.symlink?(File.join(operations, handle))
      end
    end

    def copy_runtime!(snapshot, destination)
      source = File.join(snapshot.tree, "bin/agent_workflows_operation")
      raise ResolverError, "canonical snapshot is missing operation runtime" unless File.directory?(source)

      Dir.glob(File.join(source, "*.rb")).sort.to_h do |path|
        target = File.join(destination, File.basename(path))
        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o400) do |file|
          file.write(File.binread(path))
        end
        File.chmod(0o400, target)
        [File.basename(path), file_identity(target).merge(
          "source" => "bin/agent_workflows_operation/#{File.basename(path)}"
        )]
      end
    end

    def copy_private_executable!(source, destination)
      stat = File.lstat(source)
      raise ResolverError, "canonical operation executable is not a regular file: #{source}" unless stat.file? && !stat.symlink?

      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o500) do |file|
        file.write(File.binread(source))
        file.flush
        file.fsync
      end
      File.chmod(0o500, destination)
    end

    def copy_capability_bundle!(snapshot, capabilities_root, capability)
      bundle_root = File.join(capabilities_root, capability.name)
      Dir.mkdir(bundle_root, 0o700)
      runtime = capability.runtime.to_h do |role, source_relative|
        destination = File.join(bundle_root, source_relative)
        create_private_parent_directories!(bundle_root, File.dirname(destination))
        executable = source_relative == capability.executable
        copy_private_file!(
          File.join(snapshot.tree, source_relative),
          destination,
          mode: executable ? 0o500 : 0o400
        )
        identity = executable ? executable_identity(destination) : file_identity(destination)
        [role, identity.merge(
          "source" => source_relative,
          "path" => source_relative,
          "mode" => executable ? "0500" : "0400"
        )]
      end
      Find.find(bundle_root) do |path|
        File.chmod(0o500, path) if File.directory?(path)
      end
      digest = runtime_digest(runtime, bundle_root)
      {
        "executable_role" => capability.runtime.key(capability.executable),
        "runtime" => runtime,
        "digest" => digest,
        "provenance" => "provider-operation:#{snapshot.revision}:#{digest}"
      }
    end

    def create_private_parent_directories!(root, parent)
      relative = parent.delete_prefix("#{root}/")
      current = root
      return if relative == parent || relative == "."

      relative.split("/").each do |component|
        current = File.join(current, component)
        Dir.mkdir(current, 0o700) unless File.exist?(current)
      end
    end

    def copy_private_file!(source, destination, mode:)
      stat = File.lstat(source)
      unless stat.file? && !stat.symlink?
        raise ResolverError, "canonical capability runtime is not a regular file: #{source}"
      end

      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(File.binread(source))
        file.flush
        file.fsync
      end
      File.chmod(mode, destination)
    end

    def runtime_digest(runtime, bundle_root)
      digest = Digest::SHA256.new
      runtime.sort.each do |role, recorded|
        bytes = File.binread(File.join(bundle_root, recorded.fetch("path")))
        digest << [role.bytesize].pack("N") << role
        digest << [bytes.bytesize].pack("Q>") << bytes
      end
      digest.hexdigest
    end

    def executable_identity(path)
      stat = SecurePaths.verify_private_file!(path, mode: 0o500)
      identity_payload(stat, path)
    end

    def file_identity(path)
      stat = SecurePaths.verify_private_file!(path, mode: 0o400)
      identity_payload(stat, path)
    end

    def identity_payload(stat, path)
      {
        "device" => stat.dev,
        "inode" => stat.ino,
        "size" => stat.size,
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end

    def trusted_env_executable!
      %w[/usr/bin/env /bin/env].find { |path| File.file?(path) && File.executable?(path) } ||
        raise(ResolverError, "trusted absolute env executable is unavailable")
    end

    def external_executable_identity!(path, label)
      raise ResolverError, "#{label} path must be absolute" unless path.start_with?("/")

      resolved = File.realpath(path)
      stat = File.stat(resolved)
      unless stat.file? && (stat.uid == Process.uid || stat.uid.zero?)
        raise ResolverError, "#{label} must be a trusted regular file"
      end
      raise ResolverError, "#{label} must not be group/world writable" unless (stat.mode & 0o022).zero?
      raise ResolverError, "#{label} is not executable" unless (stat.mode & 0o111).positive?

      identity_payload(stat, resolved).merge("path" => resolved)
    rescue SystemCallError => e
      raise ResolverError, "#{label} is unavailable: #{e.message}"
    end

    def operation_result(
      handle, snapshot, registry, freshness, provider_profile, provider_host,
      interpreter:, environment:, capability_state:
    )
      asset_root = File.realpath(snapshot.tree)
      {
        "schema_version" => 1,
        "operation" => handle,
        "revision" => snapshot.revision,
        "freshness" => freshness,
        "provider_profile" => provider_profile,
        "assets" => {
          "root" => asset_root,
          "skill" => File.join(asset_root, registry.assets.fetch("skill")),
          "workflow" => File.join(asset_root, registry.assets.fetch("workflow")),
          "skills" => registry.assets.fetch("skills").transform_values do |path|
            File.join(asset_root, path)
          end,
          "related_workflows" => registry.assets.fetch("related_workflows").transform_values do |path|
            File.join(asset_root, path)
          end,
          "docs" => registry.assets.fetch("docs").transform_values { |path| File.join(asset_root, path) }
        },
        "capabilities" => registry.capabilities.keys.sort,
        "capability_provenance" => capability_state.transform_values { |binding| binding.fetch("provenance") },
        "runner" => startup_environment_command(environment.fetch("path")) + [
          interpreter.fetch("path"),
          "--disable=gems",
          File.join(target, "bin/agent-workflows-run"),
          "--operation",
          handle
        ],
        "release" => [
          File.join(target, "bin/agent-workflows-resolve"),
          "release",
          "--host", provider_host,
          "--target", target,
          "--operation", handle,
          "--json"
        ]
      }
    end

    def store_git_executable
      require_relative "secure_git"
      SecureGit.new.executable
    end

    def startup_environment_command(environment)
      %w[
        RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH
        GEM_HOME GEM_PATH
      ].each_with_object([environment]) do |name, command|
        command.concat(["-u", name])
      end
    end
  end
end
