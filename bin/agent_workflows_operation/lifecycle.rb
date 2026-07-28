# frozen_string_literal: true

require "json"
require "find"
require "digest"

require_relative "errors"
require_relative "provider"
require_relative "secure_paths"
require_relative "state"
require_relative "store"

module AgentWorkflowsOperation
  OperationReference = Data.define(:handle, :revision, :root)

  class Lifecycle
    MAX_LIVE_OPERATIONS = 32
    MAX_RETAINED_REVISIONS = 8

    attr_reader :host, :target, :state, :store

    def initialize(host:, target:, state:, store:)
      @host = host
      @target = File.expand_path(target)
      @state = state
      @store = store
    end

    def list!
      inventory = inventory!
      {
        "schema_version" => 1,
        "host" => host,
        "target" => target,
        "limits" => {
          "live_operations" => MAX_LIVE_OPERATIONS,
          "retained_revisions" => MAX_RETAINED_REVISIONS
        },
        "counts" => {
          "live_operations" => inventory.fetch(:operations).length,
          "retained_revisions" => inventory.fetch(:stores).length
        },
        "installed_revision" => inventory.fetch(:installed_revision),
        "operations" => inventory.fetch(:operations).map do |operation|
          { "handle" => operation.handle, "revision" => operation.revision }
        end,
        "retained_revisions" => inventory.fetch(:stores).keys.sort
      }
    end

    def release!(handle:)
      validate_handle!(handle)
      inventory = inventory!
      operation = inventory.fetch(:operations).find { |item| item.handle == handle }
      unless operation
        gc!
        return release_result(handle, "already_released")
      end

      identity = SecurePaths.owned_identity(operation.root)
      SecurePaths.cleanup_owned_directory!(operation.root, identity)
      begin
        gc!
      rescue Error => e
        raise ReleasedGcError,
              "RELEASED_GC_FAILED: operation #{handle} was released, but lifecycle GC failed: #{e.message}"
      end
      release_result(handle, "released")
    rescue PathError, RunnerError, StoreError, ProviderError, CleanupError => e
      raise ambiguous!(e)
    end

    def gc!(additional_protected: [])
      inventory = inventory!
      protected = inventory.fetch(:operations).map(&:revision)
      protected << inventory.fetch(:installed_revision) if inventory.fetch(:installed_revision)
      protected.concat(additional_protected)
      protected.compact!
      protected.uniq!

      store_candidates = inventory.fetch(:stores).filter_map do |revision, snapshot|
        next if protected.include?(revision)

        [snapshot.root, SecurePaths.owned_identity(snapshot.root)]
      end
      debris_candidates = debris_candidates!
      store_candidates.each { |path, identity| SecurePaths.cleanup_owned_directory!(path, identity) }
      debris_candidates.each { |path, identity| SecurePaths.cleanup_owned_directory!(path, identity) }
      inventory!
    rescue PathError, RunnerError, StoreError, ProviderError, CleanupError, LifecycleError => e
      raise ambiguous!(e)
    end

    def enforce_operation_capacity!(inventory)
      operations = inventory.fetch(:operations)
      return if operations.length < MAX_LIVE_OPERATIONS

      handles = operations.map(&:handle).sort
      raise CapacityError,
            "STATE_CAPACITY_REACHED: #{operations.length}/#{MAX_LIVE_OPERATIONS} live operations; " \
            "release named handles after their final shared use: #{handles.join(',')}"
    end

    def enforce_revision_capacity!(inventory, candidate_revision = nil)
      revisions = inventory.fetch(:operations).map(&:revision)
      revisions << inventory.fetch(:installed_revision) if inventory.fetch(:installed_revision)
      revisions << candidate_revision if candidate_revision
      revisions.compact!
      revisions.uniq!
      return if revisions.length <= MAX_RETAINED_REVISIONS

      handles = inventory.fetch(:operations).map(&:handle).sort
      raise CapacityError,
            "STATE_CAPACITY_REACHED: protected revisions require #{revisions.length}/" \
            "#{MAX_RETAINED_REVISIONS} retained snapshots: #{revisions.sort.join(',')}; " \
            "live handles: #{handles.join(',')}; release named handles only after final shared use"
    end

    def inventory!
      operations = scan_operations!
      stores = scan_stores!
      installed_revision = installed_revision!
      missing = operations.map(&:revision).uniq - stores.keys
      unless missing.empty?
        raise LifecycleError, "operation references missing retained revisions: #{missing.sort.join(',')}"
      end

      {
        operations: operations,
        stores: stores,
        installed_revision: installed_revision
      }
    rescue PathError, RunnerError, StoreError, ProviderError, JSON::ParserError => e
      raise ambiguous!(e)
    rescue LifecycleError => e
      raise e if e.message.start_with?("AMBIGUOUS_LIFECYCLE_STATE:")

      raise ambiguous!(e)
    end

    private

    def scan_operations!
      parent = File.join(state.root, "operations")
      SecurePaths.verify_private_directory!(parent)
      Dir.children(parent).sort.map do |handle|
        validate_handle!(handle)
        operation_root, metadata = state.load_operation!(handle)
        revision = metadata["revision"]
        unless revision.to_s.match?(/\A[0-9a-f]{40}\z/) &&
               metadata.dig("provider", "target") == target &&
               metadata.dig("provider", "host") == host
          raise LifecycleError, "operation metadata is incomplete or belongs to another target"
        end

        verify_operation_tree!(operation_root, metadata)

        OperationReference.new(handle:, revision:, root: operation_root)
      end
    end

    def verify_operation_tree!(root, metadata)
      expected_top = %w[capabilities launcher operation.json runtime]
      unless Dir.children(root).sort == expected_top
        raise LifecycleError, "operation contains unknown or missing top-level state"
      end

      runtime = metadata["runtime"]
      capabilities = metadata["capabilities"]
      unless runtime.is_a?(Hash) && !runtime.empty? &&
             capabilities.is_a?(Hash) && !capabilities.empty? &&
             metadata["launcher"].is_a?(Hash)
        raise LifecycleError, "operation executable bindings are incomplete"
      end

      verify_bound_directory!(File.join(root, "runtime"), runtime, mode: 0o400)
      verify_capability_bundles!(File.join(root, "capabilities"), capabilities)
      verify_bound_file!(File.join(root, "launcher"), metadata.fetch("launcher"), mode: 0o500)
    end

    def verify_capability_bundles!(directory, bindings)
      SecurePaths.verify_private_directory!(directory)
      unless Dir.children(directory).sort == bindings.keys.sort
        raise LifecycleError, "operation capability directory contains unknown or missing entries"
      end

      bindings.each do |name, binding|
        unless name.match?(/\A[a-z][a-z0-9-]*\z/) && binding.is_a?(Hash)
          raise LifecycleError, "operation capability binding is malformed"
        end

        bundle = File.join(directory, name)
        verify_bundle_tree!(bundle, binding.fetch("runtime"))
      end
    rescue KeyError => e
      raise LifecycleError, "operation capability binding is incomplete: #{e.message}"
    end

    def verify_bundle_tree!(bundle, runtime)
      root_stat = File.lstat(bundle)
      unless root_stat.directory? && !root_stat.symlink? && root_stat.uid == Process.uid &&
             (root_stat.mode & 0o777) == 0o500
        raise LifecycleError, "operation capability bundle root is unsafe"
      end

      expected_files = runtime.values.map { |recorded| recorded.fetch("path") }.sort
      actual_files = []
      Find.find(bundle) do |path|
        next if path == bundle

        relative = path.delete_prefix("#{bundle}/")
        stat = File.lstat(path)
        raise LifecycleError, "operation capability bundle contains a symlink" if stat.symlink?

        if stat.directory?
          unless stat.uid == Process.uid && (stat.mode & 0o777) == 0o500
            raise LifecycleError, "operation capability bundle directory is unsafe"
          end
        elsif stat.file?
          actual_files << relative
        else
          raise LifecycleError, "operation capability bundle contains an unsupported entry"
        end
      end
      unless actual_files.sort == expected_files
        raise LifecycleError, "operation capability bundle contains unknown or missing entries"
      end

      runtime.each_value do |recorded|
        mode = recorded.fetch("mode") == "0500" ? 0o500 : 0o400
        verify_bound_file!(File.join(bundle, recorded.fetch("path")), recorded, mode:)
      end
    end

    def verify_bound_directory!(directory, bindings, mode:)
      SecurePaths.verify_private_directory!(directory)
      unless Dir.children(directory).sort == bindings.keys.sort
        raise LifecycleError, "operation binding directory contains unknown or missing entries"
      end

      bindings.each do |name, recorded|
        unless name.is_a?(String) && !name.empty? && !name.include?("/") && recorded.is_a?(Hash)
          raise LifecycleError, "operation file binding is malformed"
        end

        verify_bound_file!(File.join(directory, name), recorded, mode:)
      end
    end

    def verify_bound_file!(path, recorded, mode:)
      stat = SecurePaths.verify_private_file!(path, mode:)
      expected = [recorded["device"], recorded["inode"], recorded["size"], recorded["sha256"]]
      actual = [stat.dev, stat.ino, stat.size, Digest::SHA256.file(path).hexdigest]
      raise LifecycleError, "operation file identity differs from its published binding" unless actual == expected
    end

    def scan_stores!
      parent = File.join(state.root, "store")
      SecurePaths.verify_private_directory!(parent)
      Dir.children(parent).sort.to_h do |revision|
        unless revision.match?(/\A[0-9a-f]{40}\z/)
          raise LifecycleError, "store contains an unknown revision entry: #{revision.inspect}"
        end

        [revision, store.open!(revision)]
      end
    end

    def installed_revision!
      placeholder = StoreSnapshot.new(revision: "0" * 40, root: "", repository: "", tree: "")
      provider = Provider.new(host: host, target: target, snapshot: placeholder)
      profile = provider.profile!
      return nil unless profile == "managed"

      provider.installed_revision!
    end

    def debris_candidates!
      %w[staging quarantine].flat_map do |name|
        parent = File.join(state.root, name)
        SecurePaths.verify_private_directory!(parent)
        Dir.children(parent).sort.map do |entry|
          path = File.join(parent, entry)
          verify_debris_tree!(path)
          [path, SecurePaths.owned_identity(path)]
        end
      end
    end

    def verify_debris_tree!(root)
      stat = File.lstat(root)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise LifecycleError, "ambiguous lifecycle debris: #{root}"
      end

      Find.find(root) do |path|
        current = File.lstat(path)
        if current.symlink? || current.uid != Process.uid || (current.mode & 0o022).positive?
          raise LifecycleError, "ambiguous lifecycle debris entry: #{path}"
        end
      end
    rescue SystemCallError => e
      raise LifecycleError, "unable to validate lifecycle debris #{root}: #{e.message}"
    end

    def validate_handle!(handle)
      return handle if handle.to_s.match?(State::HANDLE_PATTERN)

      raise LifecycleError, "operation handle must be an opaque 64-hex value"
    end

    def ambiguous!(error)
      return error if error.message.start_with?("AMBIGUOUS_LIFECYCLE_STATE:")

      LifecycleError.new("AMBIGUOUS_LIFECYCLE_STATE: #{error.message}")
    end

    def release_result(handle, status)
      {
        "schema_version" => 1,
        "operation" => handle,
        "status" => status
      }
    end
  end
end
