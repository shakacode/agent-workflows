# frozen_string_literal: true

require "open3"

module PrBatchGitProbeEnv
  LOCAL_ENV_VARS_FALLBACK = %w[
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR
    GIT_CONFIG
    GIT_CONFIG_COUNT
    GIT_CONFIG_PARAMETERS
    GIT_DIR
    GIT_GRAFT_FILE
    GIT_IMPLICIT_WORK_TREE
    GIT_INDEX_FILE
    GIT_NAMESPACE
    GIT_NO_REPLACE_OBJECTS
    GIT_OBJECT_DIRECTORY
    GIT_PREFIX
    GIT_REPLACE_REF_BASE
    GIT_SHALLOW_FILE
    GIT_WORK_TREE
  ].freeze

  EXTRA_ENV_VARS = %w[
    GIT_CEILING_DIRECTORIES
  ].freeze

  module_function

  def local_env_vars
    @local_env_vars ||= begin
      stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--local-env-vars")
      names = status.success? ? stdout.force_encoding("UTF-8").scrub.lines.map(&:strip).reject(&:empty?) : []
      names.empty? ? LOCAL_ENV_VARS_FALLBACK : names
    rescue StandardError
      LOCAL_ENV_VARS_FALLBACK
    end
  end

  def probe_env(source_env = ENV)
    (local_env_vars + EXTRA_ENV_VARS).uniq.to_h { |name| [name, nil] }.tap do |env|
      source_env.each_key do |name|
        env[name] = nil if name.match?(/\AGIT_CONFIG_(KEY|VALUE)_\d+\z/)
      end
    end
  end
end
