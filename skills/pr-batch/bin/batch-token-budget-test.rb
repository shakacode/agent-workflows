#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "base64"
require "digest"
require "tmpdir"

HELPER = File.expand_path("batch-token-budget", __dir__)
FIXTURE = File.expand_path("../fixtures/batch-token-budget-v1.json", __dir__)

class BatchTokenBudgetTest < Minitest::Test
  TEST_VERIFIER_KEY = OpenSSL::PKey::RSA.generate(2048)

  def budget(state_path: nil)
    parsed = JSON.parse(File.read(FIXTURE))
    parsed["state_path"] = state_path if state_path
    parsed["trusted_verifiers"] = [{
      "id" => "coordinator-399",
      "algorithm" => "rsa-pss-sha256",
      "public_key_pem" => TEST_VERIFIER_KEY.public_key.to_pem
    }]
    parsed
  end

  def command(action, overrides = {})
    {
      "type" => "batch-token-budget-command",
      "version" => 1,
      "action" => action,
      "batch_id" => "batch-399",
      "evaluated_at" => "2026-08-12T12:00:00Z"
    }.merge(overrides)
  end

  def run_helper(state_path, input)
    install_trusted_plan(state_path, input.fetch("budget")) if input["action"] == "initialize" && input["budget"]
    run_helper_raw(state_path, JSON.generate(input))
  end

  def trusted_plan_path(state_path)
    "#{state_path}.trusted-plan.json"
  end

  def install_trusted_plan(state_path, candidate = budget(state_path: state_path))
    path = trusted_plan_path(state_path)
    File.write(path, JSON.generate(canonicalize(candidate)))
    @trusted_anchor_bindings ||= {}
    @trusted_anchor_bindings[state_path] = {
      "path" => path,
      "id" => candidate.fetch("batch_id"),
      "digest" => "sha256:#{object_digest(candidate)}"
    }
  end

  def trusted_anchor_binding(state_path)
    @trusted_anchor_bindings ||= {}
    @trusted_anchor_bindings[state_path] ||= install_trusted_plan(state_path)
  end

  def run_helper_raw(state_path, input, anchor: trusted_anchor_binding(state_path))
    stdout, stderr, status = Open3.capture3(
      HELPER,
      "--state",
      state_path,
      "--trusted-plan",
      anchor.fetch("path"),
      "--trusted-plan-id",
      anchor.fetch("id"),
      "--trusted-plan-digest",
      anchor.fetch("digest"),
      stdin_data: input
    )
    [stdout.empty? ? nil : JSON.parse(stdout), stderr, status]
  end

  def with_state
    Dir.mktmpdir("batch-token-budget-test") do |directory|
      yield File.join(directory, "state.json")
    end
  end

  def initialize_budget(state_path)
    install_trusted_plan(state_path)
    run_helper(state_path, command("initialize", "budget" => budget(state_path: state_path)))
  end

  def reservation(id:, lane_id: "lane-a", tokens: 100, target_id: nil, kind: "model-turn", overrides: {})
    target_id ||= "task-#{lane_id}"
    {
      "type" => "batch-token-reservation",
      "version" => 1,
      "id" => id,
      "scope_id" => lane_id,
      "admission_kind" => kind,
      "tokens" => tokens,
      "target" => {
        "task_id" => target_id,
        "batch_id" => "batch-399",
        "root_id" => "root-399",
        "lane_id" => lane_id,
        "work_item" => { "repo" => "owner/repo", "type" => "issue", "number" => 399 }
      },
      "target_state" => "idle",
      "message_fingerprint" => "message-#{id}",
      "telemetry" => {
        "status" => "fresh",
        "observed_at" => "2026-08-12T11:55:00Z",
        "self_estimate_tokens" => tokens,
        "descendant_estimate_tokens" => 0,
        "context_status" => "ready",
        "descendant_target_ids" => []
      }
    }.merge(overrides)
  end

  def reserve(state_path, **options)
    run_helper(
      state_path,
      command("reserve", "reservation" => reservation(**options))
    )
  end

  def usage_receipt(id: "usage-1", segments: nil)
    segments ||= [
      { "id" => "physical-self-1", "kind" => "self", "scope_id" => "lane-a", "target_id" => "task-lane-a", "tokens" => 160 },
      { "id" => "physical-child-1", "kind" => "descendant", "scope_id" => "lane-a", "target_id" => "child-a", "tokens" => 70 },
      { "id" => "physical-grandchild-1", "kind" => "descendant", "scope_id" => "lane-a", "target_id" => "grandchild-a", "tokens" => 20 }
    ]
    {
      "type" => "authoritative-token-usage-receipt",
      "version" => 1,
      "id" => id,
      "batch_id" => "batch-399",
      "cutoff" => "runtime-sequence:42",
      "observed_at" => "2026-08-12T11:59:00Z",
      "producer" => { "kind" => "host-reported", "evidence_ref" => "host-usage://task-lane-a/42" },
      "segments" => segments
    }
  end

  def task_identity(task_id:, lane_id: "lane-a")
    {
      "task_id" => task_id,
      "batch_id" => "batch-399",
      "root_id" => "root-399",
      "lane_id" => lane_id,
      "work_item" => { "repo" => "owner/repo", "type" => "issue", "number" => 399 }
    }
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end

  def object_digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(value)))
  end

  def rehash_control_tail(state)
    tail = state.fetch("control_events").last
    if tail.key?("post_state_digest")
      tail["post_state_digest"] = object_digest(state.reject { |key, _value| key == "control_events" })
    else
      tail["state_digest"] = object_digest(state.reject { |key, _value| key == "control_events" })
    end
    tail["digest"] = object_digest(tail.reject { |key, _value| key == "digest" })
  end

  def rechain_control_events(state)
    previous_digest = "0" * 64
    state.fetch("control_events").each_with_index do |event, index|
      event["sequence"] = index + 1
      event["previous_digest"] = previous_digest
      event["pre_state_digest"] = index.zero? ? "0" * 64 : state.fetch("control_events")[index - 1]["post_state_digest"] if event.key?("pre_state_digest")
      event["digest"] = object_digest(event.reject { |key, _value| key == "digest" })
      previous_digest = event.fetch("digest")
    end
  end

  def human_attestation(state_path, id:, scope_id:, action:, issued_at: "2026-08-12T11:58:00Z",
                        expires_at: "2026-08-12T13:00:00Z", signing_key: TEST_VERIFIER_KEY,
                        verifier_id: "coordinator-399", overrides: {})
    state = JSON.parse(File.read(state_path))
    signed_fields = {
      "type" => "proven-human-attestation",
      "version" => 1,
      "id" => "attestation-#{id}",
      "batch_id" => "batch-399",
      "budget_digest" => state.fetch("budget_digest"),
      "scope_id" => scope_id,
      "action" => action,
      "actor" => "maintainer@example.test",
      "issued_at" => issued_at,
      "expires_at" => expires_at,
      "verifier_id" => verifier_id,
      "algorithm" => "rsa-pss-sha256",
      "receipt_ref" => "coordination://verified-human/#{id}"
    }.merge(overrides)
    payload = JSON.generate(canonicalize(signed_fields))
    signature = signing_key.sign_pss("SHA256", payload, salt_length: :digest, mgf1_hash: "SHA256")
    signed_fields.merge("signature" => Base64.strict_encode64(signature))
  end

  def approval(state_path, id:, scope_id: "lane-a", reason: "Allow one bounded admission.",
               issued_at: "2026-08-12T11:58:00Z", expires_at: "2026-08-12T13:00:00Z")
    action = { "type" => "approve-next-admission", "decision_id" => id }
    {
      "type" => "batch-token-budget-approval",
      "version" => 1,
      "id" => id,
      "batch_id" => "batch-399",
      "scope_id" => scope_id,
      "decision" => "approve-next-admission",
      "reason" => reason,
      "attestation" => human_attestation(
        state_path,
        id: id,
        scope_id: scope_id,
        action: action,
        issued_at: issued_at,
        expires_at: expires_at
      )
    }
  end

  def budget_override(state_path, id:, scope_id:, old_limit_tokens:, new_limit_tokens:,
                      reason: "Add bounded headroom.", issued_at: "2026-08-12T11:58:00Z",
                      expires_at: "2026-08-12T13:00:00Z")
    action = {
      "type" => "increase-budget-limit",
      "decision_id" => id,
      "old_limit_tokens" => old_limit_tokens,
      "new_limit_tokens" => new_limit_tokens
    }
    {
      "type" => "batch-token-budget-override",
      "version" => 1,
      "id" => id,
      "batch_id" => "batch-399",
      "scope_id" => scope_id,
      "old_limit_tokens" => old_limit_tokens,
      "new_limit_tokens" => new_limit_tokens,
      "reason" => reason,
      "attestation" => human_attestation(
        state_path,
        id: id,
        scope_id: scope_id,
        action: action,
        issued_at: issued_at,
        expires_at: expires_at
      )
    }
  end

  def test_initialize_persists_complete_hierarchical_scope_totals_and_replays
    with_state do |state_path|
      first, stderr, status = initialize_budget(state_path)

      assert status.success?, stderr
      assert_equal "initialized", first.fetch("status")
      assert_equal 1_000, first.dig("totals", "aggregate", "limit_tokens")
      assert_equal 300, first.dig("totals", "coordinator", "limit_tokens")
      assert_equal 600, first.dig("totals", "lanes", "lane-a", "limit_tokens")
      assert File.file?(state_path)

      replay, replay_stderr, replay_status = initialize_budget(state_path)

      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replay.fetch("status")
      assert_equal first.fetch("totals"), replay.fetch("totals")

      other_path = File.join(File.dirname(state_path), "other-state.json")
      output, mismatch_stderr, mismatch_status = run_helper(
        other_path,
        command("initialize", "budget" => budget(state_path: state_path))
      )
      refute mismatch_status.success?
      assert_nil output
      assert_equal "state-path-mismatch", JSON.parse(mismatch_stderr).fetch("reason")
    end
  end

  def test_every_operation_requires_the_same_external_immutable_budget_anchor
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)

      initialized, stderr, status = run_helper(
        state_path,
        command("initialize", "budget" => candidate)
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      state = JSON.parse(File.read(state_path))
      assert_equal anchor.fetch("id"), state.dig("receipts", 0, "trusted_plan_id")
      assert_equal anchor.fetch("digest"), state.dig("receipts", 0, "trusted_plan_digest")
      assert_equal anchor.fetch("path"), state.dig("receipts", 0, "trusted_plan_path")
      assert_equal anchor.fetch("id"), state.dig("control_events", 0, "payload", "trusted_plan_id")
      assert_equal anchor.fetch("digest"), state.dig("control_events", 0, "payload", "trusted_plan_digest")
      assert_equal anchor.fetch("path"), state.dig("control_events", 0, "payload", "trusted_plan_path")
      assert_equal anchor, state.fetch("trusted_plan_binding")
      state_before = File.read(state_path)

      missing_stdout, missing_stderr, missing_status = Open3.capture3(
        HELPER,
        "--state",
        state_path,
        stdin_data: JSON.generate(command("closeout"))
      )
      refute missing_status.success?
      assert_empty missing_stdout
      assert_equal "trusted-plan-required", JSON.parse(missing_stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)

      bad_bindings = {
        "unknown-path" => [anchor.merge("path" => "UNKNOWN"), "trusted-plan-path-unknown"],
        "unreadable-path" => [anchor.merge("path" => "#{state_path}.missing"), "trusted-plan-unreadable"],
        "unknown-id" => [anchor.merge("id" => "UNKNOWN"), "trusted-plan-id-invalid"],
        "wrong-id" => [anchor.merge("id" => "other-batch"), "trusted-plan-id-mismatch"],
        "unknown-digest" => [anchor.merge("digest" => "UNKNOWN"), "trusted-plan-digest-invalid"],
        "wrong-digest" => [anchor.merge("digest" => "sha256:#{'0' * 64}"), "trusted-plan-digest-mismatch"]
      }
      bad_bindings.each do |name, (bad_anchor, expected_reason)|
        output, operation_stderr, operation_status = run_helper_raw(
          state_path,
          JSON.generate(command("closeout")),
          anchor: bad_anchor
        )
        refute operation_status.success?, name
        assert_nil output, name
        assert_equal expected_reason, JSON.parse(operation_stderr).fetch("reason"), name
        assert_equal state_before, File.read(state_path), name
      end

      alternate_path = "#{anchor.fetch('path')}.copy"
      File.write(alternate_path, File.read(anchor.fetch("path")))
      output, alternate_stderr, alternate_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor.merge("path" => alternate_path)
      )
      refute alternate_status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(alternate_stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)

      replacement_key = OpenSSL::PKey::RSA.generate(2048)
      replacement_budget = canonicalize(candidate)
      replacement_budget.dig("trusted_verifiers", 0)["public_key_pem"] = replacement_key.public_key.to_pem
      output, replacement_stderr, replacement_status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => replacement_budget)),
        anchor: anchor
      )
      refute replacement_status.success?
      assert_nil output
      assert_equal "initialize-budget-anchor-mismatch", JSON.parse(replacement_stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)

      forged_state = JSON.parse(state_before)
      forged_state["base_budget"] = replacement_budget
      forged_state["budget_digest"] = object_digest(replacement_budget)
      rehash_control_tail(forged_state)
      File.write(state_path, JSON.generate(forged_state))
      output, forged_stderr, forged_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor
      )
      refute forged_status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(forged_stderr).fetch("reason")
      File.write(state_path, state_before)

      File.write(anchor.fetch("path"), "not-json")
      output, malformed_stderr, malformed_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor
      )
      refute malformed_status.success?
      assert_nil output
      assert_equal "trusted-plan-malformed", JSON.parse(malformed_stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)

      duplicate_plan = JSON.generate(candidate).sub(
        '"batch_id":"batch-399"',
        '"batch_id":"batch-399","batch_id":"shadow-batch"'
      )
      File.write(anchor.fetch("path"), duplicate_plan)
      output, duplicate_stderr, duplicate_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor
      )
      refute duplicate_status.success?
      assert_nil output
      assert_equal "trusted-plan-malformed", JSON.parse(duplicate_stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_external_budget_binds_state_path_before_filesystem_mutation_and_requires_exact_initialization_projection
    Dir.mktmpdir("batch-token-budget-state-binding") do |directory|
      state_path = File.join(directory, "state.json")
      wrong_state_path = File.join(directory, "wrong-state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)

      output, stderr, status = run_helper_raw(
        wrong_state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        anchor: anchor
      )
      refute status.success?
      assert_nil output
      assert_equal "state-path-mismatch", JSON.parse(stderr).fetch("reason")
      refute File.exist?(wrong_state_path)
      refute File.exist?("#{wrong_state_path}.lock")

      [
        command("initialize", "budget" => nil),
        command("initialize").tap { |input| input.delete("budget") }
      ].each do |initialization|
        output, invalid_stderr, invalid_status = run_helper_raw(
          state_path,
          JSON.generate(initialization),
          anchor: anchor
        )
        refute invalid_status.success?
        assert_nil output
        assert_equal "unsupported-command-contract", JSON.parse(invalid_stderr).fetch("reason")
        refute File.exist?(state_path)
        refute File.exist?("#{state_path}.lock")
      end
    end
  end

  def test_runtime_rejects_same_or_aliased_trusted_plan_and_state_artifacts
    Dir.mktmpdir("batch-token-budget-artifact-separation") do |directory|
      same_path = File.join(directory, "same.json")
      same_budget = budget(state_path: same_path)
      File.write(same_path, JSON.generate(canonicalize(same_budget)))
      same_anchor = {
        "path" => same_path,
        "id" => same_budget.fetch("batch_id"),
        "digest" => "sha256:#{object_digest(same_budget)}"
      }
      same_before = File.read(same_path)

      output, stderr, status = run_helper_raw(
        same_path,
        JSON.generate(command("initialize", "budget" => same_budget)),
        anchor: same_anchor
      )
      refute status.success?
      assert_nil output
      assert_equal "trusted-plan-state-path-collision", JSON.parse(stderr).fetch("reason")
      assert_equal same_before, File.read(same_path)
      refute File.exist?("#{same_path}.lock")

      plan_path = File.join(directory, "trusted-plan.json")
      alias_state_path = File.join(directory, "state-alias.json")
      aliased_budget = budget(state_path: alias_state_path)
      File.write(plan_path, JSON.generate(canonicalize(aliased_budget)))
      File.symlink(plan_path, alias_state_path)
      alias_anchor = {
        "path" => plan_path,
        "id" => aliased_budget.fetch("batch_id"),
        "digest" => "sha256:#{object_digest(aliased_budget)}"
      }
      plan_before = File.read(plan_path)

      output, alias_stderr, alias_status = run_helper_raw(
        alias_state_path,
        JSON.generate(command("initialize", "budget" => aliased_budget)),
        anchor: alias_anchor
      )
      refute alias_status.success?
      assert_nil output
      assert_equal "trusted-plan-state-path-collision", JSON.parse(alias_stderr).fetch("reason")
      assert_equal plan_before, File.read(plan_path)
      refute File.exist?("#{alias_state_path}.lock")
    end
  end

  def test_initialize_rejects_untrusted_or_malformed_verifier_keys
    Dir.mktmpdir("batch-token-budget-verifier-contract") do |directory|
      mutations = {
        "unknown-algorithm" => proc { |records| records[0]["algorithm"] = "UNKNOWN" },
        "malformed-key" => proc { |records| records[0]["public_key_pem"] = "not-a-public-key" },
        "private-key" => proc { |records| records[0]["public_key_pem"] = TEST_VERIFIER_KEY.to_pem },
        "duplicate-id" => proc { |records| records << records[0].dup },
        "duplicate-key-different-id" => proc do |records|
          records << records[0].merge("id" => "different-verifier-id")
        end,
        "empty" => proc(&:clear)
      }
      mutations.each do |name, mutate|
        state_path = File.join(directory, "#{name}.json")
        candidate = budget(state_path: state_path)
        mutate.call(candidate.fetch("trusted_verifiers"))
        output, stderr, status = run_helper(
          state_path,
          command("initialize", "budget" => candidate)
        )

        refute status.success?, name
        assert_nil output, name
        assert_equal "trusted-plan-contract-invalid", JSON.parse(stderr).fetch("reason"), name
        refute File.file?(state_path), name
      end
    end
  end

  def test_lane_reservation_identity_must_match_its_accounting_scope
    with_state do |state_path|
      initialize_budget(state_path)
      wrong_target = task_identity(task_id: "lane-b-task", lane_id: "lane-b")

      blocked, stderr, status = reserve(
        state_path,
        id: "wrong-lane",
        lane_id: "lane-a",
        overrides: { "target" => wrong_target }
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "invalid-reservation", blocked.fetch("reason")
      assert_equal 0, blocked.dig("totals", "aggregate", "allocated_tokens")

      leaked, leaked_stderr, leaked_status = reserve(
        state_path,
        id: "leaked-content",
        overrides: { "prompt" => "never persist this prompt" }
      )
      assert leaked_status.success?, leaked_stderr
      assert_equal "blocked", leaked.fetch("status")
      assert_equal "invalid-reservation", leaked.fetch("reason")
      refute_includes File.read(state_path), "never persist this prompt"

      reserve(state_path, id: "identity-a", lane_id: "lane-a", target_id: "shared-task")
      distinct_identity, distinct_stderr, distinct_status = reserve(
        state_path,
        id: "identity-b",
        lane_id: "lane-b",
        target_id: "shared-task"
      )
      assert distinct_status.success?, distinct_stderr
      assert_equal "admitted", distinct_identity.fetch("status")
      assert_equal 200, distinct_identity.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 100, distinct_identity.dig("totals", "lanes", "lane-b", "reserved_tokens")
    end
  end

  def test_atomic_concurrent_reservations_never_overallocate_aggregate_or_lane_headroom
    with_state do |state_path|
      concurrent_budget = budget(state_path: state_path)
      concurrent_budget["scopes"]["lanes"].transform_values! { { "limit_tokens" => 700 } }
      concurrent_budget["thresholds"] = {
        "warning_percent" => 50,
        "approval_percent" => 95,
        "hard_percent" => 100
      }
      concurrent_budget["delegation"]["approval_threshold_tokens"] = 900
      run_helper(state_path, command("initialize", "budget" => concurrent_budget))
      cross_reservation = lambda do |id, lane_id, target_batch|
        source = task_identity(task_id: "source-#{lane_id}", lane_id: lane_id)
        source["batch_id"] = target_batch
        target = task_identity(task_id: "target-#{lane_id}", lane_id: lane_id)
        reservation(
          id: id,
          lane_id: lane_id,
          tokens: 600,
          kind: "cross-task-delegation",
          target_id: "unused",
          overrides: { "source" => source, "target" => target }
        )
      end
      inputs = [
        command("reserve", "reservation" => cross_reservation.call("reserve-a", "lane-a", "target-batch-a")),
        command("reserve", "reservation" => cross_reservation.call("reserve-b", "lane-b", "target-batch-b"))
      ]
      outputs = inputs.map do |input|
        Thread.new { run_helper(state_path, input) }
      end.map(&:value)

      assert outputs.all? { |_output, _stderr, status| status.success? }, outputs.map { |row| row[1] }.join
      statuses = outputs.map { |output, _stderr, _status| output.fetch("status") }
      assert_equal %w[admitted-with-warning budget-exhausted], statuses.sort

      closeout, stderr, status = run_helper(state_path, command("closeout"))

      assert status.success?, stderr
      assert_equal 600, closeout.dig("totals", "aggregate", "reserved_tokens")
      assert_operator closeout.dig("totals", "aggregate", "reserved_tokens"), :<=,
                      closeout.dig("totals", "aggregate", "limit_tokens")
      lane_reserved = %w[lane-a lane-b].map do |lane_id|
        closeout.dig("totals", "lanes", lane_id, "reserved_tokens")
      end
      assert_equal [0, 600], lane_reserved.sort
    end
  end

  def test_nested_authoritative_usage_is_counted_exactly_once_and_charge_back_is_nonphysical
    with_state do |state_path|
      cross_budget = budget(state_path: state_path)
      cross_budget["delegation"]["approval_threshold_tokens"] = 400
      run_helper(state_path, command("initialize", "budget" => cross_budget))
      source = task_identity(task_id: "source-task")
      source["batch_id"] = "source-batch"
      target = task_identity(task_id: "task-lane-a")
      admitted, stderr, status = run_helper(
        state_path,
        command(
          "reserve",
          "reservation" => reservation(
            id: "reserve-nested",
            tokens: 300,
            kind: "cross-task-delegation",
            overrides: {
              "source" => source,
              "target" => target,
              "telemetry" => reservation(id: "nested-envelope", tokens: 300).fetch("telemetry").merge(
                "self_estimate_tokens" => 200,
                "descendant_estimate_tokens" => 100,
                "descendant_target_ids" => %w[child-a grandchild-a]
              )
            }
          )
        )
      )
      assert status.success?, stderr
      assert_includes %w[admitted admitted-with-warning], admitted.fetch("status")

      charge_back = {
        "type" => "batch-token-charge-back",
        "version" => 1,
        "id" => "cause-1",
        "source" => source,
        "target" => target
      }
      reconcile = command(
        "reconcile",
        "reservation_id" => "reserve-nested",
        "usage_receipt" => usage_receipt,
        "charge_back" => charge_back
      )
      first, first_stderr, first_status = run_helper(state_path, reconcile)

      assert first_status.success?, first_stderr
      assert_equal "reconciled", first.fetch("status")
      assert_equal 250, first.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 250, first.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 50, first.dig("totals", "aggregate", "released_tokens")
      assert_equal 0, first.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 250, first.dig("charge_back", "tokens")
      assert_equal false, first.dig("charge_back", "physical_total_incremented")

      replay, replay_stderr, replay_status = run_helper(state_path, reconcile)

      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replay.fetch("status")
      assert_equal 250, replay.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 250, replay.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 50, replay.dig("totals", "aggregate", "released_tokens")

      reserve_again = reservation(
        id: "reserve-nested-again",
        tokens: 100,
        kind: "cross-task-delegation",
        overrides: { "source" => source, "target" => target }
      )
      run_helper(state_path, command("reserve", "reservation" => reserve_again))
      second_usage = usage_receipt(
        id: "usage-second-delegation",
        segments: [
          { "id" => "physical-second-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "task-lane-a", "tokens" => 100 }
        ]
      )
      duplicate_charge_back, duplicate_stderr, duplicate_status = run_helper(
        state_path,
        command(
          "reconcile",
          "reservation_id" => "reserve-nested-again",
          "usage_receipt" => second_usage,
          "charge_back" => charge_back
        )
      )
      refute duplicate_status.success?
      assert_nil duplicate_charge_back
      assert_equal "charge-back-already-accounted", JSON.parse(duplicate_stderr).fetch("reason")
    end
  end

  def test_approval_and_scoped_budget_increase_are_durable_and_do_not_grant_other_authority
    with_state do |state_path|
      initialize_budget(state_path)
      blocked, stderr, status = reserve(state_path, id: "reserve-approval", tokens: 500)

      assert status.success?, stderr
      assert_equal "approval-required", blocked.fetch("status")
      assert_equal "projected-approval-threshold", blocked.fetch("reason")

      approval = approval(state_path, id: "approval-1", reason: "Finish the bounded lane.")
      approved, approval_stderr, approval_status = run_helper(
        state_path,
        command("approve", "approval" => approval)
      )

      assert approval_status.success?, approval_stderr
      assert_equal "approved", approved.fetch("status")
      assert_equal %w[security review qa exact-head ownership merge], approved.fetch("preserved_gates")

      reused_id, reused_stderr, reused_status = run_helper(
        state_path,
        command(
          "reserve",
          "reservation" => reservation(
            id: "reserve-approval",
            tokens: 500,
            overrides: { "approval_id" => "approval-1" }
          )
        )
      )
      refute reused_status.success?
      assert_nil reused_id
      assert_equal "reservation-replay-mismatch", JSON.parse(reused_stderr).fetch("reason")

      admitted, admitted_stderr, admitted_status = run_helper(
        state_path,
        command(
          "reserve",
          "reservation" => reservation(
            id: "reserve-approval-authorized",
            tokens: 500,
            overrides: { "approval_id" => "approval-1" }
          )
        )
      )

      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted-with-warning", admitted.fetch("status")
      assert_equal %w[security review qa exact-head ownership merge], admitted.fetch("preserved_gates")

      hard, hard_stderr, hard_status = reserve(state_path, id: "reserve-hard", lane_id: "lane-b", tokens: 500)
      assert hard_status.success?, hard_stderr
      assert_equal "budget-exhausted", hard.fetch("status")

      override = budget_override(
        state_path,
        id: "override-1",
        scope_id: "aggregate",
        old_limit_tokens: 1_000,
        new_limit_tokens: 1_500,
        reason: "Add bounded headroom for lane-b only in this batch.",
        issued_at: "2026-08-12T12:00:00Z",
        expires_at: "2026-08-12T14:00:00Z"
      )
      increased, override_stderr, override_status = run_helper(
        state_path,
        command("override", "override" => override)
      )

      assert override_status.success?, override_stderr
      assert_equal "overridden", increased.fetch("status")
      assert_equal 1_500, increased.dig("totals", "aggregate", "limit_tokens")
      assert_equal 600, increased.dig("totals", "lanes", "lane-a", "limit_tokens")
      assert_equal 500, increased.dig("totals", "lanes", "lane-b", "limit_tokens")
      assert_equal %w[security review qa exact-head ownership merge], increased.fetch("preserved_gates")

      lane_override = budget_override(
        state_path,
        id: "override-lane-b",
        scope_id: "lane-b",
        old_limit_tokens: 500,
        new_limit_tokens: 800,
        expires_at: "2026-08-12T14:00:00Z"
      )
      run_helper(state_path, command("override", "override" => lane_override))
      resumed, resume_stderr, resume_status = reserve(
        state_path,
        id: "reserve-hard-resume",
        lane_id: "lane-b",
        tokens: 500
      )
      assert resume_status.success?, resume_stderr
      assert_equal "admitted-with-warning", resumed.fetch("status")
      assert_equal 1_000, resumed.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_aggregate_attestation_resolves_aggregate_only_and_combined_approval_stops
    Dir.mktmpdir("batch-token-budget-aggregate-approval") do |directory|
      aggregate_only_path = File.join(directory, "aggregate-only.json")
      aggregate_only_budget = budget(state_path: aggregate_only_path)
      aggregate_only_budget["scopes"]["lanes"].transform_values! { { "limit_tokens" => 1_000 } }
      run_helper(aggregate_only_path, command("initialize", "budget" => aggregate_only_budget))
      reserve(aggregate_only_path, id: "aggregate-base", lane_id: "lane-b", tokens: 500, target_id: "base")
      stopped, = reserve(
        aggregate_only_path,
        id: "aggregate-stop",
        lane_id: "lane-a",
        tokens: 300,
        target_id: "aggregate-target"
      )
      assert_equal "approval-required", stopped.fetch("status")
      aggregate_decision = JSON.parse(File.read(aggregate_only_path)).fetch("admission_decisions").values.last
      assert_equal ["aggregate"], aggregate_decision.fetch("blocking_scope_ids")

      aggregate_approval = approval(
        aggregate_only_path,
        id: "aggregate-only-approval",
        scope_id: "aggregate"
      )
      approved, approval_stderr, approval_status = run_helper(
        aggregate_only_path,
        command("approve", "approval" => aggregate_approval)
      )
      assert approval_status.success?, approval_stderr
      assert_equal "approved", approved.fetch("status")
      resumed, resume_stderr, resume_status = reserve(
        aggregate_only_path,
        id: "aggregate-resume",
        lane_id: "lane-a",
        tokens: 300,
        target_id: "aggregate-target",
        overrides: { "approval_id" => "aggregate-only-approval" }
      )
      assert resume_status.success?, resume_stderr
      assert_equal "admitted-with-warning", resumed.fetch("status")

      combined_path = File.join(directory, "combined.json")
      combined_budget = budget(state_path: combined_path)
      combined_budget["scopes"]["lanes"]["lane-b"]["limit_tokens"] = 1_000
      run_helper(combined_path, command("initialize", "budget" => combined_budget))
      reserve(combined_path, id: "combined-base", lane_id: "lane-b", tokens: 400, target_id: "combined-base")
      combined_stop, = reserve(
        combined_path,
        id: "combined-stop",
        lane_id: "lane-a",
        tokens: 480,
        target_id: "combined-target"
      )
      assert_equal "approval-required", combined_stop.fetch("status")
      combined_decision = JSON.parse(File.read(combined_path)).fetch("admission_decisions").values.last
      assert_equal %w[aggregate lane-a], combined_decision.fetch("blocking_scope_ids").sort
      aggregate_approval = approval(combined_path, id: "combined-approval", scope_id: "aggregate")
      run_helper(combined_path, command("approve", "approval" => aggregate_approval))
      combined_resume, combined_stderr, combined_status = reserve(
        combined_path,
        id: "combined-resume",
        lane_id: "lane-a",
        tokens: 480,
        target_id: "combined-target",
        overrides: { "approval_id" => "combined-approval" }
      )
      assert combined_status.success?, combined_stderr
      assert_equal "admitted-with-warning", combined_resume.fetch("status")
    end
  end

  def test_closeout_requires_lane_and_aggregate_approval_stops_to_be_explicitly_resolved
    Dir.mktmpdir("batch-token-budget-approval-closeout") do |directory|
      scenarios = {
        "lane" => { "tokens" => 500, "scope_id" => "lane-a" },
        "aggregate" => { "tokens" => 800, "scope_id" => "aggregate", "lane_limit" => 1_000 }
      }
      scenarios.each do |name, scenario|
        state_path = File.join(directory, "#{name}.json")
        candidate = budget(state_path: state_path)
        candidate.dig("scopes", "lanes", "lane-a")["limit_tokens"] = scenario["lane_limit"] if scenario["lane_limit"]
        run_helper(state_path, command("initialize", "budget" => candidate))
        stopped_request = reservation(id: "#{name}-approval-stop", tokens: scenario.fetch("tokens"))

        stopped, stopped_stderr, stopped_status = run_helper(
          state_path,
          command("reserve", "reservation" => stopped_request)
        )
        assert stopped_status.success?, stopped_stderr
        assert_equal "approval-required", stopped.fetch("status"), name

        incomplete, incomplete_stderr, incomplete_status = run_helper(state_path, command("closeout"))
        assert incomplete_status.success?, incomplete_stderr
        assert_equal "not-complete", incomplete.fetch("status"), name
        assert_equal "NOT COMPLETE", incomplete.fetch("completion"), name

        approval_id = "#{name}-approval"
        approved, approval_stderr, approval_status = run_helper(
          state_path,
          command(
            "approve",
            "approval" => approval(state_path, id: approval_id, scope_id: scenario.fetch("scope_id"))
          )
        )
        assert approval_status.success?, approval_stderr
        assert_equal "approved", approved.fetch("status"), name

        approved_but_unresolved, unresolved_stderr, unresolved_status = run_helper(state_path, command("closeout"))
        assert unresolved_status.success?, unresolved_stderr
        assert_equal "not-complete", approved_but_unresolved.fetch("status"), name
        assert_equal "NOT COMPLETE", approved_but_unresolved.fetch("completion"), name

        admitted_request = reservation(
          id: "#{name}-approved-admission",
          tokens: scenario.fetch("tokens"),
          overrides: { "approval_id" => approval_id }
        )
        admitted, admitted_stderr, admitted_status = run_helper(
          state_path,
          command("reserve", "reservation" => admitted_request)
        )
        assert admitted_status.success?, admitted_stderr
        assert_includes %w[admitted admitted-with-warning], admitted.fetch("status"), name

        released, release_stderr, release_status = run_helper(
          state_path,
          command(
            "release",
            "release" => {
              "type" => "batch-token-release",
              "version" => 1,
              "id" => "#{name}-approved-release",
              "reservation_id" => admitted_request.fetch("id"),
              "reason" => "Finish approved closeout regression."
            }
          )
        )
        assert release_status.success?, release_stderr
        assert_equal "released", released.fetch("status"), name

        complete, complete_stderr, complete_status = run_helper(state_path, command("closeout"))
        assert complete_status.success?, complete_stderr
        assert_equal "complete", complete.fetch("status"), name
        assert_equal "COMPLETE", complete.fetch("completion"), name
      end
    end
  end

  def test_human_decisions_require_verified_attestation_and_strict_binding
    with_state do |state_path|
      initialize_budget(state_path)
      baseline = File.read(state_path)
      legacy = {
        "type" => "batch-token-budget-approval",
        "version" => 1,
        "id" => "legacy-self-assertion",
        "batch_id" => "batch-399",
        "scope_id" => "lane-a",
        "decision" => "approve-next-admission",
        "approver" => "maintainer@example.test",
        "evidence_ref" => "self-attested",
        "reason" => "Unverified claim.",
        "approved_at" => "2026-08-12T11:58:00Z",
        "expires_at" => "2026-08-12T13:00:00Z"
      }
      invalid, legacy_stderr, legacy_status = run_helper(state_path, command("approve", "approval" => legacy))
      refute legacy_status.success?
      assert_nil invalid
      assert_equal "invalid-approval", JSON.parse(legacy_stderr).fetch("reason")
      assert_equal baseline, File.read(state_path)

      invalid_attestations = {
        "unknown-actor" => proc { |value| value["actor"] = "UNKNOWN" },
        "wrong-scope" => proc { |value| value["scope_id"] = "lane-b" },
        "wrong-batch" => proc { |value| value["batch_id"] = "other-batch" },
        "wrong-budget" => proc { |value| value["budget_digest"] = "0" * 64 },
        "wrong-action" => proc { |value| value["action"]["type"] = "merge" },
        "unsupported-algorithm" => proc { |value| value["algorithm"] = "UNKNOWN" },
        "unlisted-verifier" => proc { |value| value["verifier_id"] = "self-described-verifier" },
        "self-attested-ref" => proc { |value| value["receipt_ref"] = "self-attested" },
        "missing-signature" => proc { |value| value.delete("signature") },
        "malformed-signature" => proc { |value| value["signature"] = "not-base64!" },
        "expired" => proc { |value| value["expires_at"] = "2026-08-12T11:59:00Z" },
        "future" => proc { |value| value["issued_at"] = "2026-08-12T12:30:00Z" }
      }
      invalid_attestations.each do |name, mutate|
        candidate = approval(state_path, id: "invalid-#{name}")
        mutate.call(candidate.fetch("attestation"))
        output, stderr, status = run_helper(state_path, command("approve", "approval" => candidate))
        refute status.success?, name
        assert_nil output, name
        assert_equal "invalid-approval", JSON.parse(stderr).fetch("reason"), name
        assert_equal baseline, File.read(state_path), name
      end

      forged = approval(state_path, id: "forged-key")
      forged["attestation"] = human_attestation(
        state_path,
        id: "forged-key",
        scope_id: "lane-a",
        action: { "type" => "approve-next-admission", "decision_id" => "forged-key" },
        signing_key: OpenSSL::PKey::RSA.generate(2048)
      )
      forged_output, forged_stderr, forged_status = run_helper(
        state_path,
        command("approve", "approval" => forged)
      )
      refute forged_status.success?
      assert_nil forged_output
      assert_equal "invalid-approval", JSON.parse(forged_stderr).fetch("reason")
      assert_equal baseline, File.read(state_path)

      verified = approval(state_path, id: "bound-approval")
      accepted, accepted_stderr, accepted_status = run_helper(
        state_path,
        command("approve", "approval" => verified)
      )
      assert accepted_status.success?, accepted_stderr
      assert_equal "approved", accepted.fetch("status")
      changed_binding = JSON.parse(JSON.generate(verified))
      changed_binding["attestation"]["actor"] = "another-maintainer@example.test"
      replay, replay_stderr, replay_status = run_helper(
        state_path,
        command("approve", "approval" => changed_binding)
      )
      refute replay_status.success?
      assert_nil replay
      assert_equal "invalid-approval", JSON.parse(replay_stderr).fetch("reason")

      rebound = approval(state_path, id: "rebound-approval")
      rebound["attestation"] = human_attestation(
        state_path,
        id: "rebound-approval",
        scope_id: "lane-a",
        action: { "type" => "approve-next-admission", "decision_id" => "rebound-approval" },
        overrides: { "id" => verified.dig("attestation", "id") }
      )
      rebound_output, rebound_stderr, rebound_status = run_helper(
        state_path,
        command("approve", "approval" => rebound)
      )
      refute rebound_status.success?
      assert_nil rebound_output
      assert_equal "human-attestation-replay-mismatch", JSON.parse(rebound_stderr).fetch("reason")
    end
  end

  def test_budget_override_attestation_rejects_unverified_or_rebound_actions
    with_state do |state_path|
      initialize_budget(state_path)
      baseline = File.read(state_path)
      unverified = budget_override(
        state_path,
        id: "unverified-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700
      )
      unverified["attestation"]["verifier_id"] = "UNKNOWN"
      output, stderr, status = run_helper(state_path, command("override", "override" => unverified))
      refute status.success?
      assert_nil output
      assert_equal "invalid-override", JSON.parse(stderr).fetch("reason")
      assert_equal baseline, File.read(state_path)

      rebound = budget_override(
        state_path,
        id: "rebound-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700
      )
      rebound["new_limit_tokens"] = 750
      output, stderr, status = run_helper(state_path, command("override", "override" => rebound))
      refute status.success?
      assert_nil output
      assert_equal "invalid-override", JSON.parse(stderr).fetch("reason")
      assert_equal baseline, File.read(state_path)

      verified = budget_override(
        state_path,
        id: "verified-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700
      )
      accepted, accepted_stderr, accepted_status = run_helper(
        state_path,
        command("override", "override" => verified)
      )
      assert accepted_status.success?, accepted_stderr
      assert_equal "overridden", accepted.fetch("status")
      changed = JSON.parse(JSON.generate(verified))
      changed["attestation"]["receipt_ref"] = "coordination://verified-human/other"
      replay, replay_stderr, replay_status = run_helper(
        state_path,
        command("override", "override" => changed)
      )
      refute replay_status.success?
      assert_nil replay
      assert_equal "override-replay-mismatch", JSON.parse(replay_stderr).fetch("reason")
    end
  end

  def test_persisted_threshold_stops_block_smaller_followup_work_until_authorized
    with_state do |state_path|
      initialize_budget(state_path)

      approval_stop, = reserve(state_path, id: "approval-stop", lane_id: "lane-a", tokens: 500)
      assert_equal "approval-required", approval_stop.fetch("status")

      smaller_approval, = reserve(state_path, id: "approval-smaller", lane_id: "lane-a", tokens: 100)
      assert_equal "approval-required", smaller_approval.fetch("status")
      assert_equal "persisted-approval-stop", smaller_approval.fetch("reason")

      hard_stop, = reserve(state_path, id: "hard-stop", lane_id: "lane-b", tokens: 500)
      assert_equal "budget-exhausted", hard_stop.fetch("status")

      smaller_hard, = reserve(state_path, id: "hard-smaller", lane_id: "lane-b", tokens: 100)
      assert_equal "budget-exhausted", smaller_hard.fetch("status")
      assert_equal "persisted-hard-stop", smaller_hard.fetch("reason")
      assert_equal 0, smaller_hard.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_scoped_override_keeps_plan_identity_and_cannot_hide_an_unrelated_hard_stop
    with_state do |state_path|
      initialized, = initialize_budget(state_path)
      plan_digest = initialized.dig("receipt", "budget_digest")
      hard_stop, = reserve(state_path, id: "lane-a-hard", lane_id: "lane-a", tokens: 600)
      assert_equal "budget-exhausted", hard_stop.fetch("status")

      unrelated_override = budget_override(
        state_path,
        id: "lane-b-only",
        scope_id: "lane-b",
        old_limit_tokens: 500,
        new_limit_tokens: 550,
        reason: "Increase only lane-b headroom.",
        issued_at: "2026-08-12T12:00:00Z",
        expires_at: "2026-08-12T14:00:00Z"
      )
      overridden, override_stderr, override_status = run_helper(
        state_path,
        command("override", "override" => unrelated_override)
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")

      replayed, replay_stderr, replay_status = initialize_budget(state_path)
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal plan_digest, JSON.parse(File.read(state_path)).fetch("budget_digest")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "budget-exhausted", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
    end
  end

  def test_expensive_admission_fails_closed_on_stale_unknown_paused_or_compaction_telemetry
    with_state do |state_path|
      initialize_budget(state_path)

      stale, = reserve(
        state_path,
        id: "stale",
        overrides: {
          "telemetry" => reservation(id: "ignored").fetch("telemetry").merge("observed_at" => "2026-08-12T11:00:00Z")
        }
      )
      assert_equal "blocked", stale.fetch("status")
      assert_equal "telemetry-stale", stale.fetch("reason")
      assert_equal %w[read-only-discovery checkpoint], stale.fetch("allowed_actions")

      unknown, = reserve(
        state_path,
        id: "unknown",
        overrides: {
          "telemetry" => reservation(id: "ignored").fetch("telemetry").merge("status" => "UNKNOWN")
        }
      )
      assert_equal "blocked", unknown.fetch("status")
      assert_equal "telemetry-unknown", unknown.fetch("reason")

      paused, = reserve(state_path, id: "paused", overrides: { "target_state" => "paused" })
      assert_equal "blocked", paused.fetch("status")
      assert_equal "paused-target-requires-resume-approval", paused.fetch("reason")

      compaction, = reserve(
        state_path,
        id: "compaction-authorized",
        overrides: {
          "telemetry" => reservation(id: "ignored").fetch("telemetry").merge("context_status" => "compaction-required")
        }
      )
      assert_equal "approval-required", compaction.fetch("status")
      assert_equal "compaction-required", compaction.fetch("reason")

      compaction_approval = approval(
        state_path,
        id: "compaction-approval",
        reason: "Allow one bounded post-compaction turn."
      )
      run_helper(state_path, command("approve", "approval" => compaction_approval))
      compaction_request = reservation(
        id: "compaction",
        overrides: {
          "approval_id" => "compaction-approval",
          "telemetry" => reservation(id: "ignored").fetch("telemetry").merge("context_status" => "compaction-required")
        }
      )
      compacted, = run_helper(state_path, command("reserve", "reservation" => compaction_request))
      assert_equal "admitted", compacted.fetch("status")

      active, = reserve(
        state_path,
        id: "active",
        kind: "scheduled-continuation",
        overrides: { "target_state" => "active" }
      )
      assert_equal "coalesced", active.fetch("status")
      assert_equal "target-already-active", active.fetch("reason")
      assert_equal 100, active.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_cross_task_delegation_requires_source_identity_and_delegation_approval
    with_state do |state_path|
      initialize_budget(state_path)
      target = task_identity(task_id: "other-task")
      source = task_identity(task_id: "source-task")
      source["batch_id"] = "source-batch"
      cross_task = reservation(
        id: "cross-task-1",
        tokens: 260,
        kind: "cross-task-delegation",
        overrides: {
          "source" => source,
          "target" => target,
          "telemetry" => reservation(id: "ignored", tokens: 260).fetch("telemetry").merge(
            "self_estimate_tokens" => 100,
            "descendant_estimate_tokens" => 160,
            "descendant_target_ids" => %w[retained-child retained-grandchild]
          )
        }
      )
      blocked, stderr, status = run_helper(
        state_path,
        command("reserve", "reservation" => cross_task)
      )

      assert status.success?, stderr
      assert_equal "approval-required", blocked.fetch("status")
      assert_equal "projected-delegation-threshold", blocked.fetch("reason")
      assert_equal 0, blocked.dig("totals", "aggregate", "reserved_tokens")

      approval = approval(state_path, id: "cross-approval", reason: "Allow one bounded cross-task wake.")
      run_helper(state_path, command("approve", "approval" => approval))
      cross_task["id"] = "cross-task-1-authorized"
      cross_task["message_fingerprint"] = "message-cross-task-1-authorized"
      cross_task["approval_id"] = "cross-approval"
      admitted, admitted_stderr, admitted_status = run_helper(
        state_path,
        command("reserve", "reservation" => cross_task)
      )
      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted", admitted.fetch("status")
      assert_equal 260, admitted.dig("totals", "aggregate", "reserved_tokens")
      assert_equal %w[other-task retained-child retained-grandchild],
                   admitted.dig("receipt", "overshoot_envelope", "target_ids")
    end
  end

  def test_release_then_replacement_or_escalation_is_fenced_and_restart_safe
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "prior", tokens: 200)

      predecessor_missing, = reserve(
        state_path,
        id: "replacement-without-predecessor",
        tokens: 200,
        target_id: "replacement-target",
        kind: "replacement"
      )
      assert_equal "blocked", predecessor_missing.fetch("status")
      assert_equal "replacement-predecessor-required", predecessor_missing.fetch("reason")

      unfenced, = reserve(
        state_path,
        id: "replacement-too-early",
        tokens: 200,
        kind: "replacement",
        overrides: { "replaces_reservation_id" => "prior" }
      )
      assert_equal "blocked", unfenced.fetch("status")
      assert_equal "replacement-prior-not-reconciled", unfenced.fetch("reason")

      release = command(
        "release",
        "release" => {
          "type" => "batch-token-release",
          "version" => 1,
          "id" => "release-prior",
          "reservation_id" => "prior",
          "reason" => "Worker stopped before its model turn."
        }
      )
      released, release_stderr, release_status = run_helper(state_path, release)
      assert release_status.success?, release_stderr
      assert_equal "released", released.fetch("status")
      assert_equal 0, released.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 200, released.dig("totals", "aggregate", "released_tokens")

      replay, replay_stderr, replay_status = run_helper(state_path, release)
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replay.fetch("status")
      assert_equal 200, replay.dig("totals", "aggregate", "released_tokens")

      replacement, replacement_stderr, replacement_status = reserve(
        state_path,
        id: "replacement",
        tokens: 200,
        kind: "escalation",
        overrides: { "replaces_reservation_id" => "prior" }
      )
      assert replacement_status.success?, replacement_stderr
      assert_equal "admitted", replacement.fetch("status")
      assert_equal 200, replacement.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 400, replacement.dig("totals", "aggregate", "allocated_tokens")

      reused_release = release.merge(
        "release" => release.fetch("release").merge(
          "reservation_id" => "replacement",
          "reason" => "A different worker stopped."
        )
      )
      output, reused_stderr, reused_status = run_helper(state_path, reused_release)
      refute reused_status.success?
      assert_nil output
      assert_equal "release-replay-mismatch", JSON.parse(reused_stderr).fetch("reason")
    end
  end

  def test_exact_admitted_blocked_and_coalesced_reservation_replays_precede_telemetry_freshness
    with_state do |state_path|
      initialize_budget(state_path)
      requests = {
        "admitted" => reservation(id: "stale-replay-admitted", tokens: 100),
        "blocked" => reservation(
          id: "stale-replay-blocked",
          tokens: 100,
          target_id: "paused-target",
          overrides: { "target_state" => "paused" }
        ),
        "coalesced" => reservation(
          id: "stale-replay-coalesced",
          tokens: 100,
          target_id: "active-target",
          overrides: { "target_state" => "active" }
        )
      }
      expected_decisions = {
        "admitted" => "admitted",
        "blocked" => "blocked",
        "coalesced" => "coalesced"
      }
      requests.each do |name, request|
        first, first_stderr, first_status = run_helper(
          state_path,
          command("reserve", "reservation" => request)
        )
        assert first_status.success?, first_stderr
        assert_equal expected_decisions.fetch(name), first.fetch("status"), name
      end
      state_before = JSON.parse(File.read(state_path))
      allocated_before = state_before.dig("scopes", "aggregate", "allocated_tokens")
      outcomes_before = state_before.fetch("reservation_decisions").transform_values do |fence|
        object_digest(fence)
      end

      requests.each do |name, request|
        replay, replay_stderr, replay_status = run_helper(
          state_path,
          command(
            "reserve",
            "reservation" => request,
            "evaluated_at" => "2026-08-12T12:20:00Z"
          )
        )
        assert replay_status.success?, replay_stderr
        assert_equal "replayed", replay.fetch("status"), name
        assert_equal expected_decisions.fetch(name), replay.fetch("decision_status"), name
        assert_equal allocated_before, replay.dig("totals", "aggregate", "allocated_tokens"), name
      end
      state_after = JSON.parse(File.read(state_path))
      outcomes_after = state_after.fetch("reservation_decisions").transform_values do |fence|
        object_digest(fence)
      end
      assert_equal outcomes_before, outcomes_after

      changed = Marshal.load(Marshal.dump(requests.fetch("admitted")))
      changed["telemetry"]["observed_at"] = "2026-08-12T12:19:00Z"
      output, mismatch_stderr, mismatch_status = run_helper(
        state_path,
        command(
          "reserve",
          "reservation" => changed,
          "evaluated_at" => "2026-08-12T12:20:00Z"
        )
      )
      refute mismatch_status.success?
      assert_nil output
      assert_equal "reservation-replay-mismatch", JSON.parse(mismatch_stderr).fetch("reason")
    end
  end

  def test_coalesced_reservation_id_is_durably_fenced_after_predecessor_release
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "active-owner", target_id: "shared-target")
      coalesced_request = reservation(
        id: "coalesced-id",
        target_id: "shared-target",
        kind: "scheduled-continuation"
      )
      coalesced, coalesced_stderr, coalesced_status = run_helper(
        state_path,
        command("reserve", "reservation" => coalesced_request)
      )
      assert coalesced_status.success?, coalesced_stderr
      assert_equal "coalesced", coalesced.fetch("status")
      decision_state = JSON.parse(File.read(state_path))
      decision = decision_state.dig("reservation_decisions", "coalesced-id")
      refute_nil decision
      assert_equal "coalesced", decision.fetch("outcomes").last.fetch("status")

      run_helper(
        state_path,
        command(
          "release",
          "release" => {
            "type" => "batch-token-release",
            "version" => 1,
            "id" => "release-active-owner",
            "reservation_id" => "active-owner",
            "reason" => "Target turn completed."
          }
        )
      )
      after_release = File.read(state_path)
      changed_request = JSON.parse(JSON.generate(coalesced_request))
      changed_request["tokens"] = 120
      changed_request["telemetry"]["self_estimate_tokens"] = 120
      changed, changed_stderr, changed_status = run_helper(
        state_path,
        command("reserve", "reservation" => changed_request)
      )
      refute changed_status.success?
      assert_nil changed
      assert_equal "reservation-replay-mismatch", JSON.parse(changed_stderr).fetch("reason")
      assert_equal after_release, File.read(state_path)

      replayed, replay_stderr, replay_status = run_helper(
        state_path,
        command("reserve", "reservation" => coalesced_request)
      )
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal "coalesced", replayed.fetch("decision_status")
      assert_equal "target-already-active", replayed.fetch("reason")
      assert_equal after_release, File.read(state_path)

      blocked_request = reservation(
        id: "blocked-id",
        target_id: "paused-target",
        overrides: { "target_state" => "paused" }
      )
      blocked, blocked_stderr, blocked_status = run_helper(
        state_path,
        command("reserve", "reservation" => blocked_request)
      )
      assert blocked_status.success?, blocked_stderr
      assert_equal "blocked", blocked.fetch("status")
      blocked_state = JSON.parse(File.read(state_path))
      assert_equal "blocked", blocked_state.dig("reservation_decisions", "blocked-id", "outcomes", 0, "status")
      blocked_snapshot = File.read(state_path)
      blocked_replay, blocked_replay_stderr, blocked_replay_status = run_helper(
        state_path,
        command("reserve", "reservation" => blocked_request)
      )
      assert blocked_replay_status.success?, blocked_replay_stderr
      assert_equal "replayed", blocked_replay.fetch("status")
      assert_equal "blocked", blocked_replay.fetch("decision_status")
      assert_equal blocked_snapshot, File.read(state_path)
    end
  end

  def test_successful_retry_after_released_headroom_resolves_prior_hard_decision
    with_state do |state_path|
      retry_budget = budget(state_path: state_path)
      retry_budget["scopes"]["lanes"].transform_values! { { "limit_tokens" => 700 } }
      retry_budget["thresholds"] = {
        "warning_percent" => 80,
        "approval_percent" => 95,
        "hard_percent" => 100
      }
      run_helper(state_path, command("initialize", "budget" => retry_budget))
      reserve(state_path, id: "occupying", lane_id: "lane-a", tokens: 600)
      retried_request = reservation(id: "retry-after-headroom", lane_id: "lane-b", tokens: 500)

      denied, = run_helper(state_path, command("reserve", "reservation" => retried_request))
      assert_equal "budget-exhausted", denied.fetch("status")

      %w[occupying retry-after-headroom-resume].each_with_index do |reservation_id, index|
        if index == 1
          resumed_request = retried_request.merge("id" => reservation_id)
          admitted, admitted_stderr, admitted_status = run_helper(
            state_path,
            command("reserve", "reservation" => resumed_request)
          )
          assert admitted_status.success?, admitted_stderr
          assert_equal "admitted", admitted.fetch("status")
        end
        run_helper(
          state_path,
          command(
            "release",
            "release" => {
              "type" => "batch-token-release",
              "version" => 1,
              "id" => "release-#{reservation_id}",
              "reservation_id" => reservation_id,
              "reason" => "No usage was observed."
            }
          )
        )
      end

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "complete", closeout.fetch("status")
      assert_equal "COMPLETE", closeout.fetch("completion")
    end
  end

  def test_bounded_overshoot_is_measured_per_admitted_target_and_multiple_turns_fail_closed
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "overshoot", tokens: 200)
      receipt = usage_receipt(
        id: "usage-overshoot",
        segments: [
          { "id" => "overshoot-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "task-lane-a", "tokens" => 225 }
        ]
      )
      receipt["overshoot"] = [{ "target_id" => "task-lane-a", "tokens" => 25, "turns" => 2 }]

      denied, stderr, status = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "overshoot", "usage_receipt" => receipt)
      )

      assert status.success?, stderr
      assert_equal "blocked", denied.fetch("status")
      assert_equal "overshoot-envelope-invalid", denied.fetch("reason")
      assert_equal 0, denied.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 200, denied.dig("totals", "aggregate", "reserved_tokens")

      receipt["overshoot"] = [{ "target_id" => "task-lane-a", "tokens" => 25, "turns" => 1 }]
      reconciled, reconcile_stderr, reconcile_status = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "overshoot", "usage_receipt" => receipt)
      )

      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 25, reconciled.dig("receipt", "overshoot_tokens")
      assert_equal 1, reconciled.dig("receipt", "overshoot_turn_count")
      assert_equal 225, reconciled.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_authoritative_usage_targets_must_match_the_reservation_envelope
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "target-bound", tokens: 200, target_id: "reserved-task")
      wrong_target = usage_receipt(
        id: "wrong-target-usage",
        segments: [
          { "id" => "wrong-target-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "another-task", "tokens" => 100 }
        ]
      )

      blocked, stderr, status = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "target-bound", "usage_receipt" => wrong_target)
      )
      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-target-reservation-mismatch", blocked.fetch("reason")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")

      corrected = usage_receipt(
        id: "correct-target-usage",
        segments: [
          { "id" => "correct-target-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "reserved-task", "tokens" => 100 }
        ]
      )
      reconciled, = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "target-bound", "usage_receipt" => corrected)
      )
      assert_equal "reconciled", reconciled.fetch("status")
    end
  end

  def test_lane_overshoot_to_its_hard_limit_blocks_closeout_even_with_aggregate_headroom
    with_state do |state_path|
      overshoot_budget = budget(state_path: state_path)
      overshoot_budget["thresholds"] = {
        "warning_percent" => 50,
        "approval_percent" => 95,
        "hard_percent" => 100
      }
      run_helper(state_path, command("initialize", "budget" => overshoot_budget))
      reserve(state_path, id: "lane-hard-overshoot", tokens: 500)
      receipt = usage_receipt(
        id: "lane-hard-usage",
        segments: [
          { "id" => "lane-hard-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "task-lane-a", "tokens" => 650 }
        ]
      )
      receipt["overshoot"] = [{ "target_id" => "task-lane-a", "tokens" => 150, "turns" => 1 }]
      reconciled, = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "lane-hard-overshoot", "usage_receipt" => receipt)
      )
      assert_equal "reconciled", reconciled.fetch("status")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "budget-exhausted", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal 650, closeout.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 650, closeout.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_budget_exhausted_checkpoint_and_closeout_capture_exact_restart_evidence
    with_state do |state_path|
      initialize_budget(state_path)
      hard, = reserve(state_path, id: "hard", tokens: 600)
      assert_equal "budget-exhausted", hard.fetch("status")
      assert_equal "required", hard.fetch("checkpoint_status")

      checkpoint = {
        "type" => "batch-token-budget-checkpoint",
        "version" => 1,
        "id" => "checkpoint-hard-1",
        "batch_id" => "batch-399",
        "scope_id" => "lane-a",
        "status" => "budget-exhausted",
        "completion" => "NOT COMPLETE",
        "exact_work" => ["Implemented helper", "Ran focused tests"],
        "branch" => "jg-codex/399-hierarchical-token-budgets",
        "head_sha" => "a" * 40,
        "gates" => {
          "security" => "passed",
          "review" => "remaining",
          "qa" => "not-applicable",
          "exact-head" => "remaining",
          "ownership" => "held",
          "merge" => "not-authorized"
        },
        "receipt_cutoff" => "runtime-sequence:42",
        "resume_conditions" => ["Apply scoped budget increase", "Rerun exact-head gates"],
        "resume_action" => "Resume batch-399 from checkpoint-hard-1 after scoped approval."
      }
      saved, checkpoint_stderr, checkpoint_status = run_helper(
        state_path,
        command("checkpoint", "checkpoint" => checkpoint)
      )

      assert checkpoint_status.success?, checkpoint_stderr
      assert_equal "checkpointed", saved.fetch("status")
      assert_equal "NOT COMPLETE", saved.dig("checkpoint", "completion")
      assert_equal "a" * 40, saved.dig("checkpoint", "head_sha")
      assert_equal checkpoint.fetch("gates"), saved.dig("checkpoint", "gates")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "budget-exhausted", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal checkpoint, closeout.fetch("latest_checkpoint")
      assert_equal 0, closeout.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 0, closeout.dig("totals", "aggregate", "reserved_tokens")

      aggregate_override = budget_override(
        state_path,
        id: "checkpoint-aggregate-increase",
        scope_id: "aggregate",
        old_limit_tokens: 1_000,
        new_limit_tokens: 1_500,
        reason: "Resume from the hard checkpoint."
      )
      lane_override = budget_override(
        state_path,
        id: "checkpoint-lane-increase",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 1_300,
        reason: "Resume from the hard checkpoint."
      )
      run_helper(state_path, command("override", "override" => aggregate_override))
      run_helper(state_path, command("override", "override" => lane_override))
      resumed, = reserve(state_path, id: "hard-resume", tokens: 600)
      assert_equal "admitted", resumed.fetch("status")
      run_helper(
        state_path,
        command(
          "release",
          "release" => {
            "type" => "batch-token-release",
            "version" => 1,
            "id" => "release-resumed-hard",
            "reservation_id" => "hard-resume",
            "reason" => "Resumed boundary completed without observable use."
          }
        )
      )
      recovered, = run_helper(state_path, command("closeout"))
      assert_equal "complete", recovered.fetch("status")
      assert_equal "COMPLETE", recovered.fetch("completion")
    end
  end

  def test_stale_malformed_unknown_and_duplicate_authoritative_receipts_fail_closed
    with_state do |state_path|
      receipt_budget = budget(state_path: state_path)
      receipt_budget["scopes"]["lanes"]["lane-a"]["limit_tokens"] = 1_000
      run_helper(state_path, command("initialize", "budget" => receipt_budget))
      receipt_envelope = reservation(id: "receipt-envelope", tokens: 300).fetch("telemetry").merge(
        "self_estimate_tokens" => 200,
        "descendant_estimate_tokens" => 100,
        "descendant_target_ids" => %w[child-a grandchild-a]
      )
      reserve(
        state_path,
        id: "receipt-gate-1",
        tokens: 300,
        overrides: { "telemetry" => receipt_envelope }
      )
      stale_receipt = usage_receipt(id: "stale-usage")
      stale_receipt["observed_at"] = "2026-08-12T11:00:00Z"
      stale, = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "receipt-gate-1", "usage_receipt" => stale_receipt)
      )
      assert_equal "blocked", stale.fetch("status")
      assert_equal "usage-telemetry-stale", stale.fetch("reason")
      assert_equal 300, stale.dig("totals", "aggregate", "reserved_tokens")

      unknown_receipt = usage_receipt(id: "unknown-usage")
      unknown_receipt["producer"]["kind"] = "UNKNOWN"
      unknown, = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "receipt-gate-1", "usage_receipt" => unknown_receipt)
      )
      assert_equal "blocked", unknown.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", unknown.fetch("reason")

      reconcile = command(
        "reconcile",
        "reservation_id" => "receipt-gate-1",
        "usage_receipt" => usage_receipt(id: "counted-usage")
      )
      counted, = run_helper(state_path, reconcile)
      assert_equal "reconciled", counted.fetch("status")
      assert_equal 250, counted.dig("totals", "aggregate", "consumed_tokens")

      reserve(
        state_path,
        id: "receipt-gate-2",
        tokens: 300,
        overrides: { "telemetry" => receipt_envelope }
      )
      duplicate = usage_receipt(id: "duplicate-wrapper")
      denied, = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "receipt-gate-2", "usage_receipt" => duplicate)
      )
      assert_equal "blocked", denied.fetch("status")
      assert_equal "usage-segment-already-accounted", denied.fetch("reason")
      assert_equal 250, denied.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_coordinator_scope_and_all_expensive_continuation_kinds_use_the_same_admission_gate
    Dir.mktmpdir("batch-token-budget-admission-kinds") do |directory|
      %w[spawn retry review-wave scheduled-continuation monitor resume].each do |kind|
        state_path = File.join(directory, "#{kind}.json")
        initialize_budget(state_path)
        overrides = kind == "resume" ? { "target_state" => "paused" } : {}
        blocked, stderr, status = reserve(
          state_path,
          id: "#{kind}-admission",
          tokens: 500,
          kind: kind,
          overrides: overrides
        )
        assert status.success?, stderr
        assert_equal "approval-required", blocked.fetch("status"), kind
        assert_equal 0, blocked.dig("totals", "aggregate", "reserved_tokens"), kind
      end

      coordinator_state = File.join(directory, "coordinator.json")
      initialize_budget(coordinator_state)
      coordinator_target = task_identity(task_id: "root-399", lane_id: "coordinator")
      coordinator_reservation = reservation(
        id: "coordinator-turn",
        tokens: 150,
        overrides: { "scope_id" => "coordinator", "target" => coordinator_target }
      )
      admitted, stderr, status = run_helper(
        coordinator_state,
        command("reserve", "reservation" => coordinator_reservation)
      )
      assert status.success?, stderr
      assert_equal "admitted-with-warning", admitted.fetch("status")
      assert_equal 150, admitted.dig("totals", "coordinator", "reserved_tokens")
      assert_equal 150, admitted.dig("totals", "aggregate", "reserved_tokens")
      assert_equal "warning", admitted.dig("checkpoint", "status")
    end
  end

  def test_expired_scoped_overrides_restore_prior_limits_before_admission
    with_state do |state_path|
      initialize_budget(state_path)
      aggregate_override = budget_override(
        state_path,
        id: "short-aggregate",
        scope_id: "aggregate",
        old_limit_tokens: 1_000,
        new_limit_tokens: 1_500,
        reason: "One short admission window.",
        expires_at: "2026-08-12T12:05:00Z"
      )
      lane_override = budget_override(
        state_path,
        id: "short-lane",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 800,
        reason: "One short admission window.",
        expires_at: "2026-08-12T12:05:00Z"
      )
      run_helper(state_path, command("override", "override" => aggregate_override))

      incompatible_lane_override = budget_override(
        state_path,
        id: "incompatible-lane",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 1_200,
        expires_at: "2026-08-12T14:00:00Z"
      )
      incompatible, incompatible_stderr, incompatible_status = run_helper(
        state_path,
        command("override", "override" => incompatible_lane_override)
      )
      refute incompatible_status.success?
      assert_nil incompatible
      assert_equal "override-outlives-required-aggregate-headroom",
                   JSON.parse(incompatible_stderr).fetch("reason")

      run_helper(state_path, command("override", "override" => lane_override))

      expired_command = command(
        "reserve",
        "evaluated_at" => "2026-08-12T13:00:00Z",
        "reservation" => reservation(
          id: "after-expiry",
          tokens: 600,
          overrides: {
            "telemetry" => reservation(id: "ignored", tokens: 600).fetch("telemetry").merge(
              "observed_at" => "2026-08-12T12:59:00Z"
            )
          }
        )
      )
      stopped, stderr, status = run_helper(state_path, expired_command)

      assert status.success?, stderr
      assert_equal "budget-exhausted", stopped.fetch("status")
      assert_equal 1_000, stopped.dig("totals", "aggregate", "limit_tokens")
      assert_equal 600, stopped.dig("totals", "lanes", "lane-a", "limit_tokens")
      expiration_receipts = JSON.parse(File.read(state_path)).fetch("receipts").count do |receipt|
        receipt["type"] == "batch-token-budget-override-expiration-receipt"
      end
      assert_equal 2, expiration_receipts
    end
  end

  def test_usage_producer_requires_supported_kind_exact_fields_and_durable_non_self_attested_reference
    Dir.mktmpdir("batch-token-budget-producer-evidence") do |directory|
      variants = {
        "self-attested-uri" => proc { |producer| producer["evidence_ref"] = "self-attested://worker/usage" },
        "worker-self-attested-uri" => proc do |producer|
          producer["evidence_ref"] = "worker-self-attested://worker/usage"
        end,
        "plain-reference" => proc { |producer| producer["evidence_ref"] = "worker says 100 tokens" },
        "unknown-reference" => proc { |producer| producer["evidence_ref"] = "UNKNOWN" },
        "unsupported-kind" => proc { |producer| producer["kind"] = "worker-reported" },
        "extra-field" => proc { |producer| producer["self_attested"] = false }
      }
      variants.each do |name, mutate|
        state_path = File.join(directory, "#{name}.json")
        initialize_budget(state_path)
        reserve(state_path, id: "#{name}-reservation", tokens: 100, target_id: "#{name}-target")
        receipt = usage_receipt(
          id: "#{name}-usage",
          segments: [{
            "id" => "#{name}-self",
            "kind" => "self",
            "scope_id" => "lane-a",
            "target_id" => "#{name}-target",
            "tokens" => 100
          }]
        )
        mutate.call(receipt.fetch("producer"))

        blocked, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "reservation_id" => "#{name}-reservation",
            "usage_receipt" => receipt
          )
        )

        assert status.success?, stderr
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens"), name
        state = JSON.parse(File.read(state_path))
        assert_equal "active", state.dig("reservations", "#{name}-reservation", "status"), name
        assert_empty state.fetch("usage_receipts"), name
      end
    end
  end

  def test_unknown_segment_ownership_fails_closed_without_releasing_the_reservation
    with_state do |state_path|
      initialize_budget(state_path)
      unattributed_envelope = reservation(id: "ignored", tokens: 200).fetch("telemetry").merge(
        "self_estimate_tokens" => 150,
        "descendant_estimate_tokens" => 50,
        "descendant_target_ids" => ["unknown-child"]
      )
      reserve(state_path, id: "unattributed", tokens: 200, overrides: { "telemetry" => unattributed_envelope })
      receipt = usage_receipt(
        id: "usage-unattributed",
        segments: [
          { "id" => "known-self", "kind" => "self", "scope_id" => "lane-a", "target_id" => "task-lane-a", "tokens" => 100 },
          { "id" => "unknown-owner", "kind" => "descendant", "scope_id" => "UNKNOWN", "target_id" => "unknown-child", "tokens" => 50 }
        ]
      )
      blocked, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("reconcile", "reservation_id" => "unattributed", "usage_receipt" => receipt))
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal %w[read-only-discovery checkpoint], blocked.fetch("allowed_actions")
      assert_equal 0, blocked.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")
      persisted = JSON.parse(File.read(state_path))
      assert_equal "active", persisted.dig("reservations", "unattributed", "status")
      assert_empty persisted.fetch("usage_receipts")
      assert_empty persisted.fetch("usage_segments")
    end
  end

  def test_unknown_scope_usage_still_must_match_the_admitted_target_envelope
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "unknown-target-envelope", tokens: 200)
      receipt = usage_receipt(
        id: "usage-unknown-target-mismatch",
        segments: [
          {
            "id" => "unknown-target-segment",
            "kind" => "descendant",
            "scope_id" => "UNKNOWN",
            "target_id" => "not-admitted",
            "tokens" => 50
          }
        ]
      )

      blocked, stderr, status = run_helper(
        state_path,
        command("reconcile", "reservation_id" => "unknown-target-envelope", "usage_receipt" => receipt)
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 0, blocked.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_authoritative_usage_receipt_rejects_unlisted_fields_without_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "extra-receipt-field", tokens: 200)
      receipt = usage_receipt(
        id: "extra-field-usage",
        segments: [
          {
            "id" => "extra-field-self",
            "kind" => "self",
            "scope_id" => "lane-a",
            "target_id" => "task-lane-a",
            "tokens" => 100
          }
        ]
      )
      receipt["self_attested_total"] = 100

      blocked, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("reconcile", "reservation_id" => "extra-receipt-field", "usage_receipt" => receipt))
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_duplicate_json_keys_are_rejected_in_commands_receipts_attestations_and_state
    with_state do |state_path|
      initialize_budget(state_path)
      baseline = File.read(state_path)
      duplicate_command = JSON.generate(command("closeout")).sub(
        '"action":"closeout"',
        '"action":"closeout","action":"reserve"'
      )
      output, stderr, status = run_helper_raw(state_path, duplicate_command)
      refute status.success?
      assert_nil output
      assert_equal "malformed-json", JSON.parse(stderr).fetch("reason")
      assert_equal baseline, File.read(state_path)

      reserve(state_path, id: "duplicate-receipt", tokens: 200)
      before_receipt = File.read(state_path)
      reconcile = command(
        "reconcile",
        "reservation_id" => "duplicate-receipt",
        "usage_receipt" => usage_receipt(
          id: "duplicate-usage",
          segments: [
            {
              "id" => "duplicate-self",
              "kind" => "self",
              "scope_id" => "lane-a",
              "target_id" => "task-lane-a",
              "tokens" => 100
            }
          ]
        )
      )
      duplicate_receipt = JSON.generate(reconcile).sub(
        '"id":"duplicate-usage"',
        '"id":"duplicate-usage","id":"shadow-usage"'
      )
      output, stderr, status = run_helper_raw(state_path, duplicate_receipt)
      refute status.success?
      assert_nil output
      assert_equal "malformed-json", JSON.parse(stderr).fetch("reason")
      assert_equal before_receipt, File.read(state_path)

      attested = command("approve", "approval" => approval(state_path, id: "duplicate-attestation"))
      duplicate_attestation = JSON.generate(attested).sub(
        '"actor":"maintainer@example.test"',
        '"actor":"maintainer@example.test","actor":"UNKNOWN"'
      )
      output, stderr, status = run_helper_raw(state_path, duplicate_attestation)
      refute status.success?
      assert_nil output
      assert_equal "malformed-json", JSON.parse(stderr).fetch("reason")
      assert_equal before_receipt, File.read(state_path)

      corrupt_state = before_receipt.sub(/"revision":\d+/) { |field| "#{field},\"revision\":0" }
      refute_equal before_receipt, corrupt_state
      File.write(state_path, corrupt_state)
      output, stderr, status = run_helper(state_path, command("closeout"))
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_corrupt_persisted_accounting_fails_closed_after_restart
    with_state do |state_path|
      initialize_budget(state_path)
      state = JSON.parse(File.read(state_path))
      state.dig("scopes", "aggregate")["reserved_tokens"] = -1
      File.write(state_path, JSON.generate(state))

      output, stderr, status = run_helper(state_path, command("closeout"))

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_restart_rejects_deleted_reservations_and_mismatched_accounting_ledgers
    Dir.mktmpdir("batch-token-budget-ledger-integrity") do |directory|
      corruptions = {
        "deleted-reservation" => proc do |state|
          state.fetch("reservations").delete("ledger-reservation")
        end,
        "usage-ledger-total" => proc do |state|
          state.dig("usage_receipts", "ledger-usage")["tokens_counted"] += 1
        end,
        "reservation-reconciliation" => proc do |state|
          state.dig("reservations", "ledger-reservation", "reconciliation_receipt")["actual_tokens"] += 1
        end
      }
      corruptions.each do |name, corrupt|
        state_path = File.join(directory, "#{name}.json")
        initialize_budget(state_path)
        reserve(state_path, id: "ledger-reservation", tokens: 200)
        receipt = usage_receipt(
          id: "ledger-usage",
          segments: [
            {
              "id" => "ledger-self",
              "kind" => "self",
              "scope_id" => "lane-a",
              "target_id" => "task-lane-a",
              "tokens" => 120
            }
          ]
        )
        reconciled, stderr, status = run_helper(
          state_path,
          command("reconcile", "reservation_id" => "ledger-reservation", "usage_receipt" => receipt)
        )
        assert status.success?, stderr
        assert_equal "reconciled", reconciled.fetch("status")

        state = JSON.parse(File.read(state_path))
        corrupt.call(state)
        File.write(state_path, JSON.generate(state))
        output, corrupt_stderr, corrupt_status = run_helper(state_path, command("closeout"))

        refute corrupt_status.success?, name
        assert_nil output, name
        assert_equal "corrupt-persisted-state", JSON.parse(corrupt_stderr).fetch("reason"), name
      end
    end
  end

  def test_restart_rejects_scope_inflation_deleted_override_and_deleted_hard_stop
    Dir.mktmpdir("batch-token-budget-control-integrity") do |directory|
      inflated_path = File.join(directory, "inflated.json")
      initialize_budget(inflated_path)
      inflated = JSON.parse(File.read(inflated_path))
      inflated.dig("budget", "scopes", "aggregate")["limit_tokens"] = 10_000
      inflated.dig("budget", "scopes", "lanes", "lane-a")["limit_tokens"] = 10_000
      inflated.dig("scopes", "aggregate")["limit_tokens"] = 10_000
      inflated.dig("scopes", "lanes", "lane-a")["limit_tokens"] = 10_000
      inflated["effective_budget_digest"] = object_digest(inflated.fetch("budget"))
      rehash_control_tail(inflated)
      File.write(inflated_path, JSON.generate(inflated))
      output, stderr, status = reserve(inflated_path, id: "inflation-admission", tokens: 600)
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")

      override_path = File.join(directory, "deleted-override.json")
      initialize_budget(override_path)
      increase = budget_override(
        override_path,
        id: "durable-increase",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700
      )
      overridden, override_stderr, override_status = run_helper(
        override_path,
        command("override", "override" => increase)
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")
      deleted_override = JSON.parse(File.read(override_path))
      deleted_override.fetch("overrides").delete("durable-increase")
      rehash_control_tail(deleted_override)
      File.write(override_path, JSON.generate(deleted_override))
      output, stderr, status = run_helper(
        override_path,
        command("closeout", "evaluated_at" => "2026-08-12T14:00:00Z")
      )
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")

      hard_path = File.join(directory, "deleted-hard-stop.json")
      initialize_budget(hard_path)
      hard, = reserve(hard_path, id: "durable-hard-stop", tokens: 600)
      assert_equal "budget-exhausted", hard.fetch("status")
      deleted_hard = JSON.parse(File.read(hard_path))
      deleted_hard["admission_decisions"] = {}
      rehash_control_tail(deleted_hard)
      File.write(hard_path, JSON.generate(deleted_hard))
      output, stderr, status = run_helper(hard_path, command("closeout"))
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_restart_rejects_deleted_approval_and_tampered_control_event_chain
    Dir.mktmpdir("batch-token-budget-control-events") do |directory|
      approval_path = File.join(directory, "deleted-approval.json")
      initialize_budget(approval_path)
      accepted, approval_stderr, approval_status = run_helper(
        approval_path,
        command("approve", "approval" => approval(approval_path, id: "durable-approval"))
      )
      assert approval_status.success?, approval_stderr
      assert_equal "approved", accepted.fetch("status")
      deleted_approval = JSON.parse(File.read(approval_path))
      deleted_approval.fetch("approvals").delete("durable-approval")
      rehash_control_tail(deleted_approval)
      File.write(approval_path, JSON.generate(deleted_approval))
      output, stderr, status = run_helper(approval_path, command("closeout"))
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")

      attestation_path = File.join(directory, "deleted-attestation.json")
      initialize_budget(attestation_path)
      run_helper(
        attestation_path,
        command("approve", "approval" => approval(attestation_path, id: "attestation-record"))
      )
      deleted_attestation = JSON.parse(File.read(attestation_path))
      deleted_attestation.dig("approvals", "attestation-record", "decision").delete("attestation")
      rehash_control_tail(deleted_attestation)
      File.write(attestation_path, JSON.generate(deleted_attestation))
      output, stderr, status = run_helper(attestation_path, command("closeout"))
      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")

      tamper_cases = {
        "reordered" => proc(&:reverse!),
        "digest-mismatch" => proc { |events| events.last["digest"] = "0" * 64 },
        "predecessor-mismatch" => proc { |events| events.last["previous_digest"] = "0" * 64 },
        "unknown-field" => proc { |events| events.last["self_attested"] = true },
        "deleted-event" => proc(&:pop)
      }
      tamper_cases.each do |name, tamper|
        state_path = File.join(directory, "#{name}.json")
        initialize_budget(state_path)
        reserve(state_path, id: "#{name}-reservation")
        state = JSON.parse(File.read(state_path))
        assert_operator state.fetch("control_events").length, :>=, 2
        tamper.call(state.fetch("control_events"))
        File.write(state_path, JSON.generate(state))

        output, tamper_stderr, tamper_status = run_helper(state_path, command("closeout"))
        refute tamper_status.success?, name
        assert_nil output, name
        assert_equal "corrupt-persisted-state", JSON.parse(tamper_stderr).fetch("reason"), name
      end
    end
  end

  def test_restart_rejects_deleted_root_or_middle_control_events_after_public_chain_rehash
    Dir.mktmpdir("batch-token-budget-semantic-control-replay") do |directory|
      {
        "deleted-initialization" => 0,
        "deleted-middle" => 1
      }.each do |name, deletion_index|
        state_path = File.join(directory, "#{name}.json")
        initialize_budget(state_path)
        reserve(state_path, id: "#{name}-reservation", tokens: 100)
        run_helper(
          state_path,
          command(
            "release",
            "release" => {
              "type" => "batch-token-release",
              "version" => 1,
              "id" => "#{name}-release",
              "reservation_id" => "#{name}-reservation",
              "reason" => "Finish semantic replay probe."
            }
          )
        )
        state = JSON.parse(File.read(state_path))
        assert_operator state.fetch("control_events").length, :>=, 3
        state.fetch("control_events").delete_at(deletion_index)
        rechain_control_events(state)
        File.write(state_path, JSON.generate(state))

        output, stderr, status = run_helper(state_path, command("closeout"))

        refute status.success?, name
        assert_nil output, name
        assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason"), name
      end
    end
  end

  def test_restart_reducer_rejects_payload_and_final_projection_forgery_after_chain_rehash
    Dir.mktmpdir("batch-token-budget-control-payload-tamper") do |directory|
      {
        "edited-payload" => proc do |state|
          state.dig("control_events", 1, "payload", "command", "reservation")["tokens"] = 1
          rechain_control_events(state)
        end,
        "replaced-final-state" => proc do |state|
          state.dig("budget", "scopes", "aggregate")["limit_tokens"] = 10_000
          state.dig("budget", "scopes", "lanes", "lane-a")["limit_tokens"] = 10_000
          state.dig("scopes", "aggregate")["limit_tokens"] = 10_000
          state.dig("scopes", "lanes", "lane-a")["limit_tokens"] = 10_000
          state["effective_budget_digest"] = object_digest(state.fetch("budget"))
          state.dig("control_events", -1)["post_state_digest"] = object_digest(
            state.reject { |key, _value| key == "control_events" }
          )
          rechain_control_events(state)
        end,
        "orphaned-anchor" => proc do |state|
          state.dig("control_events", 0, "payload")["trusted_plan_digest"] = "sha256:#{'0' * 64}"
          rechain_control_events(state)
        end
      }.each do |name, tamper|
        state_path = File.join(directory, "#{name}.json")
        initialize_budget(state_path)
        reserve(state_path, id: "#{name}-reservation", tokens: 100)
        state = JSON.parse(File.read(state_path))
        tamper.call(state)
        File.write(state_path, JSON.generate(state))

        output, stderr, status = run_helper(state_path, command("closeout"))

        refute status.success?, name
        assert_nil output, name
        assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason"), name
      end
    end
  end

  def test_restart_rejects_deleted_charge_back_even_after_control_tail_rehash
    with_state do |state_path|
      cross_budget = budget(state_path: state_path)
      cross_budget["delegation"]["approval_threshold_tokens"] = 400
      run_helper(state_path, command("initialize", "budget" => cross_budget))
      source = task_identity(task_id: "charge-source")
      source["batch_id"] = "source-batch"
      target = task_identity(task_id: "task-lane-a")
      cross_task = reservation(
        id: "charge-reservation",
        tokens: 100,
        kind: "cross-task-delegation",
        overrides: { "source" => source, "target" => target }
      )
      run_helper(state_path, command("reserve", "reservation" => cross_task))
      usage = usage_receipt(
        id: "charge-usage",
        segments: [{
          "id" => "charge-self",
          "kind" => "self",
          "scope_id" => "lane-a",
          "target_id" => "task-lane-a",
          "tokens" => 100
        }]
      )
      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "reservation_id" => "charge-reservation",
          "usage_receipt" => usage,
          "charge_back" => {
            "type" => "batch-token-charge-back",
            "version" => 1,
            "id" => "charge-cause",
            "source" => source,
            "target" => target
          }
        )
      )
      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")

      state = JSON.parse(File.read(state_path))
      state.fetch("charge_backs").delete("charge-cause")
      rehash_control_tail(state)
      File.write(state_path, JSON.generate(state))

      output, restart_stderr, restart_status = run_helper(state_path, command("closeout"))
      refute restart_status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(restart_stderr).fetch("reason")
    end
  end

  def test_command_time_is_monotonic_and_human_receipts_cannot_take_effect_early
    with_state do |state_path|
      initialize_budget(state_path)
      future_approval = approval(
        state_path,
        id: "future-approval",
        reason: "This decision has not happened yet.",
        issued_at: "2026-08-12T12:30:00Z"
      )
      output, future_stderr, future_status = run_helper(
        state_path,
        command("approve", "approval" => future_approval)
      )
      refute future_status.success?
      assert_nil output
      assert_equal "invalid-approval", JSON.parse(future_stderr).fetch("reason")

      future_override = budget_override(
        state_path,
        id: "future-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700,
        reason: "This increase has not happened yet.",
        issued_at: "2026-08-12T12:30:00Z"
      )
      override_output, override_stderr, override_status = run_helper(
        state_path,
        command("override", "override" => future_override)
      )
      refute override_status.success?
      assert_nil override_output
      assert_equal "invalid-override", JSON.parse(override_stderr).fetch("reason")

      run_helper(state_path, command("closeout", "evaluated_at" => "2026-08-12T14:00:00Z"))
      backdated, backdated_stderr, backdated_status = run_helper(
        state_path,
        command("reserve", "reservation" => reservation(id: "backdated"))
      )
      refute backdated_status.success?
      assert_nil backdated
      assert_equal "command-time-rollback", JSON.parse(backdated_stderr).fetch("reason")
    end
  end
end
