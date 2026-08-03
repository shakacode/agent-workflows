#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/autonomous_merge_runtime_trust"

SCRIPT = File.expand_path("merge-assurance", __dir__)
load SCRIPT

class MergeAssuranceTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  DIFF_IDENTITY = "c" * 64
  NOW = Time.iso8601("2026-07-30T12:00:00Z")
  SYSTEM_GIT = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |directory|
    candidate = File.join(directory, "git")
    candidate if File.file?(candidate) && File.executable?(candidate)
  end.first
  HOSTED_CI_REPLAYS = JSON.parse(
    File.read(
      File.expand_path("../fixtures/selected-hosted-ci-hichee-replays.json", __dir__),
      encoding: "UTF-8"
    )
  ).freeze

  def setup
    @fake_gh_dir = Dir.mktmpdir("merge-assurance-gh")
    @fake_gh_calls = File.join(@fake_gh_dir, "calls")
    @original_path = ENV.fetch("PATH")
    ENV["PATH"] = @fake_gh_dir
    ENV["FAKE_GH_CALLS"] = @fake_gh_calls
    ENV["FAKE_GH_EXIT_STATUS"] = "0"
    ENV["FAKE_GH_RESPONSE"] = JSON.generate(fake_issue)
    @fake_gh = File.join(@fake_gh_dir, "gh")
    File.write(@fake_gh, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("FAKE_GH_CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
      if ENV["FAKE_GH_HANG"] == "1"
        child_pid = fork do
          trap("TERM", "IGNORE")
          File.write(ENV.fetch("FAKE_GH_CHILD_PID"), Process.pid.to_s)
          sleep 2
        end
        trap("TERM", "IGNORE")
        sleep 2
        Process.wait(child_pid)
      end
      STDOUT.write(ENV.fetch("FAKE_GH_RESPONSE"))
      exit Integer(ENV.fetch("FAKE_GH_EXIT_STATUS"))
    RUBY
    File.chmod(0o755, @fake_gh)
  end

  def teardown
    ENV["PATH"] = @original_path
    ENV.delete("FAKE_GH_CALLS")
    ENV.delete("FAKE_GH_EXIT_STATUS")
    ENV.delete("FAKE_GH_RESPONSE")
    ENV.delete("FAKE_GH_HANG")
    ENV.delete("FAKE_GH_CHILD_PID")
    ENV.delete("MERGE_ASSURANCE_GH_TIMEOUT_SECONDS")
    FileUtils.remove_entry(@fake_gh_dir)
  end

  def test_auto_mode_emits_integrity_bound_eligible_receipt
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal true, result.fetch("eligible")
    assert_equal "merge-assurance-receipt", result.fetch("contract")
    assert_equal 1, result.fetch("version")
    assert_equal "2026-07-30T12:00:00Z", result.fetch("issued_at")
    assert_equal(
      {
        "host" => "github.com",
        "repo" => "owner/repo",
        "pr" => 42,
        "base" => { "ref" => "main", "sha" => BASE_SHA },
        "head_sha" => HEAD_SHA,
        "authority" => "auto_merge_when_gates_pass",
        "diff_identity" => DIFF_IDENTITY
      },
      result.fetch("bindings")
    )
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("evidence_digest"))
    assert MergeAssurance.valid_evidence_digest?(result)
  end

  def test_selected_hosted_ci_hichee_10049_cancelled_replay_blocks
    replay = HOSTED_CI_REPLAYS.fetch("cases").find { |item| item.fetch("pr") == 10_049 }
    context = context(
      "auto_merge_when_gates_pass",
      repo: HOSTED_CI_REPLAYS.fetch("repository"),
      pull_request: replay.fetch("pr"),
      head_sha: replay.fetch("head_sha"),
      selected_hosted_runs: replay.fetch("selected_runs").map do |run|
        run.slice("provider", "run_id")
      end
    )
    records = selected_hosted_ci_receipts(replay, context)

    result = MergeAssurance.assess(
      ci_result: ready_ci(
        repo: context.fetch("repo"), pull_request: context.fetch("pr"), head_sha: context.fetch("head_sha")
      ),
      autonomous_result: autonomous_result(
        "autonomous-merge-eligible", head_sha: context.fetch("head_sha")
      ),
      context:,
      selected_hosted_ci_receipts: records,
      now: NOW
    )

    refute result.fetch("eligible")
    assert_includes(
      result.fetch("failures"),
      "selected hosted run circleci/c506a91e-5b3b-4bb6-b136-2bcfa06f69aa is cancelled"
    )
  end

  def test_cli_executes_selected_hosted_ci_receipt_seam_from_trusted_base
    account_home = File.realpath(Etc.getpwuid(Process.uid).dir)
    Dir.mktmpdir("merge-assurance-hosted-ci") do |repo_root|
      base_marker = File.join(repo_root, "base-seam-called")
      attacker_marker = File.join(repo_root, "pr-head-seam-called")
      run_git!(repo_root, "init", "-q")
      run_git!(repo_root, "config", "user.name", "Test")
      run_git!(repo_root, "config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(repo_root, ".agents/bin"))
      File.write(
        File.join(repo_root, ".agents/agent-workflow.yml"),
        <<~YAML
          selected_hosted_ci_receipts:
            executable: ".agents/bin/selected-hosted-ci-receipts"
            credential_env:
              - CIRCLECI_TOKEN
        YAML
      )
      File.write(
        File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"),
        selected_hosted_ci_seam_script(
          marker: base_marker,
          terminal_result: "cancelled",
          required_credential: %w[CIRCLECI_TOKEN allowlisted-secret],
          absent_credential: "UNRELATED_TOKEN",
          account_home:
        )
      )
      FileUtils.chmod(0o755, File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"))
      run_git!(repo_root, "add", "--all")
      run_git!(repo_root, "commit", "-qm", "trusted base")
      base_sha = run_git!(repo_root, "rev-parse", "HEAD").strip

      File.write(
        File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"),
        selected_hosted_ci_seam_script(
          marker: attacker_marker, terminal_result: "success"
        )
      )
      run_git!(repo_root, "commit", "-qam", "untrusted PR-head replacement")

      now = Time.now.utc
      selected = {
        "provider" => "circleci",
        "run_id" => "c506a91e-5b3b-4bb6-b136-2bcfa06f69aa"
      }
      merge_context = context(
        "auto_merge_when_gates_pass", selected_hosted_runs: [selected]
      )
      merge_context["host"] = "github.example"
      merge_context["base"]["sha"] = base_sha
      ci_result = ready_ci
      ci_result["context"]["host"] = merge_context.fetch("host")
      ci_result["checked_at"] = (now - 1).iso8601
      ci_result.fetch("scopes").each_value do |scope|
        scope["checked_at"] = (now - 1).iso8601
      end
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["policy_provenance"] = "git:#{base_sha}"
      autonomous["helper_provenance"] = "trusted-base:#{base_sha}"
      paths = {
        ci: File.join(repo_root, "ci.json"),
        autonomous: File.join(repo_root, "autonomous.json"),
        context: File.join(repo_root, "context.json")
      }
      File.write(paths.fetch(:ci), JSON.generate(ci_result))
      File.write(paths.fetch(:autonomous), JSON.generate(autonomous))
      File.write(paths.fetch(:context), JSON.generate(merge_context))

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => @original_path,
          "CIRCLECI_TOKEN" => "allowlisted-secret",
          "UNRELATED_TOKEN" => "must-not-be-forwarded"
        },
        RbConfig.ruby, SCRIPT,
        "--ci-result", paths.fetch(:ci),
        "--autonomous-result", paths.fetch(:autonomous),
        "--context", paths.fetch(:context),
        chdir: repo_root
      )
      result = JSON.parse(stdout)

      refute status.success?, stderr
      assert_includes(
        result.fetch("failures"),
        "selected hosted run circleci/c506a91e-5b3b-4bb6-b136-2bcfa06f69aa is cancelled"
      )
      assert File.exist?(base_marker), "trusted-base receipt seam was not invoked"
      assert_equal(
        {
          "host" => "github.example",
          "credential_forwarded" => true,
          "unrelated_credential_present" => false,
          "home_exists" => true,
          "home_private" => true,
          "home_distinct_from_account" => true,
          "home_empty" => true
        },
        JSON.parse(File.read(base_marker))
      )
      refute File.exist?(attacker_marker), "PR-head receipt seam was invoked"
    end
  end

  def test_selected_hosted_ci_seam_private_home_hides_fake_account_provider_file
    runner = MergeAssurance::Runner.new
    Dir.mktmpdir("merge-assurance-fake-account") do |fake_account_home|
      credential_relative_path = File.join(".config", "provider", "credentials")
      account_credential = File.join(fake_account_home, credential_relative_path)
      FileUtils.mkdir_p(File.dirname(account_credential))
      File.write(account_credential, "fake-account-secret")
      Dir.mktmpdir("merge-assurance-private-materialization") do |directory|
        private_home = File.join(directory, "home")
        marker = File.join(directory, "home-evidence.json")
        seam = File.join(directory, "seam.rb")
        FileUtils.mkdir_p(private_home, mode: 0o700)
        File.chmod(0o700, private_home)
        File.write(
          seam,
          <<~RUBY
            require "json"
            home = ENV.fetch("HOME")
            File.write(
              #{marker.inspect},
              JSON.generate(
                "home" => File.realpath(home),
                "private" => (File.stat(home).mode & 0o777) == 0o700,
                "empty" => Dir.empty?(home),
                "provider_credential_visible" => File.exist?(
                  File.join(home, #{credential_relative_path.inspect})
                )
              )
            )
          RUBY
        )
        account_environment = runner.send(:system_tool_environment).merge("HOME" => fake_account_home)
        runner.define_singleton_method(:system_tool_environment) { account_environment }
        request = {
          "host" => "github.com",
          "repository" => "owner/repo",
          "pr" => 42,
          "head_sha" => HEAD_SHA
        }
        environment = runner.send(
          :selected_hosted_ci_environment, request, [], home: private_home
        )

        _stdout, stderr, status = runner.send(
          :run_selected_hosted_ci_process!,
          environment,
          [RbConfig.ruby, seam],
          request,
          chdir: directory
        )
        evidence = JSON.parse(File.read(marker))

        assert status.success?, stderr
        assert File.exist?(account_credential)
        assert_equal(
          {
            "home" => File.realpath(private_home),
            "private" => true,
            "empty" => true,
            "provider_credential_visible" => false
          },
          evidence
        )
      end
    end
  end

  def test_cli_blocks_local_evidence_before_selected_hosted_ci_seam_launch
    cases = {
      "malformed-ci" => [
        ->(ci_result, _autonomous_result, _merge_context) { ci_result.clear },
        "invalid pr-ci-readiness contract or version"
      ],
      "stale-ci" => [
        lambda do |ci_result, _autonomous_result, _merge_context|
          ci_result["checked_at"] = (
            Time.now.utc - MergeAssurance::MAX_EVIDENCE_AGE_SECONDS - 1
          ).iso8601
        end,
        "ci_result evidence is stale"
      ],
      "not-ready-ci" => [
        ->(ci_result, _autonomous_result, _merge_context) { ci_result["verdict"] = "NOT_READY" },
        "ci_result is not READY"
      ],
      "authority-none" => [
        ->(_ci_result, _autonomous_result, merge_context) { merge_context["authority"] = "none" },
        "merge authority none can never produce an eligible receipt"
      ]
    }
    launched = []

    cases.each do |name, (mutate, expected_failure)|
      with_selected_hosted_ci_cli_fixture do |fixture|
        mutate.call(
          fixture.fetch(:ci_result),
          fixture.fetch(:autonomous_result),
          fixture.fetch(:context)
        )
        stdout, stderr, status = run_selected_hosted_ci_cli_fixture(fixture)
        result = JSON.parse(stdout)

        assert_equal 1, status.exitstatus, "#{name}: #{stderr}"
        assert_includes result.fetch("failures"), expected_failure, name
        launched << name if File.exist?(fixture.fetch(:seam_marker))
      end
    end

    assert_empty launched, "selected hosted CI seam launched for: #{launched.join(', ')}"
  end

  def test_cli_blocks_non_string_host_before_selected_hosted_ci_seam_launch
    with_selected_hosted_ci_cli_fixture(host: 123) do |fixture|
      stdout, stderr, status = run_selected_hosted_ci_cli_fixture(fixture)

      assert_empty stderr, "unexpected CLI exception: #{stderr}"
      result = JSON.parse(stdout)
      assert_equal 1, status.exitstatus
      assert_equal ["context host is invalid"], result.fetch("failures")
      refute File.exist?(fixture.fetch(:seam_marker)), "selected hosted CI seam was launched"
    end
  end

  def test_cli_blocks_duplicate_selected_hosted_runs_before_seam_launch
    with_selected_hosted_ci_cli_fixture do |fixture|
      selections = fixture.fetch(:context).fetch("selected_hosted_runs")
      selections << selections.first.dup
      stdout, stderr, status = run_selected_hosted_ci_cli_fixture(fixture)
      result = JSON.parse(stdout)

      assert_empty stderr
      assert_equal 1, status.exitstatus
      assert_equal ["context selected_hosted_runs contain duplicates"], result.fetch("failures")
      refute File.exist?(fixture.fetch(:seam_marker)), "selected hosted CI seam was launched"
    end
  end

  def test_runner_resamples_time_after_seam_before_rechecking_ci_freshness
    preflight_now = Time.iso8601("2026-08-03T00:00:00Z")
    final_now = preflight_now + MergeAssurance::MAX_EVIDENCE_AGE_SECONDS + 1
    with_selected_hosted_ci_cli_fixture(selected_at: preflight_now.iso8601) do |fixture|
      set_fixture_ci_checked_at(fixture, preflight_now - 1)
      stdout, stderr, exit_code, clock_calls = run_selected_hosted_ci_runner_fixture(
        fixture, times: [preflight_now, final_now]
      )
      result = JSON.parse(stdout)

      assert_empty stderr
      assert_equal 1, exit_code, "post-seam assessment reused the preflight clock"
      assert_equal 2, clock_calls
      assert_includes result.fetch("failures"), "ci_result evidence is stale"
      assert File.exist?(fixture.fetch(:seam_marker)), "selected hosted CI seam was not launched"
    end
  end

  def test_runner_uses_post_seam_time_for_selected_at_and_issued_at
    preflight_now = Time.iso8601("2026-08-03T00:00:00Z")
    final_now = preflight_now + MergeAssurance::MAX_FUTURE_SKEW_SECONDS + 1
    with_selected_hosted_ci_cli_fixture(selected_at: final_now.iso8601) do |fixture|
      set_fixture_ci_checked_at(fixture, preflight_now - 1)
      stdout, stderr, exit_code, clock_calls = run_selected_hosted_ci_runner_fixture(
        fixture, times: [preflight_now, final_now]
      )
      result = JSON.parse(stdout)

      assert_empty stderr
      assert_equal 0, exit_code, "fresh post-seam selected_at was compared to the preflight clock"
      assert_equal 2, clock_calls
      assert_equal final_now.iso8601, result.fetch("issued_at")
      assert File.exist?(fixture.fetch(:seam_marker)), "selected hosted CI seam was not launched"
    end
  end

  def test_selected_hosted_ci_policy_credential_allowlist_is_exact_and_fail_closed
    runner = MergeAssurance::Runner.new
    executable = ".agents/bin/selected-hosted-ci-receipts"
    credential_names = %w[
      CIRCLECI_TOKEN BUILDKITE_API_KEY SERVICE_SECRET DATABASE_PASSWORD
      GOOGLE_APPLICATION_CREDENTIALS AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      DEPLOY_PRIVATE_KEY
    ]
    valid = {
      "selected_hosted_ci_receipts" => {
        "executable" => executable,
        "credential_env" => credential_names
      }
    }

    assert_equal(
      [executable, credential_names],
      runner.send(:selected_hosted_ci_policy!, valid)
    )

    invalid = {
      "missing allowlist" => { "executable" => executable },
      "non-array allowlist" => { "executable" => executable, "credential_env" => "CIRCLECI_TOKEN" },
      "empty name" => { "executable" => executable, "credential_env" => [""] },
      "duplicate name" => {
        "executable" => executable,
        "credential_env" => %w[CIRCLECI_TOKEN CIRCLECI_TOKEN]
      },
      "reserved binding" => { "executable" => executable, "credential_env" => ["GH_HOST"] },
      "extra key" => { "executable" => executable, "credential_env" => [], "shell" => "ruby" }
    }
    %w[
      BASH_ENV RUBYOPT RUBYLIB LD_PRELOAD DYLD_INSERT_LIBRARIES PYTHONPATH
      NODE_OPTIONS PERL5OPT ARBITRARY_NAME
    ].each do |name|
      invalid["non-credential #{name}"] = { "executable" => executable, "credential_env" => [name] }
    end

    invalid.each do |label, seam|
      error = assert_raises(MergeAssurance::Error) do
        runner.send(:selected_hosted_ci_policy!, "selected_hosted_ci_receipts" => seam)
      end
      refute_empty error.message
      assert_includes error.message, seam.fetch("credential_env").first if
        label.start_with?("non-credential")
    end
  end

  def test_cli_blocks_mixed_selected_hosted_ci_policy_keys_without_argument_error
    Dir.mktmpdir("merge-assurance-mixed-policy") do |repo_root|
      run_git!(repo_root, "init", "-q")
      run_git!(repo_root, "config", "user.name", "Test")
      run_git!(repo_root, "config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      File.write(
        File.join(repo_root, ".agents/agent-workflow.yml"),
        <<~YAML
          selected_hosted_ci_receipts:
            executable: ".agents/bin/selected-hosted-ci-receipts"
            credential_env: []
            1: mixed-key
        YAML
      )
      run_git!(repo_root, "add", ".agents/agent-workflow.yml")
      run_git!(repo_root, "commit", "-qm", "trusted mixed policy")
      base_sha = run_git!(repo_root, "rev-parse", "HEAD").strip
      merge_context = context(
        "auto_merge_when_gates_pass",
        selected_hosted_runs: [{ "provider" => "circleci", "run_id" => "selected-workflow" }]
      )
      merge_context["base"]["sha"] = base_sha
      now = Time.now.utc
      ci_result = ready_ci
      ci_result["checked_at"] = (now - 1).iso8601
      ci_result.fetch("scopes").each_value { |scope| scope["checked_at"] = (now - 1).iso8601 }
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["policy_provenance"] = "git:#{base_sha}"
      autonomous["helper_provenance"] = "trusted-base:#{base_sha}"
      paths = {
        ci: File.join(repo_root, "ci.json"),
        autonomous: File.join(repo_root, "autonomous.json"),
        context: File.join(repo_root, "context.json")
      }
      File.write(paths.fetch(:ci), JSON.generate(ci_result))
      File.write(paths.fetch(:autonomous), JSON.generate(autonomous))
      File.write(paths.fetch(:context), JSON.generate(merge_context))
      exit_code = nil
      arguments = [
        "--ci-result", paths.fetch(:ci),
        "--autonomous-result", paths.fetch(:autonomous),
        "--context", paths.fetch(:context)
      ]

      stdout, stderr = capture_io do
        Dir.chdir(repo_root) do
          exit_code = MergeAssurance::Runner.new.run(arguments)
        end
      end
      result = JSON.parse(stdout)

      assert_equal 1, exit_code
      assert_empty stderr
      assert_equal [
        "selected hosted runs require an exact trusted-base " \
        "selected_hosted_ci_receipts executable and credential_env seam"
      ], result.fetch("failures")
      assert_equal ["merge-assurance-result", "BLOCKED", false],
                   result.values_at("contract", "verdict", "eligible")
    end
  end

  def test_cli_rejects_bash_env_before_ambient_loader_code_or_trusted_seam_runs
    Dir.mktmpdir("merge-assurance-bash-env") do |repo_root|
      loader_marker = File.join(repo_root, "ambient-loader-called")
      seam_marker = File.join(repo_root, "trusted-seam-called")
      bash_env = File.join(repo_root, "ambient-loader.bash")
      run_git!(repo_root, "init", "-q")
      run_git!(repo_root, "config", "user.name", "Test")
      run_git!(repo_root, "config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(repo_root, ".agents/bin"))
      File.write(bash_env, "printf loader-ran > #{loader_marker}\n")
      File.write(
        File.join(repo_root, ".agents/agent-workflow.yml"),
        <<~YAML
          selected_hosted_ci_receipts:
            executable: ".agents/bin/selected-hosted-ci-receipts"
            credential_env:
              - BASH_ENV
        YAML
      )
      payload = MergeAssurance.empty_selected_hosted_ci_receipts
      payload["records"] = [{
        "provider" => "circleci",
        "repository" => "owner/repo",
        "pr" => 42,
        "head_sha" => HEAD_SHA,
        "run_id" => "selected-workflow",
        "selected_at" => (Time.now.utc - 1).iso8601,
        "terminal_result" => "success"
      }]
      File.write(
        File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"),
        <<~BASH
          #!/bin/bash
          printf seam-ran > #{seam_marker}
          printf '%s\n' #{JSON.generate(payload).inspect}
        BASH
      )
      FileUtils.chmod(0o755, File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"))
      run_git!(repo_root, "add", ".agents")
      run_git!(repo_root, "commit", "-qm", "trusted base")
      base_sha = run_git!(repo_root, "rev-parse", "HEAD").strip

      now = Time.now.utc
      merge_context = context(
        "auto_merge_when_gates_pass",
        selected_hosted_runs: [{ "provider" => "circleci", "run_id" => "selected-workflow" }]
      )
      merge_context["base"]["sha"] = base_sha
      ci_result = ready_ci
      ci_result["checked_at"] = (now - 1).iso8601
      ci_result.fetch("scopes").each_value { |scope| scope["checked_at"] = (now - 1).iso8601 }
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["policy_provenance"] = "git:#{base_sha}"
      autonomous["helper_provenance"] = "trusted-base:#{base_sha}"
      paths = {
        ci: File.join(repo_root, "ci.json"),
        autonomous: File.join(repo_root, "autonomous.json"),
        context: File.join(repo_root, "context.json")
      }
      File.write(paths.fetch(:ci), JSON.generate(ci_result))
      File.write(paths.fetch(:autonomous), JSON.generate(autonomous))
      File.write(paths.fetch(:context), JSON.generate(merge_context))

      stdout, stderr, status = Open3.capture3(
        { "PATH" => @original_path, "BASH_ENV" => bash_env },
        RbConfig.ruby, SCRIPT,
        "--ci-result", paths.fetch(:ci),
        "--autonomous-result", paths.fetch(:autonomous),
        "--context", paths.fetch(:context),
        chdir: repo_root
      )
      result = JSON.parse(stdout)

      refute File.exist?(loader_marker), "ambient BASH_ENV loader code ran"
      refute File.exist?(seam_marker), "trusted seam ran before policy rejection"
      refute status.success?, stderr
      assert(result.fetch("failures").any? { |failure| failure.include?("BASH_ENV") })
    end
  end

  def test_cli_times_out_selected_hosted_ci_seam_and_terminates_its_process_group
    Dir.mktmpdir("merge-assurance-hosted-timeout") do |repo_root|
      child_pid_path = File.join(repo_root, "hung-child.pid")
      run_git!(repo_root, "init", "-q")
      run_git!(repo_root, "config", "user.name", "Test")
      run_git!(repo_root, "config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(repo_root, ".agents/bin"))
      File.write(
        File.join(repo_root, ".agents/agent-workflow.yml"),
        <<~YAML
          selected_hosted_ci_receipts:
            executable: ".agents/bin/selected-hosted-ci-receipts"
            credential_env: []
        YAML
      )
      File.write(
        File.join(repo_root, ".agents/bin/hanging-child"),
        <<~BASH
          #!/bin/bash
          trap '' TERM
          printf '%s' "$$" > "$1"
          while :; do sleep 1; done
        BASH
      )
      File.write(
        File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"),
        <<~BASH
          #!/bin/bash
          trap '' TERM
          /bin/bash .agents/bin/hanging-child #{child_pid_path} &
          while [ ! -s #{child_pid_path} ]; do sleep 0.01; done
          while :; do sleep 1; done
        BASH
      )
      FileUtils.chmod(
        0o755,
        [
          File.join(repo_root, ".agents/bin/hanging-child"),
          File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts")
        ]
      )
      run_git!(repo_root, "add", ".agents")
      run_git!(repo_root, "commit", "-qm", "trusted base")
      base_sha = run_git!(repo_root, "rev-parse", "HEAD").strip

      now = Time.now.utc
      merge_context = context(
        "auto_merge_when_gates_pass",
        selected_hosted_runs: [{ "provider" => "circleci", "run_id" => "selected-workflow" }]
      )
      merge_context["base"]["sha"] = base_sha
      ci_result = ready_ci
      ci_result["checked_at"] = (now - 1).iso8601
      ci_result.fetch("scopes").each_value { |scope| scope["checked_at"] = (now - 1).iso8601 }
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["policy_provenance"] = "git:#{base_sha}"
      autonomous["helper_provenance"] = "trusted-base:#{base_sha}"
      paths = {
        ci: File.join(repo_root, "ci.json"),
        autonomous: File.join(repo_root, "autonomous.json"),
        context: File.join(repo_root, "context.json")
      }
      File.write(paths.fetch(:ci), JSON.generate(ci_result))
      File.write(paths.fetch(:autonomous), JSON.generate(autonomous))
      File.write(paths.fetch(:context), JSON.generate(merge_context))
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      stdout, stderr, status, harness_timed_out = capture_process_group_with_deadline(
        {
          "PATH" => @original_path,
          "MERGE_ASSURANCE_SELECTED_HOSTED_CI_TIMEOUT_SECONDS" => "0.2"
        },
        RbConfig.ruby, SCRIPT,
        "--ci-result", paths.fetch(:ci),
        "--autonomous-result", paths.fetch(:autonomous),
        "--context", paths.fetch(:context),
        chdir: repo_root,
        deadline_seconds: 1.5
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      refute harness_timed_out, "merge-assurance did not bound the hosted seam"
      result = JSON.parse(stdout)
      child_pid = Integer(File.read(child_pid_path))
      refute status.success?, stderr
      assert_operator elapsed, :<, 1.5
      assert_includes(
        result.fetch("failures"),
        "trusted-base selected hosted CI seam timed out after 0.2 seconds and its process group was terminated"
      )
      refute process_alive?(child_pid), "hung hosted seam child #{child_pid} leaked"
    ensure
      begin
        Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_selected_hosted_ci_seam_leader_exit_with_lingering_child_fails_closed
    runner = MergeAssurance::Runner.new
    Dir.mktmpdir("merge-assurance-hosted-lingering") do |directory|
      child_pid_path = File.join(directory, "lingering-child.pid")
      child = File.join(directory, "child")
      leader = File.join(directory, "leader")
      File.write(
        child,
        <<~BASH
          #!/bin/bash
          trap '' TERM
          printf '%s' "$$" > "$1"
          while :; do sleep 1; done
        BASH
      )
      File.write(
        leader,
        <<~BASH
          #!/bin/bash
          /bin/bash #{child} #{child_pid_path} &
          while [ ! -s #{child_pid_path} ]; do sleep 0.01; done
        BASH
      )
      FileUtils.chmod(0o755, [child, leader])

      error = assert_raises(MergeAssurance::Error) do
        runner.send(
          :run_selected_hosted_ci_process!,
          runner.send(:system_tool_environment),
          ["/bin/bash", leader],
          { "contract" => "test-request" },
          chdir: directory
        )
      end
      child_pid = Integer(File.read(child_pid_path))

      assert_equal(
        "trusted-base selected hosted CI seam left a running process group, which was terminated",
        error.message
      )
      refute process_alive?(child_pid), "lingering hosted seam child #{child_pid} leaked"
    ensure
      begin
        Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_selected_hosted_ci_declared_credentials_must_be_present_and_nonempty
    runner = MergeAssurance::Runner.new
    request = {
      "host" => "github.com",
      "repository" => "owner/repo",
      "pr" => 42,
      "head_sha" => HEAD_SHA
    }
    credential = "MERGE_ASSURANCE_SELECTED_TOKEN"
    original = ENV[credential]

    [nil, ""].each do |value|
      value.nil? ? ENV.delete(credential) : ENV[credential] = value
      error = assert_raises(MergeAssurance::Error) do
        runner.send(
          :selected_hosted_ci_environment,
          request,
          [credential],
          home: "/private/merge-assurance-test-home"
        )
      end
      assert_includes error.message, credential
    end
  ensure
    original.nil? ? ENV.delete(credential) : ENV[credential] = original
  end

  def test_generic_env_ruby_resolves_to_verified_rbconfig_ruby
    runner = MergeAssurance::Runner.new
    Dir.mktmpdir("merge-assurance-consumer") do |repo_root|
      Dir.mktmpdir("merge-assurance-versioned-ruby") do |runtime_root|
        versioned_ruby = File.join(runtime_root, "ruby3.4")
        File.write(versioned_ruby, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, versioned_ruby)
        original_ruby = RbConfig.method(:ruby)
        RbConfig.define_singleton_method(:ruby) { versioned_ruby }

        assert_equal(
          File.realpath(versioned_ruby),
          runner.send(:resolve_env_interpreter!, "ruby", repo_root)
        )
      ensure
        RbConfig.define_singleton_method(:ruby, original_ruby) if original_ruby
      end
    end
  end

  def test_selected_hosted_ci_hichee_incident_replays
    actual = HOSTED_CI_REPLAYS.fetch("cases").to_h do |replay|
      merge_context = context(
        "auto_merge_when_gates_pass",
        repo: HOSTED_CI_REPLAYS.fetch("repository"),
        pull_request: replay.fetch("pr"),
        head_sha: replay.fetch("head_sha"),
        selected_hosted_runs: replay.fetch("selected_runs").map do |run|
          run.slice("provider", "run_id")
        end
      )
      result = MergeAssurance.assess(
        ci_result: ready_ci(
          repo: merge_context.fetch("repo"),
          pull_request: merge_context.fetch("pr"),
          head_sha: merge_context.fetch("head_sha")
        ),
        autonomous_result: autonomous_result(
          "autonomous-merge-eligible", head_sha: merge_context.fetch("head_sha")
        ),
        context: merge_context,
        selected_hosted_ci_receipts: selected_hosted_ci_receipts(replay, merge_context),
        now: NOW
      )
      [replay.fetch("pr"), result.fetch("eligible")]
    end

    assert_equal(
      { 10_049 => false, 10_048 => false, 10_026 => false, 10_036 => true },
      actual
    )
  end

  def test_selected_hosted_ci_receipts_reject_missing_stale_head_and_mismatched_pr
    selection = { "provider" => "circleci", "run_id" => "selected-run" }
    merge_context = context(
      "auto_merge_when_gates_pass", selected_hosted_runs: [selection]
    )
    valid = MergeAssurance.empty_selected_hosted_ci_receipts
    valid["records"] = [{
      **selection,
      "repository" => merge_context.fetch("repo"),
      "pr" => merge_context.fetch("pr"),
      "head_sha" => merge_context.fetch("head_sha"),
      "selected_at" => "2026-07-30T11:55:00Z",
      "terminal_result" => "success"
    }]
    cases = {
      "missing" => MergeAssurance.empty_selected_hosted_ci_receipts,
      "stale-head" => Marshal.load(Marshal.dump(valid)).tap do |receipts|
        receipts.dig("records", 0)["head_sha"] = "d" * 40
      end,
      "mismatched-pr" => Marshal.load(Marshal.dump(valid)).tap do |receipts|
        receipts.dig("records", 0)["pr"] = 43
      end
    }

    failures = cases.transform_values do |receipts|
      MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: merge_context,
        selected_hosted_ci_receipts: receipts,
        now: NOW
      ).fetch("failures")
    end

    assert_includes failures.fetch("missing"), "selected hosted run circleci/selected-run is missing"
    assert_includes failures.fetch("stale-head"), "selected hosted run circleci/selected-run head mismatch"
    assert_includes failures.fetch("mismatched-pr"), "selected hosted run circleci/selected-run PR mismatch"
  end

  def test_direct_assess_preserves_duplicate_selected_run_failure_order
    selection = { "provider" => "circleci", "run_id" => "selected-run" }
    merge_context = context(
      "auto_merge_when_gates_pass", selected_hosted_runs: [selection, selection.dup]
    )
    receipts = MergeAssurance.empty_selected_hosted_ci_receipts
    receipts["records"] = [{
      **selection,
      "repository" => merge_context.fetch("repo"),
      "pr" => merge_context.fetch("pr"),
      "head_sha" => merge_context.fetch("head_sha"),
      "selected_at" => "2026-07-30T11:59:00Z",
      "terminal_result" => "failed"
    }]

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: merge_context,
      selected_hosted_ci_receipts: receipts,
      now: NOW
    )

    assert_equal [
      "context selected_hosted_runs contain duplicates",
      "selected hosted run circleci/selected-run is failed"
    ], result.fetch("failures")
  end

  def test_direct_assess_preserves_nil_selected_hosted_runs_as_empty
    merge_context = context("auto_merge_when_gates_pass")
    merge_context["selected_hosted_runs"] = nil

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: merge_context,
      now: NOW
    )

    assert_equal true, result.fetch("eligible")
  end

  def test_malformed_selected_hosted_ci_record_has_only_primary_and_missing_failures
    selection = { "provider" => "circleci", "run_id" => "selected-run" }
    merge_context = context(
      "auto_merge_when_gates_pass", selected_hosted_runs: [selection]
    )
    receipts = MergeAssurance.empty_selected_hosted_ci_receipts
    receipts["records"] = [{}]

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: merge_context,
      selected_hosted_ci_receipts: receipts,
      now: NOW
    )

    assert_equal [
      "selected hosted CI receipt is malformed",
      "selected hosted run circleci/selected-run is missing"
    ], result.fetch("failures")
  end

  def test_ci_evidence_host_must_match_merge_context
    ci_result = ready_ci
    ci_result["context"]["host"] = "github.example"
    result = MergeAssurance.assess(
      ci_result:,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
    assert_includes result.fetch("failures"), "ci_result host binding mismatch"
  end

  def test_ci_scope_declared_ready_or_not_applicable_must_match_recomputed_rows
    cases = {
      "failed" => [
        "READY",
        { "name" => "lint", "status" => "completed", "conclusion" => "failure" },
        "NOT_READY"
      ],
      "pending" => [
        "NOT_APPLICABLE",
        { "name" => "lint", "status" => "queued", "conclusion" => nil },
        "NOT_READY"
      ],
      "cancelled" => ["READY", { "name" => "lint", "bucket" => "cancel" }, "NOT_READY"],
      "unknown" => [
        "NOT_APPLICABLE",
        { "name" => "lint", "status" => "completed", "conclusion" => nil },
        "UNKNOWN"
      ],
      "malformed" => ["READY", nil, "UNKNOWN"]
    }

    cases.each do |label, (declared, row, recomputed)|
      ci_result = ready_ci
      scope = ci_result.fetch("scopes").fetch("github_actions")
      scope["state"] = declared
      scope["rows"] = [row]
      result = MergeAssurance.assess(
        ci_result:,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )

      refute result.fetch("eligible"), label
      refute result.key?("evidence_digest"), label
      assert_includes(
        result.fetch("failures"),
        "ci_result scope github_actions declared #{declared} but recomputed #{recomputed}",
        label
      )
    end
  end

  def test_ci_row_representations_must_be_recognized_and_agree
    invalid_rows = {
      "bucket-state-contradiction" => {
        "name" => "lint", "bucket" => "pass", "state" => "failure"
      },
      "bucket-status-contradiction" => {
        "name" => "lint", "bucket" => "pass", "status" => "in_progress"
      },
      "bucket-conclusion-contradiction" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "completed", "conclusion" => "failure"
      },
      "state-status-contradiction" => {
        "name" => "lint", "state" => "success", "status" => "in_progress"
      },
      "state-conclusion-contradiction" => {
        "name" => "lint", "state" => "success",
        "status" => "completed", "conclusion" => "failure"
      },
      "status-conclusion-contradiction" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "in_progress", "conclusion" => "success"
      },
      "unrecognized-bucket" => {
        "name" => "lint", "bucket" => "mystery", "state" => "success"
      },
      "unrecognized-state" => {
        "name" => "lint", "bucket" => "pass", "state" => "mystery"
      },
      "unrecognized-status" => {
        "name" => "lint", "bucket" => "pass", "status" => "mystery"
      },
      "unrecognized-conclusion" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "completed", "conclusion" => "mystery"
      }
    }

    eligible_invalid_rows = invalid_rows.filter_map do |label, row|
      ci_result = ready_ci
      ci_result.fetch("scopes").fetch("github_actions")["rows"] = [row]
      result = MergeAssurance.assess(
        ci_result:,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_rows
  end

  def test_ci_row_official_gh_bucket_state_pairs_are_compatible
    cases = {
      "pass/SUCCESS" => [%w[pass SUCCESS], "READY"],
      "skipping/SKIPPED" => [%w[skipping SKIPPED], "READY"],
      "skipping/NEUTRAL" => [%w[skipping NEUTRAL], "READY"],
      "fail/ERROR" => [%w[fail ERROR], "NOT_READY"],
      "fail/FAILURE" => [%w[fail FAILURE], "NOT_READY"],
      "fail/TIMED_OUT" => [%w[fail TIMED_OUT], "NOT_READY"],
      "fail/ACTION_REQUIRED" => [%w[fail ACTION_REQUIRED], "NOT_READY"],
      "cancel/CANCELLED" => [%w[cancel CANCELLED], "NOT_READY"],
      "pending/EXPECTED" => [%w[pending EXPECTED], "NOT_READY"],
      "pending/REQUESTED" => [%w[pending REQUESTED], "NOT_READY"],
      "pending/WAITING" => [%w[pending WAITING], "NOT_READY"],
      "pending/QUEUED" => [%w[pending QUEUED], "NOT_READY"],
      "pending/PENDING" => [%w[pending PENDING], "NOT_READY"],
      "pending/IN_PROGRESS" => [%w[pending IN_PROGRESS], "NOT_READY"],
      "pending/STALE" => [%w[pending STALE], "NOT_READY"]
    }

    actual_states = cases.to_h do |label, ((bucket, state), _expected)|
      [label, MergeAssurance.ci_evidence_row_state({ "bucket" => bucket, "state" => state })]
    end
    skipping_ci = ready_ci
    skipping_ci.fetch("scopes").fetch("github_actions")["rows"] = [
      { "name" => "lint", "bucket" => "skipping", "state" => "SKIPPED" }
    ]
    skipping_result = MergeAssurance.assess(
      ci_result: skipping_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal(
      {
        "states" => cases.transform_values(&:last),
        "skipping_eligible" => true
      },
      {
        "states" => actual_states,
        "skipping_eligible" => skipping_result.fetch("eligible")
      }
    )
  end

  def test_ci_row_agreeing_producer_shapes_preserve_pass_fail_and_pending_states
    cases = {
      { "bucket" => "pass", "state" => "success" } => "READY",
      { "bucket" => "fail", "state" => "failure" } => "NOT_READY",
      { "bucket" => "pending", "state" => "pending" } => "NOT_READY",
      { "status" => "completed", "conclusion" => "success" } => "READY",
      { "status" => "completed", "conclusion" => "failure" } => "NOT_READY",
      { "status" => "in_progress", "conclusion" => nil } => "NOT_READY"
    }

    states = cases.keys.map { |row| MergeAssurance.ci_evidence_row_state(row) }

    assert_equal cases.values, states
  end

  def test_literal_or_nested_unknown_in_consumed_evidence_blocks
    auto = autonomous_result("autonomous-merge-eligible")
    auto["helper_trust"]["manifest"]["note"] = "nested UNKNOWN evidence"

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: auto,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
    assert_equal "BLOCKED", result.fetch("verdict")
    assert_includes result.fetch("failures"), "autonomous_result contains UNKNOWN"
    refute result.key?("evidence_digest")
  end

  def test_autonomous_provenance_must_bind_to_the_exact_base
    mutations = {
      "policy-base" => ["policy_provenance", "git:#{'d' * 40}"],
      "policy-suffix" => ["policy_provenance", "git:#{BASE_SHA}:unverified-policy"],
      "helper-base" => ["helper_provenance", "trusted-base:#{'d' * 40}"],
      "helper-kind" => ["helper_provenance", "caller-asserted:#{BASE_SHA}"]
    }
    eligible_mutations = mutations.filter_map do |name, (field, value)|
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      name if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_provenance_accepts_only_documented_bound_forms
    accepted = [
      {
        "policy_provenance" =>
          "git:#{BASE_SHA}:.agents/agent-workflow.yml@#{'d' * 40}"
      },
      {
        "policy_provenance" =>
          "git:#{BASE_SHA}:.agents/agent-workflow.yml(absent; portable-defaults)"
      },
      {
        "helper_provenance" => "verified-installed-pack:#{'d' * 64}"
      }
    ]
    verdicts = accepted.map do |fields|
      autonomous = autonomous_result("autonomous-merge-eligible").merge(fields)
      MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      ).fetch("eligible")
    end

    assert_equal [true, true, true], verdicts
  end

  def test_autonomous_helper_trust_requires_the_exact_runtime_manifest
    canonical = autonomous_runtime_manifest
    invalid_manifests = {
      "empty" => {},
      "non-string-value" => canonical.merge("helper" => 123),
      "missing-role" => canonical.reject { |role, _path| role == "decision-library" },
      "extra-role" => canonical.merge("future-library" => "/trusted/future.rb"),
      "blank-path" => canonical.merge("policy-library" => " "),
      "legacy-digest-only" => { "digest" => "sha256:#{'d' * 64}" }
    }

    eligible_invalid_manifests = invalid_manifests.filter_map do |label, manifest|
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["helper_trust"]["manifest"] = manifest
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_manifests
  end

  def test_accepts_the_exact_runtime_manifest_emitted_by_autonomous_merge_eligibility
    autonomous, base_sha = eligibility_artifact
    merge_context = context("auto_merge_when_gates_pass")
    merge_context.fetch("base")["sha"] = base_sha

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: merge_context,
      now: NOW
    )

    assert_equal "autonomous-merge-eligible", autonomous.fetch("verdict")
    assert_equal(
      "skills/pr-batch/bin/autonomous-merge-closeout",
      autonomous.dig("helper_trust", "manifest", "closeout-helper")
    )
    assert result.fetch("eligible"), result.fetch("failures", []).join("; ")
  end

  def test_autonomous_result_requires_exactly_empty_evidence_failures
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["evidence_failures"] = ["live force-push evidence is incomplete"]
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    refute result.fetch("eligible")
    refute result.key?("evidence_digest")
    assert_includes result.fetch("failures"), "autonomous_result evidence failures must be empty"
  end

  def test_autonomous_verdict_must_match_gates_and_decision_evidence
    contradictions = [
      {
        "verdict" => "autonomous-merge-eligible",
        "triggered_gates" => ["changed-files-limit"],
        "human_decision_evidence" => { "status" => "none" }
      },
      {
        "verdict" => "human-approved-for-current-head",
        "triggered_gates" => [],
        "human_decision_evidence" => {
          "status" => "accepted",
          "comment_id" => "123",
          "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
          "approved_by" => "maintainer",
          "source" => "human-pr-comment"
        }
      },
      {
        "verdict" => "human-approved-for-current-head",
        "triggered_gates" => ["changed-files-limit"],
        "human_decision_evidence" => { "status" => "none" }
      }
    ]

    eligible_contradictions = contradictions.filter_map do |fields|
      autonomous = autonomous_result(fields.fetch("verdict")).merge(fields)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      fields if result.fetch("eligible")
    end

    assert_empty eligible_contradictions
  end

  def test_accepts_each_exact_autonomous_verdict_relation_without_recomputing_thresholds
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["metrics"] = {
      "changed_files" => 10_000,
      "changed_lines" => 1_000_000,
      "commits" => 1_000,
      "reviewed_heads" => 100
    }
    autonomous_result_receipt = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    helper_approved_receipt = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approved-for-current-head"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    external_approval_receipt = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )

    assert_equal [true, true, true], [
      autonomous_result_receipt.fetch("eligible"),
      helper_approved_receipt.fetch("eligible"),
      external_approval_receipt.fetch("eligible")
    ]
  end

  def test_autonomous_result_requires_the_exact_consumed_output_shape
    mutations = {
      "unknown-top-level-field" => ->(result) { result["future_field"] = true },
      "non-string-top-level-field" => ->(result) { result[:future_field] = true },
      "missing-metrics" => ->(result) { result.delete("metrics") },
      "unknown-metric" => ->(result) { result["metrics"]["threshold"] = 10 },
      "unknown-helper-trust-field" => ->(result) { result["helper_trust"]["source"] = "caller" },
      "malformed-path-matches" => ->(result) { result["path_matches"] = {} }
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_path_matches_require_an_exact_gate_or_generated_record_shape
    invalid_path_matches = {
      "non-object" => [nil],
      "unknown-field" => [{
        "path" => "skills/example.rb",
        "gate" => "changed-files-limit",
        "reason" => "policy",
        "extra" => true
      }],
      "missing-reason" => [{
        "path" => "skills/example.rb",
        "gate" => "changed-files-limit"
      }],
      "other-missing-detail" => [{
        "path" => "app/services/checkout/charge.rb",
        "gate" => "repo-path:checkout-boundary",
        "reason" => "other"
      }],
      "other-blank-detail" => [{
        "path" => "app/services/checkout/charge.rb",
        "gate" => "repo-path:checkout-boundary",
        "reason" => "other",
        "detail" => " "
      }],
      "detail-for-non-other" => [{
        "path" => "config/deploy.yml",
        "gate" => "repo-path:infrastructure",
        "reason" => "infrastructure",
        "detail" => "extra"
      }],
      "unknown-reason" => [{
        "path" => "config/deploy.yml",
        "gate" => "repo-path:infrastructure",
        "reason" => "future-reason"
      }],
      "unknown-classification" => [{
        "path" => "generated/example.rb",
        "classification" => "vendored"
      }],
      "blank-path" => [{
        "path" => " ",
        "classification" => "generated"
      }]
    }

    eligible_invalid_matches = invalid_path_matches.filter_map do |label, path_matches|
      autonomous = autonomous_result("human-approval-required")
      autonomous["path_matches"] = path_matches
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("explicit_approval", human_merge_decision: human_merge_decision),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_matches
  end

  def test_gate_bearing_path_match_requires_its_triggered_gate
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["path_matches"] = [{
      "gate" => "repo-path:security",
      "path" => "config/security.yml",
      "reason" => "security"
    }]
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("failures"),
                    "autonomous_result path match gates are absent from triggered gates"
  end

  def test_accepts_repo_path_other_detail_emitted_by_autonomous_merge_eligibility
    autonomous = autonomous_result("human-approved-for-current-head")
    autonomous["triggered_gates"] = ["repo-path:checkout-boundary"]
    autonomous["path_matches"] = [{
      "gate" => "repo-path:checkout-boundary",
      "path" => "app/services/checkout/charge.rb",
      "reason" => "other",
      "detail" => "payment orchestration boundary"
    }]

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert result.fetch("eligible"), result.fetch("failures", []).join("; ")
  end

  def test_generated_path_rows_and_conservative_gates_preserve_one_way_binding
    generated = autonomous_result("autonomous-merge-eligible")
    generated["path_matches"] = [{
      "classification" => "generated",
      "path" => "dist/generated.js"
    }]
    generated_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: generated,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    conservative_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approved-for-current-head"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert generated_result.fetch("eligible")
    assert conservative_result.fetch("eligible")
  end

  def test_autonomous_triggered_gates_must_be_canonical_unique_and_sorted
    invalid_gates = {
      "unknown" => ["future-gate"],
      "duplicate" => %w[changed-files-limit changed-files-limit],
      "unsorted" => %w[commit-count-limit changed-files-limit],
      "malformed-repo-path" => ["repo-path:bad_id"]
    }

    eligible_invalid_gates = invalid_gates.filter_map do |label, gates|
      autonomous = autonomous_result("human-approval-required")
      autonomous["triggered_gates"] = gates
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("explicit_approval", human_merge_decision: human_merge_decision),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_gates
  end

  def test_autonomous_shadow_fields_require_the_pinned_helper_shapes
    mutations = {
      "shadow-gates-not-array" => ->(result) { result["shadow_triggered_gates"] = "reviewed-heads-limit" },
      "shadow-gate-unknown" => ->(result) { result["shadow_triggered_gates"] = ["changed-files-limit"] },
      "shadow-gate-duplicate" => lambda do |result|
        result["shadow_triggered_gates"] = %w[reviewed-heads-limit reviewed-heads-limit]
      end,
      "shadow-evidence-unknown" => ->(result) { result["shadow_evidence_unknown"] = ["future-evidence"] },
      "shadow-evidence-duplicate" => lambda do |result|
        result["shadow_evidence_unknown"] = %w[submitted-review-head-missing submitted-review-head-missing]
      end,
      "shadow-evidence-reversed" => lambda do |result|
        result["shadow_evidence_unknown"] = %w[review-pagination-incomplete submitted-review-head-missing]
      end
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_safe_class_and_rollback_assessment_must_be_compatible_known_enums
    mutations = {
      "unknown-safe-class" => ->(result) { result["safe_class"] = "future-safe-class" },
      "unknown-rollback" => ->(result) { result["rollback_assessment"] = "UNKNOWN" },
      "unsafe-not-applicable" => lambda do |result|
        result["safe_class"] = "none"
        result["rollback_assessment"] = "not-applicable"
      end
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_decision_evidence_requires_an_exact_none_or_accepted_record
    accepted = {
      "status" => "accepted",
      "comment_id" => "123",
      "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
      "approved_by" => "maintainer",
      "source" => "human-pr-comment"
    }
    cases = {
      "none-extra-field" => [
        "autonomous-merge-eligible", [], { "status" => "none", "reason" => "caller supplied" }
      ],
      "accepted-extra-field" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("reason" => "extra")
      ],
      "accepted-missing-url" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.reject { |key, _value| key == "url" }
      ],
      "accepted-non-string-comment-id" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("comment_id" => 123)
      ],
      "accepted-blank-url" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("url" => " ")
      ],
      "accepted-blank-approver" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("approved_by" => "")
      ],
      "accepted-unknown-source" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("source" => "automation")
      ],
      "uncertain" => [
        "human-approved-for-current-head",
        ["changed-files-limit"],
        accepted.merge(
          "status" => "uncertain",
          "reason" => "matching human and merge-authority attestation is missing or uncertain"
        )
      ]
    }

    missing_shape_failures = cases.filter_map do |label, (verdict, gates, decision)|
      autonomous = autonomous_result(verdict)
      autonomous["triggered_gates"] = gates
      autonomous["human_decision_evidence"] = decision
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label unless Array(result["failures"]).include?(
        "autonomous_result human decision evidence shape is invalid"
      )
    end

    assert_empty missing_shape_failures
  end

  def test_accepted_autonomous_decision_evidence_must_bind_to_current_merge_target
    accepted = autonomous_result("human-approved-for-current-head").fetch("human_decision_evidence")
    cases = {
      "other-host" => [accepted.merge(
        "url" => "https://evil.example/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "other-repo" => [accepted.merge(
        "url" => "https://github.com/other/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "other-pr" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/43#issuecomment-123"
      ), "github.com"],
      "other-comment" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42#issuecomment-124"
      ), "github.com"],
      "zero-comment-id" => [accepted.merge("comment_id" => "0"), "github.com"],
      "leading-zero-comment-id" => [accepted.merge("comment_id" => "0123"), "github.com"],
      "non-decimal-comment-id" => [accepted.merge("comment_id" => "+123"), "github.com"],
      "malformed-url" => [accepted.merge("url" => "https://[invalid"), "github.com"],
      "http-url" => [accepted.merge(
        "url" => "http://github.com/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "userinfo" => [accepted.merge(
        "url" => "https://user@github.com/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "query" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42?view=1#issuecomment-123"
      ), "github.com"],
      "extra-path" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42/files#issuecomment-123"
      ), "github.com"],
      "leading-zero-pr" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/042#issuecomment-123"
      ), "github.com"],
      "unsupported-form" => [accepted.merge(
        "url" => "https://github.com/owner/repo/commit/42#issuecomment-123"
      ), "github.com"],
      "missing-fragment" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42"
      ), "github.com"],
      "default-port-mismatch" => [accepted.merge(
        "url" => "https://github.com:8443/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "custom-port-mismatch" => [accepted.merge(
        "url" => "https://github.example/owner/repo/pull/42#issuecomment-123"
      ), "github.example:8443"]
    }

    missing_binding_failures = cases.filter_map do |label, (decision, host)|
      merge_context = context("auto_merge_when_gates_pass")
      merge_context["host"] = host
      ci_result = ready_ci
      ci_result.fetch("context")["host"] = host
      autonomous = autonomous_result("human-approved-for-current-head")
      autonomous["human_decision_evidence"] = decision
      result = MergeAssurance.assess(
        ci_result:,
        autonomous_result: autonomous,
        context: merge_context,
        now: NOW
      )
      label unless Array(result["failures"]).include?(
        "autonomous_result human decision evidence shape is invalid"
      )
    end

    assert_empty missing_binding_failures
  end

  def test_accepted_autonomous_decision_evidence_allows_bound_comment_permalink_forms
    cases = {
      "github-pull" => [
        "github.com",
        "owner/repo",
        "https://github.com/owner/repo/pull/42#issuecomment-123"
      ],
      "github-issues" => [
        "github.com",
        "owner/repo",
        "https://github.com/owner/repo/issues/42#issuecomment-123"
      ],
      "explicit-default-port" => [
        "github.com",
        "owner/repo",
        "https://github.com:443/owner/repo/pull/42#issuecomment-123"
      ],
      "ghes-custom-port" => [
        "github.example:8443",
        "owner/repo",
        "https://github.example:8443/owner/repo/issues/42#issuecomment-123"
      ],
      "case-insensitive-host-and-repo" => [
        "GitHub.Example:8443",
        "Owner/Repo",
        "https://github.example:8443/oWnEr/rEpO/pull/42#issuecomment-123"
      ]
    }

    blocked_cases = cases.filter_map do |label, (host, repo, url)|
      merge_context = context("auto_merge_when_gates_pass")
      merge_context["host"] = host
      merge_context["repo"] = repo
      ci_result = ready_ci
      ci_result.fetch("context")["host"] = host
      ci_result["repo"] = repo
      autonomous = autonomous_result("human-approved-for-current-head")
      autonomous.fetch("human_decision_evidence")["url"] = url
      result = MergeAssurance.assess(
        ci_result:,
        autonomous_result: autonomous,
        context: merge_context,
        now: NOW
      )
      [label, result.fetch("failures")] unless result.fetch("eligible")
    end

    assert_empty blocked_cases
  end

  def test_ask_requires_exact_head_human_decision_and_same_diff_walkthrough
    missing = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("ask"),
      now: NOW
    )
    eligible = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context(
        "ask",
        human_merge_decision: human_merge_decision,
        walkthrough: walkthrough("completed", "pr-walkthrough")
      ),
      now: NOW
    )

    assert_equal false, missing.fetch("eligible")
    assert_includes missing.fetch("failures"), "ask authority requires a proven exact-current-head human merge decision"
    assert_includes missing.fetch("failures"), "ask authority requires a same-diff walkthrough or explicit user skip"
    assert_equal true, eligible.fetch("eligible")
  end

  def test_human_decision_and_walkthrough_require_exact_target_bindings
    binding_keys = %w[host repo pr base_ref]
    unbound_decision = human_merge_decision.reject { |key, _value| binding_keys.include?(key) }
    unbound_walkthrough = walkthrough("completed", "pr-walkthrough").reject do |key, _value|
      binding_keys.include?(key)
    end
    decision_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: unbound_decision),
      now: NOW
    )
    walkthrough_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context(
        "ask",
        human_merge_decision: human_merge_decision,
        walkthrough: unbound_walkthrough
      ),
      now: NOW
    )

    assert_equal [false, false], [
      decision_result.fetch("eligible"),
      walkthrough_result.fetch("eligible")
    ]
  end

  def test_human_receipt_target_bindings_fail_closed_on_every_invalid_shape
    mutations = {
      "missing-host" => ->(receipt) { receipt.delete("host") },
      "unknown-repo" => ->(receipt) { receipt["repo"] = "UNKNOWN" },
      "malformed-pr" => ->(receipt) { receipt["pr"] = "42" },
      "duplicate-host" => ->(receipt) { receipt["host_copy"] = receipt["host"] },
      "conflicting-host" => ->(receipt) { receipt["host"] = "github.example" },
      "conflicting-repo" => ->(receipt) { receipt["repo"] = "other/repo" },
      "conflicting-pr" => ->(receipt) { receipt["pr"] = 43 },
      "conflicting-base-ref" => ->(receipt) { receipt["base_ref"] = "release" }
    }
    eligible_mutations = mutations.keys.flat_map do |name|
      decision = human_merge_decision
      mutations.fetch(name).call(decision)
      walkthrough_receipt = walkthrough("completed", "pr-walkthrough")
      mutations.fetch(name).call(walkthrough_receipt)
      decision_result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("human-approval-required"),
        context: context("explicit_approval", human_merge_decision: decision),
        now: NOW
      )
      walkthrough_result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("human-approval-required"),
        context: context(
          "ask",
          human_merge_decision: human_merge_decision,
          walkthrough: walkthrough_receipt
        ),
        now: NOW
      )
      [
        decision_result.fetch("eligible") ? "#{name}-decision" : nil,
        walkthrough_result.fetch("eligible") ? "#{name}-walkthrough" : nil
      ].compact
    end

    assert_empty eligible_mutations
  end

  def test_ordinary_follow_up_requires_human_approval_and_second_bundle_requires_additional_approval
    unapproved = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [ordinary_follow_up("bundle-1", approval_scope: nil)]
      ),
      now: NOW
    )
    missing_additional = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [
          ordinary_follow_up("bundle-1", approval_scope: "first-bundle"),
          ordinary_follow_up("bundle-2", approval_scope: "first-bundle")
        ]
      ),
      now: NOW
    )
    approved = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [
          ordinary_follow_up("bundle-1", approval_scope: "first-bundle"),
          ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
        ]
      ),
      now: NOW
    )

    assert_includes unapproved.fetch("failures"), "ordinary follow-up bundle bundle-1 lacks explicit human approval"
    assert_includes missing_additional.fetch("failures"), "ordinary follow-up bundle bundle-2 lacks additional explicit approval"
    assert_equal true, approved.fetch("eligible")
    assert_equal(
      %w[bundle-1 bundle-2],
      approved.dig("follow_up_accounting", "ordinary_follow_up_bundles").map { |bundle| bundle.fetch("bundle_id") }
    )
  end

  def test_follow_up_approval_rejects_items_changed_after_approval
    bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    bundle["items"] << "scope added after approval"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass", operations: [bundle]),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_follow_up_approval_rejects_cross_bundle_and_context_reuse
    mutations = {
      "bundle_id" => "bundle-other",
      "host" => "github.example",
      "repo" => "other/repo",
      "pr" => 43,
      "head_sha" => "d" * 40,
      "diff_identity" => "e" * 64
    }
    eligible_reuses = mutations.filter_map do |field, value|
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass", operations: [bundle]),
        now: NOW
      )
      field if result.fetch("eligible")
    end

    assert_empty eligible_reuses
  end

  def test_follow_up_approval_identity_is_unique_across_bundles
    first = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    additional = ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
    additional.fetch("approval")["approval_id"] = first.dig("approval", "approval_id")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [first, additional]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_one_additional_approval_cannot_authorize_multiple_bundles
    first = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    second = ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
    third = ordinary_follow_up("bundle-3", approval_scope: "additional-bundle")
    third["approval"] = second["approval"]
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [first, second, third]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_follow_up_approval_preserves_human_provenance_and_timestamp_validation
    mutations = {
      "provenance" => "automation",
      "approved_at" => "not-a-timestamp"
    }
    eligible_mutations = mutations.filter_map do |field, value|
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass", operations: [bundle]),
        now: NOW
      )
      field if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_human_decision_and_follow_up_approval_reject_excessive_future_skew
    verdicts = [30, 30.001].map do |future_seconds|
      timestamp = (NOW + future_seconds).iso8601(3)
      decision = human_merge_decision.merge("decided_at" => timestamp)
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")["approved_at"] = timestamp
      [
        MergeAssurance.assess(
          ci_result: ready_ci,
          autonomous_result: autonomous_result("human-approval-required"),
          context: context("explicit_approval", human_merge_decision: decision),
          now: NOW
        ).fetch("eligible"),
        MergeAssurance.assess(
          ci_result: ready_ci,
          autonomous_result: autonomous_result("autonomous-merge-eligible"),
          context: context("auto_merge_when_gates_pass", operations: [bundle]),
          now: NOW
        ).fetch("eligible")
      ]
    end

    assert_equal [[true, true], [false, false]], verdicts
  end

  def test_follow_up_approval_bindings_are_covered_by_receipt_evidence_digest
    bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass", operations: [bundle]),
      now: NOW
    )

    assert_equal true, result.fetch("eligible")
    assert_equal(
      bundle.fetch("approval"),
      result.dig("evidence", "context", "operations", 0, "approval")
    )
    tampered = JSON.parse(JSON.generate(result))
    tampered.dig("evidence", "context", "operations", 0, "approval")["approval_id"] = "other"
    refute MergeAssurance.valid_evidence_digest?(tampered)
  end

  def test_semantic_github_actions_change_requires_exactly_one_complete_mandatory_tracker
    missing = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true
      ),
      now: NOW
    )
    duplicate = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker, semantic_tracker.merge("tracker" => "https://github.com/owner/repo/issues/2")]
      ),
      now: NOW
    )
    eligible = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_includes missing.fetch("failures"), "semantic GitHub Actions change requires exactly one exercise tracker"
    assert_includes duplicate.fetch("failures"), "semantic GitHub Actions change requires exactly one exercise tracker"
    assert_equal true, eligible.fetch("eligible")
    assert_equal(
      semantic_tracker,
      eligible.dig("follow_up_accounting", "semantic_github_actions_tracker")
    )
    assert_equal(
      %w[api --hostname github.com repos/owner/repo/issues/1],
      fake_gh_argv
    )
    assert_equal(
      "gh-api",
      eligible.dig("evidence", "authenticated_tracker_reads", 0, "provenance")
    )
  end

  def test_authenticated_issue_read_fails_closed_on_auth_failure
    ENV["FAKE_GH_EXIT_STATUS"] = "1"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 1], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_caller_authored_tracker_verification_is_rejected
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [
          semantic_tracker.merge("read_verification" => tracker_read_verification)
        ]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_rejects_reviewer_reproduction_with_unbound_urls
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [
          semantic_tracker.merge(
            "tracker" => "https://example.invalid/issues/1",
            "source_pr" => "https://evil.invalid/pull/999"
          )
        ]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_semantic_tracker_uses_authenticated_read_without_caller_authored_provenance
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [true, 1], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_authenticated_read_fails_closed_on_unavailable_or_malformed_evidence
    cases = {
      "unavailable" => ["1", "{}"],
      "invalid-json" => ["0", "{"],
      "non-object" => ["0", "[]"],
      "malformed-object" => ["0", "{}"]
    }
    eligible_cases = cases.filter_map do |name, (exit_status, response)|
      reset_fake_gh_calls
      ENV["FAKE_GH_EXIT_STATUS"] = exit_status
      ENV["FAKE_GH_RESPONSE"] = response
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      name if result.fetch("eligible") || fake_gh_call_count != 1
    end

    assert_empty eligible_cases
  end

  def test_semantic_tracker_authenticated_read_rejects_every_exact_binding_mismatch
    mutations = {
      "tracker-host" => ->(issue) { issue["html_url"] = "https://github.example/owner/repo/issues/1" },
      "tracker-repo" => ->(issue) { issue["html_url"] = "https://github.com/other/repo/issues/1" },
      "tracker-issue" => ->(issue) { issue["number"] = 2 },
      "api-repo" => ->(issue) { issue["url"] = "https://api.github.com/repos/other/repo/issues/1" },
      "pull-request" => ->(issue) { issue["pull_request"] = {} },
      "source-pr" => lambda do |issue|
        issue["body"] = issue["body"].sub("/pull/42", "/pull/43")
      end,
      "head-sha" => lambda do |issue|
        issue["body"] = issue["body"].sub(HEAD_SHA, "d" * 40)
      end,
      "diff-identity" => lambda do |issue|
        issue["body"] = issue["body"].sub(DIFF_IDENTITY, "e" * 64)
      end,
      "operation-digest" => lambda do |issue|
        issue["body"] = issue["body"].sub(
          MergeAssurance.semantic_tracker_operation_digest(semantic_tracker),
          "sha256:#{'f' * 64}"
        )
      end
    }
    eligible_mutations = mutations.filter_map do |name, mutate|
      reset_fake_gh_calls
      issue = fake_issue
      mutate.call(issue)
      ENV["FAKE_GH_RESPONSE"] = JSON.generate(issue)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      name if result.fetch("eligible") || fake_gh_call_count != 1
    end

    assert_empty eligible_mutations
  end

  def test_semantic_tracker_rejects_duplicate_same_value_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |_key, expected_line|
      expected_line
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_rejects_expected_plus_conflicting_value_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |key, _expected_line|
      "#{key}: conflicting-value"
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_rejects_malformed_prefixed_variants_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |key, _expected_line|
      "#{key}-conflict: conflicting-value"
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_fails_closed_when_gh_is_unavailable
    File.rename(@fake_gh, "#{@fake_gh}.unavailable")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_read_timeout_terminates_the_entire_process_group
    child_pid_path = File.join(@fake_gh_dir, "hung-child.pid")
    system(@fake_gh, "--version", out: File::NULL, err: File::NULL)
    reset_fake_gh_calls
    ENV["FAKE_GH_HANG"] = "1"
    ENV["FAKE_GH_CHILD_PID"] = child_pid_path
    ENV["MERGE_ASSURANCE_GH_TIMEOUT_SECONDS"] = "0.5"
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    child_pid = Integer(File.read(child_pid_path))

    assert_equal false, result.fetch("eligible")
    assert_operator elapsed, :<, 1.5
    refute process_alive?(child_pid), "hung gh child #{child_pid} leaked"
  ensure
    begin
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    rescue Errno::ESRCH
      nil
    end
  end

  def test_authenticated_tracker_evidence_is_covered_by_receipt_digest
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )
    tampered = JSON.parse(JSON.generate(result))
    tampered.dig("evidence", "authenticated_tracker_reads", 0)["issue"] = 2

    assert_equal true, result.fetch("eligible")
    refute MergeAssurance.valid_evidence_digest?(tampered)
  end

  def test_merge_authority_none_does_not_read_semantic_tracker
    ENV["FAKE_GH_EXIT_STATUS"] = "1"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "none",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_post_merge_audit_defaults_to_accounted_and_report_only_is_a_typed_operation
    default_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    report_only_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [{
          "type" => "post-merge-audit-report-only",
          "disposition" => "report-only",
          "reason" => "The user explicitly requested a report without issue creation.",
          "provenance" => "direct-user"
        }]
      ),
      now: NOW
    )

    assert_equal "accounted", default_result.dig("follow_up_accounting", "post_merge_audit", "disposition")
    assert_equal(
      {
        "disposition" => "report-only",
        "reason" => "The user explicitly requested a report without issue creation.",
        "provenance" => "direct-user"
      },
      report_only_result.dig("follow_up_accounting", "post_merge_audit")
    )
  end

  def test_explicit_approval_requires_only_current_head_human_decision_and_none_never_qualifies
    explicit = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    none = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("none"),
      now: NOW
    )

    assert_equal true, explicit.fetch("eligible")
    assert_nil explicit.dig("evidence", "context", "walkthrough")
    assert_equal false, none.fetch("eligible")
    assert_includes none.fetch("failures"), "merge authority none can never produce an eligible receipt"
  end

  def test_human_authority_modes_require_a_known_current_autonomous_helper_result_without_applying_auto_policy
    malformed = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("unexpected-verdict"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    known_human_gate = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )

    assert_equal false, malformed.fetch("eligible")
    assert_includes malformed.fetch("failures"), "autonomous_result verdict is unrecognized"
    assert_equal true, known_human_gate.fetch("eligible")
  end

  private

  def eligibility_artifact
    repo_root, base_sha = initialize_eligibility_runtime_repo
    objective = {
      "head_sha" => HEAD_SHA,
      "base_sha" => base_sha,
      "files" => [{ "path" => "lib/example.rb", "additions" => 1, "deletions" => 0 }],
      "commits" => [{ "sha" => "c" * 40 }],
      "reviews" => [],
      "decision_comments" => []
    }
    objective_path = File.join(@fake_gh_dir, "autonomous-objective.json")
    semantic_path = File.join(@fake_gh_dir, "autonomous-semantic.json")
    gh_path = File.join(@fake_gh_dir, "autonomous-gh")
    File.write(objective_path, JSON.generate(objective))
    File.write(semantic_path, JSON.generate(autonomous_semantic_assessment))
    write_autonomous_fake_gh(gh_path)

    stdout, stderr, status = Open3.capture3(
      {
        "AUTONOMOUS_MERGE_GH" => gh_path,
        "AUTONOMOUS_MERGE_TEST_OBJECTIVE" => objective_path,
        "PATH" => @original_path
      },
      "ruby",
      File.join(repo_root, "skills/pr-batch/bin/autonomous-merge-eligibility"),
      "--repo-root", repo_root,
      "--trusted-base", base_sha,
      "--trusted-helper-provenance", "trusted-base:#{base_sha}",
      "--repo", "owner/repo",
      "--pr", "42",
      "--semantic-assessment", semantic_path
    )
    assert status.success?, stderr

    [JSON.parse(stdout), base_sha]
  end

  def initialize_eligibility_runtime_repo
    source_root = File.expand_path("../../..", __dir__)
    repo_root = File.join(@fake_gh_dir, "trusted-runtime")
    FileUtils.mkdir_p(repo_root)
    system({ "PATH" => @original_path }, "git", "init", "--quiet", repo_root, exception: true)
    system(
      { "PATH" => @original_path },
      "git", "-C", repo_root, "config", "user.email", "test@example.com",
      exception: true
    )
    system(
      { "PATH" => @original_path },
      "git", "-C", repo_root, "config", "user.name", "Test",
      exception: true
    )
    AutonomousMergeRuntimeTrust::RUNTIME_SOURCES.each_value do |source|
      destination = File.join(repo_root, source.fetch(:tree_paths).first)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source.fetch(:path), destination)
    end
    calibration_path = AutonomousMergeRuntimeTrust::CALIBRATION_TREE_PATHS.first
    FileUtils.mkdir_p(File.dirname(File.join(repo_root, calibration_path)))
    FileUtils.cp(File.join(source_root, calibration_path), File.join(repo_root, calibration_path))
    system({ "PATH" => @original_path }, "git", "-C", repo_root, "add", ".", exception: true)
    system(
      {
        "PATH" => @original_path,
        "GIT_AUTHOR_DATE" => "2000-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE" => "2000-01-01T00:00:00Z"
      },
      "git", "-C", repo_root, "commit", "--quiet", "-m", "trusted runtime",
      exception: true
    )
    base_sha, status = Open3.capture2(
      { "PATH" => @original_path },
      "git", "-C", repo_root, "rev-parse", "HEAD"
    )
    assert status.success?
    [repo_root, base_sha.strip]
  end

  def autonomous_semantic_assessment
    {
      "provenance" => "trusted-coordinator",
      "persistent_data_storage" => false,
      "infrastructure_delivery" => false,
      "irreversible_external_effect" => false,
      "public_compatibility" => false,
      "security_auth_privacy" => false,
      "architectural_product_judgment" => false,
      "unresolved_maintainer_concern" => false,
      "rollback_assessment" => "code-only-rollback-established",
      "safe_class" => "none",
      "safe_classification_complete" => true,
      "test_change" => "not-applicable",
      "decision_provenance" => []
    }
  end

  def write_autonomous_fake_gh(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      objective = JSON.parse(File.read(ENV.fetch("AUTONOMOUS_MERGE_TEST_OBJECTIVE")))
      request = ARGV.fetch(-1)
      response = case request
                 when "repos/owner/repo/pulls/42"
                   {
                     "head" => { "sha" => objective.fetch("head_sha") },
                     "base" => { "sha" => objective.fetch("base_sha") },
                     "updated_at" => "2026-07-30T11:59:00Z",
                     "changed_files" => objective.fetch("files").length,
                     "commits" => objective.fetch("commits").length
                   }
                 when "repos/owner/repo/issues/42/timeline?per_page=100&page=1"
                   []
                 when "repos/owner/repo/pulls/42/files?per_page=100&page=1"
                   objective.fetch("files").map do |file|
                     {
                       "filename" => file.fetch("path"),
                       "status" => "modified",
                       "additions" => file.fetch("additions"),
                       "deletions" => file.fetch("deletions")
                     }
                   end
                 when "repos/owner/repo/pulls/42/commits?per_page=100&page=1"
                   objective.fetch("commits")
                 when "repos/owner/repo/pulls/42/reviews?per_page=100&page=1"
                   objective.fetch("reviews")
                 when "repos/owner/repo/issues/42/comments?per_page=100&page=1"
                   objective.fetch("decision_comments")
                 else
                   warn "unexpected GitHub API path: #{request}"
                   exit 1
                 end
      puts JSON.generate(response)
    RUBY
    File.chmod(0o755, path)
  end

  def with_selected_hosted_ci_cli_fixture(
    host: "github.com", selected_at: (Time.now.utc - 1).iso8601
  )
    Dir.mktmpdir("merge-assurance-local-preflight") do |repo_root|
      seam_marker = File.join(repo_root, "selected-hosted-ci-seam-called")
      run_git!(repo_root, "init", "-q")
      run_git!(repo_root, "config", "user.name", "Test")
      run_git!(repo_root, "config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(repo_root, ".agents/bin"))
      File.write(
        File.join(repo_root, ".agents/agent-workflow.yml"),
        <<~YAML
          selected_hosted_ci_receipts:
            executable: ".agents/bin/selected-hosted-ci-receipts"
            credential_env:
              - HOSTED_CI_TOKEN
        YAML
      )
      File.write(
        File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"),
        selected_hosted_ci_seam_script(
          marker: seam_marker,
          terminal_result: "success",
          selected_at:,
          required_credential: %w[HOSTED_CI_TOKEN preflight-secret]
        )
      )
      FileUtils.chmod(0o755, File.join(repo_root, ".agents/bin/selected-hosted-ci-receipts"))
      run_git!(repo_root, "add", "--all")
      run_git!(repo_root, "commit", "-qm", "trusted selected hosted CI seam")
      base_sha = run_git!(repo_root, "rev-parse", "HEAD").strip
      selected = {
        "provider" => "circleci",
        "run_id" => "c506a91e-5b3b-4bb6-b136-2bcfa06f69aa"
      }
      merge_context = context(
        "auto_merge_when_gates_pass", selected_hosted_runs: [selected]
      )
      merge_context["host"] = host
      merge_context["base"]["sha"] = base_sha
      ci_result = ready_ci
      ci_result["context"]["host"] = host
      now = Time.now.utc
      ci_result["checked_at"] = (now - 1).iso8601
      ci_result.fetch("scopes").each_value do |scope|
        scope["checked_at"] = (now - 1).iso8601
      end
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["policy_provenance"] = "git:#{base_sha}"
      autonomous["helper_provenance"] = "trusted-base:#{base_sha}"
      fixture = {
        repo_root:,
        seam_marker:,
        ci_result:,
        autonomous_result: autonomous,
        context: merge_context
      }

      yield fixture
    end
  end

  def run_selected_hosted_ci_cli_fixture(fixture)
    arguments = write_selected_hosted_ci_cli_fixture(fixture)
    Open3.capture3(
      { "PATH" => @original_path, "HOSTED_CI_TOKEN" => "preflight-secret" },
      RbConfig.ruby, SCRIPT, *arguments,
      chdir: fixture.fetch(:repo_root)
    )
  end

  def run_selected_hosted_ci_runner_fixture(fixture, times:)
    arguments = write_selected_hosted_ci_cli_fixture(fixture)
    clock_calls = 0
    original_time_now = Time.method(:now)
    clock = lambda do
      caller_location = caller_locations(1, 1).first
      if caller_location&.absolute_path == SCRIPT && caller_location.base_label == "run"
        value = times.fetch(clock_calls)
        clock_calls += 1
        value
      else
        original_time_now.call
      end
    end
    exit_code = nil
    previous_credential = ENV["HOSTED_CI_TOKEN"]
    ENV["HOSTED_CI_TOKEN"] = "preflight-secret"
    Time.define_singleton_method(:now, &clock)
    stdout, stderr = capture_io do
      Dir.chdir(fixture.fetch(:repo_root)) do
        exit_code = MergeAssurance::Runner.new.run(arguments)
      end
    end
    [stdout, stderr, exit_code, clock_calls]
  ensure
    Time.define_singleton_method(:now, original_time_now) if original_time_now
    if previous_credential
      ENV["HOSTED_CI_TOKEN"] = previous_credential
    else
      ENV.delete("HOSTED_CI_TOKEN")
    end
  end

  def set_fixture_ci_checked_at(fixture, checked_at)
    ci_result = fixture.fetch(:ci_result)
    ci_result["checked_at"] = checked_at.iso8601
    ci_result.fetch("scopes").each_value do |scope|
      scope["checked_at"] = checked_at.iso8601
    end
  end

  def write_selected_hosted_ci_cli_fixture(fixture)
    repo_root = fixture.fetch(:repo_root)
    paths = {
      ci: File.join(repo_root, "ci.json"),
      autonomous: File.join(repo_root, "autonomous.json"),
      context: File.join(repo_root, "context.json")
    }
    File.write(paths.fetch(:ci), JSON.generate(fixture.fetch(:ci_result)))
    File.write(paths.fetch(:autonomous), JSON.generate(fixture.fetch(:autonomous_result)))
    File.write(paths.fetch(:context), JSON.generate(fixture.fetch(:context)))
    [
      "--ci-result", paths.fetch(:ci),
      "--autonomous-result", paths.fetch(:autonomous),
      "--context", paths.fetch(:context)
    ]
  end

  def capture_process_group_with_deadline(environment, *command, chdir:, deadline_seconds:)
    stdout_file = Tempfile.new("merge-assurance-test-stdout")
    stderr_file = Tempfile.new("merge-assurance-test-stderr")
    pid = Process.spawn(
      environment, *command,
      out: stdout_file.path, err: stderr_file.path, pgroup: true, chdir:
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
    status = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        status = waited[1]
        break
      end
      sleep 0.01
    end
    harness_timed_out = status.nil?
    unless status
      Process.kill("KILL", -pid)
      _waited_pid, status = Process.waitpid2(pid)
    end
    stdout_file.rewind
    stderr_file.rewind
    [stdout_file.read, stderr_file.read, status, harness_timed_out]
  ensure
    begin
      Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end
    stdout_file&.close!
    stderr_file&.close!
  end

  def run_git!(root, *args)
    stdout, stderr, status = Open3.capture3(
      {
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "commit.gpgSign",
        "GIT_CONFIG_VALUE_0" => "false"
      },
      SYSTEM_GIT, *args, chdir: root
    )
    raise "git fixture failed: #{stderr}" unless status.success?

    stdout
  end

  def selected_hosted_ci_seam_script(
    marker:, terminal_result:, required_credential: nil, absent_credential: nil,
    account_home: nil, selected_at: (Time.now.utc - 1).iso8601
  )
    record = {
      "provider" => "circleci",
      "repository" => "owner/repo",
      "pr" => 42,
      "head_sha" => HEAD_SHA,
      "run_id" => "c506a91e-5b3b-4bb6-b136-2bcfa06f69aa",
      "selected_at" => selected_at,
      "terminal_result" => terminal_result
    }
    payload = {
      "contract" => "selected-hosted-ci-receipts",
      "version" => 1,
      "complete" => true,
      "records" => [record]
    }
    credential_name, credential_value = required_credential
    <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      request = JSON.parse(STDIN.read)
      raise "host binding mismatch" unless ENV.fetch("GH_HOST") == request.fetch("host")
      credential_forwarded = #{credential_name.inspect}.nil? ||
        ENV[#{credential_name.inspect}] == #{credential_value.inspect}
      unrelated_credential_present = !#{absent_credential.inspect}.nil? &&
        ENV.key?(#{absent_credential.inspect})
      home = ENV.fetch("HOME")
      home_exists = File.directory?(home)
      home_private = home_exists && (File.stat(home).mode & 0o777) == 0o700
      home_distinct_from_account = #{account_home.inspect}.nil? ||
        File.realpath(home) != File.realpath(#{account_home.inspect})
      home_empty = home_exists && Dir.empty?(home)
      raise "allowlisted credential missing" unless credential_forwarded
      raise "unrelated credential leaked" if unrelated_credential_present
      File.write(
        #{marker.inspect},
        JSON.generate(
          "host" => request.fetch("host"),
          "credential_forwarded" => credential_forwarded,
          "unrelated_credential_present" => unrelated_credential_present,
          "home_exists" => home_exists,
          "home_private" => home_private,
          "home_distinct_from_account" => home_distinct_from_account,
          "home_empty" => home_empty
        )
      )
      puts #{JSON.generate(payload).inspect}
    RUBY
  end

  def fake_gh_call_count
    return 0 unless File.exist?(@fake_gh_calls)

    File.foreach(@fake_gh_calls).count
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def fake_gh_argv
    File.read(@fake_gh_calls).strip.split("\t")
  end

  def reset_fake_gh_calls
    File.delete(@fake_gh_calls) if File.exist?(@fake_gh_calls)
  end

  def eligible_semantic_binding_mutations
    semantic_binding_lines.filter_map do |key, expected_line|
      reset_fake_gh_calls
      issue = fake_issue
      issue["body"] = "#{issue['body']}\n#{yield(key, expected_line)}"
      ENV["FAKE_GH_RESPONSE"] = JSON.generate(issue)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      key if result.fetch("eligible")
    end
  end

  def semantic_binding_lines
    fake_issue.fetch("body").lines(chomp: true).filter_map do |line|
      next unless line.start_with?("semantic-tracker-")

      [line.split(": ", 2).first, line]
    end
  end

  def fake_issue
    {
      "id" => 101,
      "node_id" => "I_kwDOExample",
      "number" => 1,
      "url" => "https://api.github.com/repos/owner/repo/issues/1",
      "html_url" => "https://github.com/owner/repo/issues/1",
      "state" => "open",
      "title" => "Exercise semantic GitHub Actions behavior",
      "body" => [
        "Verify the semantic workflow behavior after merge.",
        "semantic-tracker-source-pr: https://github.com/owner/repo/pull/42",
        "semantic-tracker-head-sha: #{HEAD_SHA}",
        "semantic-tracker-diff-identity: #{DIFF_IDENTITY}",
        "semantic-tracker-operation-digest: " \
          "#{MergeAssurance.semantic_tracker_operation_digest(semantic_tracker)}"
      ].join("\n"),
      "updated_at" => "2026-07-30T11:59:30Z"
    }
  end

  def ready_ci(repo: "owner/repo", pull_request: 42, head_sha: HEAD_SHA)
    rows = {
      "required_status_check_rollup" => [
        { "name" => "required", "bucket" => "pass" }
      ],
      "github_actions" => [
        { "name" => "CI", "status" => "completed", "conclusion" => "success" }
      ],
      "dependabot" => [],
      "other" => []
    }
    scopes = rows.to_h do |name, scope_rows|
      [
        name,
        {
          "state" => scope_rows.empty? ? "NOT_APPLICABLE" : "READY",
          "source" => "github.test.#{name}",
          "complete" => true,
          "head_sha" => head_sha,
          "rows" => scope_rows,
          "checked_at" => "2026-07-30T11:59:00Z"
        }
      ]
    end
    {
      "contract" => "pr-ci-readiness",
      "version" => 2,
      "context" => { "host" => "github.com" },
      "repo" => repo,
      "pr" => pull_request,
      "head_sha" => head_sha,
      "checked_at" => "2026-07-30T11:59:00Z",
      "verdict" => "READY",
      "ordinary_verdict" => "READY",
      "scopes" => scopes
    }
  end

  def autonomous_result(verdict, head_sha: HEAD_SHA)
    triggered_gates, human_decision_evidence =
      case verdict
      when "human-approval-required"
        [["changed-files-limit"], { "status" => "none" }]
      when "human-approved-for-current-head"
        [
          ["changed-files-limit"],
          {
            "status" => "accepted",
            "comment_id" => "123",
            "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
            "approved_by" => "maintainer",
            "source" => "human-pr-comment"
          }
        ]
      else
        [[], { "status" => "none" }]
      end
    {
      "verdict" => verdict,
      "head_sha" => head_sha,
      "policy_provenance" => "git:#{BASE_SHA}",
      "helper_provenance" => "trusted-base:#{BASE_SHA}",
      "helper_trust" => {
        "status" => "mechanically-verified",
        "manifest" => autonomous_runtime_manifest
      },
      "metrics" => { "changed_files" => 1, "changed_lines" => 2, "commits" => 1, "reviewed_heads" => 0 },
      "path_matches" => [],
      "safe_class" => "tests",
      "triggered_gates" => triggered_gates,
      "shadow_triggered_gates" => [],
      "shadow_evidence_unknown" => [],
      "rollback_assessment" => "code-only-rollback-established",
      "human_decision_evidence" => human_decision_evidence,
      "evidence_failures" => []
    }
  end

  def autonomous_runtime_manifest
    {
      "helper" => "skills/pr-batch/bin/autonomous-merge-eligibility",
      "closeout-helper" => "skills/pr-batch/bin/autonomous-merge-closeout",
      "decision-library" => "skills/pr-batch/lib/autonomous_merge_decision.rb",
      "evidence-library" => "skills/pr-batch/lib/autonomous_merge_evidence.rb",
      "policy-library" => "bin/agent_doctor/autonomous_merge_policy.rb",
      "policy-glob-library" => "bin/agent_doctor/autonomous_merge_policy_globs.rb",
      "policy-yaml-library" => "bin/agent_doctor/autonomous_merge_policy_yaml.rb",
      "runtime-trust-library" => "skills/pr-batch/lib/autonomous_merge_runtime_trust.rb",
      "calibration-decision" =>
        "skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json"
    }
  end

  def context(
    authority, operations: [], human_merge_decision: nil, walkthrough: nil,
    semantic_github_actions_change: false, repo: "owner/repo", pull_request: 42,
    head_sha: HEAD_SHA, selected_hosted_runs: []
  )
    {
      "contract" => "merge-assurance-context",
      "version" => 1,
      "host" => "github.com",
      "repo" => repo,
      "pr" => pull_request,
      "base" => { "ref" => "main", "sha" => BASE_SHA },
      "head_sha" => head_sha,
      "authority" => authority,
      "diff_identity" => DIFF_IDENTITY,
      "human_merge_decision" => human_merge_decision,
      "walkthrough" => walkthrough,
      "semantic_github_actions_change" => semantic_github_actions_change,
      "selected_hosted_runs" => selected_hosted_runs,
      "operations" => operations
    }
  end

  def selected_hosted_ci_receipts(replay, context)
    {
      "contract" => "selected-hosted-ci-receipts",
      "version" => 1,
      "complete" => true,
      "records" => replay.fetch("selected_runs").map do |run|
        run.merge(
          "repository" => context.fetch("repo"),
          "pr" => context.fetch("pr"),
          "head_sha" => context.fetch("head_sha")
        )
      end
    }
  end

  def human_merge_decision
    {
      "contract" => "human-merge-decision",
      "version" => 1,
      "decision" => "approved",
      "host" => "github.com",
      "repo" => "owner/repo",
      "pr" => 42,
      "base_ref" => "main",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY,
      "provenance" => "direct-user",
      "merge_authority" => true,
      "decided_at" => "2026-07-30T11:59:30Z"
    }
  end

  def walkthrough(disposition, provenance)
    {
      "contract" => "pr-walkthrough",
      "version" => 1,
      "disposition" => disposition,
      "host" => "github.com",
      "repo" => "owner/repo",
      "pr" => 42,
      "base_ref" => "main",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY,
      "provenance" => provenance
    }
  end

  def ordinary_follow_up(bundle_id, approval_scope:)
    items = ["deferred cleanup"]
    approval = if approval_scope
                 {
                   "contract" => "follow-up-approval",
                   "version" => 1,
                   "approval_id" => "approval-#{bundle_id}",
                   "decision" => "approved",
                   "provenance" => "direct-user",
                   "scope" => approval_scope,
                   "bundle_id" => bundle_id,
                   "items_digest" => MergeAssurance.canonical_items_digest(items),
                   "host" => "github.com",
                   "repo" => "owner/repo",
                   "pr" => 42,
                   "head_sha" => HEAD_SHA,
                   "diff_identity" => DIFF_IDENTITY,
                   "approved_at" => "2026-07-30T11:59:30Z"
                 }
               end
    {
      "type" => "ordinary-follow-up-bundle",
      "bundle_id" => bundle_id,
      "items" => items,
      "approval" => approval
    }
  end

  def semantic_tracker
    {
      "type" => "semantic-github-actions-tracker",
      "tracker" => "https://github.com/owner/repo/issues/1",
      "source_pr" => "https://github.com/owner/repo/pull/42",
      "changed_files" => [".github/workflows/ci.yml"],
      "exercise" => "Open a secondary verification PR after merge.",
      "expected_evidence" => "The dynamic matrix checks appear on the verification PR.",
      "cleanup_instructions" => "Close the verification-only PR without merging.",
      "owner" => "maintainer"
    }
  end

  def tracker_read_verification
    {
      "contract" => "semantic-tracker-read-verification",
      "version" => 1,
      "status" => "verified",
      "complete" => true,
      "provenance" => "authenticated-github-api",
      "checked_at" => "2026-07-30T11:59:30Z",
      "tracker" => "https://github.com/owner/repo/issues/1",
      "issue" => 1,
      "host" => "github.com",
      "repo" => "owner/repo",
      "source_pr" => "https://github.com/owner/repo/pull/42",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY
    }
  end
end
