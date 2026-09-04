#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("human-attention", __dir__)

class HumanAttentionTest < Minitest::Test
  def test_resolve_uses_portable_default_labels
    with_repo_config("---\nbase_branch: main\n") do |root|
      result = run_cli("resolve", "--repo-root", root, "--repo", "acme/widgets")

      assert_predicate result[:status], :success?, result[:stderr]
      labels = JSON.parse(result[:stdout]).fetch("labels")
      assert_equal "human-attention:walkthrough", labels.fetch("walkthrough")
      assert_equal "human-attention:merge", labels.fetch("merge")
    end
  end

  def test_resolve_accepts_consumer_and_repository_overrides
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
      general = JSON.parse(run_cli("resolve", "--repo-root", root, "--repo", "acme/widgets")[:stdout])
      special = JSON.parse(run_cli("resolve", "--repo-root", root, "--repo", "acme/special")[:stdout])

      assert_equal "needs-walkthrough", general.dig("labels", "walkthrough")
      assert_equal "needs-merge", general.dig("labels", "merge")
      assert_equal "needs-walkthrough", special.dig("labels", "walkthrough")
      assert_equal "special-merge", special.dig("labels", "merge")
    end
  end

  def test_classify_rejects_both_semantic_labels
    with_repo_config("---\n") do |root|
      result = run_cli(
        "classify", "--repo-root", root, "--repo", "acme/widgets",
        "--label", "human-attention:walkthrough", "--label", "human-attention:merge"
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "must not carry both human-attention labels"
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
