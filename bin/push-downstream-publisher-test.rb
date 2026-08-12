#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

SCRIPT = File.expand_path("push-downstream", __dir__)
load SCRIPT

class PushDownstreamPublisherCliTest < Minitest::Test
  def run_cli(*)
    Open3.capture2e(RbConfig.ruby, SCRIPT, *)
  end

  def test_publisher_requires_explicit_confirmation_and_exact_source_sha
    Tempfile.create(["downstream-seam-audit", ".json"]) do |report|
      report.write("{}\n")
      report.flush

      missing_confirmation, confirmation_status = run_cli(
        "--publish-report", report.path,
        "--source-sha", "a" * 40
      )
      missing_sha, sha_status = run_cli(
        "--publish-report", report.path,
        "--confirm-publish"
      )

      refute confirmation_status.success?
      assert_includes missing_confirmation, "--confirm-publish is required"
      refute sha_status.success?
      assert_includes missing_sha, "--source-sha is required"
    end
  end

  def test_publisher_rejects_every_legacy_write_or_selection_mode
    Tempfile.create(["downstream-seam-audit", ".json"]) do |report|
      report.write("{}\n")
      report.flush
      common = [
        "--publish-report", report.path,
        "--source-sha", "a" * 40,
        "--confirm-publish"
      ]

      [
        ["--apply"],
        ["--audit"],
        ["--root", "."],
        ["--policy-fleet", "repo-prefix"],
        ["--security-audit-fleet", "secure-github-actions"],
        ["--only", "consumer"],
        ["--all"],
        ["--trusted-user", "maintainer"]
      ].each do |legacy_flags|
        output, status = run_cli(*(common + legacy_flags))

        refute status.success?, legacy_flags.inspect
        assert_includes output, "--publish-report cannot be combined", legacy_flags.inspect
      end
    end
  end

  def test_publisher_confirmation_and_source_sha_are_invalid_without_a_report
    output, status = run_cli("--source-sha", "a" * 40, "--confirm-publish")

    refute status.success?
    assert_includes output, "--source-sha and --confirm-publish require --publish-report"
  end
end

class PushDownstreamPublisherReportTest < Minitest::Test
  def test_publisher_rejects_malformed_and_unknown_reports_before_authentication
    reports = [
      "not json\n",
      JSON.generate(
        "schema" => PushDownstream::AUDIT_SCHEMA,
        "source" => {
          "repo" => "shakacode/agent-workflows",
          "sha" => PushDownstream::AUDIT_UNKNOWN,
          "worktree_clean" => PushDownstream::AUDIT_UNKNOWN
        },
        "consumers" => []
      )
    ]

    reports.each do |contents|
      Tempfile.create(["downstream-seam-audit", ".json"]) do |report|
        report.write(contents)
        report.flush

        out, err = capture_io do
          @status = PushDownstream.run_publisher(
            report.path,
            "unused-downstream.yml",
            "unused-presets.yml",
            source_sha: "a" * 40
          )
        end

        assert_equal 1, @status
        assert_empty out
        assert_includes err, "publisher failed closed"
      end
    end
  end

  def test_publisher_rejects_reported_paths_outside_the_managed_scaffold
    source_sha = "a" * 40
    report = publisher_report(
      source_sha,
      consumers: [publisher_consumer("local/consumer", "drifted", ["README.md"])]
    )

    with_report(report) do |path|
      error = assert_raises(RuntimeError) do
        PushDownstream.load_publisher_report(path, source_sha: source_sha)
      end
      assert_includes error.message, "path outside the managed scaffold"
    end
  end

  def test_publisher_rejects_a_summary_that_does_not_match_consumer_states
    source_sha = "a" * 40
    report = publisher_report(
      source_sha,
      consumers: [publisher_consumer("local/consumer", "drifted", ["AGENTS.md"])]
    )
    report["summary"]["clean"] = 1

    with_report(report) do |path|
      error = assert_raises(RuntimeError) do
        PushDownstream.load_publisher_report(path, source_sha: source_sha)
      end
      assert_includes error.message, "summary does not match consumer states"
    end
  end

  def test_publisher_rejects_registry_branches_that_are_invalid_or_target_the_base
    Dir.mktmpdir("push-downstream-publisher-registry") do |dir|
      config = File.join(dir, "downstream.yml")
      File.write(config, <<~YAML)
        defaults:
          owner: local
          base_branch: main
          pr_branch: main
        repos:
          - repo: consumer
      YAML
      consumer = publisher_consumer("local/consumer", "drifted", ["AGENTS.md"])

      error = assert_raises(RuntimeError) do
        PushDownstream.publisher_registry_repos(config, [consumer])
      end
      assert_includes error.message, "publisher branch must differ from the base branch"
    end
  end

  def test_publisher_accepts_intentionally_unapplied_follow_ups_on_a_clean_consumer
    source_sha = "a" * 40
    clean = publisher_consumer("local/consumer", "clean", [])
    clean["follow_ups"] = [PushDownstream::CLAUDE_CONSOLIDATION_FOLLOW_UP]
    report = publisher_report(source_sha, consumers: [clean])

    with_report(report) do |path|
      parsed = PushDownstream.load_publisher_report(path, source_sha: source_sha)

      assert_equal [PushDownstream::CLAUDE_CONSOLIDATION_FOLLOW_UP],
                   parsed.fetch("consumers").first.fetch("follow_ups")
    end
  end

  def test_publisher_requires_the_current_clean_source_to_match_the_report
    Dir.mktmpdir("push-downstream-publisher-source") do |root|
      git!(root, "init", "-b", "main")
      File.write(File.join(root, "source.txt"), "one\n")
      git!(root, "add", "source.txt")
      git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "source")
      source_sha = git!(root, "rev-parse", "HEAD").strip
      report = publisher_report(source_sha, consumers: [])

      File.write(File.join(root, "source.txt"), "dirty\n")
      with_report(report) do |path|
        _out, err = capture_io do
          @status = PushDownstream.run_publisher(
            path,
            "unused-downstream.yml",
            "unused-presets.yml",
            source_sha: source_sha,
            source_root: root
          )
        end

        assert_equal 1, @status
        assert_includes err, "current source does not exactly match the clean audit source"
      end
    end
  end

  def test_publisher_rejects_blocked_or_unknown_consumer_state_before_authentication
    with_clean_source do |root, source_sha|
      blocked = {
        "repo" => "local/consumer",
        "preset" => nil,
        "base_branch" => "main",
        "base_sha" => PushDownstream::AUDIT_UNKNOWN,
        "status" => "blocked",
        "seam_doctor_issues" => PushDownstream::AUDIT_UNKNOWN,
        "changed_managed_paths" => PushDownstream::AUDIT_UNKNOWN,
        "follow_ups" => PushDownstream::AUDIT_UNKNOWN,
        "reason" => "clone failed"
      }

      with_report(publisher_report(source_sha, consumers: [blocked])) do |path|
        _out, err = capture_io do
          @status = PushDownstream.run_publisher(
            path,
            "unused-downstream.yml",
            "unused-presets.yml",
            source_sha: source_sha,
            source_root: root
          )
        end

        assert_equal 1, @status
        assert_includes err, "blocked or UNKNOWN consumer state cannot publish"
      end
    end
  end

  def test_publisher_fails_closed_when_github_authentication_is_unavailable
    with_clean_source do |root, source_sha|
      Dir.mktmpdir("push-downstream-publisher-auth") do |dir|
        config = File.join(dir, "downstream.yml")
        presets = File.join(dir, "seam-presets.yml")
        File.write(config, <<~YAML)
          defaults:
            owner: local
            base_branch: main
            pr_branch: agent-workflows/seam-sync
          repos:
            - repo: consumer
        YAML
        File.write(presets, "{}\n")
        fake_bin = File.join(dir, "bin")
        FileUtils.mkdir_p(fake_bin)
        File.write(File.join(fake_bin, "gh"), "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, File.join(fake_bin, "gh"))
        drifted = {
          "repo" => "local/consumer",
          "preset" => nil,
          "base_branch" => "main",
          "base_sha" => "b" * 40,
          "status" => "drifted",
          "seam_doctor_issues" => ["missing seam"],
          "changed_managed_paths" => ["AGENTS.md"],
          "follow_ups" => []
        }

        with_report(publisher_report(source_sha, consumers: [drifted])) do |path|
          previous_path = ENV.fetch("PATH")
          ENV["PATH"] = "#{fake_bin}:#{previous_path}"
          begin
            _out, err = capture_io do
              @status = PushDownstream.run_publisher(
                path,
                config,
                presets,
                source_sha: source_sha,
                source_root: root
              )
            end
          ensure
            ENV["PATH"] = previous_path
          end

          assert_equal 1, @status
          assert_includes err, "GitHub authentication is unavailable"
        end
      end
    end
  end

  def test_publisher_syncs_only_drifted_consumers_and_never_churns_clean_consumers
    with_clean_source do |root, source_sha|
      Dir.mktmpdir("push-downstream-publisher-selection") do |dir|
        config = File.join(dir, "downstream.yml")
        presets = File.join(dir, "seam-presets.yml")
        File.write(config, <<~YAML)
          defaults:
            owner: local
            base_branch: main
            pr_branch: agent-workflows/seam-sync
          repos:
            - repo: clean-consumer
            - repo: drifted-consumer
        YAML
        File.write(presets, "{}\n")
        clean = publisher_consumer("local/clean-consumer", "clean", [])
        drifted = publisher_consumer("local/drifted-consumer", "drifted", ["AGENTS.md"])
        published = []

        with_report(publisher_report(source_sha, consumers: [clean, drifted])) do |path|
          with_module_stub(PushDownstream, :publisher_authentication_ready?, -> { true }) do
            replacement = lambda do |repo, _contract, entry|
              published << [repo.fetch(:nwo), entry.fetch("repo")]
              true
            end
            with_module_stub(PushDownstream, :publish_audited_repo, replacement) do
              out, err = capture_io do
                @status = PushDownstream.run_publisher(
                  path,
                  config,
                  presets,
                  source_sha: source_sha,
                  source_root: root
                )
              end

              assert_equal 0, @status, err
              assert_empty out
            end
          end
        end

        assert_equal [["local/drifted-consumer", "local/drifted-consumer"]], published
      end
    end
  end

  def test_publisher_attempts_every_drifted_consumer_after_one_fails
    with_clean_source do |root, source_sha|
      Dir.mktmpdir("push-downstream-publisher-multi-consumer") do |dir|
        config = File.join(dir, "downstream.yml")
        presets = File.join(dir, "seam-presets.yml")
        File.write(config, <<~YAML)
          defaults:
            owner: local
            base_branch: main
            pr_branch: agent-workflows/seam-sync
          repos:
            - repo: first
            - repo: second
        YAML
        File.write(presets, "{}\n")
        consumers = %w[first second].map do |name|
          publisher_consumer("local/#{name}", "drifted", ["AGENTS.md"])
        end
        attempted = []

        with_report(publisher_report(source_sha, consumers: consumers)) do |path|
          with_module_stub(PushDownstream, :publisher_authentication_ready?, -> { true }) do
            replacement = lambda do |repo, _contract, _entry|
              attempted << repo.fetch(:nwo)
              repo.fetch(:repo) == "second"
            end
            with_module_stub(PushDownstream, :publish_audited_repo, replacement) do
              _out, _err = capture_io do
                @status = PushDownstream.run_publisher(
                  path, config, presets, source_sha: source_sha, source_root: root
                )
              end
            end
          end
        end

        assert_equal 1, @status
        assert_equal %w[local/first local/second], attempted
      end
    end
  end

  private

  def publisher_report(source_sha, consumers:)
    counts = PushDownstream::AUDIT_STATUSES.to_h do |status|
      [status, consumers.count { |consumer| consumer["status"] == status }]
    end
    {
      "schema" => PushDownstream::AUDIT_SCHEMA,
      "source" => {
        "repo" => "shakacode/agent-workflows",
        "sha" => source_sha,
        "worktree_clean" => true
      },
      "summary" => { "total" => consumers.length }.merge(counts),
      "consumers" => consumers
    }
  end

  def publisher_consumer(repo, status, changed_paths)
    {
      "repo" => repo,
      "preset" => nil,
      "base_branch" => "main",
      "base_sha" => "c" * 40,
      "status" => status,
      "seam_doctor_issues" => status == "clean" ? [] : ["missing seam"],
      "changed_managed_paths" => changed_paths,
      "follow_ups" => []
    }
  end

  def with_report(report)
    Tempfile.create(["downstream-seam-audit", ".json"]) do |file|
      file.write(JSON.generate(report))
      file.flush
      yield file.path
    end
  end

  def git!(root, *arguments)
    output, status = Open3.capture2e("git", "-C", root, *arguments)
    raise "git fixture failed: #{output}" unless status.success?

    output
  end

  def with_clean_source
    Dir.mktmpdir("push-downstream-publisher-source") do |root|
      git!(root, "init", "-b", "main")
      File.write(File.join(root, "source.txt"), "source\n")
      git!(root, "add", "source.txt")
      git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "source")
      yield root, git!(root, "rev-parse", "HEAD").strip
    end
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

class PushDownstreamPublisherWritePathTest < Minitest::Test
  CONTRACT = {
    commands: {
      "validate" => "echo validate",
      "test" => "echo test"
    },
    policy: PushDownstream.minimum_policy("main")
  }.freeze

  def test_cli_stub_git_lookup_fails_clearly_when_git_is_missing_from_path
    Dir.mktmpdir("push-downstream-missing-git") do |dir|
      empty_path = File.join(dir, "empty-path")
      FileUtils.mkdir_p(empty_path)
      previous_path = ENV["PATH"]
      ENV["PATH"] = empty_path

      begin
        error = assert_raises(RuntimeError) do
          install_cli_stubs(File.join(dir, "stubs"))
        end
      ensure
        ENV["PATH"] = previous_path
      end

      assert_equal "git executable was not found on PATH", error.message
    end
  end

  def test_create_then_replay_reuses_one_pr_without_force_or_churn
    Dir.mktmpdir("push-downstream-publisher-write") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      audit_entry = audit(repo)
      fake_bin, gh_log, git_log = install_cli_stubs(dir)
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        first_out, first_err = capture_io do
          @first_status = PushDownstream.publish_audited_repo(repo, CONTRACT, audit_entry)
        end
        first_head = bare_ref(remote, repo.fetch(:pr_branch))
        second_out, second_err = capture_io do
          @second_status = PushDownstream.publish_audited_repo(repo, CONTRACT, audit_entry)
        end
        second_head = bare_ref(remote, repo.fetch(:pr_branch))
      ensure
        ENV["PATH"] = previous_path
      end

      assert @first_status, first_err
      assert @second_status, second_err
      assert_includes first_out, "PR local/consumer https://example.test/local/consumer/pull/1"
      assert_includes second_out, "PR local/consumer https://example.test/local/consumer/pull/1"
      assert_equal first_head, second_head

      gh_calls = File.readlines(gh_log, chomp: true)
      assert_equal(1, gh_calls.count { |call| call.start_with?("pr create ") })
      refute(gh_calls.any? { |call| call.start_with?("pr merge ") })

      push_calls = File.readlines(git_log, chomp: true).select { |call| call.match?(/(?:\A| -C \S+ )push /) }
      assert_equal 1, push_calls.length, push_calls.inspect
      refute(push_calls.any? { |call| call.include?("--force") })
    end
  end

  def test_publisher_rejects_an_empty_audited_path_list_before_staging_or_push
    Dir.mktmpdir("push-downstream-publisher-empty-paths") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      checkout = File.join(dir, "current")
      git!(dir, "clone", "--branch", "main", remote, checkout)
      git!(checkout, "config", "user.name", "Test")
      git!(checkout, "config", "user.email", "test@example.com")
      PushDownstream.reconcile_scaffold(checkout, CONTRACT)
      git!(checkout, "add", ".agents", "AGENTS.md", "CLAUDE.md")
      git!(checkout, "commit", "-m", "adopt seam")
      git!(checkout, "push", "origin", "main")
      audit_entry = audit(repo)
      assert_equal "clean", audit_entry.fetch("status")
      fake_bin, _gh_log, git_log = install_cli_stubs(dir)
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        _out, err = capture_io do
          @status = PushDownstream.publish_audited_repo(repo, CONTRACT, audit_entry)
        end
      ensure
        ENV["PATH"] = previous_path
      end

      refute @status
      assert_includes err, "no changed managed paths"
      git_calls = File.file?(git_log) ? File.readlines(git_log, chomp: true) : []
      refute(git_calls.any? { |call| call.include?("add --all --") })
      refute(git_calls.any? { |call| call.match?(/(?:\A| -C \S+ )push /) })
    end
  end

  def test_publisher_branch_compare_and_swap_handles_present_and_absent_races_without_force
    scenarios = {
      present: { initial: :present, race: nil, succeeds: true },
      deleted: { initial: :present, race: :deleted, succeeds: false },
      changed: { initial: :present, race: :changed, succeeds: false },
      absent: { initial: :absent, race: nil, succeeds: true },
      appeared: { initial: :absent, race: :appeared, succeeds: false }
    }

    scenarios.each do |name, scenario|
      Dir.mktmpdir("push-downstream-publisher-cas-#{name}") do |dir|
        remote = seed_remote(dir)
        repo = publisher_repo(remote)
        branch = repo.fetch(:pr_branch)
        base_head = bare_ref(remote, "main")
        git!(remote, "update-ref", "refs/heads/#{branch}", base_head) if scenario.fetch(:initial) == :present
        competitor = seed_competing_commit(remote, dir)
        clone = File.join(dir, "clone")
        git!(dir, "clone", "--branch", "main", remote, clone)
        git!(clone, "config", "user.name", "Test")
        git!(clone, "config", "user.email", "test@example.com")
        File.write(File.join(clone, "publisher.txt"), "publisher\n")
        git!(clone, "add", "publisher.txt")
        git!(clone, "commit", "-m", "publisher")
        new_head = git!(clone, "rev-parse", "HEAD").strip
        expected = scenario.fetch(:initial) == :present ? base_head : nil
        git_calls = []
        original_git = PushDownstream.method(:publisher_git)
        original_update = PushDownstream.method(:publisher_atomic_ref_update)
        fixture_git = method(:git!)
        record_git = lambda do |root, *arguments|
          git_calls << arguments
          original_git.call(root, *arguments)
        end
        raced = false
        inject_race = lambda do |target_repo, target_branch, before, after, staging|
          unless raced
            case scenario[:race]
            when :deleted
              fixture_git.call(remote, "update-ref", "-d", "refs/heads/#{branch}", base_head)
            when :changed, :appeared
              fixture_git.call(remote, "update-ref", "refs/heads/#{branch}", competitor)
            end
            raced = true
          end
          original_update.call(target_repo, target_branch, before, after, staging)
        end

        with_module_stub(PushDownstream, :publisher_git, record_git) do
          with_module_stub(PushDownstream, :publisher_atomic_ref_update, inject_race) do
            @published = PushDownstream.publisher_publish_branch(repo, clone, branch, expected, new_head)
          end
        end

        assert_equal scenario.fetch(:succeeds), @published, name
        expected_target =
          case scenario[:race]
          when :deleted then nil
          when :changed, :appeared then competitor
          else new_head
          end
        actual_target = bare_ref_or_nil(remote, branch)
        expected_target.nil? ? assert_nil(actual_target, name) : assert_equal(expected_target, actual_target, name)
        assert_empty git!(remote, "for-each-ref", "--format=%(refname)", "refs/heads/agent-workflows/staging/").lines,
                     name
        refute(git_calls.flatten.any? { |argument| argument.include?("--force") }, name)
      end
    end
  end

  def test_publisher_cleans_the_exact_staging_ref_when_update_raises_after_upload
    Dir.mktmpdir("push-downstream-publisher-staging-exception") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      branch = repo.fetch(:pr_branch)
      clone = File.join(dir, "clone")
      git!(dir, "clone", "--branch", "main", remote, clone)
      git!(clone, "config", "user.name", "Test")
      git!(clone, "config", "user.email", "test@example.com")
      File.write(File.join(clone, "publisher.txt"), "publisher\n")
      git!(clone, "add", "publisher.txt")
      git!(clone, "commit", "-m", "publisher")
      new_head = git!(clone, "rev-parse", "HEAD").strip
      original_git = PushDownstream.method(:publisher_git)
      raise_after_upload = lambda do |root, *arguments|
        result = original_git.call(root, *arguments)
        raise "injected failure after staging upload" if arguments.first == "push" && result

        result
      end

      with_module_stub(PushDownstream, :publisher_git, raise_after_upload) do
        _out, err = capture_io do
          @published = PushDownstream.publisher_publish_branch(repo, clone, branch, nil, new_head)
        end
        assert_includes err, "injected failure after staging upload"
      end

      refute @published
      assert_nil bare_ref_or_nil(remote, branch)
      assert_empty git!(remote, "for-each-ref", "--format=%(refname)", "refs/heads/agent-workflows/staging/").lines
    end
  end

  def test_publisher_reaps_only_stale_owned_staging_refs_before_upload
    Dir.mktmpdir("push-downstream-publisher-stale-staging") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      branch = repo.fetch(:pr_branch)
      base_head = bare_ref(remote, "main")
      now = Time.now.to_i
      stale = "agent-workflows/staging/#{now - (3 * 60 * 60)}-#{'a' * 32}"
      recent = "agent-workflows/staging/#{now - (30 * 60)}-#{'b' * 32}"
      git!(remote, "update-ref", "refs/heads/#{stale}", base_head)
      git!(remote, "update-ref", "refs/heads/#{recent}", base_head)
      clone = File.join(dir, "clone")
      git!(dir, "clone", "--branch", "main", remote, clone)
      git!(clone, "config", "user.name", "Test")
      git!(clone, "config", "user.email", "test@example.com")
      File.write(File.join(clone, "publisher.txt"), "publisher\n")
      git!(clone, "add", "publisher.txt")
      git!(clone, "commit", "-m", "publisher")
      new_head = git!(clone, "rev-parse", "HEAD").strip

      assert PushDownstream.publisher_publish_branch(repo, clone, branch, nil, new_head)

      assert_nil bare_ref_or_nil(remote, stale)
      assert_equal base_head, bare_ref(remote, recent)
      assert_equal new_head, bare_ref(remote, branch)
      assert_equal ["refs/heads/#{recent}\n"],
                   git!(remote, "for-each-ref", "--format=%(refname)",
                        "refs/heads/agent-workflows/staging/").lines
    end
  end

  def test_github_staging_ref_listing_is_exact_bounded_and_shape_checked
    repo = { owner: "local", repo: "consumer", nwo: "local/consumer" }
    oid = "a" * 40
    qualified_name = "refs/heads/agent-workflows/staging/1000000000-#{'b' * 32}"
    branch_name = qualified_name.delete_prefix("refs/heads/")
    response = {
      "data" => {
        "repository" => {
          "refs" => {
            "nodes" => [{ "prefix" => "refs/heads/", "name" => branch_name, "target" => { "oid" => oid } }],
            "pageInfo" => { "hasNextPage" => false }
          }
        }
      }
    }
    calls = []
    success = Object.new
    success.define_singleton_method(:success?) { true }

    with_module_stub(Open3, :capture2, lambda { |*arguments|
      calls << arguments
      [JSON.generate(response), success]
    }) do
      assert_equal [{ name: qualified_name, oid: oid }], PushDownstream.publisher_staging_refs(repo)
    end

    command = calls.fetch(0)
    query = command.find { |argument| argument.start_with?("query=") }
    assert_includes query, "repository(owner: $owner, name: $name)"
    assert_includes command, "owner=local"
    assert_includes command, "name=consumer"
    assert_includes query, "refPrefix: $refPrefix"
    assert_includes command, "refPrefix=refs/heads/agent-workflows/staging/"
    assert_includes command, "limit=#{PushDownstream::PUBLISH_STAGING_REF_LIMIT + 1}"

    malformed_node = Marshal.load(Marshal.dump(response))
    malformed_node.dig("data", "repository", "refs", "nodes")[0]["prefix"] = "refs/tags/"
    with_module_stub(Open3, :capture2, ->(*) { [JSON.generate(malformed_node), success] }) do
      assert_nil PushDownstream.publisher_staging_refs(repo)
    end
  end

  def test_publisher_fails_closed_before_upload_for_unknown_staging_inventory
    repo = { nwo: "local/consumer" }
    oid = "a" * 40
    now = Time.now.to_i
    cases = {
      lookup_failure: nil,
      malformed: [{ name: "refs/heads/agent-workflows/staging/not-owned", oid: oid }],
      overflow: Array.new(PushDownstream::PUBLISH_STAGING_REF_LIMIT + 1) do |index|
        {
          name: "refs/heads/agent-workflows/staging/#{now}-#{format('%032x', index)}",
          oid: oid
        }
      end
    }
    push = ->(*) { flunk "must not upload while staging inventory is unknown" }

    cases.each do |name, refs|
      with_module_stub(PushDownstream, :publisher_staging_refs, ->(_repo) { refs }) do
        with_module_stub(PushDownstream, :publisher_git, push) do
          refute PushDownstream.publisher_publish_branch(repo, "/unused", "sync", nil, oid), name
        end
      end
    end
  end

  def test_stale_cleanup_uses_the_listed_exact_oid_and_rejects_a_race
    Dir.mktmpdir("push-downstream-publisher-stale-race") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      base_head = bare_ref(remote, "main")
      competitor = seed_competing_commit(remote, dir)
      stale = "agent-workflows/staging/#{Time.now.to_i - (3 * 60 * 60)}-#{'c' * 32}"
      git!(remote, "update-ref", "refs/heads/#{stale}", base_head)
      original_update = PushDownstream.method(:publisher_update_refs)
      fixture_git = method(:git!)
      raced_update = lambda do |target_repo, updates|
        fixture_git.call(remote, "update-ref", "refs/heads/#{stale}", competitor, base_head)
        original_update.call(target_repo, updates)
      end

      with_module_stub(PushDownstream, :publisher_update_refs, raced_update) do
        refute PushDownstream.publisher_reconcile_stale_staging_refs(repo)
      end

      assert_equal competitor, bare_ref(remote, stale)
    end
  end

  def test_staging_cleanup_accepts_absence_and_never_deletes_a_different_oid
    Dir.mktmpdir("push-downstream-publisher-exact-cleanup") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      expected = bare_ref(remote, "main")
      competing = seed_competing_commit(remote, dir)
      staging = "agent-workflows/staging/#{Time.now.to_i}-#{'d' * 32}"

      assert PushDownstream.publisher_delete_staging_ref(repo, staging, expected), "already absent"
      git!(remote, "update-ref", "refs/heads/#{staging}", competing)
      refute PushDownstream.publisher_delete_staging_ref(repo, staging, expected), "different oid"
      assert_equal competing, bare_ref(remote, staging)
      assert PushDownstream.publisher_delete_staging_ref(repo, staging, competing), "exact oid"
      assert_nil bare_ref_or_nil(remote, staging)
    end
  end

  def test_staging_cleanup_failure_is_visible_and_does_not_raise_over_publish_failure
    repo = { nwo: "local/consumer" }
    oid = "a" * 40
    cleanup_failure = ->(*) { raise "cleanup unavailable" }

    with_module_stub(PushDownstream, :publisher_reconcile_stale_staging_refs, ->(*) { true }) do
      with_module_stub(PushDownstream, :publisher_git, ->(*) { true }) do
        with_module_stub(PushDownstream, :publisher_atomic_ref_update, ->(*) { false }) do
          with_module_stub(PushDownstream, :publisher_delete_staging_ref, cleanup_failure) do
            _out, err = capture_io do
              @published = PushDownstream.publisher_publish_branch(repo, "/unused", "sync", nil, oid)
            end
            assert_includes err, "publisher staging ref cleanup failed"
          end
        end
      end
    end

    refute @published
  end

  def test_github_ref_update_contract_uses_exact_before_oid_and_force_false
    repo = { nwo: "local/consumer" }
    calls = []
    success = Object.new
    success.define_singleton_method(:success?) { true }
    capture = lambda do |*arguments|
      calls << arguments
      [JSON.generate("data" => { "updateRefs" => { "clientMutationId" => nil } }), success]
    end
    updates = [
      { name: "refs/heads/agent-workflows/seam-sync", before: "a" * 40, after: "b" * 40 },
      { name: "refs/heads/agent-workflows/staging/test", before: "b" * 40, after: PushDownstream::ZERO_OID }
    ]

    with_module_stub(PushDownstream, :publisher_github_repository_id, ->(_repo) { "R_test" }) do
      with_module_stub(Open3, :capture2, capture) do
        assert PushDownstream.publisher_update_refs(repo, updates)
      end
    end

    command = calls.fetch(0)
    query = command.find { |argument| argument.start_with?("query=") }
    assert_includes query, "beforeOid: $before0"
    assert_includes query, "afterOid: $after0"
    assert_includes query, "force: false"
    assert_includes command, "before0=#{'a' * 40}"
    assert_includes command, "after1=#{PushDownstream::ZERO_OID}"
    assert_equal 1, command.count("before0=#{'a' * 40}")
    refute(command.any? { |argument| argument.include?("--force") })
  end

  def test_github_repository_lookup_uses_owner_and_name_and_checks_response_shape
    repo = { owner: "local", repo: "consumer", nwo: "local/consumer" }
    calls = []
    success = Object.new
    success.define_singleton_method(:success?) { true }
    capture = lambda do |*arguments|
      calls << arguments
      [JSON.generate("data" => { "repository" => { "id" => "R_test" } }), success]
    end

    with_module_stub(Open3, :capture2, capture) do
      assert_equal "R_test", PushDownstream.publisher_github_repository_id(repo)
    end

    command = calls.fetch(0)
    query = command.find { |argument| argument.start_with?("query=") }
    assert_includes query, "repository(owner: $owner, name: $name)"
    assert_includes command, "owner=local"
    assert_includes command, "name=consumer"
    with_module_stub(Open3, :capture2, ->(*) { ["[]", success] }) do
      assert_nil PushDownstream.publisher_github_repository_id(repo)
    end
  end

  def test_github_ref_update_rejects_valid_json_with_the_wrong_shape
    repo = { nwo: "local/consumer" }
    success = Object.new
    success.define_singleton_method(:success?) { true }
    updates = [
      { name: "refs/heads/agent-workflows/staging/test", before: "b" * 40, after: PushDownstream::ZERO_OID }
    ]
    wrong_shapes = [
      [], nil, { "data" => [] }, { "data" => { "updateRefs" => nil } },
      { "data" => { "updateRefs" => "updated" } },
      { "errors" => [{ "message" => "rejected" }], "data" => { "updateRefs" => {} } }
    ]

    with_module_stub(PushDownstream, :publisher_github_repository_id, ->(_repo) { "R_test" }) do
      wrong_shapes.each do |shape|
        with_module_stub(Open3, :capture2, ->(*) { [JSON.generate(shape), success] }) do
          refute PushDownstream.publisher_update_refs(repo, updates), shape.inspect
        end
      end
    end
  end

  def test_update_fast_forwards_the_same_pr_after_the_consumer_base_advances
    Dir.mktmpdir("push-downstream-publisher-update") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      first_audit = audit(repo)
      fake_bin, gh_log, git_log = install_cli_stubs(dir)
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        _first_out, first_err = capture_io do
          @first_status = PushDownstream.publish_audited_repo(repo, CONTRACT, first_audit)
        end
        first_head = bare_ref(remote, repo.fetch(:pr_branch))
        new_base = advance_base(remote, dir)
        updated_contract = Marshal.load(Marshal.dump(CONTRACT))
        updated_contract.fetch(:commands)["docs"] = "echo docs"
        second_audit = audit(repo, contract: updated_contract)
        second_out, second_err = capture_io do
          @second_status = PushDownstream.publish_audited_repo(repo, updated_contract, second_audit)
        end
        second_head = bare_ref(remote, repo.fetch(:pr_branch))
      ensure
        ENV["PATH"] = previous_path
      end

      assert @first_status, first_err
      assert @second_status, second_err
      assert_includes second_out, "PR local/consumer https://example.test/local/consumer/pull/1"
      assert git_success?(remote, "merge-base", "--is-ancestor", first_head, second_head)
      assert git_success?(remote, "merge-base", "--is-ancestor", new_base, second_head)

      gh_calls = File.readlines(gh_log, chomp: true)
      assert_equal(1, gh_calls.count { |call| call.start_with?("pr create ") })
      refute(gh_calls.any? { |call| call.start_with?("pr merge ") })
      push_calls = File.readlines(git_log, chomp: true).select { |call| call.match?(/(?:\A| -C \S+ )push /) }
      assert_equal 2, push_calls.length, push_calls.inspect
      refute(push_calls.any? { |call| call.include?("--force") })
    end
  end

  def test_retained_branch_with_hidden_off_scope_history_is_rejected
    Dir.mktmpdir("push-downstream-publisher-hostile-history") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      audit_entry = audit(repo)
      seed_hidden_off_scope_branch(remote, dir)
      fake_bin, gh_log, git_log = install_cli_stubs(dir)
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        _out, err = capture_io do
          @status = PushDownstream.publish_audited_repo(repo, CONTRACT, audit_entry)
        end
      ensure
        ENV["PATH"] = previous_path
      end

      refute @status
      assert_includes err, "history is not focused"
      gh_calls = File.readlines(gh_log, chomp: true)
      refute(gh_calls.any? { |call| call.start_with?("pr create ") })
      push_calls = File.readlines(git_log, chomp: true).select { |call| call.match?(/(?:\A| -C \S+ )push /) }
      assert_empty push_calls
    end
  end

  def test_retained_unaudited_content_inside_an_expected_managed_path_is_rejected
    Dir.mktmpdir("push-downstream-publisher-retained-content") do |dir|
      remote = seed_remote(dir)
      repo = publisher_repo(remote)
      audit_entry = audit(repo)
      seed_retained_managed_content_branch(remote, dir)
      fake_bin, gh_log, git_log = install_cli_stubs(dir)
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        _out, err = capture_io do
          @status = PushDownstream.publish_audited_repo(repo, CONTRACT, audit_entry)
        end
      ensure
        ENV["PATH"] = previous_path
      end

      refute @status
      assert_includes err, "managed content does not exactly match the audited desired state"
      refute(File.readlines(gh_log, chomp: true).any? { |call| call.start_with?("pr create ") })
      assert_empty File.readlines(git_log, chomp: true).grep(/(?:\A| -C \S+ )push /)
      retained = git!(remote, "show", "agent-workflows/seam-sync:AGENTS.md")
      assert_includes retained, "## Consumer rules"
    end
  end

  def test_audit_and_publisher_reject_managed_path_symlinks_without_external_writes
    Dir.mktmpdir("push-downstream-managed-symlink") do |dir|
      audit_remote = seed_remote(File.join(dir, "audit"))
      audit_external = seed_managed_symlink(audit_remote, File.join(dir, "audit"), "external")
      audit_repo = publisher_repo(audit_remote)

      audit_entry = audit(audit_repo)

      assert_equal "blocked", audit_entry.fetch("status")
      assert_includes audit_entry.fetch("reason"), "managed scaffold path contains a symlink"
      assert_equal ["sentinel.txt"], Dir.children(audit_external)
      assert_equal "unchanged\n", File.binread(File.join(audit_external, "sentinel.txt"))

      publish_remote = seed_remote(File.join(dir, "publish"))
      publish_external = seed_managed_symlink(publish_remote, File.join(dir, "publish"), "external")
      publish_repo = publisher_repo(publish_remote)
      expected_paths = %w[
        .agents/agent-workflow.yml
        .agents/bin/README.md
        .agents/bin/test
        .agents/bin/validate
        AGENTS.md
        CLAUDE.md
      ].sort
      publish_audit = {
        "base_sha" => bare_ref(publish_remote, "main"),
        "changed_managed_paths" => expected_paths
      }
      fake_bin, gh_log, git_log = install_cli_stubs(File.join(dir, "publish"))
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"

      begin
        _out, err = capture_io do
          @publish_status = PushDownstream.publish_audited_repo(publish_repo, CONTRACT, publish_audit)
        end
      ensure
        ENV["PATH"] = previous_path
      end

      refute @publish_status
      assert_includes err, "managed scaffold path contains a symlink"
      assert_equal ["sentinel.txt"], Dir.children(publish_external)
      assert_equal "unchanged\n", File.binread(File.join(publish_external, "sentinel.txt"))
      assert_empty File.readlines(git_log, chomp: true).grep(/(?:\A| -C \S+ )push /)
      gh_calls = File.file?(gh_log) ? File.readlines(gh_log, chomp: true) : []
      refute(gh_calls.any? { |call| call.start_with?("pr create ") })
    end
  end

  def test_pr_confirmation_fails_when_the_remote_branch_moved
    repo = publisher_repo("unused")
    create_pr = ->(*) { flunk "must not create a PR for a moved branch" }
    with_module_stub(PushDownstream, :publisher_remote_ref_head, ->(*) { "b" * 40 }) do
      with_module_stub(PushDownstream, :create_pr, create_pr) do
        _out, err = capture_io do
          @status = PushDownstream.publisher_ensure_pull_request(
            repo,
            [],
            clone: "/unused",
            expected_head: "a" * 40
          )
        end

        refute @status
        assert_includes err, "publisher branch moved while confirming its PR"
      end
    end
  end

  def test_pr_confirmation_rejects_an_alternate_base_pr_before_creating_a_second_pr
    repo = publisher_repo("unused")
    queries = []
    created = false
    open_pr_state = lambda do |_repo, any_base: false|
      queries << any_base
      if any_base
        { ok: true, url: "https://example.test/local/consumer/pull/9", base: "release" }
      elsif created
        { ok: true, url: "https://example.test/local/consumer/pull/10", base: "main" }
      else
        { ok: true, url: nil, base: nil }
      end
    end
    create_pr = lambda do |*|
      created = true
      "https://example.test/local/consumer/pull/10"
    end

    with_module_stub(PushDownstream, :publisher_remote_ref_head, ->(*) { "a" * 40 }) do
      with_module_stub(PushDownstream, :publisher_open_pr_state, open_pr_state) do
        with_module_stub(PushDownstream, :create_pr, create_pr) do
          _out, err = capture_io do
            @status = PushDownstream.publisher_ensure_pull_request(
              repo,
              [],
              clone: "/unused",
              expected_head: "a" * 40
            )
          end

          refute @status
          assert_includes err, "open PR on another base"
        end
      end
    end

    refute created
    assert_equal [true], queries

    post_create_queries = []
    created = false
    post_create_state = lambda do |_repo, any_base: false|
      post_create_queries << any_base
      created ? { ok: false } : { ok: true, url: nil, base: nil }
    end
    create_pr = lambda do |*|
      created = true
      "https://example.test/local/consumer/pull/10"
    end

    with_module_stub(PushDownstream, :publisher_remote_ref_head, ->(*) { "a" * 40 }) do
      with_module_stub(PushDownstream, :publisher_open_pr_state, post_create_state) do
        with_module_stub(PushDownstream, :create_pr, create_pr) do
          _out, err = capture_io do
            @status = PushDownstream.publisher_ensure_pull_request(
              repo,
              [],
              clone: "/unused",
              expected_head: "a" * 40
            )
          end

          refute @status
          assert_includes err, "unique open publisher PR"
        end
      end
    end

    assert created
    assert_equal [true, true], post_create_queries
  end

  private

  def publisher_repo(remote)
    {
      repo: "consumer",
      nwo: "local/consumer",
      base_branch: "main",
      pr_branch: "agent-workflows/seam-sync",
      preset: nil,
      remote_url: remote
    }
  end

  def seed_remote(dir)
    FileUtils.mkdir_p(dir)
    remote = File.join(dir, "consumer.git")
    seed = File.join(dir, "seed")
    system("git", "init", "--bare", remote, out: File::NULL, err: File::NULL)
    system("git", "clone", remote, seed, out: File::NULL, err: File::NULL)
    system("git", "-C", seed, "config", "user.name", "Test")
    system("git", "-C", seed, "config", "user.email", "test@example.com")
    File.write(File.join(seed, "README.md"), "consumer\n")
    system("git", "-C", seed, "add", "README.md")
    system("git", "-C", seed, "commit", "-m", "consumer base", out: File::NULL, err: File::NULL)
    system("git", "-C", seed, "branch", "-M", "main")
    system("git", "-C", seed, "push", "origin", "main", out: File::NULL, err: File::NULL)
    remote
  end

  def seed_managed_symlink(remote, dir, name)
    checkout = File.join(dir, "managed-symlink-seed")
    external = File.join(dir, name)
    FileUtils.mkdir_p(external)
    File.binwrite(File.join(external, "sentinel.txt"), "unchanged\n")
    system("git", "clone", "--branch", "main", remote, checkout, out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "config", "user.name", "Test")
    system("git", "-C", checkout, "config", "user.email", "test@example.com")
    File.symlink(external, File.join(checkout, ".agents"))
    system("git", "-C", checkout, "add", ".agents")
    system("git", "-C", checkout, "commit", "-m", "add hostile managed symlink", out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "push", "origin", "main", out: File::NULL, err: File::NULL)
    external
  end

  def audit(repo, contract: CONTRACT)
    replacement = ->(_repo, _presets) { contract }
    with_module_stub(PushDownstream, :resolve_contract, replacement) do
      PushDownstream.audit_repo(repo, {})
    end
  end

  def advance_base(remote, dir)
    checkout = File.join(dir, "base-advance")
    system("git", "clone", "--branch", "main", remote, checkout, out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "config", "user.name", "Test")
    system("git", "-C", checkout, "config", "user.email", "test@example.com")
    File.write(File.join(checkout, "consumer-owned.txt"), "base advanced\n")
    system("git", "-C", checkout, "add", "consumer-owned.txt")
    system("git", "-C", checkout, "commit", "-m", "advance consumer base", out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "push", "origin", "main", out: File::NULL, err: File::NULL)
    git!(checkout, "rev-parse", "HEAD").strip
  end

  def seed_competing_commit(remote, dir)
    checkout = File.join(dir, "competitor")
    git!(dir, "clone", "--branch", "main", remote, checkout)
    git!(checkout, "config", "user.name", "Test")
    git!(checkout, "config", "user.email", "test@example.com")
    File.write(File.join(checkout, "competitor.txt"), "competitor\n")
    git!(checkout, "add", "competitor.txt")
    git!(checkout, "commit", "-m", "competitor")
    git!(checkout, "push", "origin", "HEAD:refs/heads/competitor")
    git!(checkout, "rev-parse", "HEAD").strip
  end

  def seed_hidden_off_scope_branch(remote, dir)
    checkout = File.join(dir, "hostile-history")
    system("git", "clone", "--branch", "main", remote, checkout, out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "config", "user.name", "Test")
    system("git", "-C", checkout, "config", "user.email", "test@example.com")
    system("git", "-C", checkout, "checkout", "-b", "agent-workflows/seam-sync", out: File::NULL, err: File::NULL)
    File.write(File.join(checkout, "README.md"), "temporary hostile change\n")
    system("git", "-C", checkout, "add", "README.md")
    system("git", "-C", checkout, "commit", "-m", "touch consumer file", out: File::NULL, err: File::NULL)
    File.write(File.join(checkout, "README.md"), "consumer\n")
    system("git", "-C", checkout, "add", "README.md")
    system("git", "-C", checkout, "commit", "-m", "hide consumer file change", out: File::NULL, err: File::NULL)
    PushDownstream.reconcile_scaffold(checkout, CONTRACT)
    system("git", "-C", checkout, "add", ".agents", "AGENTS.md", "CLAUDE.md")
    system("git", "-C", checkout, "commit", "-m", "add seam", out: File::NULL, err: File::NULL)
    system(
      "git", "-C", checkout, "push", "origin", "HEAD:agent-workflows/seam-sync",
      out: File::NULL, err: File::NULL
    )
  end

  def seed_retained_managed_content_branch(remote, dir)
    checkout = File.join(dir, "retained-content")
    system("git", "clone", "--branch", "main", remote, checkout, out: File::NULL, err: File::NULL)
    system("git", "-C", checkout, "config", "user.name", "Test")
    system("git", "-C", checkout, "config", "user.email", "test@example.com")
    system("git", "-C", checkout, "checkout", "-b", "agent-workflows/seam-sync", out: File::NULL, err: File::NULL)
    PushDownstream.reconcile_scaffold(checkout, CONTRACT)
    File.open(File.join(checkout, "AGENTS.md"), "a") do |file|
      file.write("\n## Consumer rules\n\nUnaudited retained content.\n")
    end
    system("git", "-C", checkout, "add", ".agents", "AGENTS.md", "CLAUDE.md")
    system("git", "-C", checkout, "commit", "-m", "add seam with retained content", out: File::NULL, err: File::NULL)
    system(
      "git", "-C", checkout, "push", "origin", "HEAD:agent-workflows/seam-sync",
      out: File::NULL, err: File::NULL
    )
  end

  def install_cli_stubs(dir)
    fake_bin = File.join(dir, "fake-bin")
    FileUtils.mkdir_p(fake_bin)
    gh_log = File.join(dir, "gh.log")
    git_log = File.join(dir, "git.log")
    pr_state = File.join(dir, "pr-state")
    real_git = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
      candidate = File.expand_path("git", directory.empty? ? Dir.pwd : directory)
      candidate if File.file?(candidate) && File.executable?(candidate)
    end.first
    raise "git executable was not found on PATH" unless real_git

    File.write(File.join(fake_bin, "git"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{git_log.inspect}
      exec #{real_git.inspect} "$@"
    SH
    File.chmod(0o755, File.join(fake_bin, "git"))
    File.write(File.join(fake_bin, "gh"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{gh_log.inspect}
      if [ "$1 $2" = "auth status" ]; then
        exit 0
      fi
      if [ "$1 $2" = "pr list" ]; then
        if [ -f #{pr_state.inspect} ]; then
          printf '%s\\n' '[{"url":"https://example.test/local/consumer/pull/1","baseRefName":"main","headRefName":"agent-workflows/seam-sync","headRepository":{"name":"consumer","nameWithOwner":"local/consumer"},"headRepositoryOwner":{"login":"local"}}]'
        else
          printf '%s\\n' '[]'
        fi
        exit 0
      fi
      if [ "$1 $2" = "pr create" ]; then
        : > #{pr_state.inspect}
        printf '%s\\n' 'https://example.test/local/consumer/pull/1'
        exit 0
      fi
      exit 99
    SH
    File.chmod(0o755, File.join(fake_bin, "gh"))
    [fake_bin, gh_log, git_log]
  end

  def bare_ref(remote, branch)
    output, status = Open3.capture2e("git", "--git-dir", remote, "rev-parse", "refs/heads/#{branch}")
    raise "missing branch #{branch}: #{output}" unless status.success?

    output.strip
  end

  def bare_ref_or_nil(remote, branch)
    output, status = Open3.capture2e("git", "--git-dir", remote, "rev-parse", "--verify", "refs/heads/#{branch}")
    status.success? ? output.strip : nil
  end

  def git!(root, *arguments)
    output, status = Open3.capture2e("git", "-C", root, *arguments)
    raise "git fixture failed: #{output}" unless status.success?

    output
  end

  def git_success?(remote, *arguments)
    system("git", "--git-dir", remote, *arguments, out: File::NULL, err: File::NULL)
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
