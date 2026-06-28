#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for push-downstream.
# Run with: ruby bin/push-downstream-test.rb

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

SCRIPT = File.expand_path("push-downstream", __dir__)
DOCTOR = File.expand_path("agent-workflow-seam-doctor", __dir__)
load SCRIPT

class PushDownstreamPointerTest < Minitest::Test
  def test_reconcile_pointer_replaces_only_agent_workflow_section
    original = <<~MARKDOWN
      # AGENTS.md

      Intro policy.

      ## Agent Workflow Configuration

      - **Base branch**: `main`.
      - **Tests**: `bundle exec rspec`.

      ## Commands

      Keep this section.
    MARKDOWN

    result = PushDownstream.reconcile_agents_pointer(original)

    assert_includes result, "Intro policy."
    assert_includes result, "## Commands\n\nKeep this section."
    assert_equal 1, result.scan("## Agent Workflow Configuration").length
    assert_includes result, AgentWorkflowSeamDoctor::POINTER_SECTION
    refute_includes result, "- **Tests**: `bundle exec rspec`."
  end

  def test_reconcile_pointer_appends_when_missing
    original = "# AGENTS.md\n\n## Commands\n\nRun the thing.\n"

    result = PushDownstream.reconcile_agents_pointer(original)

    assert_includes result, "Run the thing."
    assert_includes result, AgentWorkflowSeamDoctor::POINTER_SECTION
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
      assert_equal(["beta"], PushDownstream.select_repos(repos, only: ["beta"]).map { |repo| repo.fetch(:repo) })
    end
  end
end

class PushDownstreamAdapterTest < Minitest::Test
  def test_resolve_contract_layers_defaults_preset_and_overrides
    presets = {
      "defaults" => {
        "commands" => { "validate" => "echo default-validate", "test" => "echo default-test" },
        "policy" => { "follow_up_prefix" => "Follow-up:", "benchmark_labels" => "n/a" }
      },
      "presets" => {
        "ts-package" => {
          "commands" => { "validate" => { "compose" => %w[build test] }, "build" => "yarn build" },
          "policy" => { "benchmark_labels" => "n/a (package)", "hosted_ci_trigger" => "n/a" }
        }
      }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: "ts-package",
      overrides: {
        "commands" => { "test" => "yarn test --runInBand" },
        "policy" => { "hosted_ci_trigger" => "CI runs on every PR" }
      }
    }

    contract = PushDownstream.resolve_contract(repo, presets)

    assert_equal({ "compose" => %w[build test] }, contract.fetch(:commands).fetch("validate"))
    assert_equal "yarn build", contract.fetch(:commands).fetch("build")
    assert_equal "yarn test --runInBand", contract.fetch(:commands).fetch("test")
    assert_equal "main", contract.fetch(:policy).fetch("base_branch")
    assert_equal "n/a (package)", contract.fetch(:policy).fetch("benchmark_labels")
    assert_equal "CI runs on every PR", contract.fetch(:policy).fetch("hosted_ci_trigger")
  end

  def test_resolve_contract_unknown_preset_raises
    error = assert_raises(RuntimeError) do
      PushDownstream.resolve_contract(
        { repo: "x", base_branch: "main", preset: "nope", overrides: {} },
        { "presets" => {} }
      )
    end

    assert_match(/unknown preset: nope/, error.message)
  end
end

class PushDownstreamScaffoldTest < Minitest::Test
  CONTRACT = {
    commands: {
      "setup" => "bundle install",
      "validate" => { "compose" => %w[lint test] },
      "test" => "bundle exec rspec \"$@\"",
      "lint" => "bundle exec rubocop \"$@\""
    },
    policy: {
      "base_branch" => "main",
      "follow_up_prefix" => "Follow-up:",
      "review_gate" => "AI reviewers are advisory.",
      "approval_exempt" => "docs and workflow text.",
      "coordination_backend" => "public claim-comment fallback.",
      "changelog" => "CHANGELOG.md; user-visible changes only.",
      "benchmark_labels" => "n/a",
      "merge_ledger" => "n/a",
      "ci_parity_environment" => "n/a",
      "hosted_ci_trigger" => "n/a",
      "ci_change_detector" => "n/a"
    }
  }.freeze

  def test_apply_scaffold_generates_binstubs_policy_readme_agents_and_claude
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      File.write(File.join(root, "AGENTS.md"), "# AGENTS.md\n\n## Commands\n")

      result = PushDownstream.reconcile_scaffold(root, CONTRACT)

      assert result.changed?
      assert_empty result.follow_ups
      assert File.executable?(File.join(root, ".agents/bin/validate"))
      assert File.executable?(File.join(root, ".agents/bin/test"))
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"'
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, 'root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"'
      assert_includes validate, '"$root/.agents/bin/lint"'
      assert_includes File.read(File.join(root, ".agents/bin/README.md")), "| `lint` | Lint / format | `bundle exec rubocop \"$@\"` |"
      assert_equal CONTRACT.fetch(:policy), YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml")), aliases: false)
      assert_includes File.read(File.join(root, "AGENTS.md")), AgentWorkflowSeamDoctor::POINTER_SECTION
      assert_equal PushDownstream::THIN_CLAUDE, File.read(File.join(root, "CLAUDE.md"))

      out, status = Open3.capture2e("ruby", DOCTOR, "--root", root)
      assert status.success?, out
    end
  end

  def test_script_content_preserves_leading_env_assignment
    content = PushDownstream.script_content(
      "test",
      'RAILS_ENV=test ruby -e "exit ENV.fetch(%q[RAILS_ENV]) == %q[test] ? 0 : 1"'
    )

    refute_includes content, "exec RAILS_ENV=test"
    assert_includes content, 'RAILS_ENV=test ruby -e "exit ENV.fetch(%q[RAILS_ENV]) == %q[test] ? 0 : 1"'
  end

  def test_apply_scaffold_preserves_repo_owned_scripts_policy_and_claude
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin"))
      test_script = File.join(root, ".agents/bin/test")
      File.write(test_script, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
        exec script/custom-test "$@"
      BASH
      File.chmod(0o755, test_script)
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/agent-workflow.yml"), {
        "base_branch" => "develop",
        "follow_up_prefix" => "Custom:"
      }.to_yaml)
      File.write(File.join(root, "CLAUDE.md"), "# Rich Claude rules\n\nKeep me.\n")

      result = PushDownstream.reconcile_scaffold(root, CONTRACT)

      assert result.changed?
      assert_includes File.read(test_script), "script/custom-test"
      policy = YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml")), aliases: false)
      assert_equal "develop", policy.fetch("base_branch")
      assert_equal "Custom:", policy.fetch("follow_up_prefix")
      assert_equal "AI reviewers are advisory.", policy.fetch("review_gate")
      assert_equal "# Rich Claude rules\n\nKeep me.\n", File.read(File.join(root, "CLAUDE.md"))
      assert_equal ["existing CLAUDE.md preserved; consolidate it to import @AGENTS.md"], result.follow_ups
    end
  end

  def test_apply_scaffold_migrates_legacy_agents_command_values
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      File.write(File.join(root, "AGENTS.md"), <<~MARKDOWN)
        # AGENTS.md

        ## Agent Workflow Configuration

        - **Base branch**: `develop`.
        - **Pre-push local validation**: `bin/validate`.
        - **CI change detector**: `script/ci-changes-detector`.
        - **Lint / format**: `bundle exec rubocop "$@"`.
        - **Docs checks**: n/a.
        - **Tests**: `bundle exec rspec "$@"`.
        - **Build / type checks**: n/a.

        ## Commands
      MARKDOWN

      PushDownstream.reconcile_scaffold(root, PushDownstream.default_local_contract("main"))

      assert_includes File.read(File.join(root, ".agents/bin/validate")), "exec bin/validate"
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec bundle exec rspec "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/lint")), 'exec bundle exec rubocop "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/ci-detect")), "exec script/ci-changes-detector"
      refute File.exist?(File.join(root, ".agents/bin/build"))
      refute File.exist?(File.join(root, ".agents/bin/docs"))
      refute_includes File.read(File.join(root, ".agents/bin/validate")),
                      "Configure this repo full local validation"
      assert_includes File.read(File.join(root, ".agents/bin/README.md")),
                      "| `validate` | Pre-push gate | `bin/validate` |"

      out, status = Open3.capture2e("ruby", DOCTOR, "--root", root)
      assert status.success?, out
    end
  end

  def test_apply_scaffold_migrates_legacy_agents_policy_values
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      File.write(File.join(root, "AGENTS.md"), <<~MARKDOWN)
        # AGENTS.md

        ## Agent Workflow Configuration

        - **Base branch**: `develop`.
        - **CI parity environment**: exact runner image docs.
        - **Secret redaction patterns**: redact TOKEN and SECRET.
        - **Follow-up issue prefix**: Follow-up:
        - **Changelog**: CHANGELOG.md; keep a changelog.
        - **Review gate**: codex review.
        - **Approval-exempt change categories**: docs.
        - **Coordination backend**: private backend.

        ## Commands
      MARKDOWN

      PushDownstream.reconcile_scaffold(root, CONTRACT)

      policy = YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml")), aliases: false)
      assert_equal "develop", policy.fetch("base_branch")
      assert_equal "exact runner image docs.", policy.fetch("ci_parity_environment")
      assert_equal "redact TOKEN and SECRET.", policy.fetch("secret_redaction_patterns")
      assert_equal "Follow-up:", policy.fetch("follow_up_prefix")
      assert_equal "CHANGELOG.md; keep a changelog.", policy.fetch("changelog")
      assert_equal "codex review.", policy.fetch("review_gate")
      assert_equal "docs.", policy.fetch("approval_exempt")
      assert_equal "private backend.", policy.fetch("coordination_backend")
    end
  end

  def test_apply_scaffold_migrates_multiline_legacy_policy_values
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      File.write(File.join(root, "AGENTS.md"), <<~MARKDOWN)
        # AGENTS.md

        ## Agent Workflow Configuration

        - **Review gate**: primary review.
          secondary review for risky changes.
        - **Approval-exempt change categories**:
          - docs
          - workflow text

        ## Commands
      MARKDOWN

      PushDownstream.reconcile_scaffold(root, CONTRACT)

      policy = YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml")), aliases: false)
      assert_equal "primary review. secondary review for risky changes.", policy.fetch("review_gate")
      assert_equal "- docs - workflow text", policy.fetch("approval_exempt")
    end
  end

  def test_readme_describes_preserved_repo_owned_script_body
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin"))
      test_script = File.join(root, ".agents/bin/test")
      File.write(test_script, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
        exec script/custom-test "$@"
      BASH
      File.chmod(0o755, test_script)

      PushDownstream.reconcile_scaffold(root, CONTRACT)

      readme = File.read(File.join(root, ".agents/bin/README.md"))
      assert_includes readme, "| `test` | Run tests | `exec script/custom-test \"$@\"` |"
    end
  end

  def test_reconcile_scaffold_is_idempotent
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      first = PushDownstream.reconcile_scaffold(root, CONTRACT)
      second = PushDownstream.reconcile_scaffold(root, CONTRACT)

      assert first.changed?
      refute second.changed?
    end
  end

  def test_reconcile_scaffold_refreshes_managed_script_when_contract_changes
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      PushDownstream.reconcile_scaffold(root, CONTRACT)
      changed_contract = Marshal.load(Marshal.dump(CONTRACT))
      changed_contract[:commands]["test"] = "bundle exec rake test"

      result = PushDownstream.reconcile_scaffold(root, changed_contract)

      assert result.changed?
      assert_includes File.read(File.join(root, ".agents/bin/test")), "exec bundle exec rake test"
      assert_includes File.read(File.join(root, ".agents/bin/README.md")), "| `test` | Run tests | `bundle exec rake test` |"
    end
  end

  def test_reconcile_scaffold_removes_stale_managed_optional_script
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      contract_with_build = Marshal.load(Marshal.dump(CONTRACT))
      contract_with_build[:commands]["build"] = "yarn build"
      PushDownstream.reconcile_scaffold(root, contract_with_build)

      result = PushDownstream.reconcile_scaffold(root, CONTRACT)

      assert result.changed?
      refute File.exist?(File.join(root, ".agents/bin/build"))
      assert_includes File.read(File.join(root, ".agents/bin/README.md")), "| `build` | Build / type-check | n/a |"
    end
  end

  def test_reconcile_scaffold_reports_chmod_only_repairs
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      PushDownstream.reconcile_scaffold(root, CONTRACT)
      path = File.join(root, ".agents/bin/test")
      File.chmod(0o644, path)

      result = PushDownstream.reconcile_scaffold(root, CONTRACT)

      assert result.changed?
      assert File.executable?(path)
    end
  end

  def test_reconcile_scaffold_exposes_missing_composed_child_to_seam_doctor
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      broken_contract = Marshal.load(Marshal.dump(CONTRACT))
      broken_contract[:commands].delete("lint")

      PushDownstream.reconcile_scaffold(root, broken_contract)
      out, status = Open3.capture2e("ruby", DOCTOR, "--root", root)

      refute status.success?
      assert_includes out, "script references missing sibling script: .agents/bin/validate -> .agents/bin/lint"
    end
  end
end

class PushDownstreamGitTest < Minitest::Test
  CONTRACT = PushDownstreamScaffoldTest::CONTRACT

  def test_checkout_sync_branch_uses_existing_remote_branch_when_present
    Dir.mktmpdir("push-downstream-git") do |dir|
      remote = File.join(dir, "remote.git")
      seed = File.join(dir, "seed")
      clone = File.join(dir, "clone")
      system("git", "init", "--bare", remote, out: File::NULL)
      system("git", "clone", remote, seed, out: File::NULL)
      system("git", "-C", seed, "config", "user.email", "test@example.com")
      system("git", "-C", seed, "config", "user.name", "Test")
      File.write(File.join(seed, "README.md"), "base\n")
      system("git", "-C", seed, "add", "README.md")
      system("git", "-C", seed, "commit", "-m", "base", out: File::NULL)
      system("git", "-C", seed, "branch", "-M", "main")
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/seam-sync", out: File::NULL)
      File.write(File.join(seed, "branch.txt"), "remote branch\n")
      system("git", "-C", seed, "add", "branch.txt")
      system("git", "-C", seed, "commit", "-m", "sync branch", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/seam-sync", out: File::NULL)
      system("git", "clone", "--branch", "main", remote, clone, out: File::NULL)

      repo = { pr_branch: "agent-workflows/seam-sync" }
      assert_equal :existing_remote, PushDownstream.checkout_sync_branch(repo, clone)

      assert_equal "agent-workflows/seam-sync", `git -C #{clone.shellescape} branch --show-current`.strip
      assert_equal "remote branch\n", File.read(File.join(clone, "branch.txt"))
    end
  end

  def test_sync_repo_creates_pr_for_current_remote_branch_without_open_pr
    Dir.mktmpdir("push-downstream-git") do |dir|
      remote, seed = seed_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/seam-sync", out: File::NULL)
      PushDownstream.reconcile_scaffold(seed, CONTRACT)
      system("git", "-C", seed, "add", ".")
      system("git", "-C", seed, "commit", "-m", "sync branch", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/seam-sync", out: File::NULL)

      repo = {
        repo: "consumer",
        nwo: "local/consumer",
        base_branch: "main",
        pr_branch: "agent-workflows/seam-sync",
        remote_url: remote
      }
      created = []
      create_pr = lambda do |called_repo, branch, follow_ups|
        created << [called_repo, branch, follow_ups]
        "https://example.test/pr/1"
      end

      with_module_stub(PushDownstream, :existing_pr_url, ->(_repo, _branch) {}) do
        with_module_stub(PushDownstream, :create_pr, create_pr) do
          out, = capture_io { assert PushDownstream.sync_repo(repo, CONTRACT) }

          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end

      assert_equal [[repo, "agent-workflows/seam-sync", []]], created
    end
  end

  private

  def seed_remote(dir)
    remote = File.join(dir, "remote.git")
    seed = File.join(dir, "seed")
    system("git", "init", "--bare", remote, out: File::NULL)
    system("git", "clone", remote, seed, out: File::NULL)
    system("git", "-C", seed, "config", "user.email", "test@example.com")
    system("git", "-C", seed, "config", "user.name", "Test")
    File.write(File.join(seed, "README.md"), "base\n")
    system("git", "-C", seed, "add", "README.md")
    system("git", "-C", seed, "commit", "-m", "base", out: File::NULL)
    system("git", "-C", seed, "branch", "-M", "main")
    system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
    [remote, seed]
  end

  def with_module_stub(mod, name, replacement)
    singleton = mod.singleton_class
    original = mod.method(name)
    singleton.define_method(name, replacement)
    yield
  ensure
    singleton.define_method(name, original)
  end
end

class PushDownstreamCliTest < Minitest::Test
  def run_cli(*)
    Open3.capture2e(RbConfig.ruby, SCRIPT, *)
  end

  def test_local_dry_run_reports_change_without_writing
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli("--root", root)

      assert status.success?, out
      assert_includes out, "would reconcile binstub scaffold"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_local_apply_creates_contract_and_is_idempotent
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli("--root", root, "--apply")

      assert status.success?, out
      assert_includes out, "PASS"
      assert File.file?(File.join(root, ".agents/bin/validate"))
      assert File.file?(File.join(root, ".agents/agent-workflow.yml"))
      assert File.file?(File.join(root, "AGENTS.md"))

      out2, status2 = run_cli("--root", root, "--apply")

      assert status2.success?, out2
      assert_includes out2, "already current"
    end
  end

  def test_local_apply_validates_preserved_repo_owned_scripts
    Dir.mktmpdir("push-downstream-cli") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin"))
      File.write(File.join(root, ".agents/bin/test"), "echo missing strict mode\n")

      out, status = run_cli("--root", root, "--apply")

      refute status.success?, out
      assert_includes out, "FAIL agent workflow seam"
      assert_includes out, "script does not enable strict bash mode: .agents/bin/test"
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
      presets = File.join(dir, "seam-presets.yml")
      File.write(config, <<~YAML)
        defaults:
          owner: shakacode
          base_branch: main
          pr_branch: agent-workflows/seam-sync
        repos:
          - { repo: alpha, preset: ruby-gem }
          - { repo: beta, preset: ruby-gem, enabled: false }
      YAML
      File.write(presets, <<~YAML)
        defaults:
          commands:
            validate: echo validate
            test: echo test
          policy:
            follow_up_prefix: "Follow-up:"
        presets:
          ruby-gem:
            commands:
              validate: bundle exec rake
              test: bundle exec rspec
            policy:
              hosted_ci_trigger: n/a
      YAML

      out, status = run_cli("--config", config, "--presets", presets)

      assert status.success?, out
      assert_includes out, "shakacode/alpha"
      assert_includes out, "agent-workflows/seam-sync"
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
end
