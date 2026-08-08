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
