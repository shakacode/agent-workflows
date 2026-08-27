#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

SCRIPT = File.expand_path("completed-batch-publication-preflight", __dir__)
FIXTURES = File.expand_path("../fixtures", __dir__)
load SCRIPT

class CompletedBatchPublicationPreflightTest < Minitest::Test
  BACKEND = "agent-coord private backend"

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name), encoding: "UTF-8"))
  end

  def no_backend_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input["coordination_status"] = {
      "contract" => "completed-batch-coordination-not-applicable",
      "version" => 1,
      "batch_id" => input.fetch("batch_id"),
      "mode" => "single_operator",
      "rationale" => "repository workflow seam declares coordination_backend: n/a",
      "source" => "https://github.com/shakacode/agent-workflows/blob/fb33440cbad49808898c4a15f8c3e0c9276b7470/.agents/agent-workflow.yml",
      "completed_at" => "2026-07-31T11:40:00Z",
      "targets" => JSON.parse(JSON.generate(input.fetch("expected_targets")))
    }
    input
  end

  def no_pr_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    number = 10_036
    target = input.fetch("expected_targets").find { |row| row.fetch("number") == number }
    target["type"] = "issue"
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == [number.to_s] }
    lane["issue_url"] = lane.delete("pr_url").sub("/pull/", "/issues/")
    lane["pr_state"] = "closed"
    snapshot = input.fetch("target_snapshots").find { |row| row.dig("target", "number") == number }
    snapshot.fetch("target")["type"] = "issue"
    snapshot["state"] = "closed"
    snapshot["head_sha"] = "not_applicable"
    snapshot["no_pr_evidence"] = {
      "url" => "https://github.com/shakacode/hichee/issues/10036",
      "rationale" => "closed issue; no implementation PR was created",
      "target" => JSON.parse(JSON.generate(snapshot.fetch("target")))
    }
    qa = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == number }
    qa.fetch("target")["type"] = "issue"
    qa["evidence"] = <<~MARKER
      <!-- qa-evidence v1
      required: no
      status: not_applicable
      head_sha: not_applicable
      tested_at: issue #10036 closed with no implementation PR
      scope: issue-only closeout
      automated_checks: not applicable
      manual_checks: not applicable
      findings: none
      release_blocking: not_applicable
      process_gap_disposition: not_applicable
      -->
    MARKER
    input
  end

  def later_closed_no_pr_with_auxiliary_qa_lane_input
    input = no_pr_input
    original_number = 10_036
    number = 10_235
    batch_id = "hc-a06-0822-2035-issue10235"
    target = input.fetch("expected_targets").find { |row| row.fetch("number") == original_number }
    snapshot = input.fetch("target_snapshots").find { |row| row.fetch("target") == target }
    qa = input.fetch("qa_evidence").find { |row| row.fetch("target") == target }

    target["number"] = number
    snapshot.fetch("target")["number"] = number
    snapshot.fetch("no_pr_evidence").fetch("target")["number"] = number
    snapshot.fetch("no_pr_evidence")["url"] = "https://github.com/shakacode/hichee/issues/#{number}"
    snapshot["source"] = "https://github.com/shakacode/hichee/issues/#{number}"
    snapshot["completed_at"] = "2026-08-25T07:05:23Z"
    qa.fetch("target")["number"] = number
    qa["user_visible_ui_change"] = "no"
    qa["evidence"] = qa.fetch("evidence").gsub("10036", number.to_s)

    input["batch_id"] = batch_id
    input["expected_targets"] = [target]
    input["target_snapshots"] = [snapshot]
    input["qa_evidence"] = [qa]
    input.dig("coordination_status", "scope")["batch_id"] = batch_id
    batch = input.dig("coordination_status", "batches", 0)
    batch["batch_id"] = batch_id
    batch["updated_at"] = "2026-08-23T08:05:03Z"
    batch["completed_at"] = "2026-08-23T08:05:03Z"
    evidence_url = "https://github.com/shakacode/hichee/issues/#{number}#issuecomment-5384964861"
    batch["lanes"] = [
      {
        "name" => "issue-10235",
        "targets" => [number.to_s],
        "status" => "done",
        "terminal" => "done",
        "closed_at" => "2026-08-23T08:04:57Z",
        "pr_state" => "no_pr_evidence",
        "evidence_url" => evidence_url
      },
      {
        "name" => "issue-10235-qa",
        "targets" => ["adhoc:hc-a06-issue10235-qa"],
        "status" => "done",
        "terminal" => "done",
        "closed_at" => "2026-08-23T08:05:03Z",
        "pr_state" => "no_pr_evidence",
        "evidence_url" => evidence_url
      }
    ]
    input["auxiliary_lane_map"] = {
      "contract" => "completed-batch-auxiliary-lane-map",
      "version" => 1,
      "lanes" => [
        {
          "coordination_target" => "adhoc:hc-a06-issue10235-qa",
          "parent_target" => JSON.parse(JSON.generate(target)),
          "role" => "qa"
        }
      ]
    }
    input
  end

  def issue_to_pr_with_qa_lane_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    target = {
      "host" => "github.com",
      "repo" => "shakacode/hichee",
      "type" => "pull_request",
      "number" => 10_299
    }
    head_sha = "ef30745eccc6e1fdae34c1b770edbc9650800e51"
    input["batch_id"] = "hc-a27-issue9521-20260822-2035"
    input["expected_targets"] = [target]
    batch = input.dig("coordination_status", "batches", 0)
    input.dig("coordination_status", "scope")["batch_id"] = input.fetch("batch_id")
    batch["batch_id"] = input.fetch("batch_id")
    batch["repo"] = target.fetch("repo")
    batch["lanes"] = %w[issue-9521 qa-issue-9521].map do |name|
      {
        "name" => name,
        "owner" => "hc-a27-#{name}",
        "targets" => ["9521"],
        "status" => "done",
        "terminal" => "done",
        "closed_at" => "2026-08-24T00:43:00Z",
        "pr_url" => "https://github.com/shakacode/hichee/pull/10299",
        "pr_state" => "merged",
        "evidence_url" => "https://github.com/shakacode/hichee/pull/10299"
      }
    end
    input["target_snapshots"] = [{
      "target" => target,
      "state" => "merged",
      "head_sha" => head_sha,
      "completed_at" => "2026-08-24T00:41:33Z",
      "source" => "https://github.com/shakacode/hichee/pull/10299"
    }]
    input["qa_evidence"] = [{
      "target" => target,
      "user_visible_ui_change" => "no",
      "evidence" => qa_v2_evidence(head_sha:, user_visible_ui_change: "no")
    }]
    input
  end

  def issue_projection_proof(source:, target:, head_sha: "ef30745eccc6e1fdae34c1b770edbc9650800e51")
    {
      "contract" => "github-issue-result-pr-projection",
      "version" => 1,
      "source_target" => source,
      "result_target" => target,
      "relationship" => "closes_issue",
      "result_head_sha" => head_sha,
      "result_merged_at" => "2026-08-24T00:41:33Z",
      "source_closed_at" => "2026-08-24T00:41:34Z",
      "verification_source" => "authenticated github graphql symmetric closing references"
    }
  end

  def issue_projection_graphql_payload(source:, target:, include_forward: true, include_reverse: true)
    head_sha = "ef30745eccc6e1fdae34c1b770edbc9650800e51"
    issue_node = {
      "number" => source.fetch("number"),
      "url" => "https://github.com/#{source.fetch('repo')}/issues/#{source.fetch('number')}",
      "state" => "CLOSED",
      "closedAt" => "2026-08-24T00:41:34Z",
      "repository" => { "nameWithOwner" => source.fetch("repo") }
    }
    pr_node = {
      "number" => target.fetch("number"),
      "url" => "https://github.com/#{target.fetch('repo')}/pull/#{target.fetch('number')}",
      "state" => "MERGED",
      "mergedAt" => "2026-08-24T00:41:33Z",
      "headRefOid" => head_sha,
      "repository" => { "nameWithOwner" => target.fetch("repo") }
    }
    {
      "data" => {
        "repository" => {
          "result" => pr_node.except("repository").merge(
            "closingIssuesReferences" => {
              "nodes" => include_forward ? [issue_node] : [],
              "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
            }
          ),
          "source" => issue_node.except("repository").merge(
            "closedByPullRequestsReferences" => {
              "nodes" => include_reverse ? [pr_node] : [],
              "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
            }
          )
        }
      }
    }
  end

  def test_issue_projection_query_includes_closed_result_pull_requests
    assert_includes CompletedBatchPublicationPreflight::TARGET_PROJECTION_QUERY,
                    "closedByPullRequestsReferences(first: 100, after: $sourceCursor, includeClosedPrs: true)"
  end

  def qa_v2_evidence(head_sha:, user_visible_ui_change:)
    ui_change = user_visible_ui_change == "yes"
    destination = ui_change ? "github_pr" : "not_applicable"
    visual_evidence = if ui_change
                        "durable: before and after https://github.com/shakacode/hichee/pull/10049#visual"
                      else
                        "not applicable: no user-visible UI change"
                      end
    paint_check = ui_change ? "passed: painted target inspected" : "not applicable: no painted surface changed"
    <<~MARKER
      <!-- qa-evidence v2
      required: yes
      status: satisfied
      head_sha: #{head_sha}
      tested_at: PR/head #{head_sha}
      scope: exact-head QA
      automated_checks: focused specs
      manual_checks: verified
      user_visible_ui_change: #{user_visible_ui_change}
      visual_evidence_destination: #{destination}
      visual_evidence: #{visual_evidence}
      paint_check: #{paint_check}
      interaction_change: no
      interaction_evidence: not applicable: no interaction changed
      visual_fix: no
      negative_control: not applicable: no visual fix
      performance_impact: not_applicable
      performance_evidence: not applicable: no rendered-page, asset, or bundle impact
      findings: none
      release_blocking: clear
      process_gap_disposition: checklist+replay
      -->
    MARKER
  end

  def assess_input(
    input,
    backend: BACKEND,
    evidence_comment_verifier: valid_evidence_comment_verifier(input),
    waiver_verifier: valid_waiver_verifier(input),
    target_verifier: valid_target_verifier(input),
    coordination_verifier: valid_coordination_verifier(input, backend)
  )
    CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: backend,
      evidence_comment_verifier:,
      waiver_verifier:,
      target_verifier:,
      coordination_verifier:
    )
  end

  def valid_evidence_comment_verifier(input)
    comments = input.dig("coordination_status", "batches", 0, "lanes").to_a.filter_map do |lane|
      url = lane["evidence_url"].to_s
      match = url.match(%r{\Ahttps://([^/]+)/([^/]+/[^/]+)/issues/(\d+)#issuecomment-(\d+)\z})
      next unless match

      comment_id = Integer(match[4], 10)
      next if comment_id == 999_999_999_999_999_999

      {
        "host" => match[1],
        "repo" => match[2],
        "comment_id" => comment_id,
        "payload" => {
          "id" => comment_id,
          "html_url" => url,
          "issue_url" => "https://api.github.com/repos/#{match[2]}/issues/#{match[3]}",
          "body" => "Authenticated no-PR closeout evidence.",
          "created_at" => "2026-08-23T08:04:50Z",
          "updated_at" => "2026-08-23T08:04:50Z"
        }
      }
    end
    comments.uniq! { |comment| [comment.fetch("host"), comment.fetch("repo"), comment.fetch("comment_id")] }

    lambda do |host:, repo:, comment_id:|
      comment = comments.find do |candidate|
        candidate.fetch("host") == host && candidate.fetch("repo") == repo &&
          candidate.fetch("comment_id") == comment_id
      end
      comment&.fetch("payload")
    end
  end

  def valid_target_verifier(input)
    lambda do |target:|
      row = input.fetch("target_snapshots").find { |candidate| candidate.fetch("target") == target }
      next unless row

      raw_head_sha = row["head_sha"].to_s.downcase
      head_sha = raw_head_sha.match?(CompletedBatchPublicationPreflight::SHA_PATTERN) ? raw_head_sha : nil
      {
        "target" => target,
        "state" => row.fetch("state"),
        "head_sha" => head_sha,
        "completed_at" => row.fetch("completed_at", "2026-08-01T00:00:00Z"),
        "verification_source" => "authenticated gh api"
      }
    end
  end

  def valid_coordination_verifier(input, configured_backend)
    expected_backend = configured_backend
    lambda do |backend:, batch_id:|
      next unless backend == expected_backend && batch_id == input.fetch("batch_id")

      input.fetch("coordination_status")
    end
  end

  def valid_waiver_verifier(input)
    row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
    comment = row && valid_waiver_comment(row, input)
    lambda do |host:, repo:, comment_id:|
      next unless comment
      next unless host == "github.com" && repo == "shakacode/hichee"
      next unless comment_id == comment.fetch("id")

      comment
    end
  end

  def valid_waiver_comment(row, input)
    target = row.fetch("target")
    snapshot = input.fetch("target_snapshots").find { |candidate| candidate.fetch("target") == target }
    head_sha = snapshot.fetch("head_sha")
    url = row.dig("maintainer_waiver", "url")
    comment_id = Integer(url[/#issuecomment-(\d+)\z/, 1], 10)
    target_url = "https://github.com/#{target.fetch('repo')}/pull/#{target.fetch('number')}"
    body = <<~BODY
      Maintainer exact-head QA waiver.

      <!-- qa-maintainer-waiver v1
      target: #{target_url}
      head_sha: #{head_sha}
      decision: waived
      -->
    BODY
    {
      "id" => comment_id,
      "html_url" => url,
      "issue_url" => "https://api.github.com/repos/#{target.fetch('repo')}/issues/#{target.fetch('number')}",
      "body" => body,
      "user" => { "login" => "justin808", "type" => "User" },
      "author_association" => "MEMBER",
      "created_at" => "2026-07-31T12:00:00Z",
      "updated_at" => "2026-07-31T12:00:00Z"
    }
  end

  def with_fake_waiver_gh(input, mode: "success", author_permission: "write")
    Dir.mktmpdir("completed-batch-publication-preflight") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
      targets = input.fetch("target_snapshots").map do |snapshot|
        target = snapshot.fetch("target")
        endpoint_type = target.fetch("type") == "pull_request" ? "pulls" : "issues"
        payload = {
          "number" => target.fetch("number"),
          "html_url" => "https://#{target.fetch('host')}/#{target.fetch('repo')}/" \
                        "#{target.fetch('type') == 'pull_request' ? 'pull' : 'issues'}/#{target.fetch('number')}",
          "state" => "closed",
          "closed_at" => "2026-08-01T00:00:00Z"
        }
        if target.fetch("type") == "pull_request"
          payload["merged_at"] = "2026-07-31T12:00:00Z"
          payload["head"] = { "sha" => snapshot.fetch("head_sha") }
        end
        {
          "host" => target.fetch("host"),
          "endpoint" => "repos/#{target.fetch('repo')}/#{endpoint_type}/#{target.fetch('number')}",
          "payload" => payload
        }
      end
      gh_log = File.join(directory, "gh.log")
      gh = File.join(bin, "gh")
      File.write(gh, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"

        File.open(#{gh_log.dump}, "a") { |file| file.puts(ARGV.join(" ")) }
        args = ARGV.dup
        abort "expected api" unless args.shift == "api"
        abort "expected --hostname" unless args.shift == "--hostname"
        host = args.shift
        endpoint = args.shift
        targets = JSON.parse(#{JSON.generate(targets).dump})
        target = targets.find do |candidate|
          candidate.fetch("host") == host && candidate.fetch("endpoint") == endpoint
        end

        if target
          puts JSON.generate(target.fetch("payload"))
        elsif endpoint == "repos/shakacode/hichee/collaborators/justin808/permission"
          puts JSON.generate(
            "permission" => #{author_permission.dump},
            "user" => { "login" => "justin808", "type" => "User" }
          )
        elsif endpoint.include?("/issues/comments/")
          exit 1 if #{mode.dump} == "not_found"

          puts #{JSON.generate(valid_waiver_comment(row, input)).dump}
        else
          abort "unexpected endpoint: \#{host} \#{endpoint}"
        end
      RUBY
      agent_coord = File.join(bin, "agent-coord")
      File.write(agent_coord, <<~'RUBY')
        #!/usr/bin/env ruby
        abort "unexpected agent-coord arguments" unless ARGV == ["status", "--batch-id", ENV.fetch("FAKE_BATCH_ID"), "--json"]

        puts ENV.fetch("FAKE_COORDINATION_STATUS")
      RUBY
      FileUtils.chmod("+x", gh)
      FileUtils.chmod("+x", agent_coord)
      runner = File.join(directory, "completed-batch-publication-preflight-runner.rb")
      File.write(runner, <<~RUBY)
        load #{SCRIPT.dump}
        fake_gh = #{gh.dump}
        original_trusted_system_tool = CompletedBatchPublicationPreflight.method(:trusted_system_tool)
        CompletedBatchPublicationPreflight.define_singleton_method(:trusted_system_tool) do |name, outside_root:|
          if name == "gh"
            CompletedBatchPublicationPreflight.trusted_external_executable(fake_gh, outside_root:)
          else
            original_trusted_system_tool.call(name, outside_root:)
          end
        end
        exit CompletedBatchPublicationPreflight.run(ARGV)
      RUBY
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "FAKE_GH_LOG" => gh_log,
        "FAKE_PREFLIGHT_RUNNER" => runner,
        "FAKE_BATCH_ID" => input.fetch("batch_id"),
        "FAKE_COORDINATION_STATUS" => JSON.generate(input.fetch("coordination_status"))
      }
      yield env
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def process_state(pid)
    stat_path = "/proc/#{pid}/stat"
    return process_alive?(pid) ? "present" : nil unless File.file?(stat_path)

    stat = File.read(stat_path, encoding: "UTF-8")
    closing_parenthesis = stat.rindex(") ")
    return "present" unless closing_parenthesis

    stat[(closing_parenthesis + 2)..].split.first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def wait_for_process_exit(pid, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 while process_state(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    process_state(pid).nil?
  end

  def test_capture_process_timeout_terminates_descendant_process_group
    Dir.mktmpdir("completed-batch-process-group") do |directory|
      descendant_pid_path = File.join(directory, "descendant.pid")
      wrapper = 'sleep 30 & descendant=$!; printf "%s\n" "$descendant" > "$1"; wait "$descendant"'
      descendant_pid = nil

      assert_raises(Timeout::Error) do
        CompletedBatchPublicationPreflight.capture_process(
          ["/bin/sh", "-c", wrapper, "process-group-wrapper", descendant_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      descendant_pid = Integer(File.read(descendant_pid_path), 10)

      assert wait_for_process_exit(descendant_pid),
             "timed process descendant #{descendant_pid} survived process-group cleanup " \
             "with state #{process_state(descendant_pid).inspect}"
    ensure
      Process.kill("KILL", descendant_pid) if descendant_pid && process_alive?(descendant_pid)
    end
  end

  def test_capture_process_timeout_reaps_nested_descendant_layers
    Dir.mktmpdir("completed-batch-nested-process-group") do |directory|
      process_ids_path = File.join(directory, "process-ids")
      intermediate_program = <<~'RUBY'
        leaf_pid = Process.spawn("/bin/sleep", "30")
        File.write(ARGV.fetch(0), [Process.ppid, Process.pid, leaf_pid].join("\n") + "\n")
        Process.wait(leaf_pid)
      RUBY
      leader_program = <<~'RUBY'
        intermediate_pid = Process.spawn(RbConfig.ruby, "-e", ARGV.fetch(1), ARGV.fetch(0))
        Process.wait(intermediate_pid)
      RUBY
      helper_program = <<~'RUBY'
        load ARGV.shift
        begin
          CompletedBatchPublicationPreflight.capture_process(
            [RbConfig.ruby, "-rrbconfig", "-e", ARGV.fetch(1), ARGV.fetch(0), ARGV.fetch(2)],
            input: "",
            timeout: 0.5
          )
          exit 1
        rescue Timeout::Error
          exit 0
        end
      RUBY
      process_ids = []
      helper_pid = Process.spawn(
        RbConfig.ruby,
        "-rrbconfig",
        "-e",
        helper_program,
        SCRIPT,
        process_ids_path,
        leader_program,
        intermediate_program
      )

      _pid, helper_status = Process.wait2(helper_pid)
      assert_predicate helper_status, :success?
      process_ids = File.readlines(process_ids_path, chomp: true).map { |line| Integer(line, 10) }
      assert_equal 3, process_ids.length

      %w[leader intermediate leaf].zip(process_ids).each do |label, pid|
        assert wait_for_process_exit(pid),
               "timed nested #{label} #{pid} survived process-group cleanup " \
               "with state #{process_state(pid).inspect}"
      end
    ensure
      process_ids.reverse_each do |pid|
        Process.kill("KILL", pid) if process_alive?(pid)
      rescue Errno::EPERM
        nil
      end
    end
  end

  def test_capture_process_timeout_kills_term_resistant_group_leader
    Dir.mktmpdir("completed-batch-term-resistant") do |directory|
      child_pid_path = File.join(directory, "child.pid")
      program = 'trap("TERM") {}; File.write(ARGV.fetch(0), Process.pid.to_s); sleep 30'
      child_pid = nil
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Timeout::Error) do
        CompletedBatchPublicationPreflight.capture_process(
          [RbConfig.ruby, "-e", program, child_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      child_pid = Integer(File.read(child_pid_path), 10)

      assert_operator elapsed, :<, 3
      assert wait_for_process_exit(child_pid),
             "TERM-resistant process-group leader #{child_pid} survived KILL escalation"
    ensure
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    end
  end

  def test_capture_process_accepts_a_closed_environment_and_explicit_working_directory
    Dir.mktmpdir("completed-batch-closed-environment") do |directory|
      original_ambient = ENV["CAPTURE_PROCESS_AMBIENT"]
      ENV["CAPTURE_PROCESS_AMBIENT"] = "must-not-leak"
      program = <<~'RUBY'
        require "json"
        puts JSON.generate("cwd" => Dir.pwd, "environment" => ENV.to_h)
      RUBY

      stdout, stderr, status = CompletedBatchPublicationPreflight.capture_process(
        [RbConfig.ruby, "-e", program],
        input: "",
        timeout: 2,
        environment: { "ONLY_CONTROLLED" => "yes" },
        chdir: directory,
        unsetenv_others: true
      )

      payload = JSON.parse(stdout)
      assert status.success?, stderr
      assert_equal File.realpath(directory), payload.fetch("cwd")
      assert_equal "yes", payload.dig("environment", "ONLY_CONTROLLED")
      refute payload.fetch("environment").key?("CAPTURE_PROCESS_AMBIENT")
    ensure
      original_ambient.nil? ? ENV.delete("CAPTURE_PROCESS_AMBIENT") : ENV["CAPTURE_PROCESS_AMBIENT"] = original_ambient
    end
  end

  def test_authenticated_gh_helpers_use_an_external_absolute_tool_with_a_closed_environment_and_safe_cwd
    Dir.mktmpdir("completed-batch-authenticated-gh") do |directory|
      repository = File.join(directory, "candidate-repository")
      candidate_bin = File.join(repository, "bin")
      external_bin = File.join(directory, "trusted-bin")
      FileUtils.mkdir_p([candidate_bin, external_bin])
      candidate_gh = File.join(candidate_bin, "gh")
      external_gh = File.join(external_bin, "gh")
      [candidate_gh, external_gh].each do |path|
        File.write(path, "#!/bin/sh\nexit 99\n")
        FileUtils.chmod(0o755, path)
      end

      ambient = %w[PATH GIT_SSH_COMMAND GIT_ASKPASS RUBYOPT RUBYLIB GH_CONFIG_DIR].to_h do |name|
        [name, ENV[name]]
      end
      credential_environment = CompletedBatchPublicationPreflight::GH_CREDENTIAL_ENV_KEYS.to_h do |name|
        [name, ENV[name]]
      end
      ENV["GITHUB_TOKEN"] = "ambient-non-gh-token"
      CompletedBatchPublicationPreflight::GH_CREDENTIAL_ENV_KEYS.each { |name| ENV.delete(name) }
      ENV.update(
        "PATH" => "#{candidate_bin}:#{ENV.fetch('PATH')}",
        "GH_TOKEN" => "approved-token",
        "GIT_SSH_COMMAND" => candidate_gh,
        "GIT_ASKPASS" => candidate_gh,
        "RUBYOPT" => "-rcandidate-loader",
        "RUBYLIB" => repository,
        "GH_CONFIG_DIR" => repository
      )

      observed = nil
      test_case = self
      capture = lambda do |command, input:, timeout:, environment: nil, chdir: nil, unsetenv_others: false|
        observed = {
          command:,
          input:,
          timeout:,
          environment:,
          chdir: File.realpath(chdir),
          unsetenv_others:
        }
        test_case.assert File.directory?(chdir), "authenticated gh cwd must exist while gh runs"
        [JSON.generate("authenticated" => true), "", Struct.new(:success?).new(true)]
      end
      resolver = lambda do |name, outside_root:|
        test_case.assert_equal "gh", name
        test_case.assert_equal File.realpath(repository), File.realpath(outside_root)
        File.realpath(external_gh)
      end
      original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
      original_resolver = if CompletedBatchPublicationPreflight.respond_to?(:trusted_system_tool)
                            CompletedBatchPublicationPreflight.method(:trusted_system_tool)
                          end
      CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &capture)
      CompletedBatchPublicationPreflight.define_singleton_method(:trusted_system_tool, &resolver)

      payload = CompletedBatchPublicationPreflight.authenticated_gh_api(
        "github.com",
        "repos/shakacode/agent-workflows/issues/comments/1",
        repository_root: repository
      )

      account = Etc.getpwuid
      expected_environment = {
        "GH_HOST" => "github.com",
        "HOME" => account.dir,
        "USER" => account.name,
        "LOGNAME" => account.name,
        "PATH" => CompletedBatchPublicationPreflight::SYSTEM_TOOL_DIRS.join(File::PATH_SEPARATOR),
        "GH_PROMPT_DISABLED" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "GH_TOKEN" => "approved-token"
      }
      assert_equal({ "authenticated" => true }, payload)
      assert_equal [
        File.realpath(external_gh),
        "api", "--hostname", "github.com",
        "repos/shakacode/agent-workflows/issues/comments/1"
      ], observed.fetch(:command)
      assert_equal "", observed.fetch(:input)
      assert_equal CompletedBatchPublicationPreflight.gh_timeout_seconds, observed.fetch(:timeout)
      assert_equal expected_environment, observed.fetch(:environment)
      assert observed.fetch(:unsetenv_others)
      refute File.exist?(observed.fetch(:chdir)), "authenticated gh cwd must be removed after gh exits"
      refute_equal File.realpath(repository), observed.fetch(:chdir)
      refute observed.fetch(:chdir).start_with?("#{File.realpath(repository)}#{File::SEPARATOR}")

      query = "query($number: Int!) { repository(owner: \"acme\", name: \"widgets\") { issue(number: $number) { id } } }"
      observed = nil
      payload = CompletedBatchPublicationPreflight.authenticated_gh_graphql(
        "github.com",
        query:,
        variables: { "number" => 184, "cursor" => "@literal-cursor" },
        repository_root: repository
      )
      assert_equal({ "authenticated" => true }, payload)
      assert_equal [
        File.realpath(external_gh),
        "api", "--hostname", "github.com", "graphql", "-f", "query=#{query}",
        "-f", "cursor=@literal-cursor", "-F", "number=184"
      ], observed.fetch(:command)
      assert_equal expected_environment, observed.fetch(:environment)
      assert observed.fetch(:unsetenv_others)
      refute File.exist?(observed.fetch(:chdir)), "authenticated GraphQL cwd must be removed after gh exits"

      observed = nil
      assert_nil CompletedBatchPublicationPreflight.authenticated_gh_graphql(
        "github.com",
        query:,
        variables: { "bad-name" => 184 },
        repository_root: repository
      )
      assert_nil observed
    ensure
      ambient&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      credential_environment&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      if original_capture
        CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &original_capture)
      end
      if original_resolver
        CompletedBatchPublicationPreflight.define_singleton_method(:trusted_system_tool, &original_resolver)
      else
        CompletedBatchPublicationPreflight.singleton_class.send(:remove_method, :trusted_system_tool)
      end
    end
  end

  def test_trusted_external_executable_rejects_candidate_controlled_and_malformed_tools
    Dir.mktmpdir("completed-batch-trusted-tool") do |directory|
      repository = File.join(directory, "candidate-repository")
      repository_bin = File.join(repository, "bin")
      external_bin = File.join(directory, "trusted-bin")
      FileUtils.mkdir_p([repository_bin, external_bin])
      repository_tool = File.join(repository_bin, "gh")
      external_tool = File.join(external_bin, "gh")
      non_executable = File.join(external_bin, "gh-non-executable")
      repository_symlink = File.join(external_bin, "gh-repository-symlink")
      File.write(repository_tool, "#!/bin/sh\nexit 0\n")
      File.write(external_tool, "#!/bin/sh\nexit 0\n")
      File.write(non_executable, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, [repository_tool, external_tool])
      FileUtils.chmod(0o644, non_executable)
      File.symlink(repository_tool, repository_symlink)

      assert_nil CompletedBatchPublicationPreflight.trusted_external_executable(
        repository_tool,
        outside_root: repository
      )
      assert_nil CompletedBatchPublicationPreflight.trusted_external_executable(
        repository_symlink,
        outside_root: repository
      )
      assert_nil CompletedBatchPublicationPreflight.trusted_external_executable(
        non_executable,
        outside_root: repository
      )
      assert_nil CompletedBatchPublicationPreflight.trusted_external_executable(
        File.join(external_bin, "missing-gh"),
        outside_root: repository
      )
      assert_equal File.realpath(external_tool),
                   CompletedBatchPublicationPreflight.trusted_external_executable(
                     external_tool,
                     outside_root: repository
                   )
    end
  end

  def test_public_claim_comment_fallback_never_invokes_private_coordination
    calls = []
    capture = lambda do |command, input:, timeout:|
      calls << { "command" => command, "input" => input, "timeout" => timeout }
      payload = {
        "scope" => { "kind" => "batch", "batch_id" => "batch-public" },
        "batches" => []
      }
      [JSON.generate(payload), "", Struct.new(:success?).new(true)]
    end
    original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &capture)

    [
      "public claim-comment fallback",
      " Public　claim-comment \n fallback. "
    ].each do |backend|
      result = CompletedBatchPublicationPreflight.authenticated_coordination_status(
        backend:,
        batch_id: "batch-public"
      )

      assert_nil result, backend.inspect
    end
    assert_empty calls

    input = fixture("completed-batch-publication-hichee-terminal.json")
    assessment = assess_input(
      input,
      backend: "public claim-comment fallback",
      coordination_verifier: CompletedBatchPublicationPreflight.method(:authenticated_coordination_status)
    )
    refute assessment.fetch("eligible")
    assert_includes assessment.fetch("blockers"), "coordination status is not authenticated or fresh"
    assert_empty calls
  ensure
    if original_capture
      CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &original_capture)
    end
  end

  def test_premature_hichee_publication_replays_blocked_for_coordination_target_and_qa
    result = assess_input(fixture("completed-batch-publication-hichee-premature.json"))

    refute result.fetch("eligible")
    assert_equal "BLOCKED", result.fetch("verdict")
    assert_includes result.fetch("blockers"), "coordination batch is not completed"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 coordination lane is nonterminal"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 target is not merged"
    [10_026, 10_048, 10_049].each do |number|
      assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:#{number} QA evidence is absent"
    end
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("snapshot_digest"))
    assert_equal "sha256:2e73bd93cdf88b511d2865d9572d6e9ba4ee3c13a65bf8048f8cded7f37e5ca5",
                 result.fetch("snapshot_digest")
  end

  def test_real_premature_marker_fixture_preserves_reported_hash_and_is_not_well_formed
    marker = File.read(
      File.join(FIXTURES, "completed-batch-publication-hichee-premature-marker.txt"),
      encoding: "UTF-8"
    )

    assert_equal "5ede1b523b283a091d74ce51a429a4d5fde200404cc37ae8c5eff32f6e0e6352",
                 Digest::SHA256.hexdigest(marker)
  end

  def test_four_terminal_reconciled_lanes_pass_with_exact_head_dispositions
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "ELIGIBLE", result.fetch("verdict")
    assert_empty result.fetch("blockers")
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_equal(
      %w[WAIVED SATISFIED NOT_APPLICABLE SATISFIED],
      result.dig("snapshot", "qa").map { |qa| qa.fetch("verdict") }
    )
    waiver = result.dig("snapshot", "qa").first.fetch("maintainer_waiver")
    expected_body = valid_waiver_comment(
      fixture("completed-batch-publication-hichee-terminal.json").fetch("qa_evidence").last,
      fixture("completed-batch-publication-hichee-terminal.json")
    ).fetch("body")
    assert_equal 5_000_000_000, waiver.fetch("comment_id")
    assert_equal "justin808", waiver.fetch("author")
    assert_equal "MEMBER", waiver.fetch("author_association")
    assert_equal Digest::SHA256.hexdigest(expected_body), waiver.fetch("body_sha256")
    assert_equal "57e048ed10551eb3cf8414a4de0064443bef730d", waiver.fetch("head_sha")
    assert_equal 10_026, waiver.dig("target", "number")
    refute(result.dig("snapshot", "targets").any? { |target| target.key?("completed_at") })
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
    assert_equal "sha256:a926d6266be958f222901d99cdcd78e3e3fd6148f575971922d66d491d16a5da",
                 result.fetch("snapshot_digest")
  end

  def test_issue_origin_lanes_resolve_to_one_authenticated_result_pr_target
    input = issue_to_pr_with_qa_lane_input
    issue = {
      "host" => "github.com",
      "repo" => "shakacode/hichee",
      "type" => "issue",
      "number" => 9_521
    }
    expected_target = input.fetch("expected_targets").first
    projection_verifier_calls = 0
    projection_verifier = lambda do |source:, target:|
      projection_verifier_calls += 1
      next unless source == issue && target == input.fetch("expected_targets").first

      issue_projection_proof(source:, target:)
    end

    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      target_projection_verifier: projection_verifier
    )

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal 1, projection_verifier_calls
    assert_equal [expected_target], result.fetch("targets")
    lanes = result.dig("snapshot", "coordination", "lanes")
    assert_equal(%w[issue-9521 qa-issue-9521], lanes.map { |lane| lane.fetch("name") })
    assert(lanes.all? { |lane| lane.fetch("target") == expected_target })
    assert_equal([issue, issue], lanes.map { |lane| lane.dig("target_projection", "source_target") })
    assert_equal(%w[closes_issue closes_issue],
                 lanes.map { |lane| lane.dig("target_projection", "relationship") })
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_duplicate_direct_target_lanes_remain_blocked
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lanes = input.dig("coordination_status", "batches", 0, "lanes")
    duplicate = JSON.parse(JSON.generate(lanes.first))
    duplicate["name"] = "hc-b-10049-duplicate"
    lanes << duplicate

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 appears in multiple coordination lanes"
  end

  def test_later_closed_no_pr_issue_preserves_auxiliary_qa_lane_without_publishing_adhoc_target
    input = later_closed_no_pr_with_auxiliary_qa_lane_input

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal input.fetch("expected_targets"), result.fetch("targets")
    lanes = result.dig("snapshot", "coordination", "lanes")
    assert_equal(%w[issue-10235 issue-10235-qa], lanes.map { |lane| lane.fetch("name") })
    assert_equal([nil, "adhoc:hc-a06-issue10235-qa"], lanes.map { |lane| lane["coordination_target"] })
    assert(lanes.all? { |lane| lane.fetch("target") == input.fetch("expected_targets").first })
    assert lanes.all? do |lane|
      lane.fetch("completion_mode") == "authenticated_issue_closure_after_no_pr_closeout"
    end
    assert_equal false, lanes.last.fetch("publication_target")
    assert_equal "NOT_APPLICABLE", result.dig("snapshot", "qa", 0, "verdict")
    assert_nil result.dig("snapshot", "qa", 0, "head_sha")
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
    assert CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      evidence_comment_verifier: valid_evidence_comment_verifier(input),
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_auxiliary_qa_lane_cannot_replace_the_publication_target_lane
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    input.dig("coordination_status", "batches", 0, "lanes").shift

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 is absent from resolved coordination scope"
  end

  def test_auxiliary_qa_lane_must_bind_its_evidence_to_the_expected_issue
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    qa_lane = input.dig("coordination_status", "batches", 0, "lanes", 1)
    qa_lane["evidence_url"] = qa_lane.fetch("evidence_url").sub("10235", "10236")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane issue-10235-qa target is absent or ambiguous"
  end

  def test_auxiliary_qa_lane_must_share_the_primary_lane_evidence_comment
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    qa_lane = input.dig("coordination_status", "batches", 0, "lanes", 1)
    qa_lane["evidence_url"] = qa_lane.fetch("evidence_url").sub("5384964861", "5384964862")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane issue-10235-qa target is absent or ambiguous"
  end

  def test_unrelated_adhoc_lane_cannot_masquerade_as_auxiliary_qa_by_copying_evidence
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    unrelated_lane = input.dig("coordination_status", "batches", 0, "lanes", 1)
    unrelated_lane["name"] = "unrelated-operations"
    unrelated_lane["targets"] = ["adhoc:hc-a06-unrelated-operations"]

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane unrelated-operations target is absent or ambiguous"
  end

  def test_auxiliary_lane_requires_an_exact_trusted_mapping
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    input.delete("auxiliary_lane_map")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane issue-10235-qa target is absent or ambiguous"
  end

  def test_auxiliary_lane_rejects_mismatched_trusted_mapping_fields
    mutations = {
      "coordination target" => lambda do |mapping|
        mapping["coordination_target"] = "adhoc:hc-a06-other-qa"
      end,
      "parent target" => lambda do |mapping|
        mapping.fetch("parent_target")["number"] = 10_236
      end,
      "role" => lambda do |mapping|
        mapping["role"] = "operations"
      end
    }

    mutations.each do |label, mutate|
      input = later_closed_no_pr_with_auxiliary_qa_lane_input
      mutate.call(input.dig("auxiliary_lane_map", "lanes", 0))

      result = assess_input(input)

      refute result.fetch("eligible"), label
      assert_includes result.fetch("blockers"),
                      "coordination lane issue-10235-qa target is absent or ambiguous",
                      label
    end
  end

  def test_no_pr_lanes_require_authenticated_existing_evidence_comment
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    forged_url = "https://github.com/shakacode/hichee/issues/10235#issuecomment-999999999999999999"
    input.dig("coordination_status", "batches", 0, "lanes").each do |lane|
      lane["evidence_url"] = forged_url
    end

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 coordination lane issue-10235 terminal evidence comment " \
                    "is not authenticated or fresh"
  end

  def test_no_pr_evidence_comment_verification_fails_closed_when_comment_is_missing
    input = later_closed_no_pr_with_auxiliary_qa_lane_input

    result = assess_input(input, evidence_comment_verifier: ->(**) {})

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 coordination lane issue-10235 terminal evidence comment " \
                    "is not authenticated or fresh"
  end

  def test_no_pr_evidence_comment_requires_exact_authenticated_identity
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    valid_verifier = valid_evidence_comment_verifier(input)
    mutations = {
      "id" => ->(comment) { comment["id"] += 1 },
      "html_url" => ->(comment) { comment["html_url"] = comment.fetch("html_url").sub("10235", "10236") },
      "issue_url" => ->(comment) { comment["issue_url"] = comment.fetch("issue_url").sub("10235", "10236") }
    }

    mutations.each do |label, mutate|
      verifier = lambda do |host:, repo:, comment_id:|
        comment = JSON.parse(JSON.generate(valid_verifier.call(host:, repo:, comment_id:)))
        mutate.call(comment)
        comment
      end

      result = assess_input(input, evidence_comment_verifier: verifier)

      refute result.fetch("eligible"), label
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#issue:10235 coordination lane issue-10235 terminal evidence comment " \
                      "is not authenticated or fresh",
                      label
    end
  end

  def test_no_pr_evidence_comment_verification_is_memoized_per_comment
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    valid_verifier = valid_evidence_comment_verifier(input)
    calls = 0
    verifier = lambda do |**keywords|
      calls += 1
      valid_verifier.call(**keywords)
    end

    result = assess_input(input, evidence_comment_verifier: verifier)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal 1, calls
  end

  def test_no_pr_evidence_comment_is_reauthenticated_during_reassessment
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    receipt = assess_input(input)
    assert receipt.fetch("eligible")

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      receipt,
      coordination_backend: BACKEND,
      evidence_comment_verifier: ->(**) {},
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_auxiliary_qa_lane_rejects_public_url_fields_or_non_later_closure
    with_url = later_closed_no_pr_with_auxiliary_qa_lane_input
    with_url.dig("coordination_status", "batches", 0, "lanes", 1)["issue_url"] =
      "https://github.com/shakacode/hichee/issues/10235"
    with_url_result = assess_input(with_url)
    refute with_url_result.fetch("eligible")
    assert_includes with_url_result.fetch("blockers"),
                    "coordination lane issue-10235-qa target is absent or ambiguous"

    non_later = later_closed_no_pr_with_auxiliary_qa_lane_input
    non_later.fetch("target_snapshots").first["completed_at"] = "2026-08-23T08:05:03Z"
    non_later_result = assess_input(non_later)
    refute non_later_result.fetch("eligible")
    assert_includes non_later_result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 coordination target state is not closed"
  end

  def test_auxiliary_qa_lane_does_not_authorize_head_bound_no_pr_qa
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    qa = input.fetch("qa_evidence").first
    fabricated_head = "a" * 40
    qa["evidence"] = qa.fetch("evidence")
                       .sub("required: no", "required: yes")
                       .sub("status: not_applicable", "status: satisfied")
                       .sub("head_sha: not_applicable", "head_sha: #{fabricated_head}")
                       .sub("release_blocking: not_applicable", "release_blocking: clear")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 QA evidence contradicts typed no-PR disposition"
  end

  def test_auxiliary_qa_lane_disappearance_invalidates_receipt_reassessment
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    receipt = assess_input(input)
    refreshed_status = JSON.parse(JSON.generate(input.fetch("coordination_status")))
    refreshed_status.dig("batches", 0, "lanes").pop

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      receipt,
      coordination_backend: BACKEND,
      evidence_comment_verifier: valid_evidence_comment_verifier(input),
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: lambda do |backend:, batch_id:|
        refreshed_status if backend == BACKEND && batch_id == input.fetch("batch_id")
      end
    )
  end

  def test_done_lane_requires_no_pr_evidence_state_for_later_issue_closure_reconciliation
    input = later_closed_no_pr_with_auxiliary_qa_lane_input
    input.dig("coordination_status", "batches", 0, "lanes", 0)["pr_state"] = "open"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 coordination and target state disagree"
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10235 coordination target state is not closed"
  end

  def test_direct_lane_target_must_match_coordination_batch_repo
    target = {
      "host" => "github.com",
      "repo" => "acme/other",
      "type" => "pull_request",
      "number" => 7
    }
    lane = {
      "pr_url" => "https://github.com/acme/other/pull/7",
      "targets" => ["7"]
    }

    assert_empty CompletedBatchPublicationPreflight.targets_for_lane(
      lane,
      "acme/batch",
      [target]
    )

    lane.delete("targets")
    assert_empty CompletedBatchPublicationPreflight.targets_for_lane(
      lane,
      "acme/batch",
      [target]
    )
  end

  def test_authenticated_projection_requires_symmetric_github_relationships
    input = issue_to_pr_with_qa_lane_input
    target = input.fetch("expected_targets").first
    source = {
      "host" => "github.com",
      "repo" => target.fetch("repo"),
      "type" => "issue",
      "number" => 9_521
    }
    payload = issue_projection_graphql_payload(source:, target:)
    original = CompletedBatchPublicationPreflight.method(:authenticated_gh_graphql)
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **_arguments|
      payload
    end

    proof = CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)

    assert_equal issue_projection_proof(source:, target:), proof

    mismatched_closed_at = issue_projection_graphql_payload(source:, target:)
    mismatched_closed_at.dig(
      "data", "repository", "result", "closingIssuesReferences", "nodes", 0
    )["closedAt"] = "2026-08-24T00:42:34Z"
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **_arguments|
      mismatched_closed_at
    end
    assert_nil CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)

    asymmetric = issue_projection_graphql_payload(source:, target:, include_reverse: false)
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **_arguments|
      asymmetric
    end
    assert_nil CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql, &original) if original
  end

  def test_authenticated_projection_accepts_canonical_repository_url_casing
    input = issue_to_pr_with_qa_lane_input
    target = input.fetch("expected_targets").first
    source = {
      "host" => "github.com",
      "repo" => target.fetch("repo"),
      "type" => "issue",
      "number" => 9_521
    }
    payload = issue_projection_graphql_payload(source:, target:)
    canonical_repo = "ShakaCode/HiChee"
    repository = payload.dig("data", "repository")
    repository.fetch("result")["url"] = "https://github.com/#{canonical_repo}/pull/#{target.fetch('number')}"
    repository.fetch("source")["url"] = "https://github.com/#{canonical_repo}/issues/#{source.fetch('number')}"
    issue_node = repository.dig("result", "closingIssuesReferences", "nodes", 0)
    issue_node["url"] = repository.fetch("source").fetch("url")
    issue_node["repository"]["nameWithOwner"] = canonical_repo
    pr_node = repository.dig("source", "closedByPullRequestsReferences", "nodes", 0)
    pr_node["url"] = repository.fetch("result").fetch("url")
    pr_node["repository"]["nameWithOwner"] = canonical_repo
    original = CompletedBatchPublicationPreflight.method(:authenticated_gh_graphql)
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **_arguments|
      payload
    end

    proof = CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)

    assert_equal issue_projection_proof(source:, target:), proof
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql, &original) if original
  end

  def test_authenticated_projection_paginates_both_relationships_and_rejects_a_repeated_cursor
    input = issue_to_pr_with_qa_lane_input
    target = input.fetch("expected_targets").first
    source = {
      "host" => "github.com",
      "repo" => target.fetch("repo"),
      "type" => "issue",
      "number" => 9_521
    }
    first_page = issue_projection_graphql_payload(source:, target:, include_forward: false, include_reverse: false)
    first_page.dig("data", "repository", "result", "closingIssuesReferences", "pageInfo").merge!(
      "hasNextPage" => true,
      "endCursor" => "result-page-1"
    )
    first_page.dig("data", "repository", "source", "closedByPullRequestsReferences", "pageInfo").merge!(
      "hasNextPage" => true,
      "endCursor" => "source-page-1"
    )
    pages = [first_page, issue_projection_graphql_payload(source:, target:)]
    variables = []
    original = CompletedBatchPublicationPreflight.method(:authenticated_gh_graphql)
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **arguments|
      variables << arguments.fetch(:variables)
      pages.shift
    end

    proof = CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)

    assert_equal issue_projection_proof(source:, target:), proof
    assert_nil variables.first["resultCursor"]
    assert_nil variables.first["sourceCursor"]
    assert_equal "result-page-1", variables.last.fetch("resultCursor")
    assert_equal "source-page-1", variables.last.fetch("sourceCursor")

    repeated = issue_projection_graphql_payload(source:, target:, include_forward: false, include_reverse: false)
    repeated.dig("data", "repository", "result", "closingIssuesReferences", "pageInfo").merge!(
      "hasNextPage" => true,
      "endCursor" => "same-result-cursor"
    )
    repeated.dig("data", "repository", "source", "closedByPullRequestsReferences", "pageInfo").merge!(
      "hasNextPage" => true,
      "endCursor" => "same-source-cursor"
    )
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql) do |_host, **_arguments|
      repeated
    end
    assert_nil CompletedBatchPublicationPreflight.authenticated_target_projection(source:, target:)
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:authenticated_gh_graphql, &original) if original
  end

  def test_issue_origin_projection_disappearing_on_reassessment_blocks_receipt
    input = issue_to_pr_with_qa_lane_input
    receipt = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      target_projection_verifier: ->(source:, target:) { issue_projection_proof(source:, target:) }
    )
    assert receipt.fetch("eligible")

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      receipt,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      target_projection_verifier: ->(source:, target:) {}
    )
  end

  def test_issue_origin_pr_url_alone_or_mismatched_projection_head_cannot_resolve_scope
    input = issue_to_pr_with_qa_lane_input
    without_projection = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
    refute without_projection.fetch("eligible")
    assert_includes without_projection.fetch("blockers"),
                    "coordination lane issue-9521 target is absent or ambiguous"
    assert_includes without_projection.fetch("blockers"),
                    "coordination lane qa-issue-9521 target is absent or ambiguous"

    mismatched_head = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      target_projection_verifier: lambda do |source:, target:|
        issue_projection_proof(source:, target:, head_sha: "f" * 40)
      end
    )
    refute mismatched_head.fetch("eligible")
    assert_includes mismatched_head.fetch("blockers"),
                    "shakacode/hichee#pull_request:10299 projected result facts disagree with authenticated target"
  end

  def test_each_lane_role_must_remain_terminal_after_projection
    input = issue_to_pr_with_qa_lane_input
    input.dig("coordination_status", "batches", 0, "lanes", 1)["status"] = "in_progress"
    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      target_projection_verifier: ->(source:, target:) { issue_projection_proof(source:, target:) }
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10299 coordination lane is nonterminal"
    assert_equal 2, result.dig("snapshot", "coordination", "lanes").length
  end

  def test_abandoned_or_superseded_lane_accepts_later_authenticated_target_completion_without_rewriting_closeout
    %w[abandoned superseded].each do |terminal_state|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      lane = input.dig("coordination_status", "batches", 0, "lanes")
                  .find { |row| row.fetch("targets") == ["10048"] }
      lane["status"] = terminal_state
      lane["terminal"] = terminal_state
      lane.delete("pr_state")
      lane.delete("evidence_url")

      result = assess_input(input)

      assert result.fetch("eligible"), result.fetch("blockers").join("\n")
      reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                              .find { |row| row.dig("target", "number") == 10_048 }
      assert_equal terminal_state, reconciled_lane.fetch("status")
      assert_equal terminal_state, reconciled_lane.fetch("terminal")
      assert_equal "authenticated_target_after_coordination_closeout",
                   reconciled_lane.fetch("completion_mode")
      reconciled_target = result.dig("snapshot", "targets")
                                .find { |row| row.dig("target", "number") == 10_048 }
      assert_equal "2026-08-01T00:00:00Z", reconciled_target.fetch("completed_at")
      assert_nil reconciled_lane.fetch("target_state")
      assert_nil reconciled_lane.fetch("evidence")
    end
  end

  def test_abandoned_issue_lane_accepts_later_authenticated_close
    input = no_pr_input
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10036"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_036 }
    assert_equal "issue", reconciled_lane.dig("target", "type")
    assert_equal "authenticated_target_after_coordination_closeout",
                 reconciled_lane.fetch("completion_mode")
  end

  def test_abandoned_lane_stays_blocked_when_target_is_not_later_completed
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["state"] = "open"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10048 target is not merged"
  end

  def test_abandoned_lane_stays_blocked_when_target_completed_before_coordination_closeout
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["completed_at"] = "2026-07-30T08:43:03Z"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_048 }
    refute reconciled_lane.key?("completion_mode")
  end

  def test_abandoned_lane_cannot_reuse_pre_closeout_coordination_state_and_evidence
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["completed_at"] = "2026-07-30T08:43:03Z"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target completion is not authenticated after " \
                    "coordination closeout"
  end

  def test_abandoned_lane_preserves_historical_open_state_when_target_later_authenticates_as_merged
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane["pr_state"] = "open"
    lane.delete("evidence_url")

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_048 }
    assert_equal "open", reconciled_lane.fetch("target_state")
    assert_equal "authenticated_target_after_coordination_closeout",
                 reconciled_lane.fetch("completion_mode")
  end

  def test_authenticated_target_completion_does_not_rescue_nonterminal_lane
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "in_progress"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination lane is nonterminal"
    refute_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target completion is not authenticated after " \
                    "coordination closeout"
  end

  def test_abandoned_lane_stays_blocked_without_authenticated_target_completion
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input, target_verifier: ->(target:) {})

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target state/head is not authenticated or fresh"
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
  end

  def test_authenticated_target_completion_does_not_rescue_invalid_terminal_timestamp
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane["closed_at"] = nil
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination lane is nonterminal"
  end

  def test_done_lane_still_requires_coordination_terminal_evidence
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination terminal evidence is absent"
  end

  def test_assess_fails_closed_without_live_target_and_coordination_verifiers
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input)
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "coordination status is not authenticated or fresh"
    input.fetch("expected_targets").each do |target|
      assert_includes result.fetch("blockers"),
                      "#{target.fetch('repo')}##{target.fetch('type')}:#{target.fetch('number')} " \
                      "target state/head is not authenticated or fresh"
    end
  end

  def test_snapshot_is_deterministic_under_source_array_reordering
    input = fixture("completed-batch-publication-hichee-terminal.json")
    baseline = assess_input(input)
    input.fetch("expected_targets").reverse!
    input.fetch("target_snapshots").rotate!
    input.fetch("qa_evidence").reverse!
    input.dig("coordination_status", "batches", 0, "lanes").rotate!
    replay = assess_input(input)

    assert_equal baseline.fetch("snapshot"), replay.fetch("snapshot")
    assert_equal baseline.fetch("snapshot_digest"), replay.fetch("snapshot_digest")
  end

  def test_receipt_binds_the_exact_raw_source_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)

    assert_equal CompletedBatchPublicationPreflight.canonicalize(input), result.fetch("source_input")
    assert_equal BACKEND, result.fetch("coordination_backend")
    assert_equal BACKEND, result.dig("snapshot", "coordination_backend")
    assert_equal CompletedBatchPublicationPreflight.digest(result.fetch("source_input")),
                 result.fetch("source_input_digest")
  end

  def test_reassessment_rejects_altered_raw_input_even_with_recomputed_digests
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    result.dig("source_input", "target_snapshots", 0)["head_sha"] = "b" * 40
    result["source_input_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("source_input"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_reassessment_rejects_source_input_coordination_mode_mismatch_with_recomputed_digests
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    result.fetch("source_input")["coordination_status"] = no_backend_input.fetch("coordination_status")
    result["source_input_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("source_input"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    assert CompletedBatchPublicationPreflight.valid_receipt?(result),
           "integrity digests alone must not authenticate the source-input backend mode"
    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_reassessment_rejects_trusted_backend_mismatch_before_live_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    target_calls = []
    coordination_calls = []

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: "n/a",
      waiver_verifier: ->(**) { flunk "waiver verifier must not run" },
      target_verifier: lambda { |**args|
        target_calls << args
        flunk "target verifier must not run"
      },
      coordination_verifier: lambda { |**args|
        coordination_calls << args
        flunk "coordination verifier must not run"
      }
    )
    assert_empty target_calls
    assert_empty coordination_calls
  end

  def test_unknown_and_in_progress_qa_block_completion
    %w[unknown in_progress].each do |status|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      qa = input.fetch("qa_evidence").first
      qa["evidence"] = qa.fetch("evidence")
                         .sub("status: satisfied", "status: #{status}")
                         .sub("release_blocking: clear", "release_blocking: blocked")
      result = assess_input(input)

      refute result.fetch("eligible"), status
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10049 QA disposition is #{status}", status
    end
  end

  def test_trusted_current_ui_classification_requires_visual_evidence_v2
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
    qa = input.fetch("qa_evidence").first
    qa["user_visible_ui_change"] = "yes"
    qa["evidence"] = qa.fetch("evidence").sub(
      "scope: PR #10049 exact-head checks",
      "scope: current user-visible UI change"
    )

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA disposition is UNKNOWN"
    snapshot = result.dig("snapshot", "qa").find { |row| row.dig("target", "number") == 10_049 }
    assert_equal "yes", snapshot.fetch("user_visible_ui_change")
    assert_equal "UNKNOWN", snapshot.fetch("verdict")
  end

  def test_visual_evidence_v2_must_match_the_trusted_ui_classification
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
    qa = input.fetch("qa_evidence").first
    qa["user_visible_ui_change"] = "yes"
    head_sha = input.fetch("target_snapshots").first.fetch("head_sha")
    qa["evidence"] = qa_v2_evidence(head_sha:, user_visible_ui_change: "no")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA UI classification contradicts trusted input"
  end

  def test_non_ui_v1_remains_eligible_and_v2_must_not_self_classify_as_ui
    input = fixture("completed-batch-publication-hichee-terminal.json")
    v1_result = assess_input(input)

    assert v1_result.fetch("eligible"), v1_result.fetch("blockers").join("\n")
    assert_equal(
      ["no"] * 4,
      v1_result.dig("snapshot", "qa").map { |row| row.fetch("user_visible_ui_change") }
    )

    qa = input.fetch("qa_evidence").first
    head_sha = input.fetch("target_snapshots").first.fetch("head_sha")
    qa["evidence"] = qa_v2_evidence(head_sha:, user_visible_ui_change: "yes")
    v2_result = assess_input(input)

    refute v2_result.fetch("eligible")
    assert_includes v2_result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA UI classification contradicts trusted input"
  end

  def test_missing_or_invalid_trusted_ui_classification_blocks
    [nil, "true", true, "YES", "UNKNOWN"].each do |classification|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
      qa = input.fetch("qa_evidence").first
      if classification.nil?
        qa.delete("user_visible_ui_change")
      else
        qa["user_visible_ui_change"] = classification
      end

      result = assess_input(input)

      refute result.fetch("eligible"), classification.inspect
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10049 trusted QA UI classification is absent or invalid",
                      classification.inspect
    end
  end

  def test_closed_issue_without_pr_uses_typed_no_pr_evidence_instead_of_a_fabricated_sha
    input = no_pr_input
    number = 10_036
    snapshot = input.fetch("target_snapshots").find { |row| row.dig("target", "number") == number }

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    issue_snapshot = result.dig("snapshot", "targets").find { |row| row.dig("target", "number") == number }
    assert_nil issue_snapshot.fetch("head_sha")
    assert_equal snapshot.fetch("no_pr_evidence"), issue_snapshot.fetch("no_pr_evidence")
    issue_qa = result.dig("snapshot", "qa").find { |row| row.dig("target", "number") == number }
    assert_equal "NOT_APPLICABLE", issue_qa.fetch("verdict")
  end

  def test_no_pr_issue_rejects_head_bound_satisfied_qa
    input = no_pr_input
    fabricated_head = "a" * 40
    qa = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_036 }
    qa["evidence"] = qa.fetch("evidence")
                       .sub("required: no", "required: yes")
                       .sub("status: not_applicable", "status: satisfied")
                       .sub("head_sha: not_applicable", "head_sha: #{fabricated_head}")
                       .sub(
                         "tested_at: issue #10036 closed with no implementation PR",
                         "tested_at: PR/head #{fabricated_head}"
                       )
                       .sub("release_blocking: not_applicable", "release_blocking: clear")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10036 QA evidence contradicts typed no-PR disposition"
  end

  def test_no_pr_evidence_fails_closed_for_forged_url_target_or_rationale
    mutations = [
      ->(evidence) { evidence["url"] = evidence.fetch("url").sub("10036", "10048") },
      ->(evidence) { evidence.fetch("target")["number"] = 10_048 },
      ->(evidence) { evidence["rationale"] = "UNKNOWN" }
    ]

    mutations.each_with_index do |mutate, index|
      input = no_pr_input
      evidence = input.fetch("target_snapshots")
                      .find { |row| row.dig("target", "number") == 10_036 }
                      .fetch("no_pr_evidence")
      mutate.call(evidence)

      result = assess_input(input)

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#issue:10036 no-PR evidence is invalid or inconsistent",
                      index
    end
  end

  def test_waived_qa_requires_replayable_maintainer_waiver
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").last.delete("maintainer_waiver")
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
  end

  def test_forged_nonexistent_maintainer_waiver_comment_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    qa = input.fetch("qa_evidence").find { |row| row.key?("maintainer_waiver") }
    original_url = qa.dig("maintainer_waiver", "url")
    forged_url = "https://github.com/shakacode/hichee/pull/10026#issuecomment-999999999999999999"
    qa["evidence"] = qa.fetch("evidence").sub(original_url, forged_url)
    qa["maintainer_waiver"] = { "url" => forged_url }

    result = assess_input(input, waiver_verifier: ->(**_keywords) {})

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
  end

  def test_checker_reported_nonexistent_comment_and_caller_asserted_metadata_block
    input = fixture("completed-batch-publication-hichee-terminal.json")
    formerly_waived = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_026 }
    satisfied_evidence = formerly_waived.fetch("evidence").sub("status: waived", "status: satisfied")
    satisfied_evidence = satisfied_evidence.sub(/findings: waived: .+/, "findings: none")
    satisfied_evidence = satisfied_evidence.sub("release_blocking: waived", "release_blocking: clear")
    formerly_waived["evidence"] = satisfied_evidence
    formerly_waived.delete("maintainer_waiver")

    forged_url = "https://github.com/shakacode/hichee/issues/10036#issuecomment-999999999999999999"
    newly_waived = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_036 }
    waived_evidence = newly_waived.fetch("evidence").sub("status: satisfied", "status: waived")
    waived_evidence = waived_evidence.sub("findings: none", "findings: waived: #{forged_url}")
    waived_evidence = waived_evidence.sub("release_blocking: clear", "release_blocking: waived")
    newly_waived["evidence"] = waived_evidence
    newly_waived["maintainer_waiver"] = {
      "url" => forged_url,
      "author" => "fabricated-maintainer",
      "author_association" => "MEMBER",
      "body_sha256" => "f" * 64
    }

    result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10036 maintainer QA waiver is not replayable"
  end

  def test_authenticated_waiver_comment_metadata_and_marker_mismatches_block
    mutations = [
      ->(comment) { comment["id"] += 1 },
      ->(comment) { comment["html_url"] = comment.fetch("html_url").sub("5000000000", "5000000001") },
      ->(comment) { comment["issue_url"] = comment.fetch("issue_url").sub("10026", "10036") },
      ->(comment) { comment["author_association"] = "NONE" },
      ->(comment) { comment.fetch("user")["type"] = "Bot" },
      ->(comment) { comment["body"] = comment.fetch("body").sub("decision: waived", "decision: denied") },
      ->(comment) { comment["body"] = comment.fetch("body").sub("57e048ed", "67e048ed") },
      ->(comment) { comment["body"] = comment.fetch("body").sub("/pull/10026", "/pull/10036") }
    ]

    mutations.each_with_index do |mutate, index|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
      comment = valid_waiver_comment(row, input)
      mutate.call(comment)
      result = assess_input(input, waiver_verifier: ->(**_keywords) { comment })

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable",
                      index
    end
  end

  def test_eligible_waiver_receipt_requires_an_authenticated_comment_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    receipt = assess_input(input)

    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: ->(**_keywords) {}
    )
    assert CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: valid_waiver_verifier(input)
    )

    changed_comment = valid_waiver_comment(input.fetch("qa_evidence").last, input)
    changed_comment["body"] = "#{changed_comment.fetch('body')}\nEdited after publication.\n"
    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: ->(**_keywords) { changed_comment }
    )
  end

  def test_malformed_waiver_url_returns_false_instead_of_raising_during_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    receipt = assess_input(input)
    receipt.dig("snapshot", "qa", 0, "maintainer_waiver")["url"] = "https://[malformed"
    receipt["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(receipt.fetch("snapshot"))
    receipt["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      receipt.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: valid_waiver_verifier(input)
    )
  end

  def test_expected_target_absent_from_coordination_scope_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.dig("coordination_status", "batches", 0, "lanes").pop
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 is absent from resolved coordination scope"
  end

  def test_conflicting_lane_url_and_target_identity_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes", 0)
    lane["targets"] = ["10026"]
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane hc-b-10049 target is absent or ambiguous"
  end

  def test_eligible_receipt_requires_a_nonempty_valid_target_set
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))
    result["targets"] = []
    result["snapshot"]["targets"] = []
    result["snapshot"]["qa"] = []
    result["snapshot"]["coordination"]["lanes"] = []
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_recomputed_eligible_receipt_cannot_omit_coordination_and_qa_rows
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))
    result.dig("snapshot", "coordination")["lanes"] = []
    result["snapshot"]["qa"] = []
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_no_backend_single_operator_path_accepts_typed_durable_evidence
    result = assess_input(no_backend_input, backend: "n/a")

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "not_applicable", result.dig("snapshot", "coordination", "status")
    assert_equal "single_operator", result.dig("snapshot", "coordination", "not_applicable", "mode")
  end

  def test_no_backend_path_rejects_missing_or_malformed_typed_evidence
    mutations = [
      ->(proof) { proof.delete("rationale") },
      ->(proof) { proof["source"] = "not a durable URL" },
      ->(proof) { proof.fetch("targets").pop },
      ->(proof) { proof["mode"] = "multi_operator" },
      ->(proof) { proof["completed_at"] = "not-a-timestamp" }
    ]

    mutations.each_with_index do |mutate, index|
      input = no_backend_input
      mutate.call(input.fetch("coordination_status"))
      result = assess_input(input, backend: "n/a")

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "typed no-backend coordination evidence is absent or invalid",
                      index
    end
  end

  def test_cli_reads_the_repository_coordination_backend_seam
    input = fixture("completed-batch-publication-hichee-terminal.json")
    with_fake_waiver_gh(input) do |env|
      Tempfile.create(["agent-workflow", ".yml"]) do |config|
        config.write("coordination_backend: agent-coord private backend\n")
        config.flush
        out, err, status = Open3.capture3(
          env,
          "ruby",
          env.fetch("FAKE_PREFLIGHT_RUNNER"),
          "--workflow-config",
          config.path,
          "--input",
          File.join(FIXTURES, "completed-batch-publication-hichee-terminal.json")
        )

        assert status.success?, err
        result = JSON.parse(out)
        assert result.fetch("eligible")
        assert_equal "agent-coord private backend", result.dig("snapshot", "coordination_backend")
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_includes calls,
                        "api --hostname github.com repos/shakacode/hichee/pulls/10026"
        assert_includes calls,
                        "api --hostname github.com repos/shakacode/hichee/issues/comments/5000000000"
      end
    end
  end

  def test_cli_authenticated_waiver_comment_404_blocks_completion
    input = fixture("completed-batch-publication-hichee-terminal.json")
    row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
    original_url = row.dig("maintainer_waiver", "url")
    missing_url = "https://github.com/shakacode/hichee/pull/10026#issuecomment-999999999999999999"
    row["evidence"] = row.fetch("evidence").sub(original_url, missing_url)
    row["maintainer_waiver"] = { "url" => missing_url }

    with_fake_waiver_gh(input, mode: "not_found") do |env|
      Tempfile.create(["agent-workflow", ".yml"]) do |config|
        config.write("coordination_backend: agent-coord private backend\n")
        config.flush
        Tempfile.create(["preflight", ".json"]) do |preflight|
          preflight.write(JSON.generate(input))
          preflight.flush
          out, _err, status = Open3.capture3(
            env,
            "ruby",
            env.fetch("FAKE_PREFLIGHT_RUNNER"),
            "--workflow-config",
            config.path,
            "--input",
            preflight.path
          )

          assert_equal 1, status.exitstatus
          result = JSON.parse(out)
          refute result.fetch("eligible")
          assert_includes result.fetch("blockers"),
                          "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
          assert_includes(
            File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true),
            "api --hostname github.com repos/shakacode/hichee/issues/comments/999999999999999999"
          )
        end
      end
    end
  end

  def test_cli_waiver_author_requires_current_write_permission
    %w[read triage collaborator].each do |permission|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      with_fake_waiver_gh(input, author_permission: permission) do |env|
        Tempfile.create(["agent-workflow", ".yml"]) do |config|
          config.write("coordination_backend: agent-coord private backend\n")
          config.flush
          out, _err, status = Open3.capture3(
            env,
            "ruby",
            env.fetch("FAKE_PREFLIGHT_RUNNER"),
            "--workflow-config",
            config.path,
            "--input",
            File.join(FIXTURES, "completed-batch-publication-hichee-terminal.json")
          )

          assert_equal 1, status.exitstatus, permission
          result = JSON.parse(out)
          refute result.fetch("eligible"), permission
          assert_includes result.fetch("blockers"),
                          "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable",
                          permission
          assert_includes(
            File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true),
            "api --hostname github.com repos/shakacode/hichee/collaborators/justin808/permission",
            permission
          )
        end
      end
    end
  end
end
