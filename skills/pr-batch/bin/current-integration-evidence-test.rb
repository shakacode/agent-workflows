#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"
require_relative "../lib/current_integration_evidence"

class CurrentIntegrationEvidenceTest < Minitest::Test
  HEAD_FILE = "lib/feature.rb"

  def test_github_snapshot_decodes_non_ascii_json_as_utf8_under_an_ascii_default
    with_github_payload(github_payload(metadata: "café")) do
      original_encoding = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      snapshot = CurrentIntegrationEvidence.github_snapshot(
        repo: "example/repo", pr_number: 7, base_ref: "main"
      )

      assert_equal "a" * 40, snapshot.fetch("head_sha")
      assert_equal "b" * 40, snapshot.fetch("base_sha")
    ensure
      Encoding.default_external = original_encoding
    end
  end

  def test_github_snapshot_rejects_invalid_utf8_as_an_evidence_error
    payload = github_payload(metadata: "placeholder").b
    payload.sub!("placeholder".b, "\xFF".b)

    with_github_payload(payload) do
      error = assert_raises(CurrentIntegrationEvidence::Error) do
        CurrentIntegrationEvidence.github_snapshot(
          repo: "example/repo", pr_number: 7, base_ref: "main"
        )
      end

      assert_equal "GitHub current-integration response is not valid UTF-8", error.message
    end
  end

  def test_github_snapshot_rejects_lone_surrogate_decoded_from_candidate_oid
    payload = github_payload(metadata: "metadata", candidate_oid: "candidate-placeholder")
    payload.sub!("candidate-placeholder", '\udcff')

    with_github_payload(payload) do
      error = assert_raises(CurrentIntegrationEvidence::Error) do
        CurrentIntegrationEvidence.github_snapshot(
          repo: "example/repo", pr_number: 7, base_ref: "main"
        )
      end

      assert_equal(
        "GitHub current-integration response contains invalid Unicode scalar data",
        error.message
      )
    end
  end

  def test_disjoint_safe_base_delta_reuses_exact_head_evidence
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      result = collect(fixture)

      assert_equal "current-integration-evidence", result.fetch("contract")
      assert_equal 1, result.fetch("version")
      assert_equal fixture.fetch(:recorded_base), result.fetch("recorded_base_sha")
      assert_equal fixture.fetch(:head), result.fetch("head_sha")
      assert_equal fixture.fetch(:current_base), result.dig("current_base", "sha")
      assert_equal "github-potential-merge-commit", result.dig("candidate", "source")
      assert_equal "reuse-exact-head", result.dig("reuse", "decision")
      assert_equal ["base-delta-reuse-safe"], result.dig("reuse", "reasons")
      assert_equal 1, result.dig("telemetry", "validator_replays_avoided")
      assert_equal 1, result.dig("telemetry", "review_replays_avoided")
      assert_nil result.dig("telemetry", "elapsed_seconds_saved")
      assert_match(/\A[0-9a-f]{64}\z/, result.fetch("patch_identity"))
    end
  end

  def test_disjoint_safe_pr_delta_reuses_exact_head_evidence
    with_repository(base_delta_path: "lib/other.rb", head_path: "docs/feature.md") do |fixture|
      result = collect(fixture)

      assert_equal "reuse-exact-head", result.dig("reuse", "decision")
      assert_equal ["pr-delta-reuse-safe"], result.dig("reuse", "reasons")
      assert_equal 1, result.dig("telemetry", "validator_replays_avoided")
      assert_equal 1, result.dig("telemetry", "review_replays_avoided")
    end
  end

  def test_disjoint_safe_deltas_report_sorted_reuse_reasons
    with_repository(base_delta_path: "docs/guide.md", head_path: "docs/feature.md") do |fixture|
      result = collect(fixture)

      assert_equal "reuse-exact-head", result.dig("reuse", "decision")
      assert_equal %w[base-delta-reuse-safe pr-delta-reuse-safe], result.dig("reuse", "reasons")
    end
  end

  def test_disjoint_code_on_both_sides_requires_fresh_integration
    with_repository(base_delta_path: "lib/other.rb") do |fixture|
      result = collect(fixture)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_equal ["neither-delta-reuse-safe"], result.dig("reuse", "reasons")
      assert_equal 0, result.dig("telemetry", "validator_replays_avoided")
      assert_equal 0, result.dig("telemetry", "review_replays_avoided")
    end
  end

  def test_high_risk_pr_delta_blocks_reuse_even_when_base_delta_is_safe
    with_repository(base_delta_path: "docs/guide.md", head_path: ".github/workflows/ci.yml") do |fixture|
      result = collect(fixture)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_equal ["pr-delta-high-risk"], result.dig("reuse", "reasons")
    end
  end

  def test_nested_workflow_pr_delta_blocks_reuse_even_when_base_delta_is_safe
    with_repository(base_delta_path: "docs/guide.md", head_path: "template/.github/workflows/ci.yml") do |fixture|
      result = collect(fixture)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_equal ["pr-delta-high-risk"], result.dig("reuse", "reasons")
    end
  end

  def test_root_and_nested_github_actions_paths_are_high_risk_in_both_deltas
    paths = [
      ".github/workflows/ci.yml",
      ".github/actions/setup/action.yml",
      "template/.github/workflows/ci.yml",
      "template/.github/actions/setup/action.yml",
      "template:v1/.github/workflows/ci.yml",
      "template:v1/.github/actions/setup/action.yml"
    ]

    paths.each do |path|
      with_repository(base_delta_path: "docs/guide.md", head_path: path) do |fixture|
        result = collect(fixture)

        assert_equal "fresh-integration-required", result.dig("reuse", "decision"), "PR delta: #{path}"
        assert_equal ["pr-delta-high-risk"], result.dig("reuse", "reasons"), "PR delta: #{path}"
      end

      with_repository(base_delta_path: path, head_path: "docs/feature.md") do |fixture|
        result = collect(fixture)

        assert_equal "fresh-integration-required", result.dig("reuse", "decision"), "base delta: #{path}"
        assert_equal ["base-delta-high-risk"], result.dig("reuse", "reasons"), "base delta: #{path}"
      end
    end
  end

  def test_high_risk_base_delta_blocks_reuse_even_when_pr_delta_is_safe
    with_repository(base_delta_path: ".github/workflows/ci.yml", head_path: "docs/feature.md") do |fixture|
      result = collect(fixture)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_equal ["base-delta-high-risk"], result.dig("reuse", "reasons")
    end
  end

  def test_portable_current_integration_policy_paths_are_high_risk_on_both_layouts
    %w[
      skills/pr-batch/lib/current_integration_evidence.rb
      .agents/skills/pr-batch/lib/current_integration_evidence.rb
    ].each do |head_path|
      with_repository(base_delta_path: "docs/guide.md", head_path:) do |fixture|
        result = collect(fixture)

        assert_equal "fresh-integration-required", result.dig("reuse", "decision"), head_path
        assert_equal ["pr-delta-high-risk"], result.dig("reuse", "reasons"), head_path
      end
    end
  end

  def test_consumer_high_risk_pr_delta_blocks_reuse_even_when_base_delta_is_safe
    policy = AutonomousMergePolicy.parse(<<~YAML)
      autonomous_merge:
        human_review_paths:
          - id: deployment
            pattern: deploy/**
            reason: infrastructure
    YAML
    with_repository(base_delta_path: "docs/guide.md", head_path: "deploy/app.yml") do |fixture|
      result = collect(fixture, policy:)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_equal ["pr-delta-high-risk"], result.dig("reuse", "reasons")
    end
  end

  def test_overlapping_paths_require_fresh_integration
    with_repository(
      base_delta_path: HEAD_FILE,
      base_delta_content: "line one\nline two\nbase-side\n"
    ) do |fixture|
      result = collect(fixture)

      assert_equal "fresh-integration-required", result.dig("reuse", "decision")
      assert_includes result.dig("reuse", "reasons"), "path-overlap"
    end
  end

  def test_base_unchanged_is_explicit_and_does_not_claim_avoided_replays
    with_repository(base_delta_path: nil) do |fixture|
      result = collect(fixture)

      assert_equal "base-unchanged", result.dig("reuse", "decision")
      assert_equal ["base-unchanged"], result.dig("reuse", "reasons")
      assert_equal 0, result.dig("telemetry", "validator_replays_avoided")
      assert_equal 0, result.dig("telemetry", "review_replays_avoided")
    end
  end

  def test_base_unchanged_verifies_the_live_base_snapshot_is_stable
    with_repository(base_delta_path: nil) do |fixture|
      reads = 0
      reader = lambda do |**|
        reads += 1
        value = snapshot(fixture)
        value["base_sha"] = "f" * 40 if reads == 2
        value
      end

      error = assert_raises(CurrentIntegrationEvidence::Error) do
        CurrentIntegrationEvidence.base_unchanged(
          repo_root: fixture.fetch(:root),
          repo: "example/repo",
          pr_number: 7,
          recorded_base_sha: fixture.fetch(:recorded_base),
          head_sha: fixture.fetch(:head),
          trusted_base_sha: fixture.fetch(:current_base),
          pr_paths: [fixture.fetch(:head_path)],
          policy: AutonomousMergePolicy.parse("{}"),
          snapshot_reader: reader
        )
      end

      assert_includes error.message, "live base ref does not match trusted current base"
    end
  end

  def test_base_unchanged_ignores_provider_candidate_oid_churn
    with_repository(base_delta_path: nil) do |fixture|
      reads = 0
      reader = lambda do |**|
        reads += 1
        value = snapshot(fixture)
        value.fetch("candidate")["oid"] = (reads == 1 ? "d" : "e") * 40
        value
      end

      result = CurrentIntegrationEvidence.base_unchanged(
        repo_root: fixture.fetch(:root),
        repo: "example/repo",
        pr_number: 7,
        recorded_base_sha: fixture.fetch(:recorded_base),
        head_sha: fixture.fetch(:head),
        trusted_base_sha: fixture.fetch(:current_base),
        pr_paths: [fixture.fetch(:head_path)],
        policy: AutonomousMergePolicy.parse("{}"),
        snapshot_reader: reader
      )

      assert_equal "base-unchanged", result.dig("reuse", "decision")
    end
  end

  def test_collect_ignores_provider_candidate_oid_churn
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      reads = 0
      reader = lambda do |**|
        reads += 1
        value = snapshot(fixture)
        value.fetch("candidate")["oid"] = (reads == 1 ? "d" : "e") * 40
        value
      end

      result = collect(fixture, snapshot_reader: reader)

      assert_equal "reuse-exact-head", result.dig("reuse", "decision")
      assert_equal "d" * 40, result.dig("candidate", "oid")
    end
  end

  def test_local_git_fallback_ignores_ambient_git_overrides_and_repository_state
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      value = snapshot(fixture)
      value["candidate"] = nil
      wrapper_dir = Dir.mktmpdir("current-integration-untrusted-git")
      wrapper = File.join(wrapper_dir, "git")
      marker = File.join(wrapper_dir, "invoked")
      system_git = CurrentIntegrationEvidence::SYSTEM_TOOL_DIRS
                   .map { |directory| File.join(directory, "git") }
                   .find { |path| File.file?(path) && File.executable?(path) }
      refute_nil system_git
      File.write(
        wrapper,
        "#!/bin/sh\nprintf 'invoked\\n' >> #{marker.inspect}\nexec #{system_git.inspect} \"$@\"\n"
      )
      FileUtils.chmod(0o755, wrapper)
      original_git = ENV["CURRENT_INTEGRATION_GIT"]
      original_git_dir = ENV["GIT_DIR"]
      ENV["CURRENT_INTEGRATION_GIT"] = wrapper
      ENV["GIT_DIR"] = File.join(wrapper_dir, "poisoned.git")

      result = collect(fixture, snapshot_reader: ->(**) { value })

      assert_equal "git-merge-tree", result.dig("candidate", "source")
      refute File.exist?(marker), "untrusted CURRENT_INTEGRATION_GIT was executed"
    ensure
      original_git ? ENV["CURRENT_INTEGRATION_GIT"] = original_git : ENV.delete("CURRENT_INTEGRATION_GIT")
      original_git_dir ? ENV["GIT_DIR"] = original_git_dir : ENV.delete("GIT_DIR")
      FileUtils.remove_entry(wrapper_dir) if wrapper_dir && File.exist?(wrapper_dir)
    end
  end

  def test_library_loads_its_policy_dependency_without_caller_ordering
    library = File.expand_path("../lib/current_integration_evidence", __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-e",
      "require #{library.inspect}; abort 'missing policy' unless defined?(AutonomousMergePolicy)"
    )

    assert status.success?, stderr
  end

  def test_stale_provider_candidate_falls_back_to_trusted_local_merge_tree
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      stale = snapshot(fixture)
      stale.fetch("candidate")["parents"] = [fixture.fetch(:recorded_base), fixture.fetch(:head)]

      result = collect(fixture, snapshot_reader: ->(**) { stale })

      assert_equal "git-merge-tree", result.dig("candidate", "source")
      assert_nil result.dig("candidate", "oid")
      assert_equal fixture.fetch(:candidate_tree), result.dig("candidate", "tree_oid")
      assert_equal [fixture.fetch(:current_base), fixture.fetch(:head)], result.dig("candidate", "parents")
    end
  end

  def test_malformed_provider_candidate_identity_fails_closed
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      malformed = snapshot(fixture)
      malformed.fetch("candidate")["parents"] = ["not-a-sha", fixture.fetch(:head)]

      error = assert_raises(CurrentIntegrationEvidence::Error) do
        collect(fixture, snapshot_reader: ->(**) { malformed })
      end
      assert_includes error.message, "candidate identity"
    end
  end

  def test_trusted_local_merge_tree_is_used_when_provider_candidate_is_unavailable
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      value = snapshot(fixture)
      value["candidate"] = nil

      result = collect(fixture, snapshot_reader: ->(**) { value })

      assert_equal "git-merge-tree", result.dig("candidate", "source")
      assert_nil result.dig("candidate", "oid")
      assert_equal fixture.fetch(:candidate_tree), result.dig("candidate", "tree_oid")
      assert_equal [fixture.fetch(:current_base), fixture.fetch(:head)], result.dig("candidate", "parents")
    end
  end

  def test_tree_identical_base_advance_reuses_a_wholly_safe_pr_delta
    with_repository(base_delta_path: nil, head_path: "docs/feature.md", base_empty_commit: true) do |fixture|
      result = collect(fixture)

      refute_equal fixture.fetch(:recorded_base), fixture.fetch(:current_base)
      assert_empty result.dig("base_delta", "paths")
      assert_equal "reuse-exact-head", result.dig("reuse", "decision")
      assert_equal ["pr-delta-reuse-safe"], result.dig("reuse", "reasons")
    end
  end

  def test_snapshot_semantic_movement_fails_closed
    with_repository(base_delta_path: "docs/guide.md") do |fixture|
      reads = 0
      reader = lambda do |**|
        reads += 1
        value = snapshot(fixture)
        value["candidate"]["tree_oid"] = "f" * 40 if reads == 2
        value
      end

      error = assert_raises(CurrentIntegrationEvidence::Error) do
        collect(fixture, snapshot_reader: reader)
      end
      assert_includes error.message, "changed during evidence collection"
    end
  end

  def test_cli_fields_reject_at_file_expansion_before_snapshot_read
    values = [
      { repo: "@owner/repo" },
      { repo: "owner/@repo" },
      { base_ref: "@main" },
      { base_ref: "main@{1}" },
      { base_ref: "-main" }
    ]

    values.each do |override|
      assert_input_error_before_snapshot(override)
    end
  end

  def test_malformed_cli_field_types_raise_contract_error_before_snapshot_read
    values = [
      { repo: nil },
      { base_ref: nil },
      { recorded_base_sha: nil },
      { head_sha: 123 },
      { trusted_base_sha: [] }
    ]

    values.each do |override|
      assert_input_error_before_snapshot(override)
    end
  end

  private

  def github_payload(metadata:, candidate_oid: nil)
    candidate = if candidate_oid
                  {
                    "oid" => candidate_oid,
                    "tree" => { "oid" => "c" * 40 },
                    "parents" => {
                      "totalCount" => 2,
                      "nodes" => [{ "oid" => "b" * 40 }, { "oid" => "a" * 40 }]
                    }
                  }
                end

    JSON.generate(
      "metadata" => metadata,
      "data" => {
        "repository" => {
          "pullRequest" => {
            "headRefOid" => "a" * 40,
            "baseRefName" => "main",
            "potentialMergeCommit" => candidate
          },
          "ref" => { "target" => { "oid" => "b" * 40 } }
        }
      }
    )
  end

  def with_github_payload(payload)
    Dir.mktmpdir("current-integration-github-test") do |root|
      payload_path = File.join(root, "payload.json")
      fake_gh = File.join(root, "gh")
      File.binwrite(payload_path, payload)
      File.write(fake_gh, <<~'RUBY')
        #!/usr/bin/env ruby
        $stdout.binmode
        $stdout.write(File.binread(ENV.fetch("CURRENT_INTEGRATION_TEST_PAYLOAD")))
      RUBY
      File.chmod(0o755, fake_gh)
      original_command = ENV["CURRENT_INTEGRATION_GH"]
      original_payload = ENV["CURRENT_INTEGRATION_TEST_PAYLOAD"]
      ENV["CURRENT_INTEGRATION_GH"] = fake_gh
      ENV["CURRENT_INTEGRATION_TEST_PAYLOAD"] = payload_path
      yield
    ensure
      ENV["CURRENT_INTEGRATION_GH"] = original_command
      ENV["CURRENT_INTEGRATION_TEST_PAYLOAD"] = original_payload
    end
  end

  def collect(
    fixture, policy: AutonomousMergePolicy.parse("{}"),
    snapshot_reader: ->(**) { snapshot(fixture) }
  )
    CurrentIntegrationEvidence.collect(
      repo_root: fixture.fetch(:root),
      repo: "example/repo",
      pr_number: 7,
      recorded_base_sha: fixture.fetch(:recorded_base),
      head_sha: fixture.fetch(:head),
      trusted_base_sha: fixture.fetch(:current_base),
      pr_paths: [fixture.fetch(:head_path)],
      policy:,
      changelog_path: "CHANGELOG.md",
      snapshot_reader:
    )
  end

  def with_repository(
    base_delta_path:, base_delta_content: "base delta\n", head_path: HEAD_FILE, base_empty_commit: false
  )
    Dir.mktmpdir("current-integration-evidence-test") do |root|
      git!(root, "init", "--quiet", "-b", "main")
      git!(root, "config", "user.email", "test@example.com")
      git!(root, "config", "user.name", "Test")
      File.write(File.join(root, "README.md"), "base\n")
      FileUtils.mkdir_p(File.join(root, File.dirname(head_path)))
      File.write(File.join(root, head_path), "line one\nline two\nline three\n")
      git!(root, "add", ".")
      git!(root, "commit", "--quiet", "-m", "base")
      recorded_base = git!(root, "rev-parse", "HEAD").strip

      git!(root, "switch", "--quiet", "-c", "feature")
      File.write(File.join(root, head_path), "feature\nline two\nline three\n")
      git!(root, "add", ".")
      git!(root, "commit", "--quiet", "-m", "feature")
      head = git!(root, "rev-parse", "HEAD").strip

      git!(root, "switch", "--quiet", "main")
      if base_delta_path
        FileUtils.mkdir_p(File.join(root, File.dirname(base_delta_path)))
        File.write(File.join(root, base_delta_path), base_delta_content)
        git!(root, "add", ".")
        git!(root, "commit", "--quiet", "-m", "advance base")
      elsif base_empty_commit
        git!(root, "commit", "--quiet", "--allow-empty", "-m", "advance base without a tree change")
      end
      current_base = git!(root, "rev-parse", "HEAD").strip
      candidate_tree = git!(root, "merge-tree", "--write-tree", current_base, head).lines.first.strip

      yield(
        root:,
        recorded_base:,
        current_base:,
        head:,
        head_path:,
        candidate_tree:
      )
    end
  end

  def snapshot(fixture)
    {
      "head_sha" => fixture.fetch(:head),
      "base_ref" => "main",
      "base_sha" => fixture.fetch(:current_base),
      "candidate" => {
        "oid" => "c" * 40,
        "tree_oid" => fixture.fetch(:candidate_tree),
        "parents" => [fixture.fetch(:current_base), fixture.fetch(:head)],
        "parent_count" => 2
      }
    }
  end

  def git!(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise stderr unless status.success?

    stdout
  end

  def assert_input_error_before_snapshot(override)
    reads = 0
    arguments = {
      repo_root: Dir.tmpdir,
      repo: "example/repo",
      pr_number: 7,
      recorded_base_sha: "a" * 40,
      head_sha: "b" * 40,
      trusted_base_sha: "c" * 40,
      pr_paths: [],
      policy: AutonomousMergePolicy.parse("{}"),
      changelog_path: "CHANGELOG.md",
      base_ref: "main",
      snapshot_reader: lambda do |**|
        reads += 1
        raise "snapshot reader must not run"
      end
    }.merge(override)

    assert_raises(CurrentIntegrationEvidence::Error) do
      CurrentIntegrationEvidence.collect(**arguments)
    end
    assert_equal 0, reads
  end
end
