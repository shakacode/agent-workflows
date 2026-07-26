# frozen_string_literal: true

require_relative "errors"
require_relative "lifecycle"
require_relative "lifecycle_lease"
require_relative "provider"
require_relative "registry"
require_relative "state"
require_relative "store"

module AgentWorkflowsOperation
  class Resolver
    attr_reader :host, :target, :state, :store, :lifecycle, :lease

    def initialize(host:, target:, lease: nil)
      @host = host
      @target = File.expand_path(target)
      @state = State.new(target: @target)
      @store = Store.new(state_root: state.root)
      @lifecycle = Lifecycle.new(host:, target: @target, state:, store:)
      @lease = lease || LifecycleLease.new(target: @target, root: state.root)
    end

    def begin!(degraded: false)
      lease.with_exclusive do
        profile = installed_profile
        if profile == "pinned"
          raise ProviderError, "PINNED_PROVIDER_OPERATION_UNAVAILABLE: pinned providers do not resolve operations"
        end

        inventory = lifecycle.gc!
        lifecycle.enforce_operation_capacity!(inventory)
        lifecycle.enforce_revision_capacity!(inventory)
        begin
          snapshot = if degraded
                       revision = installed_revision
                       store.open!(revision)
                     else
                       fetch_current_store!
                     end
          lifecycle.enforce_revision_capacity!(lifecycle.inventory!, snapshot.revision)
          registry = Registry.load!(snapshot)
          provider = Provider.new(host: host, target: target, snapshot: snapshot).verify!
          freshness = degraded ? "degraded" : "current"
          state.publish_operation!(
            snapshot: snapshot,
            registry: registry,
            provider: provider,
            freshness: freshness
          )
        rescue CleanupError
          raise
        rescue Error => e
          begin
            lifecycle.gc!
          rescue Error => cleanup_error
            raise ResolverError,
                  "#{e.message}; operation begin cleanup failed: #{cleanup_error.message}"
          end
          raise e
        end
      end
    rescue PathError, GitError, StoreError, RegistryError, ProviderError, ResolverError, LifecycleError
      raise
    rescue StandardError => e
      raise ResolverError, "operation begin failed: #{e.message}"
    end

    def release!(handle:)
      lease.with_exclusive { lifecycle.release!(handle:) }
    end

    def list!
      lease.with_shared { lifecycle.list! }
    end

    private

    def fetch_current_store!
      store.fetch_current!
    end

    def installed_revision
      placeholder = StoreSnapshot.new(revision: "0" * 40, root: "", repository: "", tree: "")
      Provider.new(host: host, target: target, snapshot: placeholder).installed_revision!
    end

    def installed_profile
      placeholder = StoreSnapshot.new(revision: "0" * 40, root: "", repository: "", tree: "")
      Provider.new(host: host, target: target, snapshot: placeholder).profile!
    end
  end
end
