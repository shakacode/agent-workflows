#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

load File.expand_path("completed-batch-audit-receipt", __dir__)

class CompletedBatchAuditReceiptTest < Minitest::Test
  SCRIPT = File.expand_path("completed-batch-audit-receipt", __dir__)

  def marker(body)
    "<!-- completed-batch-audit v1\n#{body.chomp}\n-->\n"
  end

  def ready_marker
    marker(<<~BODY)
      batch_id: batch-184
      audit_status: complete
      verdict: clean
      scope_evidence: targets #184; audit report
      checker_evidence: checker sol/xhigh; independent from every maker; report #184
      findings: none
      followups_dispositions: none
    BODY
  end

  def followup_marker
    marker(<<~BODY)
      batch_id: batch-184
      audit_status: blocked
      verdict: follow-ups-remain
      scope_evidence: targets #184; audit report
      checker_evidence: checker sol/xhigh; independent from every maker; report #184
      findings: OUTSTANDING #184
      followups_dispositions: ref: #184; owner: maintainer; current status: open; disposition: fix; evidence: issue #184
    BODY
  end

  def test_exact_v1_marker_replays_ready
    result = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184"
    )

    assert result.fetch("well_formed")
    assert result.fetch("ready")
    assert_empty result.fetch("blockers")
    assert_equal "clean", result.dig("fields", "verdict")
  end

  def test_external_blocker_union_forces_derived_readiness_false
    result = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184",
      other_blockers: [" release owner confirmation "]
    )

    assert result.fetch("well_formed")
    refute result.fetch("ready")
    assert_equal ["release owner confirmation"], result.fetch("blockers")
    assert_equal(
      "Conversation status: Follow-ups remain — release owner confirmation.",
      CompletedBatchAuditReceipt.final_status(result)
    )
  end

  def test_malformed_external_blockers_fail_closed_with_sanitized_label
    invalid_blockers = ["", "line\nbreak", "<!-- injected -->", 42]

    invalid_blockers.each do |blocker|
      result = CompletedBatchAuditReceipt.replay_marker(
        ready_marker,
        expected_batch_id: "batch-184",
        other_blockers: [blocker]
      )

      assert result.fetch("well_formed"), blocker.inspect
      refute result.fetch("ready"), blocker.inspect
      assert_equal(
        ["completed-batch-audit external blocker invalid"],
        result.fetch("blockers"),
        blocker.inspect
      )
    end

    mixed = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184",
      other_blockers: ["", " safe\towner ", "<!-- injected -->"]
    )
    assert_equal(
      ["completed-batch-audit external blocker invalid", "safe owner"],
      mixed.fetch("blockers")
    )
    refute_includes CompletedBatchAuditReceipt.final_status(mixed), "<!--"
  end

  def test_cli_malformed_external_blockers_never_make_clean_receipt_ready
    ["", "line\nbreak", "<!-- injected -->"].each do |blocker|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path,
          "--other-blocker",
          blocker
        )

        assert status.success?, "#{blocker.inspect}: #{err}"
        result = JSON.parse(out)
        assert result.fetch("well_formed"), blocker.inspect
        refute result.fetch("ready"), blocker.inspect
        assert_equal(
          ["completed-batch-audit external blocker invalid"],
          result.fetch("blockers"),
          blocker.inspect
        )
        assert_nil(result.fetch("chat_reference")[blocker]) unless blocker.empty?
      end
    end
  end

  def test_verified_human_login_accepts_only_matching_user_objects
    invalid_users = [
      { "login" => "justin808" },
      { "login" => "justin808", "type" => "UNKNOWN" },
      { "login" => "justin808", "type" => "Organization" }
    ]

    invalid_users.each do |user|
      assert_raises(CompletedBatchAuditReceipt::Error, user.inspect) do
        CompletedBatchAuditReceipt.verified_human_login!(user, context: "test actor")
      end
    end
    assert_raises(CompletedBatchAuditReceipt::Error) do
      CompletedBatchAuditReceipt.verified_human_login!(
        { "login" => "other-maintainer", "type" => "User" },
        context: "test actor",
        expected_login: "justin808"
      )
    end
    assert_equal "justin808", CompletedBatchAuditReceipt.verified_human_login!(
      { "login" => "justin808", "type" => "User" },
      context: "test actor",
      expected_login: "justin808"
    )
    ["justin.emu", "justin emu", "justin/emu"].each do |login|
      assert_raises(CompletedBatchAuditReceipt::Error, login) do
        CompletedBatchAuditReceipt.verified_human_login!(
          { "login" => login, "type" => "User" },
          context: "test actor"
        )
      end
    end
  end

  def test_cli_usage_errors_use_documented_exit
    _out, _err, status = Open3.capture3("ruby", SCRIPT)

    assert_equal 64, status.exitstatus
  end

  def test_cli_rejects_command_incompatible_input_options
    Dir.mktmpdir("completed-batch-audit-usage") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      reference_path = File.join(directory, "reference.txt")
      File.write(receipt_path, ready_marker)
      File.write(reference_path, "invalid reference")

      _out, _err, publish_status = Open3.capture3(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path,
        "--reference-file",
        reference_path
      )
      _out, _err, replay_status = Open3.capture3(
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--receipt",
        receipt_path
      )
      _out, _err, invalid_option_precedence_status = Open3.capture3(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        File.join(directory, "missing-targets.json"),
        "--receipt",
        receipt_path,
        "--reference-file",
        reference_path
      )

      assert_equal 64, publish_status.exitstatus
      assert_equal 64, replay_status.exitstatus
      assert_equal 64, invalid_option_precedence_status.exitstatus
    end
  end

  def test_missing_reference_file_is_structured_integrity_failure
    Dir.mktmpdir("completed-batch-audit-missing-reference") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      missing_reference = File.join(directory, "missing-reference.txt")

      out, _err, status = Open3.capture3(
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        missing_reference,
        "--other-blocker",
        " release owner confirmation ",
        "--other-blocker",
        "<!-- injected -->"
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal(
        [
          "completed-batch-audit marker invalid",
          "release owner confirmation",
          "completed-batch-audit external blocker invalid"
        ],
        result.fetch("blockers")
      )
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_missing_receipt_and_manifest_files_are_structured_integrity_failures
    Dir.mktmpdir("completed-batch-audit-missing-input") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      cases = {
        "receipt" => [
          "publish",
          "--expected-batch-id", "batch-184",
          "--targets-json", targets_path,
          "--receipt", File.join(directory, "missing-receipt.txt")
        ],
        "manifest" => [
          "publish",
          "--expected-batch-id", "batch-184",
          "--targets-json", File.join(directory, "missing-targets.json"),
          "--receipt", receipt_path
        ]
      }

      cases.each do |label, args|
        out, _err, status = Open3.capture3("ruby", SCRIPT, *args)

        assert_equal 1, status.exitstatus, label
        result = JSON.parse(out)
        refute result.fetch("well_formed"), label
        refute result.fetch("ready"), label
        assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers"), label
        assert_nil result.fetch("chat_reference"), label
      end
    end
  end

  def test_malformed_manifest_json_is_structured_integrity_failure
    Dir.mktmpdir("completed-batch-audit-malformed-manifest") do |directory|
      targets_path = File.join(directory, "targets.json")
      receipt_path = File.join(directory, "receipt.txt")
      File.write(targets_path, "{")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit marker invalid.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_missing_or_wrong_batch_fails_closed
    missing = CompletedBatchAuditReceipt.replay_marker("", expected_batch_id: "batch-184")
    wrong_batch = CompletedBatchAuditReceipt.replay_marker(ready_marker, expected_batch_id: "batch-185")

    [missing, wrong_batch].each do |result|
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
    end
  end

  def test_deterministic_anchor_prefers_prs_then_normalized_repo_and_number
    targets = [
      { "host" => "github.com", "repo" => "Zulu/Repo", "type" => "issue", "number" => 1 },
      { "host" => "github.com", "repo" => "Acme/Widgets", "type" => "pull_request", "number" => 9 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 4 }
    ]

    anchor = CompletedBatchAuditReceipt.deterministic_targets(targets).first

    assert_equal "pull_request", anchor.fetch("type")
    assert_equal 4, anchor.fetch("number")
  end

  def test_publish_anchor_selection_never_falls_through_first_deterministic_target
    targets = [
      { "host" => "github.com", "repo" => "zulu/widgets", "type" => "pull_request", "number" => 185 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    ]
    calls = []
    fake_api = lambda do |host, endpoint, method: "GET", input: nil|
      calls << [host, endpoint, method, input]
      case endpoint
      when "user"
        { "login" => "justin808", "type" => "User" }
      when "repos/acme/widgets/issues/184"
        {
          "number" => 184,
          "html_url" => "https://github.com/acme/widgets/pull/184",
          "locked" => true,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/issues/185"
        {
          "number" => 185,
          "html_url" => "https://github.com/zulu/widgets/pull/185",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/collaborators/justin808/permission"
        { "permission" => "write", "user" => { "login" => "justin808", "type" => "User" } }
      else
        flunk "unexpected API endpoint: #{endpoint}"
      end
    end

    error = nil
    with_stubbed_gh_api(fake_api) do
      error = assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.select_verified_anchor(targets)
      end
    end

    assert_equal "CompletedBatchAuditReceipt::AnchorVerificationError", error.class.name
    assert_equal [
      ["github.com", "user", "GET", nil],
      ["github.com", "repos/acme/widgets/issues/184", "GET", nil]
    ], calls
  end

  def test_target_host_validation_rejects_noncanonical_authorities
    invalid_hosts = [
      "https://github.com",
      "github.com/",
      ".github.com",
      "github..com",
      "-github.com",
      "github.com-",
      "github.com:0",
      "github.com:65536"
    ]

    invalid_hosts.each do |host|
      assert_raises(ArgumentError, host) do
        CompletedBatchAuditReceipt.deterministic_targets(
          [{ "host" => host, "repo" => "acme/widgets", "type" => "issue", "number" => 184 }]
        )
      end
    end
  end

  def test_readback_mutation_state_requires_positive_comment_id
    [nil, 0, -1, "not-an-id"].each do |comment_id|
      assert_raises(ArgumentError) do
        CompletedBatchAuditReceipt::PostReadbackError.new("invalid state", comment_id:)
      end
    end

    error = CompletedBatchAuditReceipt::PostReadbackError.new("valid state", comment_id: "9001")
    assert_equal 9001, error.comment_id
  end

  def test_typed_operational_errors_map_to_fixed_safe_blockers
    unsafe_message = "remote\n<!-- untrusted -->"
    cases = {
      CompletedBatchAuditReceipt::AnchorVerificationError.new(unsafe_message) =>
        "completed-batch-audit anchor verification failed",
      CompletedBatchAuditReceipt::ReplayGitHubApiError.new(unsafe_message) =>
        "completed-batch-audit replay GitHub API request failed",
      CompletedBatchAuditReceipt::PostOutcomeUnknownError.new(unsafe_message) =>
        "completed-batch-audit comment POST outcome unknown",
      CompletedBatchAuditReceipt::PostReadbackError.new(unsafe_message, comment_id: 9001) =>
        "completed-batch-audit comment readback verification failed"
    }

    cases.each do |error, expected|
      blocker = CompletedBatchAuditReceipt.failure_blocker(error)
      assert_equal expected, blocker
      refute_includes blocker, "untrusted"
    end
    assert_equal(
      "completed-batch-audit marker invalid",
      CompletedBatchAuditReceipt.failure_blocker(CompletedBatchAuditReceipt::Error.new(unsafe_message))
    )
  end

  def test_empty_manifest_fails_closed_without_post_or_fallback_issue_creation
    with_fake_gh do |env, directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit marker invalid.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      refute File.exist?(env.fetch("FAKE_GH_LOG"))
    end
  end

  def test_publish_posts_then_reads_back_before_emitting_compact_reference
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_empty result.fetch("blockers")
      reference = result.fetch("chat_reference")
      assert_includes reference, "Completed-batch audit: clean"
      assert_includes reference, "https://github.com/acme/widgets/pull/184#issuecomment-9001"
      assert_match(/SHA-256 `[0-9a-f]{64}`/, reference)
      refute_includes reference, "<!-- completed-batch-audit"

      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(1, calls.count { |call| call.include?("--method POST") })
      assert_operator(calls.index { |call| call.include?("--method POST") }, :<,
                      calls.index { |call| call.end_with?("repos/acme/widgets/issues/comments/9001") })
    end
  end

  def test_publish_accepts_the_documented_full_durable_comment_body
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      full_body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, full_body)

      out, err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert status.success?, err
      assert JSON.parse(out).fetch("ready")
      assert_equal full_body, File.read(env.fetch("FAKE_GH_BODY"))
    end
  end

  def test_publish_rejects_extra_visible_text_around_a_full_durable_comment_body
    ["unexpected preface\n%s", "%sunexpected suffix\n"].each do |format|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        full_body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, format(format, full_body))

        out, _err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus
        result = JSON.parse(out)
        refute result.fetch("well_formed")
        refute result.fetch("ready")
        assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
        refute File.exist?(env.fetch("FAKE_GH_LOG"))
      end
    end
  end

  def test_replay_fetches_exact_comment_id_and_verifies_reference_bindings
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))

      out, err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_empty result.fetch("blockers")
      assert_equal "Conversation status: Ready for archiving.", result.fetch("final_status")
      assert_equal JSON.parse(publish_out).fetch("chat_reference"), result.fetch("chat_reference")
    end
  end

  def test_replay_missing_remote_comment_remains_structured_exit_one
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      env["FAKE_GH_MODE"] = "readback-failure"
      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit replay GitHub API request failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit replay GitHub API request failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      refute result.key?("mutation_state")
    end
  end

  def test_cli_publish_and_replay_never_report_ready_with_external_blockers
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path,
        "--other-blocker",
        "release owner confirmation"
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("well_formed")
      refute published.fetch("ready")
      assert_equal ["release owner confirmation"], published.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — release owner confirmation.",
        published.fetch("final_status")
      )

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--other-blocker",
        "release owner confirmation"
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      refute replayed.fetch("ready")
      assert_equal ["release owner confirmation"], replayed.fetch("blockers")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
    end
  end

  def test_invalid_remote_reference_fails_closed_and_preserves_sanitized_external_blockers
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, _publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?
      reference = JSON.parse(publish_out).fetch("chat_reference")
      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, reference.sub(/SHA-256 `[0-9a-f]{64}`/, "SHA-256 `#{'0' * 64}`"))

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--other-blocker",
        " release owner confirmation ",
        "--other-blocker",
        "release owner confirmation"
      )

      refute status.success?
      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal ["completed-batch-audit marker invalid", "release owner confirmation"], result.fetch("blockers")
      assert_equal "Conversation status: Follow-ups remain — completed-batch-audit marker invalid; release owner confirmation.",
                   result.fetch("final_status")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_post_success_readback_failure_reports_ambiguous_mutation_without_retry
    with_fake_gh(mode: "readback-failure") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_equal 9001, result.fetch("comment_id")
      assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit comment readback verification failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(1, calls.count { |call| call.include?("--method POST") })
      assert_equal(1, calls.count { |call| call.end_with?("repos/acme/widgets/issues/comments/9001") })
    end
  end

  def test_post_success_invalid_readback_schema_is_a_remote_failure_not_usage
    %w[readback-invalid-json readback-array].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        assert_equal "comment-created-readback-unknown", result.fetch("mutation_state"), mode
        assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers"), mode
        assert_nil result.fetch("chat_reference"), mode
      end
    end
  end

  def test_ambiguous_post_outcome_has_distinct_state_without_comment_id_or_retry
    %w[post-nonzero post-timeout post-invalid-json post-array post-missing-id].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        assert_equal "comment-post-outcome-unknown", result.fetch("mutation_state"), mode
        refute result.key?("comment_id"), mode
        assert_equal ["completed-batch-audit comment POST outcome unknown"], result.fetch("blockers"), mode
        assert_equal(
          "Conversation status: Follow-ups remain — completed-batch-audit comment POST outcome unknown.",
          result.fetch("final_status"),
          mode
        )
        assert_nil result.fetch("chat_reference"), mode
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_equal 1, calls.count { |call| call.include?("--method POST") }, mode
        assert_equal 0, calls.count { |call| call.include?("issues/comments/") }, mode
      end
    end
  end

  def test_post_timeout_is_bounded_and_reaps_child_before_delayed_side_effect
    with_fake_gh(mode: "post-timeout") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_equal 1, status.exitstatus
      assert_operator elapsed, :<, 1.75
      child_pid = Integer(File.read(env.fetch("FAKE_GH_PID"), encoding: "UTF-8"), 10)
      assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.25
      sleep 0.05 while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      refute File.exist?(env.fetch("FAKE_GH_LATE_SIDE_EFFECT"))

      result = JSON.parse(out)
      assert_equal "comment-post-outcome-unknown", result.fetch("mutation_state")
      refute result.key?("comment_id")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      post_count = calls.count { |call| call.include?("--method POST") }
      assert_equal 1, post_count
    end
  end

  def test_compact_reference_preserves_explicit_github_enterprise_port
    reference = "Completed-batch audit: clean — " \
                "[durable v1 receipt](https://github.company.example:8443/acme/widgets/issues/184#issuecomment-9001); " \
                "SHA-256 `#{'a' * 64}`; author `maintainer`; " \
                "version `2026-07-18T18:00:00Z/2026-07-18T18:00:00Z`."

    parsed = CompletedBatchAuditReceipt.parse_reference(reference)

    assert_equal "github.company.example:8443", parsed.dig("target", "host")
    assert_equal "issue", parsed.dig("target", "type")
  end

  def test_publish_and_replay_canonicalize_explicit_default_https_port
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com:443", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      refute_includes published.fetch("chat_reference"), "github.com:443"

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      assert replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
    end
  end

  def test_publish_and_replay_adopt_api_canonical_repo_casing
    with_fake_gh(mode: "canonical-repo-case") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert_includes published.fetch("chat_reference"), "github.com/Acme/Widgets/pull/184#issuecomment-9001"
      assert_equal "Acme/Widgets", published.dig("receipt", "repo")

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_includes calls, "api --hostname github.com repos/Acme/Widgets/collaborators/justin808/permission"
      assert_includes calls, "api --hostname github.com repos/Acme/Widgets/issues/184/comments --method POST --input -"
      comment_read_count = calls.count { |call| call.end_with?("repos/Acme/Widgets/issues/comments/9001") }
      assert_equal 2, comment_read_count
    end
  end

  def test_target_payload_casing_exception_rejects_hostile_identity_changes
    target = { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    base = {
      "number" => 184,
      "html_url" => "https://github.com/Acme/Widgets/pull/184",
      "locked" => false,
      "pull_request" => {}
    }
    hostile_payloads = [
      base.merge("html_url" => "https://example.com/Acme/Widgets/pull/184"),
      base.merge("html_url" => "https://github.com/Acme/Other/pull/184"),
      base.merge("html_url" => "https://github.com/Acme/Widgets/issues/184"),
      base.merge("html_url" => "https://github.com/Acme/Widgets/pull/185"),
      base.merge("number" => 185)
    ]

    assert_equal "Acme/Widgets", CompletedBatchAuditReceipt.verify_target_payload!(base, target).fetch("repo")
    hostile_payloads.each do |payload|
      assert_raises(CompletedBatchAuditReceipt::Error, payload.fetch("html_url")) do
        CompletedBatchAuditReceipt.verify_target_payload!(payload, target)
      end
    end
  end

  def test_emu_login_with_underscore_round_trips_publish_and_replay
    with_fake_gh(mode: "emu-actor") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert_includes published.fetch("chat_reference"), "author `justin_emu`"

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      assert JSON.parse(replay_out).fetch("ready")
    end
  end

  def test_enterprise_issue_api_url_must_preserve_the_manifest_port
    target = {
      "host" => "github.company.example:8443",
      "repo" => "acme/widgets",
      "type" => "issue",
      "number" => 184
    }

    assert_raises(CompletedBatchAuditReceipt::Error) do
      CompletedBatchAuditReceipt.verify_issue_url!(
        "https://github.company.example:9443/api/v3/repos/acme/widgets/issues/184",
        target
      )
    end
  end

  def test_publish_rejects_a_different_but_valid_readback_body
    with_fake_gh(mode: "changed-valid-body") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers")
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_publish_rejects_bot_accounts_as_durable_receipt_authors
    with_fake_gh(mode: "bot-actor") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit anchor verification failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_rejects_authenticated_bot_object_with_human_login
    with_fake_gh(mode: "actor-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_failure_matrix_fails_closed_after_exactly_one_post
    %w[wrong-author association-none edited wrong-url wrong-issue-url malformed-body invalid-user].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        refute result.fetch("well_formed"), mode
        refute result.fetch("ready"), mode
        assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers"), mode
        assert_nil result.fetch("chat_reference"), mode
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_equal 1, calls.count { |call| call.include?("--method POST") }, mode
      end
    end
  end

  def test_publish_rejects_comment_bot_object_with_human_login
    with_fake_gh(mode: "comment-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_equal 9001, result.fetch("comment_id")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_replay_rejects_comment_bot_object_with_human_login
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      env["FAKE_GH_MODE"] = "comment-type-bot"
      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      refute result.key?("mutation_state")
    end
  end

  def test_replay_ignores_current_actor_permission_and_target_lock_state
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      File.write(env.fetch("FAKE_GH_LOG"), "")
      env["FAKE_GH_MODE"] = "replay-current-state-changed"
      out, err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_equal [
        "api --hostname github.com repos/acme/widgets/issues/comments/9001"
      ], File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
    end
  end

  def test_invalid_permission_schema_fails_closed_before_posting
    with_fake_gh(mode: "invalid-permission-user") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_rejects_permission_bot_object_with_human_login
    with_fake_gh(mode: "permission-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_issue_only_batch_can_anchor_and_replay_a_verified_nonready_receipt
    with_fake_gh(target_type: "issue") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "issue", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, followup_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("well_formed")
      refute published.fetch("ready")
      assert_equal ["#184 (open): fix"], published.fetch("blockers")
      assert_includes published.fetch("chat_reference"), "/issues/184#issuecomment-9001"
      assert_equal "Conversation status: Follow-ups remain — #184 (open): fix.", published.fetch("final_status")

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      refute replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
    end
  end

  def test_replay_binding_matrix_uses_only_the_manifest_and_exact_comment_endpoint
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      reference = JSON.parse(publish_out).fetch("chat_reference")
      variants = {
        "host" => reference.sub("github.com", "example.com"),
        "repo" => reference.sub("acme/widgets", "acme/other"),
        "type" => reference.sub("/pull/184", "/issues/184"),
        "number" => reference.sub("/pull/184", "/pull/185"),
        "id" => reference.sub("issuecomment-9001", "issuecomment-9002"),
        "result" => reference.sub("audit: clean", "audit: follow-ups-remain"),
        "version" => reference.sub(
          "2026-07-18T18:00:00Z/2026-07-18T18:00:00Z",
          "2026-07-18T18:00:01Z/2026-07-18T18:00:01Z"
        )
      }

      variants.each do |label, candidate|
        reference_path = File.join(directory, "#{label}.txt")
        File.write(reference_path, candidate)
        out, _err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "replay",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--reference-file",
          reference_path
        )
        assert_equal 1, status.exitstatus, label
        result = JSON.parse(out)
        refute result.fetch("well_formed"), label
        refute result.fetch("ready"), label
        assert_nil result.fetch("chat_reference"), label
      end

      log = File.read(env.fetch("FAKE_GH_LOG"), encoding: "UTF-8")
      refute_includes log, "https://"
      refute_match(%r{issues/comments(?:\s|$)}, log)
    end
  end

  def test_replay_rejects_noncanonical_verified_manifest_target_before_comment_readback
    targets = [
      { "host" => "github.com", "repo" => "zulu/widgets", "type" => "pull_request", "number" => 185 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    ]
    body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
    created_at = "2026-07-18T18:00:00Z"
    second_target_receipt = {
      "url" => "https://github.com/zulu/widgets/pull/185#issuecomment-9002",
      "sha256" => Digest::SHA256.hexdigest(body),
      "author" => "justin808",
      "created_at" => created_at,
      "updated_at" => created_at
    }
    reference = CompletedBatchAuditReceipt.compact_reference("clean", second_target_receipt)
    calls = []
    fake_api = lambda do |host, endpoint, method: "GET", input: nil|
      calls << [host, endpoint, method, input]
      case endpoint
      when "user"
        { "login" => "justin808", "type" => "User" }
      when "repos/acme/widgets/issues/184"
        {
          "number" => 184,
          "html_url" => "https://github.com/acme/widgets/pull/184",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/issues/185"
        {
          "number" => 185,
          "html_url" => "https://github.com/zulu/widgets/pull/185",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/acme/widgets/collaborators/justin808/permission",
           "repos/zulu/widgets/collaborators/justin808/permission"
        { "permission" => "write", "user" => { "login" => "justin808", "type" => "User" } }
      when "repos/zulu/widgets/issues/comments/9002"
        {
          "id" => 9002,
          "html_url" => second_target_receipt.fetch("url"),
          "issue_url" => "https://api.github.com/repos/zulu/widgets/issues/185",
          "user" => { "login" => "justin808", "type" => "User" },
          "author_association" => "MEMBER",
          "created_at" => created_at,
          "updated_at" => created_at,
          "body" => body
        }
      else
        flunk "unexpected API endpoint: #{endpoint}"
      end
    end

    with_stubbed_gh_api(fake_api) do
      assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.replay_reference(
          expected_batch_id: "batch-184",
          targets:,
          reference:
        )
      end
    end

    assert_empty calls
    refute(calls.any? { |_host, _endpoint, method, _input| method == "POST" })
  end

  def test_replay_github_api_failure_has_a_distinct_typed_error
    target = { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
    created_at = "2026-07-18T18:00:00Z"
    reference = CompletedBatchAuditReceipt.compact_reference(
      "clean",
      {
        "url" => "https://github.com/acme/widgets/pull/184#issuecomment-9001",
        "sha256" => Digest::SHA256.hexdigest(body),
        "author" => "justin808",
        "created_at" => created_at,
        "updated_at" => created_at
      }
    )
    failing_api = lambda do |_host, _endpoint, method: "GET", input: nil|
      flunk "unexpected non-GET request" unless method == "GET" && input.nil?

      raise CompletedBatchAuditReceipt::Error, "remote text must not become a blocker"
    end

    error = nil
    with_stubbed_gh_api(failing_api) do
      error = assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.replay_reference(
          expected_batch_id: "batch-184",
          targets: [target],
          reference:
        )
      end
    end

    assert_equal "CompletedBatchAuditReceipt::ReplayGitHubApiError", error.class.name
  end

  def write_json(directory, name, value)
    path = File.join(directory, name)
    File.write(path, JSON.generate(value))
    path
  end

  def with_stubbed_gh_api(callable)
    original = CompletedBatchAuditReceipt.method(:gh_api)
    CompletedBatchAuditReceipt.define_singleton_method(:gh_api, callable)
    yield
  ensure
    CompletedBatchAuditReceipt.define_singleton_method(:gh_api, original)
  end

  def with_fake_gh(mode: nil, target_type: "pull_request")
    Dir.mktmpdir("completed-batch-audit-receipt") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      gh = File.join(bin, "gh")
      File.write(gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        File.open(ENV.fetch("FAKE_GH_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
        args = ARGV.dup
        abort "expected api" unless args.shift == "api"
        if args[0] == "--hostname"
          args.shift
          host = args.shift
          abort "wrong host" unless host == "github.com"
        end
        endpoint = args.shift
        method = "GET"
        if (index = args.index("--method"))
          method = args.fetch(index + 1)
        end

        actor = if ENV["FAKE_GH_MODE"] == "bot-actor"
                  "automation[bot]"
                elsif ENV["FAKE_GH_MODE"] == "replay-current-state-changed"
                  "other-current-actor"
                elsif ENV["FAKE_GH_MODE"] == "emu-actor"
                  "justin_emu"
                else
                  "justin808"
                end
        durable_actor = ENV["FAKE_GH_MODE"] == "replay-current-state-changed" ? "justin808" : actor
        actor_type = ENV["FAKE_GH_MODE"] == "actor-type-bot" ? "Bot" : "User"
        target_type = ENV.fetch("FAKE_TARGET_TYPE")
        target_segment = target_type == "pull_request" ? "pull" : "issues"
        canonical_repo = ENV["FAKE_GH_MODE"] == "canonical-repo-case" ? "Acme/Widgets" : "acme/widgets"
        comment = lambda do |body|
          body = body.sub("checker sol/xhigh", "checker terra/high") if ENV["FAKE_GH_MODE"] == "changed-valid-body"
          body = "malformed durable body" if ENV["FAKE_GH_MODE"] == "malformed-body"
          result = {
            "id" => 9001,
            "node_id" => "IC_kwDO9001",
            "html_url" => "https://github.com/#{canonical_repo}/#{target_segment}/184#issuecomment-9001",
            "issue_url" => "https://api.github.com/repos/#{canonical_repo}/issues/184",
            "user" => {
              "login" => durable_actor,
              "type" => ENV["FAKE_GH_MODE"] == "comment-type-bot" ? "Bot" : "User"
            },
            "author_association" => "MEMBER",
            "created_at" => "2026-07-18T18:00:00Z",
            "updated_at" => "2026-07-18T18:00:00Z",
            "body" => body
          }
          result["user"]["login"] = "other-maintainer" if ENV["FAKE_GH_MODE"] == "wrong-author"
          result["user"] = "not-an-object" if ENV["FAKE_GH_MODE"] == "invalid-user"
          result["author_association"] = "NONE" if ENV["FAKE_GH_MODE"] == "association-none"
          result["updated_at"] = "2026-07-18T18:00:01Z" if ENV["FAKE_GH_MODE"] == "edited"
          result["html_url"] = result["html_url"].sub("issuecomment-9001", "issuecomment-9002") if ENV["FAKE_GH_MODE"] == "wrong-url"
          result["issue_url"] = result["issue_url"].sub("/issues/184", "/issues/185") if ENV["FAKE_GH_MODE"] == "wrong-issue-url"
          result
        end

        case [method, endpoint]
        when ["GET", "user"]
          puts JSON.generate("login" => actor, "type" => actor_type)
        when ["GET", "repos/acme/widgets/issues/184"]
          target = {
            "number" => 184,
            "html_url" => "https://github.com/#{canonical_repo}/#{target_segment}/184",
            "locked" => ENV["FAKE_GH_MODE"] == "replay-current-state-changed"
          }
          target["pull_request"] = { "url" => "https://api.github.com/repos/acme/widgets/pulls/184" } if target_type == "pull_request"
          puts JSON.generate(target)
        when ["GET", "repos/#{canonical_repo}/collaborators/#{actor}/permission"]
          user = if ENV["FAKE_GH_MODE"] == "invalid-permission-user"
                   "not-an-object"
                 else
                   type = ENV["FAKE_GH_MODE"] == "permission-type-bot" ? "Bot" : "User"
                   { "login" => actor, "type" => type }
                 end
          permission = ENV["FAKE_GH_MODE"] == "replay-current-state-changed" ? "none" : "write"
          puts JSON.generate("permission" => permission, "user" => user)
        when ["POST", "repos/#{canonical_repo}/issues/184/comments"]
          payload = JSON.parse($stdin.read)
          File.write(ENV.fetch("FAKE_GH_BODY"), payload.fetch("body"))
          exit 1 if ENV["FAKE_GH_MODE"] == "post-nonzero"
          if ENV["FAKE_GH_MODE"] == "post-timeout"
            File.write(ENV.fetch("FAKE_GH_PID"), Process.pid.to_s)
            sleep 2
            File.write(ENV.fetch("FAKE_GH_LATE_SIDE_EFFECT"), "completed")
          end
          if ENV["FAKE_GH_MODE"] == "post-invalid-json"
            puts "{"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "post-array"
            puts "[]"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "post-missing-id"
            puts "{}"
            exit
          end
          puts JSON.generate(comment.call(payload.fetch("body")))
        when ["GET", "repos/#{canonical_repo}/issues/comments/9001"]
          exit 1 if ENV["FAKE_GH_MODE"] == "readback-failure"
          if ENV["FAKE_GH_MODE"] == "readback-invalid-json"
            puts "{"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "readback-array"
            puts "[]"
            exit
          end
          puts JSON.generate(comment.call(File.read(ENV.fetch("FAKE_GH_BODY"))))
        else
          warn "unexpected fake gh call: #{method} #{endpoint} #{args.inspect}"
          exit 1
        end
      RUBY
      FileUtils.chmod(0o755, gh)
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "FAKE_GH_LOG" => File.join(directory, "gh.log"),
        "FAKE_GH_BODY" => File.join(directory, "comment-body.txt"),
        "FAKE_GH_PID" => File.join(directory, "gh.pid"),
        "FAKE_GH_LATE_SIDE_EFFECT" => File.join(directory, "gh-late-side-effect.txt"),
        "FAKE_GH_MODE" => mode.to_s,
        "FAKE_TARGET_TYPE" => target_type,
        "COMPLETED_BATCH_AUDIT_GH_TIMEOUT_SECONDS" => mode == "post-timeout" ? "1" : "60"
      }
      yield env, directory
    end
  end
end
