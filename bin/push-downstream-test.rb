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

  def test_registry_apply_keys_contracts_by_full_repo_identity
    yaml = <<~YAML
      defaults:
        base_branch: main
        pr_branch: agent-workflows/seam-sync
      repos:
        - owner: owner-a
          repo: app
          overrides:
            commands:
              validate: echo owner-a
        - owner: owner-b
          repo: app
          overrides:
            commands:
              validate: echo owner-b
    YAML

    with_config(yaml) do |path|
      calls = []
      sync_repo = lambda do |repo, contract|
        calls << [repo.fetch(:nwo), contract.fetch(:commands).fetch("validate")]
        true
      end

      with_module_stub(PushDownstream, :sync_repo, sync_repo) do
        assert_equal 0, PushDownstream.run_registry(path, File.join(File.dirname(path), "missing.yml"),
                                                    only: nil, include_disabled: false, apply: true)
      end

      assert_equal [["owner-a/app", "echo owner-a"], ["owner-b/app", "echo owner-b"]], calls
    end
  end

  def test_registry_dry_run_reports_invalid_contract_without_aborting_valid_repos
    yaml = <<~YAML
      defaults:
        owner: shakacode
        base_branch: main
        pr_branch: agent-workflows/seam-sync
      repos:
        - repo: good
        - repo: bad
          overrides:
            trust:
              trusted_bots: [github-actions]
              trusted_metadata_bots: [github-actions]
    YAML

    with_config(yaml) do |path|
      out, err = capture_io do
        @registry_status = PushDownstream.run_registry(path, File.join(File.dirname(path), "missing.yml"),
                                                       only: nil, include_disabled: false, apply: false)
      end

      assert_equal 1, @registry_status
      assert_includes out, "shakacode/good"
      refute_includes out, "shakacode/bad"
      assert_includes err, "FAIL shakacode/bad: invalid trust config"
    end
  end

  def test_registry_apply_continues_after_invalid_contract
    yaml = <<~YAML
      defaults:
        owner: shakacode
        base_branch: main
        pr_branch: agent-workflows/seam-sync
      repos:
        - repo: good
        - repo: bad
          overrides:
            trust:
              trusted_bots: [github-actions]
              trusted_metadata_bots: [github-actions]
    YAML

    with_config(yaml) do |path|
      calls = []
      sync_repo = lambda do |repo, _contract|
        calls << repo.fetch(:nwo)
        true
      end

      with_module_stub(PushDownstream, :sync_repo, sync_repo) do
        _out, err = capture_io do
          @registry_status = PushDownstream.run_registry(path, File.join(File.dirname(path), "missing.yml"),
                                                         only: nil, include_disabled: false, apply: true)
        end

        assert_equal 1, @registry_status
        assert_equal ["shakacode/good"], calls
        assert_includes err, "FAIL shakacode/bad: invalid trust config"
      end
    end
  end

  private

  def with_module_stub(mod, name, replacement)
    singleton = mod.singleton_class
    original = mod.method(name)
    singleton.define_method(name, replacement)
    yield
  ensure
    singleton.define_method(name, original)
  end
end

class PushDownstreamAdapterTest < Minitest::Test
  def test_resolve_contract_layers_defaults_preset_and_overrides
    presets = {
      "defaults" => {
        "commands" => { "validate" => "echo default-validate", "test" => "echo default-test" },
        "policy" => { "follow_up_prefix" => "Follow-up:", "benchmark_labels" => "n/a" },
        "trust" => { "trusted_bots" => ["dependabot"] }
      },
      "presets" => {
        "ts-package" => {
          "commands" => { "validate" => { "compose" => %w[build test] }, "build" => "yarn build" },
          "policy" => { "benchmark_labels" => "n/a (package)", "hosted_ci_trigger" => "n/a" },
          "trust" => { "trusted_metadata_bots" => ["github-actions"] }
        }
      }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: "ts-package",
      overrides: {
        "commands" => { "test" => "yarn test --runInBand" },
        "policy" => { "hosted_ci_trigger" => "CI runs on every PR" },
        "trust" => { "trusted_users" => ["justin808"] }
      }
    }

    contract = PushDownstream.resolve_contract(repo, presets)

    assert_equal({ "compose" => %w[build test] }, contract.fetch(:commands).fetch("validate"))
    assert_equal "yarn build", contract.fetch(:commands).fetch("build")
    assert_equal "yarn test --runInBand", contract.fetch(:commands).fetch("test")
    assert_equal "main", contract.fetch(:policy).fetch("base_branch")
    assert_equal "n/a (package)", contract.fetch(:policy).fetch("benchmark_labels")
    assert_equal "CI runs on every PR", contract.fetch(:policy).fetch("hosted_ci_trigger")
    assert_equal ["dependabot"], contract.fetch(:trust).fetch("trusted_bots")
    assert_equal ["github-actions"], contract.fetch(:trust).fetch("trusted_metadata_bots")
    assert_equal ["justin808"], contract.fetch(:trust).fetch("trusted_users")
    assert_equal true, contract.fetch(:trust_configured)
  end

  def test_resolve_contract_tracks_explicit_empty_trust
    repo = {
      repo: "rsc", base_branch: "main", preset: nil,
      overrides: { "trust" => {} }
    }

    contract = PushDownstream.resolve_contract(repo, {})

    assert_equal true, contract.fetch(:trust_configured)
    assert_equal PushDownstream.empty_trust_config, contract.fetch(:trust)
  end

  def test_resolve_contract_empty_trust_override_does_not_clear_layered_trust
    presets = {
      "presets" => {
        "ruby-gem" => {
          "trust" => { "trusted_users" => ["maintainer-login"] }
        }
      }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: "ruby-gem",
      overrides: { "trust" => {} }
    }

    contract = PushDownstream.resolve_contract(repo, presets)

    assert_equal true, contract.fetch(:trust_configured)
    assert_equal ["maintainer-login"], contract.fetch(:trust).fetch("trusted_users")
  end

  def test_resolve_contract_normalizes_trusted_user_case_for_idempotent_merge
    presets = {
      "defaults" => {
        "trust" => {
          "trusted_users" => ["@Justin808"],
          "trusted_teams" => ["Acme/Maintainers"]
        }
      }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: nil,
      overrides: {
        "trust" => {
          "trusted_users" => ["justin808"],
          "trusted_teams" => ["acme/maintainers"]
        }
      }
    }

    contract = PushDownstream.resolve_contract(repo, presets)

    assert_equal ["justin808"], contract.fetch(:trust).fetch("trusted_users")
    assert_equal ["acme/maintainers"], contract.fetch(:trust).fetch("trusted_teams")
  end

  def test_resolve_contract_rejects_bot_metadata_overlap
    presets = {
      "defaults" => {
        "trust" => { "trusted_bots" => ["GitHub-Actions[bot]"] }
      }
    }
    repo = {
      repo: "rsc", base_branch: "main", preset: nil,
      overrides: { "trust" => { "trusted_metadata_bots" => ["github-actions"] } }
    }

    error = assert_raises(RuntimeError) do
      PushDownstream.resolve_contract(repo, presets)
    end

    assert_match(/bot\(s\) listed in both trusted_bots and trusted_metadata_bots: github-actions/, error.message)
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
      assert_includes File.read(File.join(root, "AGENTS.md"), encoding: "UTF-8"), AgentWorkflowSeamDoctor::POINTER_SECTION
      assert_equal PushDownstream::THIN_CLAUDE, File.read(File.join(root, "CLAUDE.md"))
      refute File.exist?(File.join(root, ".agents/trusted-github-actors.yml"))

      out, status = Open3.capture2e(RbConfig.ruby, DOCTOR, "--root", root)
      assert status.success?, out
    end
  end

  def test_apply_scaffold_writes_repo_local_trust_config
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = {
        "trusted_users" => ["justin808"],
        "trusted_bots" => ["dependabot"],
        "trusted_metadata_bots" => ["github-actions"],
        "trusted_teams" => []
      }

      result = PushDownstream.reconcile_scaffold(root, contract)

      assert result.changed?
      trust = YAML.safe_load(File.read(File.join(root, ".agents/trusted-github-actors.yml")), aliases: false)
      assert_equal ["justin808"], trust.fetch("trusted_users")
      assert_equal ["dependabot"], trust.fetch("trusted_bots")
      assert_equal ["github-actions"], trust.fetch("trusted_metadata_bots")
      assert_equal [], trust.fetch("trusted_teams")
    end
  end

  def test_apply_scaffold_writes_explicit_empty_repo_local_trust_config
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = PushDownstream.empty_trust_config
      contract[:trust_configured] = true

      result = PushDownstream.reconcile_scaffold(root, contract)

      assert result.changed?
      trust = YAML.safe_load(File.read(File.join(root, ".agents/trusted-github-actors.yml")), aliases: false)
      assert_equal [], trust.fetch("trusted_users")
      assert_equal [], trust.fetch("trusted_bots")
      assert_equal [], trust.fetch("trusted_metadata_bots")
      assert_equal [], trust.fetch("trusted_teams")
    end
  end

  def test_apply_scaffold_preserves_existing_trust_config_entries
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/trusted-github-actors.yml"), {
        "trusted_users" => ["existing-maintainer"],
        "trusted_bots" => ["coderabbitai"],
        "trusted_metadata_bots" => [],
        "trusted_teams" => ["maintainers"]
      }.to_yaml)
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = {
        "trusted_users" => ["justin808"],
        "trusted_bots" => [],
        "trusted_metadata_bots" => ["github-actions"],
        "trusted_teams" => []
      }

      PushDownstream.reconcile_scaffold(root, contract)

      trust = YAML.safe_load(File.read(File.join(root, ".agents/trusted-github-actors.yml")), aliases: false)
      assert_equal %w[existing-maintainer justin808], trust.fetch("trusted_users")
      assert_equal ["coderabbitai"], trust.fetch("trusted_bots")
      assert_equal ["github-actions"], trust.fetch("trusted_metadata_bots")
      assert_equal ["maintainers"], trust.fetch("trusted_teams")
    end
  end

  def test_apply_scaffold_rejects_existing_trust_bot_metadata_overlap
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      path = File.join(root, ".agents/trusted-github-actors.yml")
      File.write(path, {
        "trusted_users" => [],
        "trusted_bots" => ["GitHub-Actions[bot]"],
        "trusted_metadata_bots" => [],
        "trusted_teams" => []
      }.to_yaml)
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = { "trusted_metadata_bots" => ["github-actions"] }

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_scaffold(root, contract)
      end

      assert_match(/bot\(s\) listed in both trusted_bots and trusted_metadata_bots: github-actions/, error.message)
    end
  end

  def test_apply_scaffold_keeps_existing_trust_file_when_configured_entries_already_exist
    Dir.mktmpdir("push-downstream-scaffold") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      path = File.join(root, ".agents/trusted-github-actors.yml")
      original = <<~YAML
        # Maintainer-approved local trust.
        trusted_users:
          - justin808
        trusted_bots: []
        trusted_metadata_bots: []
        trusted_teams: []
      YAML
      File.write(path, original)
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = { "trusted_users" => ["justin808"] }

      PushDownstream.reconcile_scaffold(root, contract)

      assert_equal original, File.read(path)
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

  def test_script_content_preserves_shell_operator_commands
    {
      "pipeline" => "bin/validate | tee validate.log",
      "redirect" => "bin/validate > validate.log",
      "fallback" => "bin/validate || bin/test"
    }.each_value do |command|
      content = PushDownstream.script_content("validate", command)

      assert_includes content, command
      refute_includes content, "exec #{command}"
    end
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

      out, status = Open3.capture2e(RbConfig.ruby, DOCTOR, "--root", root)
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
      out, status = Open3.capture2e(RbConfig.ruby, DOCTOR, "--root", root)

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

  def test_checkout_sync_branch_fails_closed_when_remote_branch_lookup_errors
    git_calls = []
    with_module_stub(PushDownstream, :remote_branch_state, ->(_clone, _branch) { :error }) do
      with_module_stub(PushDownstream, :git, lambda { |_clone, *args|
        git_calls << args
        flunk "must not create or fetch a branch after lookup error"
      }) do
        assert_nil PushDownstream.checkout_sync_branch({ pr_branch: "agent-workflows/seam-sync" }, "/missing-clone")
      end
    end

    assert_empty git_calls
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

  def test_sync_repo_validates_unchanged_existing_remote_branch_before_reusing_pr
    Dir.mktmpdir("push-downstream-git") do |dir|
      remote, seed = seed_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/seam-sync", out: File::NULL)
      FileUtils.mkdir_p(File.join(seed, ".agents/bin"))
      File.write(File.join(seed, ".agents/bin/test"), "echo missing strict mode\n")
      File.chmod(0o755, File.join(seed, ".agents/bin/test"))
      PushDownstream.reconcile_scaffold(seed, CONTRACT)
      system("git", "-C", seed, "add", ".")
      system("git", "-C", seed, "commit", "-m", "invalid current sync branch", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/seam-sync", out: File::NULL)

      repo = {
        repo: "consumer",
        nwo: "local/consumer",
        base_branch: "main",
        pr_branch: "agent-workflows/seam-sync",
        remote_url: remote
      }
      create_pr = ->(_repo, _branch, _follow_ups) { flunk "should not create or reuse a PR for invalid seam" }

      with_module_stub(PushDownstream, :existing_pr_url, ->(_repo, _branch) {}) do
        with_module_stub(PushDownstream, :create_pr, create_pr) do
          _out, err = capture_io { refute PushDownstream.sync_repo(repo, CONTRACT) }

          assert_includes err, "FAIL local/consumer: seam doctor:"
          assert_includes err, "script does not enable strict bash mode: .agents/bin/test"
        end
      end
    end
  end

  def test_sync_repo_reports_existing_invalid_trust_config_without_raising
    Dir.mktmpdir("push-downstream-git") do |dir|
      remote, seed = seed_remote(dir)
      FileUtils.mkdir_p(File.join(seed, ".agents"))
      File.write(File.join(seed, ".agents/trusted-github-actors.yml"), {
        "trusted_users" => [],
        "trusted_bots" => ["github-actions"],
        "trusted_metadata_bots" => ["github-actions"],
        "trusted_teams" => []
      }.to_yaml)
      system("git", "-C", seed, "add", ".agents/trusted-github-actors.yml")
      system("git", "-C", seed, "commit", "-m", "invalid trust config", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      repo = {
        repo: "consumer",
        nwo: "local/consumer",
        base_branch: "main",
        pr_branch: "agent-workflows/seam-sync",
        remote_url: remote
      }
      contract = Marshal.load(Marshal.dump(CONTRACT))
      contract[:trust] = { "trusted_users" => ["maintainer-login"] }
      contract[:trust_configured] = true

      _out, err = capture_io { refute PushDownstream.sync_repo(repo, contract) }

      assert_includes err, "FAIL local/consumer: invalid trust config"
      assert_includes err, "bot(s) listed in both trusted_bots and trusted_metadata_bots: github-actions"
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

class PushDownstreamPolicyFleetTest < Minitest::Test
  CONTRACT = PushDownstreamScaffoldTest::CONTRACT
  SOURCE_REGISTRY = File.expand_path("../downstream.yml", __dir__)

  def test_repo_prefix_registry_covers_the_explicit_consumer_inventory
    fleet = PushDownstream.load_policy_fleet(SOURCE_REGISTRY, "repo-prefix")
    repos = fleet.fetch(:repos)
    prefixes = repos.to_h { |repo| [repo.fetch(:repo), repo.fetch(:policy).fetch("repo_prefix")] }
    bases = repos.to_h { |repo| [repo.fetch(:repo), repo.fetch(:base_branch)] }

    assert_equal ["repo_prefix"], fleet.fetch(:policy_keys)
    assert_equal "agent-workflows/repo-prefix", repos.first.fetch(:pr_branch)
    assert_equal 34, repos.length
    assert_equal 34, prefixes.values.uniq.length
    assert_equal "ACSA", prefixes.fetch("agent-coord-sim-alpha")
    assert_equal "HCBK", prefixes.fetch("hichee-backup")
    assert_equal "ROROCT", prefixes.fetch("react_on_rails-demo-octochangelog-on-rails-pro")
    assert_equal "SCW", prefixes.fetch("sc-website")
    %w[cypress-playwright-on-rails hichee hichee-backup react-on-rails-demo-ssr-hmr react-webpack-rails-tutorial sc-website].each do |repo|
      assert_equal "master", bases.fetch(repo)
    end
    assert_equal 28, bases.values.count("main")
  end

  def test_policy_fleet_rejects_unknown_selection_and_non_explicit_policy_keys
    Dir.mktmpdir("push-downstream-policy-registry") do |dir|
      config = File.join(dir, "downstream.yml")
      File.write(config, <<~YAML)
        defaults: { owner: shakacode }
        policy_fleets:
          repo-prefix:
            policy_keys: [repo_prefix]
            pr_branch: agent-workflows/repo-prefix
            repos:
              - { repo: alpha, base_branch: main, policy: { repo_prefix: ALPHA, unrelated: preserve } }
      YAML

      out, err = capture_io do
        @status = PushDownstream.run_policy_fleet(config, fleet_name: "repo-prefix", only: ["missing"], apply: false)
      end

      assert_equal 1, @status
      assert_empty out
      assert_includes err, "must set exactly: repo_prefix"

      selection_out, selection_err = capture_io do
        @selection_status = PushDownstream.run_policy_fleet(
          SOURCE_REGISTRY, fleet_name: "repo-prefix", only: ["missing"], apply: false
        )
      end
      assert_equal 1, @selection_status
      assert_empty selection_out
      assert_includes selection_err, "unknown policy fleet selection: missing"
    end
  end

  def test_policy_fleet_rejects_a_pr_branch_that_matches_a_merged_target_base_before_apply
    Dir.mktmpdir("push-downstream-policy-registry") do |dir|
      config = File.join(dir, "downstream.yml")
      File.write(config, <<~YAML)
        defaults: { owner: shakacode }
        policy_fleets:
          repo-prefix:
            policy_keys: [repo_prefix]
            pr_branch: agent-workflows/repo-prefix
            repos:
              - repo: alpha
                base_branch: main
                pr_branch: main
                policy: { repo_prefix: ALPHA }
      YAML

      out, err = capture_io do
        @dry_status = PushDownstream.run_policy_fleet(config, fleet_name: "repo-prefix", only: nil, apply: false)
      end
      assert_equal 1, @dry_status
      assert_empty out
      assert_includes err, "policy fleet repo-prefix shakacode/alpha pr_branch must differ from base_branch (main)"

      with_module_stub(PushDownstream, :sync_policy_repo, ->(*) { flunk "must not sync or push a base branch" }) do
        out, err = capture_io do
          @apply_status = PushDownstream.run_policy_fleet(config, fleet_name: "repo-prefix", only: nil, apply: true)
        end
        assert_equal 1, @apply_status
        assert_empty out
        assert_includes err, "policy fleet repo-prefix shakacode/alpha pr_branch must differ from base_branch (main)"
      end
    end
  end

  def test_policy_fleet_rejects_non_scalar_values_before_apply
    invalid_policies = {
      "array" => "[not-a-scalar]",
      "mapping" => "{ nested: value }",
      "null" => ""
    }

    invalid_policies.each_value do |custom_value|
      Dir.mktmpdir("push-downstream-policy-registry") do |dir|
        config = File.join(dir, "downstream.yml")
        File.write(config, <<~YAML)
          defaults: { owner: shakacode }
          policy_fleets:
            scalar-check:
              policy_keys: [repo_prefix, custom]
              pr_branch: agent-workflows/repo-prefix
              repos:
                - repo: alpha
                  base_branch: main
                  policy:
                    repo_prefix: ALPHA
                    custom: #{custom_value}
        YAML

        out, err = capture_io do
          @status = PushDownstream.run_policy_fleet(config, fleet_name: "scalar-check", only: nil, apply: false)
        end
        assert_equal 1, @status
        assert_empty out
        assert_includes err, "unsupported scalar custom for shakacode/alpha"
      end
    end
  end

  def test_policy_reconcile_changes_only_explicit_values_and_requires_existing_config
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(policy_path, {
        "base_branch" => "main",
        "repo_prefix" => "OLD",
        "custom_policy" => "preserve"
      }.to_yaml)
      original_policy = File.read(policy_path)
      sentinel = File.join(root, "AGENTS.md")
      File.write(sentinel, "untouched\n")

      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "NEW" })

      expected_policy = {
        "base_branch" => "main",
        "repo_prefix" => "NEW",
        "custom_policy" => "preserve"
      }
      assert_equal expected_policy, YAML.safe_load(File.read(policy_path), aliases: false)
      assert_equal original_policy.sub(/^repo_prefix: OLD\n/, "repo_prefix: NEW\n"), File.read(policy_path)
      assert_equal "untouched\n", File.read(sentinel)

      FileUtils.rm(policy_path)
      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "NEW" })
      end
      assert_equal "missing policy config: .agents/agent-workflow.yml", error.message
    end
  end

  def test_policy_reconcile_preserves_quoted_key_spelling_and_final_newline_state
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(policy_path, "base_branch: main\n\"repo_prefix\" : OLD")

      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "NEW" })

      assert_equal "base_branch: main\n\"repo_prefix\" : NEW", File.read(policy_path)
      assert_equal "NEW", YAML.safe_load(File.read(policy_path), aliases: false).fetch("repo_prefix")
      assert PushDownstream.policy_patch_allows_only_selected_lines?("-\"repo_prefix\" : OLD\n+\"repo_prefix\" : \"NEW\"\n", ["repo_prefix"])
    end
  end

  def test_policy_reconcile_preserves_inline_comments_and_quoted_hash_values
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))

      File.binwrite(policy_path, "repo_prefix: OLD # rationale\r\n")
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal "repo_prefix: ROR # rationale\r\n", File.binread(policy_path)

      File.binwrite(policy_path, "repo_prefix: \"OLD # literal\" # rationale\n")
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "NEW # literal" })
      assert_equal "repo_prefix: 'NEW # literal' # rationale\n", File.binread(policy_path)

      File.binwrite(policy_path, "repo_prefix: OLD # keep \\1 and \\& here\n")
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal "repo_prefix: ROR # keep \\1 and \\& here\n", File.binread(policy_path)

      value = "NEW\\path\\1\\&"
      File.binwrite(policy_path, "repo_prefix: OLD\n")
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => value })
      assert_equal "repo_prefix: #{value}\n", File.binread(policy_path)
      assert_equal value, YAML.safe_load(File.binread(policy_path), aliases: false).fetch("repo_prefix")
    end
  end

  def test_policy_reconcile_uses_actual_top_level_entry_not_fake_multiline_key_text
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))

      fake_continuation = "custom_policy: \"before\nrepo_prefix: after\"\n"
      File.binwrite(policy_path, "#{fake_continuation}repo_prefix: OLD\n")
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal "#{fake_continuation}repo_prefix: ROR\n", File.binread(policy_path)

      File.binwrite(policy_path, fake_continuation)
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal "#{fake_continuation}repo_prefix: ROR\n", File.binread(policy_path)
    end
  end

  def test_policy_reconcile_rejects_duplicate_selected_key_spellings_without_rewriting
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.binwrite(policy_path, "base_branch: main\nrepo_prefix: OLD\n\"repo_prefix\": ROR\n")
      original_bytes = File.binread(policy_path)

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_equal "selected policy key is ambiguous or not a top-level scalar: repo_prefix", error.message
      assert_equal original_bytes, File.binread(policy_path)
    end
  end

  def test_policy_reconcile_rejects_duplicate_explicit_selected_key_without_rewriting
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.binwrite(policy_path, "? repo_prefix\n: OLD\nrepo_prefix: ROR\n")
      original_bytes = File.binread(policy_path)

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_equal "selected policy key is ambiguous or not a top-level scalar: repo_prefix", error.message
      assert_equal original_bytes, File.binread(policy_path)
    end
  end

  def test_policy_reconcile_rejects_symlink_without_following_or_rewriting_target
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      external_target = File.join(root, "external-policy.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.binwrite(external_target, "base_branch: main\nrepo_prefix: OLD\n")
      original_target_bytes = File.binread(external_target)
      File.symlink(external_target, policy_path)

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_equal "policy config must be a regular non-symlink file: .agents/agent-workflow.yml", error.message
      assert File.symlink?(policy_path)
      assert_equal external_target, File.readlink(policy_path)
      assert_equal original_target_bytes, File.binread(external_target)
    end
  end

  def test_policy_reconcile_rejects_symlinked_parent_without_following_or_rewriting_target
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      external_agents = File.join(root, "external-agents")
      external_target = File.join(external_agents, "agent-workflow.yml")
      FileUtils.mkdir_p(external_agents)
      File.binwrite(external_target, "base_branch: main\nrepo_prefix: OLD\n")
      original_target_bytes = File.binread(external_target)
      File.symlink(external_agents, File.join(root, ".agents"))

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_includes error.message, "policy config path has a symlink or non-directory ancestor"
      assert File.symlink?(File.join(root, ".agents"))
      assert_equal external_agents, File.readlink(File.join(root, ".agents"))
      assert_equal original_target_bytes, File.binread(external_target)
      refute File.exist?(policy_path) && !File.symlink?(File.join(root, ".agents"))
    end
  end

  def test_policy_reconcile_refuses_selected_block_scalar_without_changing_bytes
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.binwrite(policy_path, "base_branch: main\nrepo_prefix: |-\n  OLD\n")
      original_bytes = File.binread(policy_path)

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_equal "selected policy key is not a supported single-line top-level scalar: repo_prefix", error.message
      assert_equal original_bytes, File.binread(policy_path)
    end
  end

  def test_policy_reconcile_preserves_unselected_wrapped_and_block_scalars_when_updating_or_appending
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))

      wrapped = "base_branch: main\nreview_gate: review this carefully before merging\n  and preserve the full rationale\nrepo_prefix: OLD\n"
      File.binwrite(policy_path, wrapped)
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal wrapped.sub("repo_prefix: OLD", "repo_prefix: ROR"), File.binread(policy_path)

      block = "base_branch: main\nrelease_notes: |-\n  first line\n  second line\n"
      File.binwrite(policy_path, block)
      assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      assert_equal "#{block}repo_prefix: ROR\n", File.binread(policy_path)
    end
  end

  def test_policy_reconcile_refuses_multiple_documents_before_appending_missing_key
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.binwrite(policy_path, "base_branch: main\n---\nrepo_prefix: OLD\n")
      original_bytes = File.binread(policy_path)

      error = assert_raises(RuntimeError) do
        PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
      end

      assert_equal "policy config must contain exactly one YAML document; policy-only reconciliation is unsafe", error.message
      assert_equal original_bytes, File.binread(policy_path)
    end
  end

  def test_policy_reconcile_appends_implicit_yaml_key_names_as_exact_strings
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(policy_path, "base_branch: main\n")
      selected_policy = { "true" => "TRUE", "yes" => "YES", "null" => "NULL", "repo_prefix" => "ROR" }

      assert PushDownstream.reconcile_policy_keys(root, selected_policy)

      parsed = YAML.safe_load(File.read(policy_path), aliases: false)
      assert_equal selected_policy, parsed.slice(*selected_policy.keys)
      assert_equal selected_policy.keys.sort, parsed.keys.grep(String).reject { |key| key == "base_branch" }.sort
      assert_includes File.read(policy_path), "repo_prefix: ROR\n"
    end
  end

  def test_policy_scalar_yaml_round_trips_non_bmp_strings_and_rejects_non_finite_floats
    value = "prefix 😀 suffix"

    scalar = PushDownstream.policy_scalar_yaml(value)
    assert_equal value, YAML.safe_load(scalar, aliases: false)
    assert_equal 1.25, YAML.safe_load(PushDownstream.policy_scalar_yaml(1.25), aliases: false)

    [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |non_finite|
      assert_raises(RuntimeError) { PushDownstream.policy_scalar_yaml(non_finite) }
    end
  end

  def test_policy_scalar_yaml_rejects_multiline_values_before_apply
    assert_raises(RuntimeError) { PushDownstream.policy_scalar_yaml("first\nsecond") }

    Dir.mktmpdir("push-downstream-policy-registry") do |dir|
      config = File.join(dir, "downstream.yml")
      File.write(config, <<~YAML)
        defaults: { owner: shakacode }
        policy_fleets:
          multiline-scalar:
            policy_keys: [custom]
            pr_branch: agent-workflows/repo-prefix
            repos:
              - repo: alpha
                base_branch: main
                policy:
                  custom: |-
                    first
                    second
      YAML

      out, err = with_module_stub(PushDownstream, :sync_policy_repo, ->(*) { flunk "must reject before apply" }) do
        capture_io do
          @status = PushDownstream.run_policy_fleet(config, fleet_name: "multiline-scalar", only: nil, apply: true)
        end
      end

      assert_equal 1, @status
      assert_empty out
      assert_includes err, "unsupported scalar custom for shakacode/alpha"
    end
  end

  def test_policy_open_pr_state_ignores_fork_head_and_accepts_same_repository_head
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }
    status = Struct.new(:success?).new(true)
    pull_requests = [
      {
        "url" => "https://example.test/pr/fork",
        "baseRefName" => "main",
        "headRefName" => "agent-workflows/repo-prefix",
        "headRepository" => { "name" => "consumer", "nameWithOwner" => "outside/consumer" },
        "headRepositoryOwner" => { "login" => "outside" }
      },
      {
        "url" => "https://example.test/pr/same-repository",
        "baseRefName" => "main",
        "headRefName" => "agent-workflows/repo-prefix",
        "headRepository" => { "name" => "consumer", "nameWithOwner" => "shakacode/consumer" },
        "headRepositoryOwner" => { "login" => "shakacode" }
      }
    ]
    command = []

    with_module_stub(Open3, :capture2, lambda { |*args|
      command.replace(args)
      [JSON.generate(pull_requests), status]
    }) do
      url, succeeded, base = PushDownstream.policy_open_pr_state(repo, any_base: true)
      assert succeeded
      assert_equal "https://example.test/pr/same-repository", url
      assert_equal "main", base
    end

    refute_includes command, "--base"
    assert_includes command, "--limit"
    assert_includes command, PushDownstream::POLICY_PR_LIST_LIMIT.to_s
    assert_includes command, "url,baseRefName,headRepository,headRepositoryOwner,headRefName"
  end

  def test_policy_open_pr_state_fails_closed_and_returns_all_same_repository_matches
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }
    status = Struct.new(:success?).new(true)
    main_pr = {
      "url" => "https://example.test/pr/main",
      "baseRefName" => "main",
      "headRefName" => "agent-workflows/repo-prefix",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "shakacode/consumer" },
      "headRepositoryOwner" => { "login" => "shakacode" }
    }
    release_pr = main_pr.merge("url" => "https://example.test/pr/release", "baseRefName" => "release")

    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate([main_pr, release_pr]), status] }) do
      url, succeeded, base, matches = PushDownstream.policy_open_pr_state(repo, any_base: true)
      assert_nil url
      refute succeeded
      assert_nil base
      assert_equal [main_pr, release_pr], matches
    end
  end

  def test_policy_open_pr_state_fails_closed_when_a_capped_fork_only_result_may_hide_same_repo_pr
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }
    status = Struct.new(:success?).new(true)
    fork_pr = {
      "url" => "https://example.test/pr/fork",
      "headRefName" => "agent-workflows/repo-prefix",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "outside/consumer" },
      "headRepositoryOwner" => { "login" => "outside" }
    }
    pull_requests = Array.new(PushDownstream::POLICY_PR_LIST_LIMIT, fork_pr)

    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate(pull_requests), status] }) do
      url, succeeded = PushDownstream.policy_open_pr_state(repo, any_base: true)
      assert_nil url
      refute succeeded
    end
  end

  def test_policy_open_pr_state_fails_closed_when_a_capped_result_has_only_a_configured_base_pr
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }
    status = Struct.new(:success?).new(true)
    fork_pr = {
      "url" => "https://example.test/pr/fork",
      "headRefName" => "agent-workflows/repo-prefix",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "outside/consumer" },
      "headRepositoryOwner" => { "login" => "outside" }
    }
    same_repo_pr = fork_pr.merge(
      "url" => "https://example.test/pr/same-repository",
      "baseRefName" => "main",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "shakacode/consumer" },
      "headRepositoryOwner" => { "login" => "shakacode" }
    )
    pull_requests = Array.new(PushDownstream::POLICY_PR_LIST_LIMIT - 1, fork_pr) + [same_repo_pr]

    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate(pull_requests), status] }) do
      url, succeeded, base, matches = PushDownstream.policy_open_pr_state(repo, any_base: true)
      assert_nil url
      refute succeeded
      assert_nil base
      assert_equal [same_repo_pr], matches
    end
  end

  def test_ensure_policy_pull_request_uses_repository_bound_lookup_after_push
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }
    status = Struct.new(:success?).new(true)
    fork_pr = {
      "url" => "https://example.test/pr/fork",
      "headRefName" => "agent-workflows/repo-prefix",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "outside/consumer" },
      "headRepositoryOwner" => { "login" => "outside" }
    }
    same_repo_pr = fork_pr.merge(
      "url" => "https://example.test/pr/same-repository",
      "headRepository" => { "name" => "consumer", "nameWithOwner" => "shakacode/consumer" },
      "headRepositoryOwner" => { "login" => "shakacode" }
    )

    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate([fork_pr]), status] }) do
      with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/new" }) do
        out, = capture_io { assert PushDownstream.ensure_policy_pull_request(repo) }
        assert_includes out, "PR shakacode/consumer https://example.test/pr/new"
      end
    end

    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate([same_repo_pr]), status] }) do
      with_module_stub(PushDownstream, :create_policy_pr, ->(*) { flunk "must reuse only the same-repository PR" }) do
        out, = capture_io { assert PushDownstream.ensure_policy_pull_request(repo) }
        assert_includes out, "PR shakacode/consumer https://example.test/pr/same-repository"
      end
    end
  end

  def test_ensure_policy_pull_request_fails_closed_when_state_lookup_is_unavailable
    repo = { nwo: "shakacode/consumer", pr_branch: "agent-workflows/repo-prefix", base_branch: "main" }

    with_module_stub(PushDownstream, :policy_open_pr_state, ->(*) { [nil, false] }) do
      with_module_stub(PushDownstream, :create_policy_pr, ->(*) { flunk "must not create without a proven PR state" }) do
        _out, err = capture_io { refute PushDownstream.ensure_policy_pull_request(repo) }
        assert_includes err, "could not prove whether the policy branch has an open PR"
      end
    end
  end

  def test_policy_value_comparisons_require_exact_scalar_classes_in_both_directions
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))

      [[1, 1.0, Float], [1.0, 1, Integer]].each do |existing, desired, expected_class|
        File.write(policy_path, { "repo_prefix" => existing }.to_yaml)
        assert PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => desired })
        actual = YAML.safe_load(File.read(policy_path), aliases: false).fetch("repo_prefix")
        assert_instance_of expected_class, actual

        repo = { base_branch: "main" }
        with_module_stub(PushDownstream, :policy_config_at_ref, ->(_clone, _ref) { { "repo_prefix" => existing } }) do
          refute PushDownstream.policy_base_has_desired_values?(repo, "unused", { "repo_prefix" => desired })
        end
      end
    end
  end

  def test_policy_unselected_values_reject_nested_mapping_key_type_changes
    base_policy = { "unselected" => { 1 => "value" } }
    head_policy = { "unselected" => { "1" => "value" } }

    refute PushDownstream.policy_unselected_values_match?(base_policy, head_policy, ["repo_prefix"])

    nil_base_policy = { "unselected" => { 1 => nil } }
    nil_head_policy = { "unselected" => { 1.0 => nil } }
    refute PushDownstream.policy_unselected_values_match?(nil_base_policy, nil_head_policy, ["repo_prefix"])
  end

  def test_policy_reconcile_fails_closed_when_missing_key_cannot_be_appended_to_block_mapping
    Dir.mktmpdir("push-downstream-policy-reconcile") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))

      ["{ base_branch: main }\n", "base_branch: main\n...\n", "base_branch: main\r\n... # explicit end\r\n"].each do |content|
        File.binwrite(policy_path, content)
        original_bytes = File.binread(policy_path)
        error = assert_raises(RuntimeError) do
          PushDownstream.reconcile_policy_keys(root, { "repo_prefix" => "ROR" })
        end
        assert_equal "cannot append selected policy key outside a top-level block mapping", error.message
        assert_equal original_bytes, File.binread(policy_path)
      end
    end
  end

  def test_policy_apply_commits_only_policy_config_after_valid_seam_preflight
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, _seed = seed_valid_remote(dir)
      repo = {
        repo: "consumer",
        nwo: "local/consumer",
        base_branch: "main",
        pr_branch: "agent-workflows/repo-prefix",
        policy: { "repo_prefix" => "ROR" },
        remote_url: remote
      }

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end

      policy_branch = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      refute_empty policy_branch
      changed_paths = `git --git-dir=#{remote.shellescape} diff --name-only refs/heads/main...#{policy_branch}`.lines.map(&:strip)
      assert_equal [".agents/agent-workflow.yml"], changed_paths

      clone = File.join(dir, "verify")
      assert system("git", "clone", "--branch", "agent-workflows/repo-prefix", remote, clone, out: File::NULL)
      policy = YAML.safe_load(File.read(File.join(clone, ".agents/agent-workflow.yml")), aliases: false)
      assert_equal "ROR", policy.fetch("repo_prefix")
      assert_equal "main", policy.fetch("base_branch")
      assert_equal "Follow-up:", policy.fetch("follow_up_prefix")
    end
  end

  def test_policy_apply_fails_closed_when_consumer_seam_is_missing
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote = File.join(dir, "remote.git")
      seed = File.join(dir, "seed")
      system("git", "init", "--bare", remote, out: File::NULL)
      system("git", "clone", remote, seed, out: File::NULL)
      configure_git_author(seed)
      File.write(File.join(seed, "README.md"), "base\n")
      system("git", "-C", seed, "add", "README.md")
      system("git", "-C", seed, "commit", "-m", "base", out: File::NULL)
      system("git", "-C", seed, "branch", "-M", "main")
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      repo = {
        repo: "consumer", nwo: "local/consumer", base_branch: "main",
        pr_branch: "agent-workflows/repo-prefix", policy: { "repo_prefix" => "ROR" }, remote_url: remote
      }
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }

      assert_includes err, "seam doctor on current base before policy update"
      assert_includes err, "missing AGENTS.md"
      refute system("git", "--git-dir=#{remote}", "show-ref", "--verify", "--quiet", "refs/heads/agent-workflows/repo-prefix")
    end
  end

  def test_policy_apply_rejects_existing_branch_with_unrelated_changes
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.write(File.join(seed, "unrelated.txt"), "do not include\n")
      system("git", "-C", seed, "add", "unrelated.txt")
      system("git", "-C", seed, "commit", "-m", "unrelated", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      repo = {
        repo: "consumer", nwo: "local/consumer", base_branch: "main",
        pr_branch: "agent-workflows/repo-prefix", policy: { "repo_prefix" => "ROR" }, remote_url: remote
      }
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }

      assert_includes err, "existing policy branch includes non-policy paths: unrelated.txt"
      branch_paths = `git --git-dir=#{remote.shellescape} diff --name-only refs/heads/main...refs/heads/agent-workflows/repo-prefix`.lines.map(&:strip)
      assert_equal ["unrelated.txt"], branch_paths
    end
  end

  def test_policy_apply_rejects_retained_branch_update_with_open_pr_on_alternate_base_before_mutation
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "OLD")
      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip

      queries = []
      with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
        queries << any_base
        [
          nil,
          false,
          nil,
          [
            { "url" => "https://example.test/pr/main", "baseRefName" => "main" },
            { "url" => "https://example.test/pr/alternate-base", "baseRefName" => "release" }
          ]
        ]
      }) do
        _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
        assert_includes err, "retained policy branch has open PR on alternate base release https://example.test/pr/alternate-base"
      end

      assert_equal [true], queries
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_leases_normal_retained_branch_update_to_checked_out_remote_head
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "OLD")
      branch = "agent-workflows/repo-prefix"
      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/#{branch}`.strip
      git_calls = []
      policy_states = [[nil, true, nil], [nil, true, nil], [nil, true, nil]]
      original_git = PushDownstream.method(:git)

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { policy_states.shift }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          with_module_stub(PushDownstream, :git, lambda { |clone, *args|
            git_calls << args
            original_git.call(clone, *args)
          }) do
            out, = capture_io { assert PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
            assert_includes out, "PR local/consumer https://example.test/pr/1"
          end
        end
      end

      assert_includes git_calls, [
        "push", "--force-with-lease=refs/heads/#{branch}:#{branch_before}", "origin", "HEAD:#{branch}"
      ]
      refute_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/#{branch}`.strip
    end
  end

  def test_policy_apply_rechecks_base_before_pushing_a_new_policy_branch
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, = seed_valid_remote(dir)
      branch = "agent-workflows/repo-prefix"

      with_module_stub(PushDownstream, :policy_base_ref_matches_remote?, ->(_repo, _clone) { false }) do
        _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
        assert_includes err, "current base moved before policy push; rerun from fresh state"
      end

      refute system("git", "--git-dir=#{remote}", "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
    end
  end

  def test_policy_apply_leases_new_branch_creation_against_a_branch_appearing_before_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      branch = "agent-workflows/repo-prefix"
      git_calls = []
      original_git = PushDownstream.method(:git)
      created_remote_branch = false

      with_module_stub(PushDownstream, :create_policy_pr, ->(*) { flunk "must not create a PR after branch-creation race" }) do
        with_module_stub(PushDownstream, :git, lambda { |clone, *args|
          git_calls << args
          if args.first == "push" && !created_remote_branch
            system("git", "-C", seed, "checkout", "-B", "policy-race", "main", out: File::NULL)
            system("git", "-C", seed, "push", "origin", "HEAD:#{branch}", out: File::NULL)
            created_remote_branch = true
          end
          original_git.call(clone, *args)
        }) do
          out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          refute_includes out, "PR local/consumer"
          assert_includes err, "policy push failed"
        end
      end

      assert created_remote_branch
      assert_includes git_calls, ["push", "--force-with-lease=refs/heads/#{branch}:", "origin", "HEAD:#{branch}"]
    end
  end

  def test_policy_apply_cancels_retained_branch_push_when_alternate_base_pr_appears_after_preflight
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "OLD")
      git_calls = []
      policy_states = [
        [nil, true, nil, []],
        [nil, true, nil, [{ "url" => "https://example.test/pr/release", "baseRefName" => "release" }]]
      ]
      original_git = PushDownstream.method(:git)

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { policy_states.shift }) do
        with_module_stub(PushDownstream, :git, lambda { |clone, *args|
          git_calls << args
          original_git.call(clone, *args)
        }) do
          _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes err, "retained policy branch gained open PR on alternate base release https://example.test/pr/release; policy push cancelled"
        end
      end

      refute(git_calls.any? { |args| args.first == "push" })
    end
  end

  def test_policy_apply_refuses_success_when_policy_branch_moves_after_pr_creation
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      branch = "agent-workflows/repo-prefix"

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, lambda { |_repo, _branch|
          system("git", "-C", seed, "checkout", "-B", "policy-race", "main", out: File::NULL)
          File.write(File.join(seed, "README.md"), "raced after policy push\n")
          system("git", "-C", seed, "add", "README.md")
          system("git", "-C", seed, "commit", "-m", "move policy branch", out: File::NULL)
          system("git", "-C", seed, "push", "--force", "origin", "HEAD:#{branch}", out: File::NULL)
          "https://example.test/pr/1"
        }) do
          out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          refute_includes out, "PR local/consumer"
          assert_includes err, "policy branch moved while confirming its PR; rerun from fresh state"
        end
      end
    end
  end

  def test_policy_apply_rejects_hidden_unrelated_commit_that_was_reverted_in_net_diff
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.write(File.join(seed, "unrelated.txt"), "do not retain\n")
      system("git", "-C", seed, "add", "unrelated.txt")
      system("git", "-C", seed, "commit", "-m", "add unrelated", out: File::NULL)
      system("git", "-C", seed, "rm", "unrelated.txt", out: File::NULL)
      system("git", "-C", seed, "commit", "-m", "revert unrelated", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

      assert_includes err, "includes non-policy paths: unrelated.txt"
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_rejects_retained_branch_when_current_base_seam_is_invalid
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "ROR")
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      File.write(File.join(seed, ".agents/bin/test"), "invalid base seam\n")
      system("git", "-C", seed, "add", ".agents/bin/test")
      system("git", "-C", seed, "commit", "-m", "break base seam", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

      assert_includes err, "seam doctor on current base before policy update"
      assert_includes err, "script is not a bash wrapper: .agents/bin/test"
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_uses_merge_base_so_current_base_only_movement_is_not_branch_drift
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "ROR")
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      File.write(File.join(seed, "base-only.txt"), "moved after branch\n")
      system("git", "-C", seed, "add", "base-only.txt")
      system("git", "-C", seed, "commit", "-m", "base-only movement", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      repo = policy_repo(remote, "ROR")
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end
    end
  end

  def test_policy_apply_rejects_same_value_branch_with_unselected_textual_policy_change
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.open(File.join(seed, ".agents/agent-workflow.yml"), "a") { |file| file << "# retained formatting change\n" }
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "format policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "NEXT"), ["repo_prefix"]) }

      assert_includes err, "existing policy branch changes content outside selected top-level policy lines"
    end
  end

  def test_policy_apply_rejects_quoted_multiline_unselected_branch_mutation_without_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.open(File.join(seed, ".agents/agent-workflow.yml"), "a") do |file|
        file << "custom_policy: \"before\nrepo_prefix: after\"\n"
      end
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "multiline unrelated policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

      assert_includes err, "existing policy branch changes parsed unselected policy values"
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_rejects_semantic_same_edit_inside_unselected_multiline_scalar
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      policy_path = File.join(seed, ".agents/agent-workflow.yml")
      File.open(policy_path, "a") { |file| file << "custom_policy: \"before\n  repo_prefix: after\"\n" }
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "add multiline custom policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      content = File.binread(policy_path).sub("\n  repo_prefix: after\"\n", "\n    repo_prefix: after\"\n")
      File.binwrite(policy_path, content)
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "format multiline custom policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      base_policy = YAML.safe_load(`git --git-dir=#{remote.shellescape} show refs/heads/main:.agents/agent-workflow.yml`, aliases: false)
      branch_policy = YAML.safe_load(`git --git-dir=#{remote.shellescape} show refs/heads/agent-workflows/repo-prefix:.agents/agent-workflow.yml`, aliases: false)
      assert_equal base_policy.fetch("custom_policy"), branch_policy.fetch("custom_policy")

      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "NEXT"), ["repo_prefix"]) }

      assert_includes err, "existing policy branch changes content outside selected top-level policy lines"
    end
  end

  def test_policy_apply_rejects_retained_branch_with_multiple_yaml_documents_without_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.open(File.join(seed, ".agents/agent-workflow.yml"), "a") { |file| file << "---\nrepo_prefix: ROR\n" }
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "second policy document", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

      assert_includes err, "existing policy branch does not have exactly one YAML document; policy-only isolation is unsafe"
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_reports_up_to_date_for_retained_squash_merged_branch_with_desired_values
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "ROR")
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "squash merge prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      any_base_queries = []
      with_module_stub(PushDownstream, :existing_pr_url, ->(_repo, _branch) { flunk "must not create an empty PR" }) do
        with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
          any_base_queries << any_base
          [nil, true]
        }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes out, "UP_TO_DATE local/consumer"
        end
      end
      assert_equal [true], any_base_queries
    end
  end

  def test_policy_apply_reruns_retained_branch_with_unchanged_unselected_multiline_scalar
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      policy_path = File.join(seed, ".agents/agent-workflow.yml")
      File.open(policy_path, "a") do |file|
        file << "custom_policy: review the generated workflow carefully\n  before merging changes\n"
      end
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure wrapped policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      any_base_queries = []
      with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
        any_base_queries << any_base
        [nil, true]
      }) do
        out, = capture_io { assert PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

        assert_includes out, "UP_TO_DATE local/consumer"
      end
      assert_equal [true], any_base_queries
    end
  end

  def test_policy_apply_refreshes_retained_branch_after_base_drifts_without_open_pr
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "drift prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end

      clone = File.join(dir, "verify-refresh")
      assert system("git", "clone", "--branch", "agent-workflows/repo-prefix", remote, clone, out: File::NULL)
      policy = YAML.safe_load(File.read(File.join(clone, ".agents/agent-workflow.yml")), aliases: false)
      assert_equal "ROR", policy.fetch("repo_prefix")
      assert_equal [".agents/agent-workflow.yml"], `git -C #{clone.shellescape} diff --name-only origin/main...HEAD`.lines.map(&:strip)
    end
  end

  def test_policy_refresh_rechecks_base_immediately_before_leased_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "drift prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch = "agent-workflows/repo-prefix"
      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/#{branch}`.strip
      original_remote_ref_head = PushDownstream.method(:remote_ref_head)
      base_reads = 0

      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :remote_ref_head, lambda { |clone, ref|
          if ref == "refs/heads/main"
            base_reads += 1
            return "moved-base" if base_reads == 2
          end
          original_remote_ref_head.call(clone, ref)
        }) do
          _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes err, "current base moved before leased policy refresh push; rerun from fresh state"
        end
      end

      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/#{branch}`.strip
    end
  end

  def test_policy_refresh_cancels_when_open_pr_appears_before_leased_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "drift prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      states = [[nil, true], [nil, true], [nil, true], ["https://example.test/pr/1", true]]
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { states.shift }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { flunk "must not create a PR after race" }) do
          _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes err, "retained policy branch gained open PR on any base https://example.test/pr/1; refresh push cancelled"
        end
      end
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_refuses_retained_pr_success_when_remote_branch_moves_after_lookup
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "ROR")

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { ["https://example.test/pr/1", true, "main"] }) do
        with_module_stub(PushDownstream, :remote_ref_head, ->(_clone, _ref) { "remote-branch-moved" }) do
          with_module_stub(PushDownstream, :local_ref_head, ->(_clone, _ref) { "locally-validated-branch" }) do
            _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
            assert_includes err, "retained policy branch moved while confirming its open PR; rerun from fresh state"
          end
        end
      end
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_refresh_rejects_active_pr_on_an_alternate_base_before_push
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "drift prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      queries = []
      with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
        queries << any_base
        any_base ? ["https://example.test/pr/alternate-base", true, "release"] : [nil, true]
      }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { flunk "must not create a PR" }) do
          _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes err, "retained policy branch has open PR on alternate base release https://example.test/pr/alternate-base"
        end
      end

      assert_equal [true], queries
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_reports_up_to_date_from_current_base_before_touching_retained_branch
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "stale prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure current base", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      any_base_queries = []
      with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
        any_base_queries << any_base
        [nil, true]
      }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(*) { flunk "must not create a PR" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
          assert_includes out, "UP_TO_DATE local/consumer"
        end
      end
      assert_equal [true], any_base_queries
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_refuses_up_to_date_when_retained_old_branch_has_alternate_base_pr
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      push_policy_branch(seed, "OLD")
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure current base", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      any_base_queries = []
      with_module_stub(PushDownstream, :policy_open_pr_state, lambda { |_repo, any_base: false|
        any_base_queries << any_base
        ["https://example.test/pr/release", true, "release"]
      }) do
        out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
        refute_includes out, "UP_TO_DATE"
        assert_includes err, "retained policy branch has open PR on any base https://example.test/pr/release; close it before reporting up to date"
      end

      assert_equal [true], any_base_queries
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_rejects_desired_base_with_duplicate_selected_keys_before_checkout
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      policy_path = File.join(seed, ".agents/agent-workflow.yml")
      File.open(policy_path, "a") { |file| file << "repo_prefix: OLD\nrepo_prefix: ROR\n" }
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "duplicate desired prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      base_before = `git --git-dir=#{remote.shellescape} show refs/heads/main:.agents/agent-workflow.yml`
      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      with_module_stub(PushDownstream, :checkout_sync_branch, ->(*) { flunk "must reject ambiguous base before checkout" }) do
        out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
        refute_includes out, "UP_TO_DATE"
        assert_includes err, "current base policy config has ambiguous selected policy keys: repo_prefix"
      end

      assert_equal base_before, `git --git-dir=#{remote.shellescape} show refs/heads/main:.agents/agent-workflow.yml`
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_refuses_up_to_date_when_remote_base_differs_from_local_snapshot
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "stale prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
      system("git", "-C", seed, "checkout", "main", out: File::NULL)
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "ROR" })
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "configure current base", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      branch_before = `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
      with_module_stub(PushDownstream, :remote_ref_head, ->(_clone, _ref) { "remote-base-moved" }) do
        with_module_stub(PushDownstream, :local_ref_head, ->(_clone, _ref) { "local-base-snapshot" }) do
          with_module_stub(PushDownstream, :policy_open_pr_state, ->(*) { flunk "must not report or refresh" }) do
            _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }
            assert_includes err, "current base moved while checking retained policy branch; rerun from fresh state"
          end
        end
      end
      assert_equal branch_before, `git --git-dir=#{remote.shellescape} rev-parse refs/heads/agent-workflows/repo-prefix`.strip
    end
  end

  def test_policy_apply_allows_one_newline_missing_prefix_on_second_sync
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, _seed = seed_valid_remote(dir)

      repo = policy_repo(remote, "ROR")
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { ["https://example.test/pr/1", true, "main"] }) do
        out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
        assert_includes out, "PR local/consumer https://example.test/pr/1"
      end
    end
  end

  def test_policy_apply_allows_unterminated_file_missing_prefix_on_second_sync
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      policy_path = File.join(seed, ".agents/agent-workflow.yml")
      File.write(policy_path, File.read(policy_path).sub(/\n+\z/, ""))
      refute File.read(policy_path).end_with?("\n")
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "unterminated policy", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      repo = policy_repo(remote, "ROR")
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { ["https://example.test/pr/1", true, "main"] }) do
        result = nil
        out, err = capture_io { result = PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
        assert result, err
        assert_includes out, "PR local/consumer https://example.test/pr/1"
      end
    end
  end

  def test_policy_apply_allows_final_selected_key_without_terminal_newline_on_second_sync
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      policy_path = File.join(seed, ".agents/agent-workflow.yml")
      PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => "OLD" })
      File.write(policy_path, File.read(policy_path).delete_suffix("\n"))
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "unterminated prefix", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "main", out: File::NULL)

      repo = policy_repo(remote, "ROR")
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { [nil, true] }) do
        with_module_stub(PushDownstream, :create_policy_pr, ->(_repo, _branch) { "https://example.test/pr/1" }) do
          out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
          assert_includes out, "PR local/consumer https://example.test/pr/1"
        end
      end
      with_module_stub(PushDownstream, :policy_open_pr_state, ->(_repo, **) { ["https://example.test/pr/1", true, "main"] }) do
        out, = capture_io { assert PushDownstream.sync_policy_repo(repo, ["repo_prefix"]) }
        assert_includes out, "PR local/consumer https://example.test/pr/1"
      end
    end
  end

  def test_policy_apply_rejects_mode_only_change_on_retained_branch
    Dir.mktmpdir("push-downstream-policy-git") do |dir|
      remote, seed = seed_valid_remote(dir)
      system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
      File.chmod(0o755, File.join(seed, ".agents/agent-workflow.yml"))
      system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
      system("git", "-C", seed, "commit", "-m", "mode only", out: File::NULL)
      system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)

      _out, err = capture_io { refute PushDownstream.sync_policy_repo(policy_repo(remote, "ROR"), ["repo_prefix"]) }

      assert_includes err, "existing policy branch changes content outside selected top-level policy lines"
    end
  end

  private

  def seed_valid_remote(dir)
    remote = File.join(dir, "remote.git")
    seed = File.join(dir, "seed")
    system("git", "init", "--bare", remote, out: File::NULL)
    system("git", "clone", remote, seed, out: File::NULL)
    configure_git_author(seed)
    File.write(File.join(seed, "README.md"), "base\n")
    PushDownstream.reconcile_scaffold(seed, CONTRACT)
    system("git", "-C", seed, "add", ".")
    system("git", "-C", seed, "commit", "-m", "base", out: File::NULL)
    system("git", "-C", seed, "branch", "-M", "main")
    system("git", "-C", seed, "push", "origin", "main", out: File::NULL)
    [remote, seed]
  end

  def configure_git_author(dir)
    system("git", "-C", dir, "config", "user.email", "test@example.com")
    system("git", "-C", dir, "config", "user.name", "Test")
  end

  def push_policy_branch(seed, prefix)
    system("git", "-C", seed, "checkout", "-b", "agent-workflows/repo-prefix", out: File::NULL)
    PushDownstream.reconcile_policy_keys(seed, { "repo_prefix" => prefix })
    system("git", "-C", seed, "add", ".agents/agent-workflow.yml")
    system("git", "-C", seed, "commit", "-m", "configure prefix", out: File::NULL)
    system("git", "-C", seed, "push", "origin", "agent-workflows/repo-prefix", out: File::NULL)
  end

  def policy_repo(remote, prefix)
    {
      repo: "consumer", nwo: "local/consumer", base_branch: "main",
      pr_branch: "agent-workflows/repo-prefix", policy: { "repo_prefix" => prefix }, remote_url: remote
    }
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

  def test_policy_fleet_apply_rejects_explicit_empty_only_without_syncing
    out, status = run_cli("--policy-fleet", "repo-prefix", "--only", "", "--apply")

    refute status.success?
    assert_includes out, "policy fleet selection must include at least one non-blank repository"
    refute_includes out, "PR shakacode/"
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

  def test_local_apply_can_seed_trusted_actors
    Dir.mktmpdir("push-downstream-cli") do |root|
      out, status = run_cli(
        "--root", root, "--apply",
        "--trusted-user", "justin808",
        "--trusted-bot", "coderabbitai",
        "--trusted-metadata-bot", "github-actions",
        "--trusted-team", "acme/maintainers"
      )

      assert status.success?, out
      trust = YAML.safe_load(File.read(File.join(root, ".agents/trusted-github-actors.yml")), aliases: false)
      assert_equal ["justin808"], trust.fetch("trusted_users")
      assert_equal ["coderabbitai"], trust.fetch("trusted_bots")
      assert_equal ["github-actions"], trust.fetch("trusted_metadata_bots")
      assert_equal ["acme/maintainers"], trust.fetch("trusted_teams")
    end
  end

  def test_registry_mode_rejects_cli_trust_flags
    out, status = run_cli("--trusted-user", "justin808")

    refute status.success?, out
    assert_includes out, "--trusted-* flags require --root"
  end

  def test_local_apply_reports_invalid_trust_config_without_backtrace
    Dir.mktmpdir("push-downstream-cli") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/trusted-github-actors.yml"), {
        "trusted_users" => [],
        "trusted_bots" => ["github-actions"],
        "trusted_metadata_bots" => ["github-actions"],
        "trusted_teams" => []
      }.to_yaml)

      out, status = run_cli("--root", root, "--apply", "--trusted-user", "maintainer-login")

      refute status.success?, out
      assert_includes out, "FAIL #{root}: invalid trust config"
      assert_includes out, "bot(s) listed in both trusted_bots and trusted_metadata_bots: github-actions"
      refute_includes out, "Traceback"
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
