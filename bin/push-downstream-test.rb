#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for push-downstream.
# Run with: ruby bin/push-downstream-test.rb

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("push-downstream", __dir__)
DOCTOR = File.expand_path("agent-workflow-seam-doctor", __dir__)
load SCRIPT

class PushDownstreamReconcileTest < Minitest::Test
  def test_reconcile_inserts_complete_seam_when_missing
    original = "# AGENTS.md\n\n## Commands\n\nRun the thing.\n"

    result = PushDownstream.reconcile(original, base_branch: "main")

    # Existing content is preserved verbatim.
    assert_includes result, "## Commands"
    assert_includes result, "Run the thing."

    # The managed section is added with every required key.
    assert_includes result, "## Agent Workflow Configuration"
    AgentWorkflowSeamDoctor::REQUIRED_KEYS.each do |key|
      assert_includes result, "- **#{key}**:", "missing seam key #{key}"
    end

    # Base branch is seeded from the argument; unspecified keys default to n/a.
    assert_match(/- \*\*Base branch\*\*: .*main/, result)
    assert_match(%r{- \*\*Tests\*\*: n/a}, result)
  end

  def test_reconcile_preserves_existing_values_and_fills_missing_keys
    agents = <<~MARKDOWN
      # AGENTS.md

      ## Agent Workflow Configuration

      Stale preamble that the command should replace.

      - **Base branch**: `develop` (compare via `origin/develop`).
      - **Tests**: `bundle exec rspec`.

      ## Commands

      Run things.
    MARKDOWN

    result = PushDownstream.reconcile(agents, base_branch: "main")

    # Repo-owned values survive verbatim, even though base_branch arg differs.
    assert_includes result, "- **Base branch**: `develop` (compare via `origin/develop`)."
    assert_includes result, "- **Tests**: `bundle exec rspec`."
    # Missing required keys are filled with n/a.
    assert_match(%r{- \*\*Coordination backend\*\*: n/a}, result)
    # The section is reconciled in place, not duplicated.
    assert_equal 1, result.scan("## Agent Workflow Configuration").length
    # Content outside the section is preserved.
    assert_includes result, "## Commands"
    assert_includes result, "Run things."
  end

  def test_reconcile_preserves_multiline_wrapped_values
    agents = <<~MARKDOWN
      # AGENTS.md

      ## Agent Workflow Configuration

      - **Tests**: `bundle exec rspec`,
        `pnpm run test`, and targeted e2e commands.

      ## Commands
    MARKDOWN

    result = PushDownstream.reconcile(agents, base_branch: "main")

    assert_includes result, "- **Tests**: `bundle exec rspec`,\n  `pnpm run test`, and targeted e2e commands."
  end

  def test_reconcile_preserves_extra_optional_keys_after_required
    agents = <<~MARKDOWN
      # AGENTS.md

      ## Agent Workflow Configuration

      - **Base branch**: `main`.
      - **Default simplify model**: claude-opus-4-8.

      ## Commands
    MARKDOWN

    result = PushDownstream.reconcile(agents, base_branch: "main")

    assert_includes result, "- **Default simplify model**: claude-opus-4-8."
    # Optional keys are kept, but after the canonical required block.
    assert_operator result.index("Default simplify model"), :>, result.index("Coordination backend")
  end

  def test_reconcile_is_idempotent
    [
      "# AGENTS.md\n\n## Commands\n\nRun.\n",
      "# AGENTS.md\n\n## Agent Workflow Configuration\n\n- **Tests**: `rspec`.\n\n## Commands\n"
    ].each do |agents|
      once = PushDownstream.reconcile(agents, base_branch: "main")
      twice = PushDownstream.reconcile(once, base_branch: "main")

      assert_equal once, twice, "not idempotent for: #{agents.inspect}"
    end
  end

  def test_reconciled_output_passes_seam_doctor
    Dir.mktmpdir("push-downstream-doctor") do |root|
      reconciled = PushDownstream.reconcile("# AGENTS.md\n\n## Commands\n", base_branch: "main")
      File.write(File.join(root, "AGENTS.md"), reconciled)

      out, status = Open3.capture2e("ruby", DOCTOR, "--root", root)

      assert status.success?, out
      assert_includes out, "PASS"
    end
  end
end

class PushDownstreamConfigTest < Minitest::Test
  def with_config(yaml)
    Dir.mktmpdir("push-downstream-config") do |dir|
      path = File.join(dir, "downstream.yml")
      File.write(path, yaml)
      yield path
    end
  end

  def test_load_config_applies_defaults_and_per_repo_overrides
    yaml = <<~YAML
      defaults:
        owner: shakacode
        base_branch: main
        pr_branch: agent-workflows/seam-sync
        enabled: true
      repos:
        - { repo: shakapacker, tier: library }
        - { repo: legacy-demo, tier: demo, base_branch: master }
    YAML

    with_config(yaml) do |path|
      repos = PushDownstream.load_config(path)

      assert_equal 2, repos.length
      first = repos.fetch(0)
      assert_equal "shakacode", first.fetch(:owner)
      assert_equal "shakapacker", first.fetch(:repo)
      assert_equal "shakacode/shakapacker", first.fetch(:nwo)
      assert_equal "main", first.fetch(:base_branch)
      assert_equal "agent-workflows/seam-sync", first.fetch(:pr_branch)
      assert_equal true, first.fetch(:enabled)

      # A per-repo base_branch overrides the default.
      assert_equal "master", repos.fetch(1).fetch(:base_branch)
    end
  end

  def test_select_repos_filters_disabled_and_honors_only
    yaml = <<~YAML
      defaults:
        owner: shakacode
        base_branch: main
        pr_branch: agent-workflows/seam-sync
      repos:
        - { repo: alpha }
        - { repo: beta, enabled: false }
    YAML

    with_config(yaml) do |path|
      repos = PushDownstream.load_config(path)

      assert_equal(["alpha"], PushDownstream.select_repos(repos).map { |repo| repo.fetch(:repo) })
      assert_equal(%w[alpha beta], PushDownstream.select_repos(repos, include_disabled: true).map { |repo| repo.fetch(:repo) })
      # An explicit --only name selects a repo even when disabled.
      assert_equal(["beta"], PushDownstream.select_repos(repos, only: ["beta"]).map { |repo| repo.fetch(:repo) })
    end
  end
end

class PushDownstreamCliTest < Minitest::Test
  def run_cli(*)
    Open3.capture2e("ruby", SCRIPT, *)
  end

  def test_local_dry_run_reports_change_without_writing
    Dir.mktmpdir("push-downstream-cli") do |root|
      agents = File.join(root, "AGENTS.md")
      original = "# AGENTS.md\n\n## Commands\n"
      File.write(agents, original)

      out, status = run_cli("--root", root)

      assert status.success?, out
      assert_includes out, "would update"
      # Dry-run must not touch the file.
      assert_equal original, File.read(agents)
    end
  end

  def test_local_apply_writes_seam_and_is_idempotent
    Dir.mktmpdir("push-downstream-cli") do |root|
      agents = File.join(root, "AGENTS.md")
      File.write(agents, "# AGENTS.md\n\n## Commands\n")

      out, status = run_cli("--root", root, "--apply")

      assert status.success?, out
      assert_includes out, "PASS"
      assert_includes File.read(agents), "## Agent Workflow Configuration"

      # Re-applying is a no-op.
      out2, status2 = run_cli("--root", root, "--apply")

      assert status2.success?, out2
      assert_includes out2, "already current"
    end
  end

  def test_local_creates_agents_when_missing_on_apply
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli("--root", root, "--apply")

      assert status.success?, out
      assert_includes out, "PASS"
      agents = File.join(root, "AGENTS.md")
      assert File.file?(agents), "AGENTS.md should be created"
      assert_includes File.read(agents), "## Agent Workflow Configuration"
    end
  end

  def test_local_dry_run_reports_create_without_writing
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli("--root", root)

      assert status.success?, out
      assert_includes out, "would create"
      refute File.exist?(File.join(root, "AGENTS.md")), "dry-run must not create the file"
    end
  end

  def test_local_errors_when_root_directory_missing
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli("--root", File.join(root, "does-not-exist"))

      refute status.success?
      assert_includes out, "missing directory"
    end
  end

  def test_local_reconciles_non_ascii_agents_under_ascii_locale
    Dir.mktmpdir("push-downstream-cli") do |root|
      agents = File.join(root, "AGENTS.md")
      # Real AGENTS.md files carry non-ASCII bytes (em dashes, arrows). Reading
      # under a non-UTF-8 locale must not crash the reconcile.
      File.write(agents, "# AGENTS.md\n\nReact on Rails → SSR — overview.\n\n## Commands\n")

      out, status = Open3.capture2e(
        { "LC_ALL" => "C", "LANG" => "C" }, "ruby", SCRIPT, "--root", root, "--apply"
      )

      assert status.success?, out
      assert_includes out, "PASS"
      body = File.read(agents, encoding: "UTF-8")
      assert_includes body, "## Agent Workflow Configuration"
      assert_includes body, "React on Rails → SSR — overview."
    end
  end

  def test_registry_dry_run_lists_enabled_targets
    Dir.mktmpdir("push-downstream-registry") do |dir|
      config = File.join(dir, "downstream.yml")
      File.write(config, <<~YAML)
        defaults:
          owner: shakacode
          base_branch: main
          pr_branch: agent-workflows/seam-sync
        repos:
          - { repo: alpha }
          - { repo: beta, enabled: false }
      YAML

      out, status = run_cli("--config", config)

      assert status.success?, out
      assert_includes out, "shakacode/alpha"
      assert_includes out, "agent-workflows/seam-sync"
      # Disabled repos are not planned unless --include-disabled.
      refute_includes out, "shakacode/beta"
    end
  end
end
