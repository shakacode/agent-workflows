#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/human_attention"

SCRIPT = File.expand_path("human-attention", __dir__)
LABEL_POLICY = <<~YAML
  ---
  human_attention:
    labels:
      walkthrough: human-attention:walkthrough
      merge: human-attention:merge
YAML

class HumanAttentionTest < Minitest::Test
  def test_labels_for_requires_consumer_label_policy
    with_repo_config("---\nbase_branch: main\n") do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      end

      assert_includes error.message, "must define walkthrough and merge"
    end
  end

  def test_labels_for_requires_both_consumer_labels
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
    YAML
    with_repo_config(config) do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      end

      assert_includes error.message, "must define walkthrough and merge"
    end
  end

  def test_labels_for_rejects_padded_label_names
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: " needs-merge"
    YAML
    with_repo_config(config) do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      end

      assert_includes error.message, "must not have leading or trailing whitespace"
    end
  end

  # Production break: gh pr edit treats a comma as a label separator, so one
  # configured semantic label could mutate multiple unrelated labels.
  def test_labels_for_rejects_label_names_with_commas
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: "needs,walkthrough"
          merge: needs-merge
    YAML
    with_repo_config(config) do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      end

      assert_includes error.message, "must not contain commas"
    end
  end

  # Production break: GitHub label names are case-insensitive, so labels that
  # differ only by case would assign both semantic states to one label.
  def test_labels_for_rejects_case_insensitive_duplicate_label_names
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: Human-Attention
          merge: human-attention
    YAML
    with_repo_config(config) do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      end

      assert_includes error.message, "labels must be distinct"
    end
  end

  def test_labels_for_accepts_consumer_and_repository_overrides
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: needs-walkthrough
          merge: needs-merge
        repositories:
          acme/special:
            labels:
              merge: special-merge
    YAML
    with_repo_config(config) do |root|
      loaded = HumanAttention.load_config(root)
      general = HumanAttention.labels_for(loaded, "acme/widgets")
      special = HumanAttention.labels_for(loaded, "acme/special")

      assert_equal "needs-walkthrough", general.fetch("walkthrough")
      assert_equal "needs-merge", general.fetch("merge")
      assert_equal "needs-walkthrough", special.fetch("walkthrough")
      assert_equal "special-merge", special.fetch("merge")
    end
  end

  def test_labels_for_matches_repository_overrides_case_insensitively
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: needs-walkthrough
          merge: needs-merge
        repositories:
          Acme/Widgets:
            labels:
              merge: repository-merge
    YAML
    with_repo_config(config) do |root|
      labels = HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")

      assert_equal "needs-walkthrough", labels.fetch("walkthrough")
      assert_equal "repository-merge", labels.fetch("merge")
    end
  end

  def test_labels_for_rejects_case_insensitive_duplicate_repository_overrides
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: needs-walkthrough
          merge: needs-merge
        repositories:
          Acme/Widgets: {}
          acme/widgets: {}
    YAML
    with_repo_config(config) do |root|
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.labels_for(HumanAttention.load_config(root), "ACME/WIDGETS")
      end

      assert_includes error.message, "is ambiguous"
    end
  end

  def test_library_classify_rejects_both_semantic_labels
    with_repo_config(LABEL_POLICY) do |root|
      labels = HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      error = assert_raises(HumanAttention::Error) do
        HumanAttention.classify(
          labels: ["human-attention:walkthrough", "human-attention:merge"], configured_labels: labels
        )
      end

      assert_includes error.message, "must not carry both human-attention labels"
    end
  end

  def test_desk_mirrors_labeled_prs_and_reports_degraded_repositories
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          acme/widgets: {}
          acme/broken: {}
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        args = ARGV.join(" ")
        if args.include?("acme/broken")
          warn "unavailable"
          exit 1
        else
          puts JSON.generate([
            {"number" => 7, "title" => "Explain change", "url" => "https://github.com/acme/widgets/pull/7", "updatedAt" => "2026-09-03T12:00:00Z", "headRefOid" => "#{'a' * 40}", "labels" => [{"name" => "human-attention:walkthrough"}]},
            {"number" => 8, "title" => "Ready to merge", "url" => "https://github.com/acme/widgets/pull/8", "updatedAt" => "2026-09-03T12:01:00Z", "headRefOid" => "#{'b' * 40}", "labels" => [{"name" => "human-attention:merge"}]}
          ])
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "desk", "--repo-root", root,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "HUMAN_ATTENTION_REFRESHED_AT" => "2026-09-03T12:02:00Z" }
      )

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes result[:stdout], "2 human decisions"
      assert_includes result[:stdout], "1 of 2 — WALKTHROUGH — acme/widgets — Explain change"
      assert_includes result[:stdout], "2 of 2 — MERGE — acme/widgets — Ready to merge"
      assert_includes result[:stdout], "Degraded repositories: acme/broken"
      assert_includes result[:stdout], "This queue does not represent remaining agent-owned work."
    end
  end

  # Production break: GitHub repository identities are case-insensitive, so
  # case-only duplicates would query one repository twice and duplicate its
  # desk cards and decision count.
  def test_desk_rejects_case_insensitive_duplicate_repositories_before_querying_github
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          - acme/widgets
          - Acme/Widgets
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "desk", "--repo-root", root,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "human-attention repositories must be unique ignoring case"
      refute_path_exists calls
    end
  end

  def test_desk_degrades_only_the_repository_with_conflicting_labels_and_discards_its_rows
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          acme/conflicted: {}
          acme/healthy: {}
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        repo = ARGV.fetch(ARGV.index("--repo") + 1)
        labels = repo.end_with?("conflicted") ? ["human-attention:walkthrough", "human-attention:merge"] : ["human-attention:merge"]
        puts JSON.generate([{"number" => 7, "title" => repo, "url" => "https://example.test/7", "headRefOid" => "#{'a' * 40}", "labels" => labels.map { |name| {"name" => name} }}])
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli("desk", "--repo-root", root, env: { "HUMAN_ATTENTION_GH" => fake_gh })

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes result[:stdout], "MERGE — acme/healthy"
      refute_includes result[:stdout], "WALKTHROUGH — acme/conflicted"
      assert_includes result[:stdout], "Degraded repositories: acme/conflicted"
    end
  end

  def test_desk_degrades_a_malformed_repository_override_without_hiding_healthy_repositories
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          acme/broken:
            labels: invalid
          acme/healthy: {}
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        repo = ARGV.fetch(ARGV.index("--repo") + 1)
        puts JSON.generate([{
          "number" => 7,
          "title" => repo,
          "url" => "https://example.test/7",
          "headRefOid" => "#{'a' * 40}",
          "labels" => [{"name" => "human-attention:merge"}]
        }])
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli("desk", "--repo-root", root, env: { "HUMAN_ATTENTION_GH" => fake_gh })

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes result[:stdout], "MERGE — acme/healthy"
      refute_includes result[:stdout], "MERGE — acme/broken"
      assert_includes result[:stdout], "Degraded repositories: acme/broken"
    end
  end

  def test_desk_rejects_a_malformed_global_label_policy
    config = <<~YAML
      ---
      human_attention:
        labels: invalid
        repositories:
          acme/widgets: {}
    YAML
    with_repo_config(config) do |root|
      result = run_cli("desk", "--repo-root", root)

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "human_attention labels must be a mapping"
    end
  end

  def test_desk_requests_more_than_the_default_thirty_open_pull_requests
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          acme/widgets: {}
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        limit = ARGV.fetch(ARGV.index("--limit") + 1).to_i
        rows = Array.new(30) do |index|
          {"number" => index + 1, "title" => "Ordinary", "url" => "https://example.test/\#{index + 1}", "headRefOid" => "#{'a' * 40}", "labels" => []}
        end
        rows << {"number" => 31, "title" => "Needs attention", "url" => "https://example.test/31", "headRefOid" => "#{'b' * 40}", "labels" => [{"name" => "human-attention:merge"}]} if limit > 30
        puts JSON.generate(rows)
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli("desk", "--repo-root", root, env: { "HUMAN_ATTENTION_GH" => fake_gh })

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes result[:stdout], "MERGE — acme/widgets — Needs attention"
    end
  end

  def test_desk_does_not_treat_a_label_as_exact_head_readiness_evidence
    config = <<~YAML
      ---
      human_attention:
        labels:
          walkthrough: human-attention:walkthrough
          merge: human-attention:merge
        repositories:
          acme/widgets: {}
    YAML
    with_repo_config(config) do |root|
      fake_gh = File.join(root, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "number" => 7,
          "title" => "Labeled before a later push",
          "url" => "https://example.test/7",
          "headRefOid" => "#{'b' * 40}",
          "labels" => [{"name" => "human-attention:merge"}]
        }])
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli("desk", "--repo-root", root, env: { "HUMAN_ATTENTION_GH" => fake_gh })

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes result[:stdout], "Current head: `#{'b' * 40}`"
      assert_includes result[:stdout], "Exact-head readiness is unverified"
      refute_includes result[:stdout], "all ordinary gates passed"
    end
  end

  def test_transition_replaces_the_other_semantic_label_at_the_expected_head
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
        if ARGV[0, 2] == ["pr", "view"]
          edited = File.read(ENV.fetch("CALLS")).include?("--add-label\thuman-attention:merge")
          label = edited ? "human-attention:merge" : "human-attention:walkthrough"
          puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'a' * 40}", "labels" => [{"name" => label}]})
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      assert_predicate result[:status], :success?, result[:stderr]
      edit = File.readlines(calls, chomp: true).find { |line| line.start_with?("pr\tedit") }
      assert_includes edit, "--remove-label\thuman-attention:walkthrough"
      assert_includes edit, "--add-label\thuman-attention:merge"
      view_count = File.readlines(calls).count { |line| line.start_with?("pr\tview") }
      assert_equal 2, view_count
    end
  end

  # Production break: GitHub returns canonical label casing, which can differ
  # from policy casing; exact comparisons would miss the active state and try
  # to add the same label again.
  def test_transition_classifies_current_labels_case_insensitively
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
        if ARGV[0, 2] == ["pr", "view"]
          puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'a' * 40}", "labels" => [{"name" => "Human-Attention:Merge"}]})
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      assert_predicate result[:status], :success?, result[:stderr]
      edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
      assert_empty edits
    end
  end

  # Production break: a merged or manually closed PR can retain an attention
  # label forever because clearing the semantic state required the PR to be open.
  def test_transition_clears_attention_labels_on_closed_and_merged_prs
    %w[CLOSED MERGED].each do |pr_state|
      with_repo_config(LABEL_POLICY) do |root|
        fake_gh = File.join(root, "gh")
        calls = File.join(root, "calls")
        File.write(fake_gh, <<~RUBY)
          #!/usr/bin/env ruby
          require "json"
          File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
          if ARGV[0, 2] == ["pr", "view"]
            edited = File.read(ENV.fetch("CALLS")).include?("--remove-label\thuman-attention:merge")
            labels = edited ? [] : [{"name" => "human-attention:merge"}]
            puts JSON.generate({"state" => ENV.fetch("PR_STATE"), "headRefOid" => "#{'a' * 40}", "labels" => labels})
          end
        RUBY
        File.chmod(0o755, fake_gh)

        result = run_cli(
          "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
          "--state", "none", "--expected-head", ("a" * 40).to_s,
          env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls, "PR_STATE" => pr_state }
        )

        assert_predicate result[:status], :success?, "#{pr_state}: #{result[:stderr]}"
        edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
        assert_equal 1, edits.length, pr_state
        assert_includes edits.first, "--remove-label\thuman-attention:merge"
      end
    end
  end

  def test_transition_does_not_assign_attention_labels_on_a_closed_pr
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
        if ARGV[0, 2] == ["pr", "view"]
          puts JSON.generate({"state" => "CLOSED", "headRefOid" => "#{'a' * 40}", "labels" => []})
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "PR is not open"
      edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
      assert_empty edits
    end
  end

  def test_transition_clears_attention_state_when_head_changes_during_edit
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.open(ENV.fetch("CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
        if ARGV[0, 2] == ["pr", "view"]
          view_count = File.readlines(ENV.fetch("CALLS")).count { |line| line.start_with?("pr\tview") }
          case view_count
          when 1
            puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'a' * 40}", "labels" => [{"name" => "human-attention:walkthrough"}]})
          when 2
            puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'b' * 40}", "labels" => [{"name" => "human-attention:merge"}]})
          else
            puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'b' * 40}", "labels" => []})
          end
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "attention state cleared"
      edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
      assert_equal 2, edits.length
      assert_includes edits.last, "--remove-label\thuman-attention:merge"
    end
  end

  # Production break: a successful edit can read back both semantic labels or
  # the wrong single label, and returning immediately would leave stale human
  # attention state on the PR.
  def test_transition_clears_both_semantic_labels_after_verification
    assert_verification_mismatch_cleared("both")
  end

  def test_transition_clears_the_wrong_semantic_label_after_verification
    assert_verification_mismatch_cleared("wrong")
  end

  # Production break: GitHub can partially apply a combined remove/add edit
  # before returning failure, leaving a PR with both semantic labels.
  def test_transition_clears_semantic_labels_after_a_partially_failed_edit
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        calls = ENV.fetch("CALLS")
        File.open(calls, "a") { |file| file.puts(ARGV.join("\t")) }
        lines = File.readlines(calls)
        if ARGV[0, 2] == ["pr", "view"]
          view_count = lines.count { |line| line.start_with?("pr\tview") }
          labels = case view_count
                   when 1 then ["human-attention:walkthrough"]
                   when 2 then ["human-attention:walkthrough", "human-attention:merge"]
                   else []
                   end
          puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'a' * 40}", "labels" => labels.map { |name| {"name" => name} }})
        elsif ARGV[0, 2] == ["pr", "edit"]
          edit_count = lines.count { |line| line.start_with?("pr\tedit") }
          if edit_count == 1
            warn "partial label update"
            exit 1
          end
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "update failed; attention state cleared"
      edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
      assert_equal 2, edits.length
      assert_includes edits.last, "--remove-label\thuman-attention:walkthrough"
      assert_includes edits.last, "--remove-label\thuman-attention:merge"
      view_count = File.readlines(calls).count { |line| line.start_with?("pr\tview") }
      assert_equal 3, view_count
    end
  end

  # Production break: malformed CLI values escape the error boundary and expose
  # a Ruby backtrace instead of one actionable parser message.
  def test_invalid_numeric_option_fails_without_a_backtrace
    result = run_cli("transition", "--pr", "not-a-number")

    refute_predicate result[:status], :success?
    assert_empty result[:stdout]
    assert_equal "invalid argument: --pr not-a-number\n", result[:stderr]
  end

  private

  def assert_verification_mismatch_cleared(mismatch)
    with_repo_config(LABEL_POLICY) do |root|
      fake_gh = File.join(root, "gh")
      calls = File.join(root, "calls")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        calls = ENV.fetch("CALLS")
        File.open(calls, "a") { |file| file.puts(ARGV.join("\t")) }
        if ARGV[0, 2] == ["pr", "view"]
          view_count = File.readlines(calls).count { |line| line.start_with?("pr\tview") }
          labels = case view_count
                   when 1 then ["human-attention:walkthrough"]
                   when 2
                     ENV.fetch("MISMATCH") == "both" ?
                       ["human-attention:walkthrough", "human-attention:merge"] :
                       ["human-attention:walkthrough"]
                   else []
                   end
          puts JSON.generate({"state" => "OPEN", "headRefOid" => "#{'a' * 40}", "labels" => labels.map { |name| {"name" => name} }})
        end
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "transition", "--repo-root", root, "--repo", "acme/widgets", "--pr", "7",
        "--state", "merge", "--expected-head", ("a" * 40).to_s,
        env: { "HUMAN_ATTENTION_GH" => fake_gh, "CALLS" => calls, "MISMATCH" => mismatch }
      )

      refute_predicate result[:status], :success?, mismatch
      assert_includes result[:stderr], "verification mismatch; attention state cleared"
      edits = File.readlines(calls, chomp: true).select { |line| line.start_with?("pr\tedit") }
      assert_equal 2, edits.length, mismatch
      assert_includes edits.last, "--remove-label\thuman-attention:walkthrough"
      if mismatch == "both"
        assert_includes edits.last, "--remove-label\thuman-attention:merge"
      end
      view_count = File.readlines(calls).count { |line| line.start_with?("pr\tview") }
      assert_equal 3, view_count, mismatch
    end
  end

  def with_repo_config(contents)
    Dir.mktmpdir("human-attention-test") do |root|
      agents = File.join(root, ".agents")
      Dir.mkdir(agents)
      File.write(File.join(agents, "agent-workflow.yml"), contents)
      yield root
    end
  end

  def run_cli(*arguments, stdin: "", env: {})
    stdout, stderr, status = Open3.capture3(env, SCRIPT, *arguments, stdin_data: stdin)
    { stdout:, stderr:, status: }
  end
end
