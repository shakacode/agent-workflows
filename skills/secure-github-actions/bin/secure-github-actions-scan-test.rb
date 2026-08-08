#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "etc"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "../lib/secure_github_actions_scanner"

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

  def test_dot_prefixed_workflow_is_scanned
    with_repository("jobs: {}\n") do |root|
      hidden_workflow = File.join(root, ".github/workflows/.called.yml")
      File.write(hidden_workflow, <<~'YAML')
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.pull_request.title }}"
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      finding = JSON.parse(stdout).fetch("review_findings").first
      assert_equal "secure-github-actions/expression-in-run", finding.fetch("rule_id")
      assert_equal ".github/workflows/.called.yml", finding.dig("location", "file")
    end
  end

  def test_glob_metacharacter_root_scans_workflow_and_composite_action
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer[fixture]")
      workflow = File.join(root, ".github/workflows/unsafe.yml")
      action = File.join(root, "components/example/action.yml")
      policy = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(workflow))
      FileUtils.mkdir_p(File.dirname(action))
      FileUtils.mkdir_p(File.dirname(policy))
      File.write(workflow, <<~'YAML')
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.pull_request.title }}"
      YAML
      File.write(action, <<~YAML)
        runs:
          using: composite
          steps:
            - uses: owner/action@v1
      YAML
      File.write(policy, YAML.dump("trusted_actions" => ["owner/action"]))

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/expression-in-run",
        "secure-github-actions/unpinned-external-use"
      ], rule_ids(document)
      assert_equal [
        ".github/workflows/unsafe.yml",
        "components/example/action.yml"
      ], document.dig("scan", "files_scanned")
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

  def test_cli_accepts_flow_style_pinned_uses_with_same_line_version_comments
    sha = "0123456789abcdef0123456789abcdef01234567"
    workflows = [
      <<~YAML,
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - { uses: owner/action@#{sha} } # v1.2.3
      YAML
      "jobs: { build: { runs-on: ubuntu-latest, steps: [{ uses: owner/action@#{sha} }] } } # v1.2.3\n",
      <<~YAML,
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - { uses: owner/action@#{sha}, } # v1.2.3
      YAML
      "jobs: { build: { runs-on: ubuntu-latest, steps: [{ uses: owner/action@#{sha}, },] } } # v1.2.3\n"
    ]

    actual = workflows.map do |workflow|
      with_repository(workflow, trusted_actions: ["owner/action"]) do |root|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    assert_equal [[0, "", []], [0, "", []], [0, "", []], [0, "", []]], actual
  end

  def test_cli_rejects_flow_style_pinned_uses_with_unrelated_or_later_comments
    sha = "0123456789abcdef0123456789abcdef01234567"
    workflows = [
      <<~YAML,
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - { uses: owner/action@#{sha}, name: unrelated } # v1.2.3
      YAML
      <<~YAML
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - { uses: owner/action@#{sha} }
                # v1.2.3
      YAML
    ]

    actual = workflows.map do |workflow|
      with_repository(workflow, trusted_actions: ["owner/action"]) do |root|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    expected = [1, "", ["secure-github-actions/missing-version-comment"]]
    assert_equal [expected, expected], actual
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

  def test_repo_root_local_action_is_accepted_and_scanned
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./
    YAML
      File.write(File.join(root, "action.yml"), <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/expression-in-run"], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "action.yml"
    end
  end

  def test_local_action_reference_rejects_backslash_as_an_alternate_separator
    with_repository(<<~'YAML') do |root|
      jobs:
        build:
          steps:
            - uses: './tmp\evil'
    YAML
      action = File.join(root, "tmp\\evil/action.yml")
      FileUtils.mkdir_p(File.dirname(action))
      File.write(action, "runs: { using: composite, steps: [] }\n")

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

  def test_root_merge_alias_cannot_hide_jobs
    with_repository(<<~'YAML') do |root|
      hidden: &root
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.issue.title }}"
      <<: *root
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      finding = JSON.parse(stdout).fetch("review_findings").first
      assert_equal "secure-github-actions/unsupported-yaml-alias", finding.fetch("rule_id")
      assert_equal "<<", finding.dig("location", "symbol")
    end
  end

  def test_merge_alias_sequences_cannot_hide_jobs
    workflows = [
      <<~'YAML',
        hidden: &root
          jobs:
            build:
              steps:
                - run: echo "${{ github.event.issue.title }}"
        <<: [*root]
      YAML
      <<~'YAML'
        hidden: &jobs
          build:
            steps:
              - run: echo "${{ github.event.issue.title }}"
        jobs: { <<: [*jobs] }
      YAML
    ]

    actual = workflows.map do |workflow|
      with_repository(workflow) do |root|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    assert_equal [
      [1, "", ["secure-github-actions/unsupported-yaml-alias"]],
      [1, "", ["secure-github-actions/unsupported-yaml-alias"]]
    ], actual
  end

  def test_direct_merge_mapping_cannot_hide_jobs
    with_repository(<<~'YAML') do |root|
      <<:
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.issue.title }}"
    YAML
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      finding = JSON.parse(stdout).fetch("review_findings").first
      assert_equal "secure-github-actions/unsupported-yaml-alias", finding.fetch("rule_id")
      assert_equal "<<", finding.dig("location", "symbol")
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

  def test_git_action_discovery_scans_tracked_and_unignored_but_not_ignored_descriptors
    with_repository("jobs: {}\n") do |root|
      tracked_action = File.join(root, "actions/tracked/action.yml")
      untracked_action = File.join(root, "actions/untracked/action.yml")
      ignored_action = File.join(root, "node_modules/pkg/action.yml")
      [tracked_action, untracked_action, ignored_action].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~'YAML')
          runs:
            using: composite
            steps:
              - run: echo "${{ github.event.issue.title }}"
        YAML
      end
      File.write(File.join(root, ".gitignore"), "actions/tracked/\nnode_modules/\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore")
      git!(root, "add", "--force", "actions/tracked/action.yml")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "actions/tracked/action.yml",
        "actions/untracked/action.yml"
      ], document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
      refute_includes document.dig("scan", "files_scanned"), "node_modules/pkg/action.yml"
    end
  end

  def test_git_action_discovery_scans_case_variant_tracked_descriptor_on_case_insensitive_filesystems
    skip "filesystem is case-sensitive" unless filesystem_case_insensitive?

    with_repository("jobs: {}\n") do |root|
      indexed_action = File.join(root, "Actions/local/action.yml")
      FileUtils.mkdir_p(File.dirname(indexed_action))
      File.write(indexed_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.write(File.join(root, ".gitignore"), "actions/\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore")
      git!(root, "add", "--force", "Actions/local/action.yml")
      git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fixture")

      intermediate = File.join(root, "actions-case-rename")
      File.rename(File.join(root, "Actions"), intermediate)
      File.rename(intermediate, File.join(root, "actions"))
      assert_empty git!(root, "status", "--short")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/expression-in-run"], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "actions/local/action.yml"
    end
  end

  def test_git_action_discovery_scans_case_variant_tracked_descriptor_filename
    skip "filesystem is case-sensitive" unless filesystem_case_insensitive?

    with_repository("jobs: {}\n") do |root|
      indexed_action = File.join(root, "source/action.yml")
      FileUtils.mkdir_p(File.dirname(indexed_action))
      File.write(indexed_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", "source/action.yml")
      git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fixture")

      intermediate = File.join(root, "source/action-case-rename")
      File.rename(indexed_action, intermediate)
      File.rename(intermediate, File.join(root, "source/ACTION.YML"))
      assert_empty git!(root, "status", "--short")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["source/ACTION.YML"],
                   document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
      assert_includes document.dig("scan", "files_scanned"), "source/ACTION.YML"
    end
  end

  def test_explicitly_referenced_ignored_untracked_action_is_still_scanned
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./node_modules/pkg
    YAML
      action_path = File.join(root, "node_modules/pkg/action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(action_path, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.write(File.join(root, ".gitignore"), "node_modules/\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/expression-in-run"], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "node_modules/pkg/action.yml"
    end
  end

  def test_git_action_discovery_keeps_unignored_directory_boundary_findings
    with_repository("jobs: {}\n") do |root|
      action_dir = File.join(root, "opaque-action")
      FileUtils.mkdir_p(action_dir)
      File.write(File.join(action_dir, "action.yml"), <<~'YAML')
        runs:
          using: composite
          steps: []
      YAML
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml")
      File.chmod(0o111, action_dir)

      begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        File.chmod(0o755, action_dir)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      assert_equal ["secure-github-actions/unsafe-file"], rule_ids(JSON.parse(stdout))
    end
  end

  def test_git_action_discovery_rejects_tracked_action_ancestors_replaced_by_non_directories
    actual = %i[symlink regular_file].map do |replacement|
      with_repository("jobs: {}\n") do |root|
        action_path = File.join(root, "actions/local/action.yml")
        FileUtils.mkdir_p(File.dirname(action_path))
        File.write(action_path, "runs: { using: composite, steps: [] }\n")
        git!(root, "init", "-b", "main")
        git!(root, "add", ".github/workflows/test.yml", "actions/local/action.yml")

        actions_root = File.join(root, "actions")
        FileUtils.remove_entry(actions_root)
        if replacement == :symlink
          replacement_target = File.join(root, "replacement-target")
          FileUtils.mkdir_p(replacement_target)
          File.symlink(replacement_target, actions_root)
        else
          File.write(actions_root, "not a directory\n")
        end
        File.write(File.join(root, "ordinary-file"), "not an action directory\n")

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        document = JSON.parse(stdout)
        [
          status.exitstatus,
          stderr,
          rule_ids(document),
          document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
        ]
      end
    end

    expected = [1, "", ["secure-github-actions/unsafe-file"], ["actions"]]
    assert_equal [expected, expected], actual
  end

  def test_git_action_discovery_rejects_case_variant_tracked_ancestor_replacements
    skip "filesystem is case-sensitive" unless filesystem_case_insensitive?

    actual = %i[symlink regular_file fifo].map do |replacement|
      with_repository("jobs: {}\n") do |root|
        indexed_action = File.join(root, "Actions/local/action.yml")
        FileUtils.mkdir_p(File.dirname(indexed_action))
        File.write(indexed_action, "runs: { using: composite, steps: [] }\n")
        File.write(File.join(root, ".gitignore"), "actions/\n")
        git!(root, "init", "-b", "main")
        git!(root, "add", ".github/workflows/test.yml", ".gitignore")
        git!(root, "add", "--force", "Actions/local/action.yml")

        FileUtils.remove_entry(File.join(root, "Actions"))
        replacement_path = File.join(root, "actions")
        case replacement
        when :symlink
          replacement_target = File.join(root, "replacement-target")
          FileUtils.mkdir_p(replacement_target)
          File.symlink(replacement_target, replacement_path)
        when :regular_file
          File.write(replacement_path, "not a directory\n")
        when :fifo
          File.mkfifo(replacement_path)
        end

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        document = JSON.parse(stdout)
        [
          status.exitstatus,
          stderr,
          rule_ids(document),
          document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
        ]
      end
    end

    expected = [1, "", ["secure-github-actions/unsafe-file"], ["actions"]]
    assert_equal [expected, expected, expected], actual
  end

  def test_git_reviewable_identity_keeps_distinct_case_entries_separate_on_case_sensitive_filesystems
    skip "filesystem is case-insensitive" if filesystem_case_insensitive?

    with_repository("jobs: {}\n") do |root|
      tracked_action = File.join(root, "Actions/local/action.yml")
      ignored_action = File.join(root, "actions/local/action.yml")
      FileUtils.mkdir_p(File.dirname(tracked_action))
      FileUtils.mkdir_p(File.dirname(ignored_action))
      File.write(tracked_action, "runs: { using: composite, steps: [] }\n")
      File.write(ignored_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.write(File.join(root, ".gitignore"), "actions/\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore", "Actions/local/action.yml")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_empty rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "Actions/local/action.yml"
      refute_includes document.dig("scan", "files_scanned"), "actions/local/action.yml"

      FileUtils.remove_entry(File.join(root, "actions"))
      File.symlink(File.join(root, "Actions"), File.join(root, "actions"))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      assert_empty rule_ids(JSON.parse(stdout))
    end
  end

  def test_git_reviewable_identity_lookup_errors_fail_closed
    with_repository("jobs: {}\n") do |root|
      ignored_action = File.join(root, "node_modules/pkg/action.yml")
      FileUtils.mkdir_p(File.dirname(ignored_action))
      File.write(ignored_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.write(File.join(root, ".gitignore"), "node_modules/\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore")
      scanner = SecureGitHubActions::Scanner.new(root)
      scanner.define_singleton_method(:reviewable_path_lstat) { |*| raise Errno::EACCES }

      result = scanner.scan

      refute_predicate result, :clean?
      assert_equal ["secure-github-actions/unsafe-file"],
                   result.findings.map { |finding| finding.fetch("rule_id") }.uniq
    end
  end

  def test_git_descriptor_membership_does_not_treat_ignored_ambient_hardlink_as_reviewable
    with_repository("jobs: {}\n") do |root|
      source_action = File.join(root, "source/action.yml")
      ambient_action = File.join(root, "ambient/action.yml")
      symlink_action = File.join(root, "linked/action.yml")
      [source_action, ambient_action, symlink_action].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(source_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.link(source_action, ambient_action)
      File.symlink(source_action, symlink_action)
      File.write(File.join(root, ".gitignore"), "/ambient/action.yml\n/linked/action.yml\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore", "source/action.yml")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["source/action.yml"],
                   document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
      assert_includes document.dig("scan", "files_scanned"), "source/action.yml"
      refute_includes document.dig("scan", "files_scanned"), "ambient/action.yml"
      refute_includes document.dig("scan", "files_scanned"), "linked/action.yml"
    end
  end

  def test_git_descriptor_membership_does_not_treat_same_parent_hardlink_as_same_filename
    with_repository("jobs: {}\n") do |root|
      tracked_action = File.join(root, "source/action.yml")
      ignored_action = File.join(root, "source/action.yaml")
      FileUtils.mkdir_p(File.dirname(tracked_action))
      File.write(tracked_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.link(tracked_action, ignored_action)
      File.write(File.join(root, ".gitignore"), "/source/action.yaml\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", ".github/workflows/test.yml", ".gitignore", "source/action.yml")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["source/action.yml"],
                   document.fetch("review_findings").map { |finding| finding.dig("location", "file") }
      refute_includes document.dig("scan", "files_scanned"), "source/action.yaml"
    end
  end

  def test_action_discovery_requires_list_and_traverse_permissions
    expected_rules = {
      0o111 => ["secure-github-actions/unsafe-file"],
      0o311 => ["secure-github-actions/unsafe-file"],
      0o511 => ["secure-github-actions/expression-in-run"]
    }

    actual = expected_rules.keys.to_h do |mode|
      with_repository("jobs: {}\n") do |root|
        action_dir = File.join(root, "opaque-action")
        FileUtils.mkdir_p(action_dir)
        File.write(File.join(action_dir, "action.yml"), <<~'YAML')
          runs:
            using: composite
            steps:
              - run: echo "${{ github.event.issue.title }}"
        YAML
        File.chmod(mode, action_dir)

        begin
          stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        ensure
          File.chmod(0o755, action_dir)
        end

        [mode, [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]]
      end
    end

    assert_equal expected_rules.transform_values { |rules| [1, "", rules] }, actual
  end

  def test_unreferenced_symlinked_action_descriptor_fails_closed_without_reading_target
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      action_dir = File.join(root, "local-action")
      outside = File.join(outer, "action.yml")
      FileUtils.mkdir_p(File.join(root, ".github/workflows"))
      FileUtils.mkdir_p(action_dir)
      File.write(File.join(root, ".github/workflows/test.yml"), "jobs: {}\n")
      File.write(outside, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.symlink(outside, File.join(action_dir, "action.yml"))

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/unsafe-file"], rule_ids(document)
      refute_includes document.dig("scan", "files_scanned"), "local-action/action.yml"
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

  def test_untraversable_github_directory_fails_closed
    with_repository("jobs: {}\n") do |root|
      github_path = File.join(root, ".github")
      File.chmod(0o000, github_path)

      begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        File.chmod(0o755, github_path)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal ["secure-github-actions/unsafe-file"], rule_ids(document)
      assert_equal ".github", document.fetch("review_findings").first.dig("location", "file")
    end
  end

  def test_workflows_directory_requires_list_and_traverse_permissions
    workflow = <<~'YAML'
      jobs:
        build:
          steps:
            - run: echo "${{ github.event.issue.title }}"
    YAML
    expected_rules = {
      0o111 => ["secure-github-actions/unsafe-file"],
      0o311 => ["secure-github-actions/unsafe-file"],
      0o511 => ["secure-github-actions/expression-in-run"]
    }

    actual = expected_rules.keys.to_h do |mode|
      with_repository(workflow) do |root|
        workflows_path = File.join(root, ".github/workflows")
        File.chmod(mode, workflows_path)

        begin
          stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        ensure
          File.chmod(0o755, workflows_path)
        end

        [mode, [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]]
      end
    end

    assert_equal expected_rules.transform_values { |rules| [1, "", rules] }, actual
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

  def test_non_scalar_and_alias_allowlist_entries_fail_closed_as_structured_findings
    sha = "0123456789abcdef0123456789abcdef01234567"
    policies = [
      "trusted_actions:\n  - owner: action\n",
      "trusted_actions:\n  - [owner/action]\n",
      "shared: &action owner/action\ntrusted_actions:\n  - *action\n"
    ]

    actual = policies.map do |policy|
      with_repository(<<~YAML) do |root|
        jobs:
          build:
            steps:
              - uses: owner/action@#{sha} # v1.2.3
      YAML
        policy_path = File.join(root, ".agents/agent-workflow.yml")
        FileUtils.mkdir_p(File.dirname(policy_path))
        File.write(policy_path, policy)

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    expected = [
      1,
      "",
      [
        "secure-github-actions/invalid-trusted-actions-policy",
        "secure-github-actions/untrusted-external-use"
      ]
    ]
    assert_equal [expected, expected, expected], actual
  end

  def test_alias_and_non_scalar_trusted_actions_keys_fail_closed_as_structured_findings
    sha = "0123456789abcdef0123456789abcdef01234567"
    policies = [
      "policy_key: &policy_key trusted_actions\n*policy_key:\n  - owner/action\n",
      "? [trusted_actions]\n: [owner/action]\n"
    ]

    actual = policies.map do |policy|
      with_repository(<<~YAML) do |root|
        jobs:
          build:
            steps:
              - uses: owner/action@#{sha} # v1.2.3
      YAML
        policy_path = File.join(root, ".agents/agent-workflow.yml")
        FileUtils.mkdir_p(File.dirname(policy_path))
        File.write(policy_path, policy)

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    expected = [
      1,
      "",
      [
        "secure-github-actions/invalid-trusted-actions-policy",
        "secure-github-actions/untrusted-external-use"
      ]
    ]
    assert_equal [expected, expected], actual
  end

  def test_policy_merge_and_alias_indirection_fails_closed_without_external_uses
    policies = [
      <<~YAML,
        inherited: &inherited
          trusted_actions: [owner/action]
        <<: *inherited
      YAML
      <<~YAML,
        first: &first
          trusted_actions: [owner/action]
        second: &second
          enabled: true
        <<: [*first, *second]
      YAML
      <<~YAML,
        !!merge injected:
          trusted_actions: [owner/action]
      YAML
      <<~YAML
        <<:
          trusted_actions: [owner/action]
      YAML
    ]

    actual = policies.map do |policy|
      with_repository("jobs: {}\n") do |root|
        policy_path = File.join(root, ".agents/agent-workflow.yml")
        FileUtils.mkdir_p(File.dirname(policy_path))
        File.write(policy_path, policy)

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
        [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]
      end
    end

    expected = [1, "", ["secure-github-actions/invalid-trusted-actions-policy"]]
    assert_equal [expected, expected, expected, expected], actual
  end

  def test_ordinary_unrelated_policy_mappings_remain_valid
    with_repository("jobs: {}\n") do |root|
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(policy_path))
      File.write(policy_path, <<~YAML)
        metadata:
          enabled: true
          channel: stable
        "<<":
          trusted_actions: [owner/action]
      YAML

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      assert_empty rule_ids(JSON.parse(stdout))
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

  def test_referenced_local_action_is_scanned_when_its_directory_is_not_listable
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./local-action
    YAML
      action_dir = File.join(root, "local-action")
      action_path = File.join(action_dir, "action.yml")
      FileUtils.mkdir_p(action_dir)
      File.write(action_path, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.chmod(0o111, action_dir)

      begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        File.chmod(0o755, action_dir)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsafe-file",
        "secure-github-actions/expression-in-run"
      ], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "local-action/action.yml"
    end
  end

  def test_referenced_local_action_chains_are_scanned_once_across_cycles
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./actions/a
            - uses: ./actions/a
    YAML
      action_a = File.join(root, "actions/a/action.yml")
      action_b = File.join(root, "hidden-parent/b/action.yml")
      FileUtils.mkdir_p(File.dirname(action_a))
      FileUtils.mkdir_p(File.dirname(action_b))
      File.write(action_a, <<~YAML)
        runs:
          using: composite
          steps:
            - uses: ./hidden-parent/b
            - uses: ./hidden-parent/b
      YAML
      File.write(action_b, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
            - uses: ./actions/a
      YAML
      hidden_parent = File.join(root, "hidden-parent")
      File.chmod(0o111, hidden_parent)

      begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        File.chmod(0o755, hidden_parent)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsafe-file",
        "secure-github-actions/expression-in-run"
      ], rule_ids(document)
      files = document.dig("scan", "files_scanned")
      assert_equal 1, files.count("actions/a/action.yml")
      assert_equal 1, files.count("hidden-parent/b/action.yml")
    end
  end

  def test_referenced_local_action_is_scanned_below_non_listable_github_directory
    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./.github/actions/local
    YAML
      action_path = File.join(root, ".github/actions/local/action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(action_path, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      github_path = File.join(root, ".github")
      File.chmod(0o111, github_path)

      begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        File.chmod(0o755, github_path)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsafe-file",
        "secure-github-actions/expression-in-run"
      ], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), ".github/actions/local/action.yml"
    end
  end

  def test_referenced_local_action_is_scanned_when_acl_denies_directory_listing
    skip "directory ACLs are only available on Darwin" unless RUBY_PLATFORM.include?("darwin")

    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./acl-action
    YAML
      action_dir = File.join(root, "acl-action")
      action_path = File.join(action_dir, "action.yml")
      FileUtils.mkdir_p(action_dir)
      File.write(action_path, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      acl = "user:#{Etc.getpwuid(Process.uid).name} deny list"
      _stdout, apply_stderr, apply_status = Open3.capture3("/bin/chmod", "+a", acl, action_dir)
      skip "filesystem does not support deny-list ACLs: #{apply_stderr}" unless apply_status.success?

      begin
        refute File.readable?(action_dir)
        assert File.executable?(action_dir)
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)
      ensure
        Open3.capture3("/bin/chmod", "-a", acl, action_dir)
      end

      assert_equal 1, status.exitstatus
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_equal [
        "secure-github-actions/unsafe-file",
        "secure-github-actions/expression-in-run"
      ], rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "acl-action/action.yml"
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

  def test_case_aliased_excluded_roots_are_rejected_when_they_resolve_to_the_same_directory
    skip "filesystem is case-sensitive" unless filesystem_case_insensitive?

    aliases = {
      ".git" => ".GIT",
      ".codex" => ".CODEX",
      ".tmp" => ".TMP",
      "tmp" => "TMP"
    }
    actual = aliases.to_h do |excluded_root, reference_root|
      with_repository(<<~YAML) do |root|
        jobs:
          build:
            steps:
              - uses: ./#{reference_root}/local
      YAML
        action_path = File.join(root, excluded_root, "local/action.yml")
        FileUtils.mkdir_p(File.dirname(action_path))
        File.write(action_path, "runs: { using: composite, steps: [] }\n")

        stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

        [excluded_root, [status.exitstatus, stderr, rule_ids(JSON.parse(stdout))]]
      end
    end

    assert_equal aliases.keys.to_h { |root| [root, [1, "", ["secure-github-actions/unsafe-local-use"]]] }, actual
  end

  def test_distinct_case_variant_root_is_allowed_on_case_sensitive_filesystems
    skip "filesystem is case-insensitive" if filesystem_case_insensitive?

    with_repository(<<~YAML) do |root|
      jobs:
        build:
          steps:
            - uses: ./TMP/local
    YAML
      excluded_action = File.join(root, "tmp/hidden/action.yml")
      allowed_action = File.join(root, "TMP/local/action.yml")
      FileUtils.mkdir_p(File.dirname(excluded_action))
      FileUtils.mkdir_p(File.dirname(allowed_action))
      File.write(excluded_action, <<~'YAML')
        runs:
          using: composite
          steps:
            - run: echo "${{ github.event.issue.title }}"
      YAML
      File.write(allowed_action, "runs: { using: composite, steps: [] }\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCANNER, "--json", root)

      assert_predicate status, :success?
      assert_empty stderr
      document = JSON.parse(stdout)
      assert_empty rule_ids(document)
      assert_includes document.dig("scan", "files_scanned"), "TMP/local/action.yml"
      refute_includes document.dig("scan", "files_scanned"), "tmp/hidden/action.yml"
    end
  end

  def test_missing_normalized_excluded_root_is_distinct_but_indeterminate_identity_fails_closed
    with_repository("jobs: {}\n") do |root|
      scanner = SecureGitHubActions::Scanner.new(root)

      scanner.define_singleton_method(:action_root_entry_exists?) { |*, **| false }
      scanner.define_singleton_method(:identical_action_roots?) { |*, **| raise "identity lookup must not run" }
      refute scanner.send(:excluded_action_root?, "TMP/local")

      scanner.define_singleton_method(:action_root_entry_exists?) { |*, **| raise Errno::EACCES }
      assert scanner.send(:excluded_action_root?, "TMP/local")
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

  def git!(root, *arguments)
    output, status = Open3.capture2e("git", "-C", root, *arguments)
    raise "git fixture failed: #{output}" unless status.success?

    output
  end

  def filesystem_case_insensitive?
    Dir.mktmpdir("secure-github-actions-case-probe") do |root|
      lower = File.join(root, "case-probe")
      upper = File.join(root, "CASE-PROBE")
      Dir.mkdir(lower)
      return File.identical?(lower, upper)
    end
  end

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
