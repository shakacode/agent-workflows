#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/human_attention"

SCRIPT = File.expand_path("human-attention", __dir__)

class HumanAttentionTest < Minitest::Test
  def test_labels_for_uses_portable_default_labels
    with_repo_config("---\nbase_branch: main\n") do |root|
      labels = HumanAttention.labels_for(HumanAttention.load_config(root), "acme/widgets")
      assert_equal "human-attention:walkthrough", labels.fetch("walkthrough")
      assert_equal "human-attention:merge", labels.fetch("merge")
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

  def test_library_classify_rejects_both_semantic_labels
    with_repo_config("---\n") do |root|
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

  def test_desk_degrades_only_the_repository_with_conflicting_labels_and_discards_its_rows
    config = <<~YAML
      ---
      human_attention:
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

  def test_desk_requests_more_than_the_default_thirty_open_pull_requests
    config = <<~YAML
      ---
      human_attention:
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

  def test_transition_replaces_the_other_semantic_label_at_the_expected_head
    with_repo_config("---\n") do |root|
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

  def test_transition_clears_attention_state_when_head_changes_during_edit
    with_repo_config("---\n") do |root|
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

  private

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
