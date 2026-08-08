#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class SecureGitHubActionsScanTest < Minitest::Test
  SCANNER = File.expand_path("secure-github-actions-scan", __dir__)
  FIXTURES = File.expand_path("../fixtures", __dir__)

  def test_cli_rejects_expression_in_block_run_scalar
    with_repository(<<~YAML, trusted_actions: ["owner/workflows"]) do |root|
      jobs:
        build:
          steps:
            - run: |
                echo "${{ github.event.pull_request.title }}"
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/expression-in-run"], rule_ids(document)
      assert_equal ".github/workflows/test.yml",
                   document.fetch("review_findings").first.dig("location", "file")
    end
  end

  def test_cli_rejects_mutable_external_use
    with_repository(<<~YAML, trusted_actions: ["owner/action"]) do |root|
      jobs:
        build:
          steps:
            - uses: owner/action@v1 # v1
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unpinned-external-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_cli_rejects_pinned_external_use_without_readable_version_comment
    sha = "0123456789abcdef0123456789abcdef01234567"
    with_repository(<<~YAML, trusted_actions: ["owner/action"]) do |root|
      jobs:
        build:
          steps:
            - uses: owner/action@#{sha}
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/missing-version-comment"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_missing_allowlist_fails_closed_for_pinned_external_use
    sha = "0123456789abcdef0123456789abcdef01234567"
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: owner/action@#{sha} # v1.2.3
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/untrusted-external-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_local_action_reference_cannot_escape_repository
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./nested/../../outside
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsafe-local-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_local_action_symlink_cannot_escape_repository
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_path = File.join(root, ".github/workflows/test.yml")
      outside_action = File.join(outer, "outside-action")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      FileUtils.mkdir_p(outside_action)
      File.write(File.join(outside_action, "action.yml"), "runs: { using: composite, steps: [] }\n")
      File.symlink(outside_action, File.join(root, "linked-action"))
      File.write(workflow_path, <<~YAML)
        jobs:
          build:
            steps:
              - uses: ./linked-action
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsafe-local-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_malformed_workflow_fails_closed_as_structured_finding
    with_repository("jobs: [\n") do |root|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/invalid-yaml"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_expression_detection_covers_folded_and_explicit_string_scalars
    with_repository(<<~'YAML') do |root|
      jobs:
        build:
          steps:
            - run: >-
                echo "${{ github.ref }}"
            - run: !!str 'echo "${{ github.sha }}"'
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/expression-in-run",
        "secure-github-actions/expression-in-run"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_timestamp_scalar_regression_does_not_prevent_action_checks
    sha = "0123456789abcdef0123456789abcdef01234567"
    with_repository(<<~YAML, trusted_actions: ["owner/action"]) do |root|
      generated_on: 2026-08-02
      generated_at: 2026-08-02T12:34:56Z
      jobs:
        build:
          steps:
            - uses: owner/action@v1 # v1
            - uses: owner/action@#{sha} # v1.2.3
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unpinned-external-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_aliases_cannot_hide_sensitive_step_content
    with_repository(<<~'YAML', trusted_actions: ["owner/action"]) do |root|
      hidden_run: &hidden_run
        run: echo "${{ github.event.pull_request.title }}"
      hidden_use: &hidden_use
        uses: owner/action@v1
      jobs:
        build:
          steps:
            - *hidden_run
            - <<: *hidden_use
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsupported-yaml-alias",
        "secure-github-actions/unsupported-yaml-alias"
      ], rule_ids(document)
      symbols = document.fetch("review_findings").map { |finding| finding.dig("location", "symbol") }
      assert_equal [
        "jobs.build.steps.0",
        "jobs.build.steps.1.<<"
      ], symbols
    end
  end

  def test_unknown_and_cyclic_aliases_fail_closed_at_step_boundaries
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - *unknown_step
            - &cyclic_step
              <<: *cyclic_step
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/unsupported-yaml-alias",
        "secure-github-actions/unsupported-yaml-alias"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_composite_step_alias_fails_closed
    with_repository("jobs: {}\n") do |root|
      action_path = File.join(root, "components/aliased/action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(action_path, <<~'YAML')
        hidden: &hidden
          run: echo "${{ github.event.issue.title }}"
        runs:
          using: composite
          steps:
            - *hidden
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      finding = JSON.parse(stdout).fetch("review_findings").first
      assert_equal "secure-github-actions/unsupported-yaml-alias", finding.fetch("rule_id")
      assert_equal "runs.steps.0", finding.dig("location", "symbol")
    end
  end

  def test_alias_mapping_key_cannot_hide_root_jobs
    with_repository(<<~YAML) do |root|
      jobs_key: &jobs_key jobs
      *jobs_key:
        build:
          runs-on: ubuntu-latest
          steps:
            - run: echo safe
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      finding = JSON.parse(stdout).fetch("review_findings").first
      assert_equal "secure-github-actions/unsupported-yaml-mapping-key", finding.fetch("rule_id")
      assert_equal ".github/workflows/test.yml", finding.dig("location", "file")
      assert_equal 2, finding.dig("location", "line")
      assert_includes finding.dig("location", "symbol"), "non-scalar-key"
    end
  end

  def test_alias_mapping_keys_cannot_hide_workflow_step_run_or_uses
    with_repository(<<~'YAML', trusted_actions: ["owner/action"]) do |root|
      run_key: &run_key run
      uses_key: &uses_key uses
      jobs:
        build:
          steps:
            - *run_key: echo "${{ github.event.pull_request.title }}"
            - *uses_key: owner/action@v1
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/unsupported-yaml-mapping-key",
        "secure-github-actions/unsupported-yaml-mapping-key"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_alias_mapping_key_cannot_hide_job_level_reusable_workflow_use
    with_repository(<<~YAML, trusted_actions: ["owner/workflows"]) do |root|
      uses_key: &uses_key uses
      jobs:
        deploy:
          *uses_key: owner/workflows/.github/workflows/deploy.yml@v1
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsupported-yaml-mapping-key"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_alias_mapping_keys_cannot_hide_composite_step_run_or_uses
    with_repository("jobs: {}\n", trusted_actions: ["owner/action"]) do |root|
      action_path = File.join(root, "components/key-alias/action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(action_path, <<~'YAML')
        run_key: &run_key run
        uses_key: &uses_key uses
        runs:
          using: composite
          steps:
            - *run_key: echo "${{ github.event.issue.title }}"
            - *uses_key: owner/action@v1
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsupported-yaml-mapping-key",
        "secure-github-actions/unsupported-yaml-mapping-key"
      ], rule_ids(document)
      files = document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
      assert_equal [
        "components/key-alias/action.yml",
        "components/key-alias/action.yml"
      ], files
    end
  end

  def test_scanner_covers_nested_composite_actions
    with_repository("jobs: {}\n", trusted_actions: ["owner/action"]) do |root|
      action_path = File.join(root, "components/example/action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(action_path, <<~YAML)
        runs:
          using: composite
          steps:
            - uses: owner/action@v1 # v1
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/unpinned-external-use"], rule_ids(document)
      assert_equal "components/example/action.yml",
                   document.fetch("review_findings").first.dig("location", "file")
    end
  end

  def test_symlinked_workflow_fails_closed_without_reading_target
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_path = File.join(root, ".github/workflows/linked.yml")
      outside_path = File.join(outer, "outside.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      File.write(outside_path, "jobs: {}\n")
      File.symlink(outside_path, workflow_path)

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/unsafe-file"], rule_ids(document)
      assert_equal ".github/workflows/linked.yml",
                   document.fetch("review_findings").first.dig("location", "file")
    end
  end

  def test_symlinked_workflows_directory_fails_closed_even_when_empty
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      outside = File.join(outer, "outside-workflows")
      FileUtils.mkdir_p(File.join(root, ".github"))
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(root, ".github/workflows"))

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/unsafe-file"], rule_ids(document)
      assert_equal ".github/workflows", document.fetch("review_findings").first.dig("location", "file")
    end
  end

  def test_symlinked_trusted_actions_policy_is_invalid_and_not_read
    sha = "0123456789abcdef0123456789abcdef01234567"
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_path = File.join(root, ".github/workflows/test.yml")
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      outside_policy = File.join(outer, "policy.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(workflow_path, <<~YAML)
        jobs:
          build:
            steps:
              - uses: owner/action@#{sha} # v1.2.3
      YAML
      File.write(outside_policy, YAML.dump("trusted_actions" => ["owner/action"]))
      File.symlink(outside_policy, policy_path)

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/invalid-trusted-actions-policy",
        "secure-github-actions/untrusted-external-use"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_sensitive_keys_with_non_scalar_values_fail_closed
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - run: [echo, unsafe]
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/invalid-structure"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_wildcard_allowlist_entry_is_invalid_and_does_not_trust_action
    sha = "0123456789abcdef0123456789abcdef01234567"
    with_repository(<<~YAML, trusted_actions: ["owner/*"]) do |root|
      jobs:
        build:
          steps:
            - uses: owner/action@#{sha} # v1.2.3
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/invalid-trusted-actions-policy",
        "secure-github-actions/untrusted-external-use"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_multiple_policy_documents_are_invalid_and_do_not_trust_action
    sha = "0123456789abcdef0123456789abcdef01234567"
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: owner/action@#{sha} # v1.2.3
    YAML
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(policy_path, <<~YAML)
        trusted_actions:
          - owner/action
        ---
        trusted_actions: []
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal [
        "secure-github-actions/invalid-trusted-actions-policy",
        "secure-github-actions/untrusted-external-use"
      ], rule_ids(JSON.parse(stdout))
    end
  end

  def test_local_digest_and_trusted_pinned_uses_are_clean
    sha = "0123456789abcdef0123456789abcdef01234567"
    digest = "a" * 64
    with_repository(<<~YAML, trusted_actions: ["owner/action"]) do |root|
      jobs:
        build:
          steps:
            - uses: ./.github/actions/local
            - uses: docker://alpine@sha256:#{digest}
            - uses: owner/action/subpath@#{sha} # v1.2.3
    YAML
      local_action = File.join(root, ".github/actions/local")
      FileUtils.mkdir_p(local_action)
      File.write(File.join(local_action, "action.yml"), "runs: { using: composite, steps: [] }\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      assert_empty rule_ids(JSON.parse(stdout))
    end
  end

  def test_referenced_local_action_in_excluded_root_is_rejected
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./tmp/evil
    YAML
      action = File.join(root, "tmp/evil/action.yml")
      FileUtils.mkdir_p(File.dirname(action))
      File.write(action, "runs: { using: composite, steps: [] }\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsafe-local-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_step_local_action_requires_a_regular_descriptor
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./local-action
    YAML
      FileUtils.mkdir_p(File.join(root, "local-action"))

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsafe-local-use"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_step_local_action_rejects_a_symlinked_descriptor
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_path = File.join(root, ".github/workflows/test.yml")
      action_dir = File.join(root, "local-action")
      outside = File.join(outer, "action.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      FileUtils.mkdir_p(action_dir)
      File.write(outside, "runs: { using: composite, steps: [] }\n")
      File.symlink(outside, File.join(action_dir, "action.yml"))
      File.write(workflow_path, <<~YAML)
        jobs:
          build:
            steps:
              - uses: ./local-action
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_includes rule_ids(JSON.parse(stdout)), "secure-github-actions/unsafe-local-use"
    end
  end

  def test_job_level_local_reusable_workflow_is_accepted
    with_repository(<<~YAML) do |root|
      on: workflow_call
      jobs:
        call:
          uses: ./.github/workflows/called.yml
    YAML
      File.write(File.join(root, ".github/workflows/called.yml"), <<~YAML)
        on: workflow_call
        jobs:
          called:
            runs-on: ubuntu-latest
            steps:
              - run: echo safe
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      assert_empty rule_ids(JSON.parse(stdout))
    end
  end

  def test_job_level_local_reusable_workflow_rejects_symlink
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_dir = File.join(root, ".github/workflows")
      outside = File.join(outer, "called.yml")
      FileUtils.mkdir_p(workflow_dir)
      File.write(outside, "on: workflow_call\njobs: {}\n")
      File.symlink(outside, File.join(workflow_dir, "called.yml"))
      File.write(File.join(workflow_dir, "caller.yml"), <<~YAML)
        on: workflow_call
        jobs:
          call:
            uses: ./.github/workflows/called.yml
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_includes rule_ids(JSON.parse(stdout)), "secure-github-actions/unsafe-local-use"
    end
  end

  def test_shakapacker_snapshot_replays_known_rollout_blockers
    root = File.join(FIXTURES, "shakapacker-2026-08-07")
    evidence = YAML.safe_load_file(File.join(root, "evidence.yml"), aliases: false)

    assert_equal "shakacode/shakapacker", evidence.fetch("repository")
    assert_equal "cdd7397cc59a1bfca89d7941e70fa61631e1ad5f", evidence.fetch("head_sha")
    refute_path_exists File.join(root, ".github/dependabot.yml")

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

    assert_equal 1, status.exitstatus
    assert_empty stderr
    assert_equal [
      "secure-github-actions/expression-in-run",
      "secure-github-actions/unpinned-external-use",
      "secure-github-actions/untrusted-external-use"
    ], rule_ids(JSON.parse(stdout))
  end

  def test_cli_rejects_secrets_inherit
    with_repository(<<~YAML, trusted_actions: ["owner/workflows"]) do |root|
      jobs:
        deploy:
          uses: owner/workflows/.github/workflows/deploy.yml@0123456789abcdef0123456789abcdef01234567 # v1
          secrets: inherit
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/secrets-inherit"], rule_ids(JSON.parse(stdout))
    end
  end

  private

  def with_repository(workflow, trusted_actions: nil)
    Dir.mktmpdir("secure-github-actions") do |root|
      path = File.join(root, ".github/workflows/test.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, workflow)
      if trusted_actions
        policy_path = File.join(root, ".agents/agent-workflow.yml")
        FileUtils.mkdir_p(File.dirname(policy_path))
        File.write(policy_path, YAML.dump("trusted_actions" => trusted_actions))
      end
      yield root
    end
  end

  def rule_ids(document)
    document.fetch("review_findings").map { |finding| finding.fetch("rule_id") }
  end
end
