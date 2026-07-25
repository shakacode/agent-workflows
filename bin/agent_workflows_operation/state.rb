# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
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
          destination = File.join(capabilities, name)
          copy_private_executable!(File.join(snapshot.tree, capability.executable), destination)
          [name, executable_identity(destination).merge("source" => capability.executable)]
        end
        metadata = {
          "schema_version" => 1,
          "operation" => handle,
          "revision" => snapshot.revision,
          "freshness" => freshness,
          "provider" => provider,
          "launcher" => executable_identity(launcher_path),
          "runtime" => runtime_state,
          "capabilities" => capability_state
        }
        SecurePaths.write_json!(File.join(stage, "operation.json"), metadata)
        destination = File.join(operations, handle)
        File.rename(stage, destination)
        published = true
        load_operation!(handle)
        operation_result(handle, snapshot, registry, freshness)
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

    def operation_result(handle, snapshot, registry, freshness)
      asset_root = File.realpath(snapshot.tree)
      {
        "operation" => handle,
        "revision" => snapshot.revision,
        "freshness" => freshness,
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
        "runner" => [File.join(target, "bin/agent-workflows-run"), "--operation", handle]
      }
    end
  end
end
