# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "secure_paths"
require_relative "tree"

module AgentWorkflowsOperation
  class Provider
    PROFILES = %w[managed pinned].freeze
    COMPANION_BIN_FILES = %w[
      bin/agent-workflow-seam-doctor
      bin/agent-workflows-delivery-state
      bin/agent-workflows-doctor
      bin/agent-workflows-lifecycle
      bin/agent-workflows-resolve
      bin/agent-workflows-run
      bin/agent-workflows-status
      bin/agent-workflows-trust-audit
      bin/install-agent-workflows
      bin/upgrade-agent-workflows
    ].freeze
    COMPANION_DOC_FILES = %w[
      docs/agent-workflows-model-routing.md
      docs/coordination-backend.md
      docs/review-finding-schema.md
    ].freeze

    CODEX_UPDATE = <<~GUIDANCE.strip
      Run `codex plugin marketplace upgrade agent-workflows`, then
      `codex plugin remove scw@agent-workflows` and
      `codex plugin add scw@agent-workflows`. Reinstall companion assets from
      that exact canonical main checkout with
      `bin/install-agent-workflows --host codex --mode copy --delivery-mode plugin-companion --provider-profile managed --gh-executable /absolute/path/to/gh`.
      Fully restart Codex and start a new session before retrying.
    GUIDANCE
    CLAUDE_UPDATE = <<~GUIDANCE.strip
      Run `/plugin marketplace update agent-workflows`, then
      `/plugin update scw@agent-workflows`. Reinstall companion assets from
      that exact canonical main checkout with
      `bin/install-agent-workflows --host claude --mode copy --delivery-mode plugin-companion --provider-profile managed --gh-executable /absolute/path/to/gh`.
      Run `/reload-plugins` and start a new session before retrying.
    GUIDANCE

    attr_reader :host, :target, :snapshot

    def initialize(host:, target:, snapshot:)
      @host = host
      @target = target
      @snapshot = snapshot
      raise ProviderError, "host must be codex or claude" unless %w[codex claude].include?(host)
    end

    def verify!(expected_revision: snapshot.revision)
      metadata = companion_metadata!
      profile = profile_from!(metadata)
      if profile == "pinned"
        raise ProviderError, "PINNED_PROVIDER_OPERATION_UNAVAILABLE: pinned providers do not resolve current operations"
      end

      companion_revision = metadata["source_revision"]
      native = native_state!
      roots = Array(native["roots"])
      unless native["state"] == "active" && roots.length == 1
        fail_update!("active native provider is unavailable or ambiguous")
      end
      native_root = File.realpath(roots.fetch(0))
      native_revision = host == "codex" ? verify_codex_native!(native_root) : verify_claude_native!(native_root)

      unless native_revision == companion_revision
        fail_update!(
          "native and companion provider revisions do not match " \
          "(native #{native_revision}, companion #{companion_revision})"
        )
      end
      unless native_revision == expected_revision
        fail_update!(
          "installed provider is stale (installed #{native_revision}, canonical main #{expected_revision})"
        )
      end

      verify_native_tree!(native_root)
      verify_codex_clean!(native_root) if host == "codex"
      verify_companion_files!
      gh_executable = metadata["gh_executable"]
      unless gh_executable.is_a?(String) && gh_executable.start_with?("/")
        raise ProviderError,
              "MANAGED_TOOL_BINDING_REQUIRED: install metadata must declare an explicit absolute gh executable"
      end

      {
        "profile" => profile,
        "host" => host,
        "target" => target,
        "native_root" => native_root,
        "native_revision" => native_revision,
        "companion_revision" => companion_revision,
        "gh_executable" => gh_executable
      }
    end

    def installed_revision!
      metadata = companion_metadata!
      revision = metadata["source_revision"]
      unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)
        fail_update!("companion source_revision is not a full commit SHA")
      end

      revision
    end

    def profile!
      profile_from!(install_metadata!)
    end

    private

    def profile_from!(metadata)
      profile = metadata.fetch("provider_profile", "pinned")
      return profile if PROFILES.include?(profile)

      raise ProviderError, "unsupported provider profile: #{profile.inspect}"
    end

    def companion_metadata!
      metadata = install_metadata!
      unless metadata["host"] == host &&
             metadata["delivery_mode"] == "plugin-companion" && metadata["mode"] == "copy"
        fail_update!("companion metadata must record this host, mode copy, and plugin-companion delivery")
      end
      revision = metadata["source_revision"]
      fail_update!("companion source_revision is invalid") unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)

      metadata
    end

    def install_metadata!
      path = File.join(target, ".agent-workflows-install.json")
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        fail_update!("companion install metadata is missing, unsafe, or writable by another user")
      end
      metadata = JSON.parse(File.binread(path))
      fail_update!("install metadata root must be an object") unless metadata.is_a?(Hash)

      metadata
    rescue Errno::ENOENT, JSON::ParserError => e
      fail_update!("companion install metadata is unavailable: #{e.message}")
    end

    def native_state!
      load_delivery_state!
      AgentWorkflowsDeliveryState.native_state(host, target)
    rescue StandardError => e
      fail_update!("native provider state could not be verified: #{e.message}")
    end

    def load_delivery_state!
      return if defined?(AgentWorkflowsDeliveryState)

      delivery_state = File.join(target, "bin/agent-workflows-delivery-state")
      timeout_budget = File.join(target, "bin/agent_doctor/timeout_budget.rb")
      verify_companion_file!("bin/agent-workflows-delivery-state")
      verify_companion_file!("bin/agent_doctor/timeout_budget.rb")
      raise ProviderError, "verified delivery-state dependency disappeared" unless File.file?(timeout_budget)

      load delivery_state
    end

    def verify_codex_native!(root)
      git_directory = File.join(root, ".git")
      git_stat = File.lstat(git_directory)
      unless git_stat.directory? && !git_stat.symlink? && git_stat.uid == Process.uid
        fail_update!("Codex native cache .git directory is missing or unsafe")
      end
      alternates = File.join(git_directory, "objects/info/alternates")
      if File.exist?(alternates) || File.symlink?(alternates)
        fail_update!("Codex native cache must not use Git object alternates")
      end

      head = snapshot_git.repository_head!(root)
      fail_update!("Codex native cache HEAD is not a full commit SHA") unless head.match?(/\A[0-9a-f]{40}\z/)

      head
    rescue Errno::ENOENT, GitError => e
      fail_update!("Codex native cache Git proof failed: #{e.message}")
    end

    def verify_codex_clean!(root)
      status = snapshot_git.repository_status!(root)
      fail_update!("Codex native cache Git checkout is not clean") unless status.empty?
    rescue GitError => e
      fail_update!("Codex native cache Git status failed: #{e.message}")
    end

    def verify_claude_native!(root)
      receipt_path = File.join(target, "plugins/installed_plugins.json")
      payload = JSON.parse(File.binread(receipt_path))
      receipts = payload.dig("plugins", "scw@agent-workflows")
      receipts = Array(receipts).select { |receipt| receipt.is_a?(Hash) }
      fail_update!("Claude native plugin receipt is missing or ambiguous") unless receipts.length == 1

      receipt = receipts.fetch(0)
      receipt_root = File.realpath(receipt.fetch("installPath"))
      fail_update!("Claude receipt installPath does not match the active provider root") unless receipt_root == root
      revision = receipt["gitCommitSha"]
      fail_update!("Claude receipt gitCommitSha is invalid") unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)

      revision
    rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => e
      fail_update!("Claude native plugin receipt could not be verified: #{e.message}")
    end

    def verify_native_tree!(root)
      Tree.verify_against_git!(
        git: snapshot_git,
        repository: snapshot.repository,
        revision: snapshot.revision,
        root: root,
        private_home: File.join(snapshot.root, "home"),
        ignore_git: host == "codex"
      )
    rescue StoreError => e
      fail_update!("active native provider content does not match canonical main: #{e.message}")
    end

    def verify_companion_files!
      prefixes = %w[bin/agent_doctor/ bin/agent_workflows_operation/ docs/solutions/ workflows/]
      managed = snapshot_manifest.keys.select do |relative|
        prefixes.any? { |prefix| relative.start_with?(prefix) }
      end
      (managed + COMPANION_BIN_FILES + COMPANION_DOC_FILES + ["LICENSE"]).uniq.each do |relative|
        verify_companion_file!(relative)
      end
    end

    def verify_companion_file!(relative)
      Tree.verify_file_against_git!(
        git: snapshot_git,
        repository: snapshot.repository,
        revision: snapshot.revision,
        root: target,
        relative: relative,
        private_home: File.join(snapshot.root, "home"),
        manifest: snapshot_manifest
      )
    rescue StoreError => e
      fail_update!("companion bootstrap content does not match canonical main: #{e.message}")
    end

    def snapshot_git
      @snapshot_git ||= SecureGit.new
    end

    def snapshot_manifest
      @snapshot_manifest ||= snapshot_git.ls_tree!(
        snapshot.repository,
        snapshot.revision,
        private_home: File.join(snapshot.root, "home")
      )
    end

    def fail_update!(reason)
      guidance = host == "codex" ? CODEX_UPDATE : CLAUDE_UPDATE
      raise ProviderError, "PROVIDER_UPDATE_REQUIRED: #{reason}.\n#{guidance}"
    end
  end
end
