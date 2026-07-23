# frozen_string_literal: true

module AgentWorkflowsOperation
  class Error < StandardError; end
  class PathError < Error; end
  class GitError < Error; end
  class StoreError < Error; end
  class CleanupError < StoreError; end
  class RegistryError < Error; end
  class ProviderError < Error; end
  class ResolverError < Error; end
  class RunnerError < Error; end
end
