# frozen_string_literal: true

require "digest"

require_relative "errors"
require_relative "provider"
require_relative "registry"
require_relative "secure_paths"
require_relative "state"
require_relative "store"
require_relative "tree"

module AgentWorkflowsOperation
  class Runner
    attr_reader :target, :state, :store

    def initialize(target:)
      @target = File.expand_path(target)
      @state = State.new(target: @target)
      @store = Store.new(state_root: state.root)
    rescue PathError => e
      raise RunnerError, e.message
    end

    def launch!(handle:, capability:, arguments:)
      operation_root, metadata, snapshot, = validated_operation!(handle, capability)
      launcher = File.join(operation_root, "launcher")
      verify_executable_identity!(launcher, metadata.fetch("launcher"), "operation launcher")
      verify_runtime!(operation_root, metadata, snapshot)
      command = [
        launcher,
        "--target", target,
        "--operation", handle,
        capability,
        "--",
        *arguments
      ]
      verify_runtime!(operation_root, metadata, snapshot)
      verify_executable_identity!(launcher, metadata.fetch("launcher"), "operation launcher")
      exec(*command)
    rescue KeyError => e
      raise RunnerError, "operation metadata is incomplete: #{e.message}"
    end

    def run!(handle:, capability:, arguments:)
      operation_root, metadata, snapshot, registry = validated_operation!(handle, capability)
      definition = registry.capability!(capability)
      if definition.requires_current_provider && metadata["freshness"] != "current"
        raise RunnerError, "CURRENT_PROVIDER_REQUIRED: #{capability} is unavailable in degraded/offline operations"
      end

      begin
        Provider.new(
          host: metadata.dig("provider", "host"),
          target: target,
          snapshot: snapshot
        ).verify!(expected_revision: metadata.fetch("revision"))
      rescue ProviderError => e
        raise RunnerError, "provider moved after operation begin: #{e.message}"
      end

      executable = File.join(operation_root, "capabilities", capability)
      recorded = metadata.fetch("capabilities").fetch(capability)
      verify_executable_identity!(executable, recorded, "capability inode")
      Tree.verify_path_against_git!(
        git: store.git,
        repository: snapshot.repository,
        revision: snapshot.revision,
        path: executable,
        source_relative: recorded.fetch("source"),
        private_home: File.join(snapshot.root, "home")
      )
      verify_executable_identity!(executable, recorded, "canonical executable")
      exec(executable, *arguments)
    rescue KeyError, RegistryError => e
      raise RunnerError, "operation capability binding is invalid: #{e.message}"
    rescue StoreError => e
      raise RunnerError, "canonical executable verification failed: #{e.message}"
    end

    private

    def validated_operation!(handle, capability)
      operation_root, metadata = state.load_operation!(handle)
      revision = metadata["revision"]
      snapshot = store.open!(revision)
      registry = Registry.load!(snapshot)
      registry.capability!(capability)
      unless metadata.dig("provider", "target") == target
        raise RunnerError, "operation provider target does not match this installed runner"
      end

      [operation_root, metadata, snapshot, registry]
    rescue StoreError => e
      raise RunnerError, "operation is not bound to a valid canonical content store: #{e.message}"
    end

    def verify_executable_identity!(path, recorded, label)
      stat = SecurePaths.verify_private_file!(path, mode: 0o500)
      unless stat.dev == recorded["device"] && stat.ino == recorded["inode"] &&
             stat.size == recorded["size"]
        raise RunnerError, "#{label} does not match the published operation inode"
      end

      digest = Digest::SHA256.file(path).hexdigest
      raise RunnerError, "#{label} does not match the published operation hash" unless digest == recorded["sha256"]
    rescue PathError => e
      raise RunnerError, "#{label} is unsafe: #{e.message}"
    end

    def verify_runtime!(operation_root, metadata, snapshot)
      runtime = metadata.fetch("runtime")
      raise RunnerError, "operation runtime binding must be a nonempty object" unless runtime.is_a?(Hash) && !runtime.empty?

      runtime.each do |name, recorded|
        unless name.match?(/\A[a-z_]+\.rb\z/) && recorded.is_a?(Hash)
          raise RunnerError, "operation runtime binding is malformed"
        end

        path = File.join(operation_root, "runtime", name)
        verify_file_identity!(path, recorded, "operation runtime #{name}")
        Tree.verify_path_against_git!(
          git: store.git,
          repository: snapshot.repository,
          revision: snapshot.revision,
          path: path,
          source_relative: recorded.fetch("source"),
          private_home: File.join(snapshot.root, "home")
        )
      end
    rescue KeyError, StoreError => e
      raise RunnerError, "operation runtime does not match canonical content: #{e.message}"
    end

    def verify_file_identity!(path, recorded, label)
      stat = SecurePaths.verify_private_file!(path, mode: 0o400)
      unless stat.dev == recorded["device"] && stat.ino == recorded["inode"] &&
             stat.size == recorded["size"]
        raise RunnerError, "#{label} does not match the published operation inode"
      end

      digest = Digest::SHA256.file(path).hexdigest
      raise RunnerError, "#{label} does not match the published operation hash" unless digest == recorded["sha256"]
    rescue PathError => e
      raise RunnerError, "#{label} is unsafe: #{e.message}"
    end
  end
end
