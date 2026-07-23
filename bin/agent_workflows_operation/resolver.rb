# frozen_string_literal: true

require_relative "errors"
require_relative "provider"
require_relative "registry"
require_relative "state"
require_relative "store"

module AgentWorkflowsOperation
  class Resolver
    attr_reader :host, :target, :state, :store

    def initialize(host:, target:)
      @host = host
      @target = File.expand_path(target)
      @state = State.new(target: @target)
      @store = Store.new(state_root: state.root)
    end

    def begin!(degraded: false)
      snapshot = if degraded
                   revision = installed_revision
                   store.open!(revision)
                 else
                   fetch_current_store!
                 end
      registry = Registry.load!(snapshot)
      provider = Provider.new(host: host, target: target, snapshot: snapshot).verify!
      freshness = degraded ? "degraded" : "current"
      state.publish_operation!(
        snapshot: snapshot,
        registry: registry,
        provider: provider,
        freshness: freshness
      )
    rescue PathError, GitError, StoreError, RegistryError, ProviderError, ResolverError
      raise
    rescue StandardError => e
      raise ResolverError, "operation begin failed: #{e.message}"
    end

    private

    def fetch_current_store!
      store.fetch_current!
    end

    def installed_revision
      placeholder = StoreSnapshot.new(revision: "0" * 40, root: "", repository: "", tree: "")
      Provider.new(host: host, target: target, snapshot: placeholder).installed_revision!
    end
  end
end
