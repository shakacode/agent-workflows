#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for push-downstream.
# Run with: ruby bin/push-downstream-test.rb

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
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

      out, status = Open3.capture2e(RbConfig.ruby, DOCTOR, "--root", root)

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

class PushDownstreamAdapterTest < Minitest::Test
  def with_file(name, body)
    Dir.mktmpdir("push-downstream-adapter") do |dir|
      path = File.join(dir, name)
      File.write(path, body)
      yield path
    end
  end

  def test_load_config_carries_preset_and_overrides
    yaml = <<~YAML
      defaults:
        owner: shakacode
        base_branch: main
        pr_branch: agent-workflows/seam-sync
      repos:
        - repo: rsc
          preset: ts-package
          overrides:
            Tests: "`yarn test` with conditions."
    YAML

    with_file("downstream.yml", yaml) do |path|
      repo = PushDownstream.load_config(path).fetch(0)

      assert_equal "ts-package", repo.fetch(:preset)
      assert_equal({ "Tests" => "`yarn test` with conditions." }, repo.fetch(:overrides))
    end
  end

  def test_load_presets_reads_defaults_and_named_presets
    yaml = <<~YAML
      defaults:
        Coordination backend: shared backend.
      presets:
        ts-package:
          Tests: "`yarn test`."
    YAML

    with_file("seam-presets.yml", yaml) do |path|
      presets = PushDownstream.load_presets(path)

      assert_equal "shared backend.", presets.fetch("defaults").fetch("Coordination backend")
      assert_equal "`yarn test`.", presets.fetch("presets").fetch("ts-package").fetch("Tests")
    end
  end

  def test_resolve_values_layers_defaults_preset_and_overrides
    presets = {
      "defaults" => { "Coordination backend" => "shared backend.", "Benchmark labels" => "n/a." },
      "presets" => { "ts-package" => { "Tests" => "`yarn test`.", "Benchmark labels" => "n/a (pkg)." } }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: "ts-package",
      overrides: { "Tests" => "`yarn test:all`." }
    }

    values = PushDownstream.resolve_values(repo, presets)

    assert_equal "shared backend.", values["Coordination backend"] # global default
    assert_equal "n/a (pkg).", values["Benchmark labels"]          # preset beats default
    assert_equal "`yarn test:all`.", values["Tests"]               # override beats preset
    assert_equal "`main`.", values["Base branch"]                  # seeded from base_branch
  end

  def test_resolve_values_unknown_preset_raises
    error = assert_raises(RuntimeError) do
      PushDownstream.resolve_values(
        { repo: "x", base_branch: "main", preset: "nope" }, { "presets" => {} }
      )
    end
    assert_match(/unknown preset: nope/, error.message)
  end

  def test_reconcile_seeds_unset_keys_but_preserves_existing
    agents = "# AGENTS.md\n\n## Agent Workflow Configuration\n\n- **Tests**: `existing`.\n\n## End\n"
    seed = { "Tests" => "`seeded`.", "Lint / format" => "`rubocop`." }

    result = PushDownstream.reconcile(agents, base_branch: "main", seed: seed)

    assert_includes result, "- **Tests**: `existing`."        # repo-owned wins over seed
    assert_includes result, "- **Lint / format**: `rubocop`." # seed fills an unset key
    assert_match(%r{- \*\*Docs checks\*\*: n/a}, result) # unseeded -> n/a
  end

  def test_reconcile_creates_seam_from_seed_values
    seed = { "Tests" => "`yarn test`.", "Coordination backend" => "shared backend." }

    result = PushDownstream.reconcile("# AGENTS.md\n", base_branch: "main", seed: seed)

    assert_includes result, "- **Tests**: `yarn test`."
    assert_includes result, "- **Coordination backend**: shared backend."
    assert_match(/- \*\*Base branch\*\*: .*main/, result) # base branch default still applies
    assert_match(%r{- \*\*Docs checks\*\*: n/a}, result) # unseeded -> n/a
  end
end

class PushDownstreamCliTest < Minitest::Test
  def run_cli(*)
    Open3.capture2e(RbConfig.ruby, SCRIPT, *)
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
        { "LC_ALL" => "C", "LANG" => "C" }, RbConfig.ruby, SCRIPT, "--root", root, "--apply"
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

  def test_registry_dry_run_honors_only_and_all_flags
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

      only_out, only_status = run_cli("--config", config, "--only", "beta")

      assert only_status.success?, only_out
      assert_includes only_out, "shakacode/beta"
      refute_includes only_out, "shakacode/alpha"

      all_out, all_status = run_cli("--config", config, "--all")

      assert all_status.success?, all_out
      assert_includes all_out, "shakacode/alpha"
      assert_includes all_out, "shakacode/beta"
    end
  end

  def test_registry_apply_updates_existing_remote_sync_branch
    Dir.mktmpdir("push-downstream-existing-branch") do |dir|
      remote = File.join(dir, "remote.git")
      seed = File.join(dir, "seed")
      clone = File.join(dir, "clone")
      branch = "agent-workflows/seam-sync"
      repo = { nwo: "local/example", base_branch: "main", pr_branch: branch }

      system("git", "init", "--bare", remote, out: File::NULL, err: File::NULL)
      system("git", "clone", remote, seed, out: File::NULL, err: File::NULL)
      configure_git(seed)
      File.write(File.join(seed, "AGENTS.md"), "# AGENTS.md\n")
      system("git", "-C", seed, "add", "AGENTS.md", out: File::NULL, err: File::NULL)
      system("git", "-C", seed, "commit", "-m", "base", out: File::NULL, err: File::NULL)
      system("git", "-C", seed, "branch", "-M", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", seed, "checkout", "-b", branch, out: File::NULL, err: File::NULL)
      File.write(File.join(seed, "AGENTS.md"), "# AGENTS.md\n\nexisting sync branch\n")
      system("git", "-C", seed, "commit", "-am", "existing sync", out: File::NULL, err: File::NULL)
      system("git", "-C", seed, "push", "origin", branch, out: File::NULL, err: File::NULL)

      system("git", "clone", "--depth", "1", "--branch", "main", "file://#{remote}", clone,
             out: File::NULL, err: File::NULL)
      configure_git(clone)
      File.write(File.join(clone, "AGENTS.md"), "# AGENTS.md\n\nupdated sync branch\n")

      out = nil
      with_pr_url_stub("https://example.test/pr") do
        out, = capture_io do
          assert PushDownstream.open_pull_request(repo, clone)
        end
      end
      assert_includes out, "https://example.test/pr"

      system("git", "-C", seed, "fetch", "origin", branch, out: File::NULL, err: File::NULL)
      remote_body, status = Open3.capture2("git", "-C", seed, "show", "origin/#{branch}:AGENTS.md")
      assert status.success?, remote_body
      assert_includes remote_body, "updated sync branch"
    end
  end

  def configure_git(dir)
    system("git", "-C", dir, "config", "user.email", "agent@example.test", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.name", "Agent Test", out: File::NULL, err: File::NULL)
  end

  def with_pr_url_stub(url)
    original_existing_pr_url = PushDownstream.method(:existing_pr_url)
    original_create_pr = PushDownstream.method(:create_pr)
    created = false

    PushDownstream.define_singleton_method(:existing_pr_url) { |_repo, _branch| url }
    PushDownstream.define_singleton_method(:create_pr) do |_repo, _branch|
      created = true
      nil
    end

    yield
    refute created, "existing PR should be reused"
  ensure
    PushDownstream.define_singleton_method(:existing_pr_url) do |repo, branch|
      original_existing_pr_url.call(repo, branch)
    end
    PushDownstream.define_singleton_method(:create_pr) do |repo, branch|
      original_create_pr.call(repo, branch)
    end
  end
end
