#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "base64"
require "digest"
require "rbconfig"
require "time"
require "tmpdir"

HELPER = File.expand_path("batch-token-budget", __dir__)
FIXTURE = File.expand_path("../fixtures/batch-token-budget-v1.json", __dir__)
USAGE_HELPER = File.expand_path("batch-usage-receipt", __dir__)
USAGE_FIXTURE = File.expand_path("../fixtures/batch-usage-receipt/descendants.json", __dir__)

class BatchTokenBudgetTest < Minitest::Test
  TEST_VERIFIER_KEY = OpenSSL::PKey::RSA.generate(2048)
  TRUSTED_CLOCK_SOURCE = <<~RUBY
    class << Time
      def now
        at(Float(ENV.fetch("BATCH_TOKEN_BUDGET_TEST_EPOCH"))).utc
      end
    end
    class << Process
      def clock_gettime(_clock_id, *_arguments)
        0.0
      end
    end
  RUBY
  DEFAULT_TRUSTED_CLOCK_DIRECTORY = Dir.mktmpdir("batch-token-budget-default-clock")
  DEFAULT_TRUSTED_CLOCK_PRELOADER = File.join(DEFAULT_TRUSTED_CLOCK_DIRECTORY, "trusted-clock.rb")
  File.write(DEFAULT_TRUSTED_CLOCK_PRELOADER, TRUSTED_CLOCK_SOURCE)
  Minitest.after_run { FileUtils.remove_entry(DEFAULT_TRUSTED_CLOCK_DIRECTORY) }

  def load_batch_token_budget_module
    return if defined?(BatchTokenBudget)

    source = File.read(HELPER, encoding: "UTF-8").split("\noptions = {}\n", 2).fetch(0)
    Dir.mktmpdir("batch-token-budget-module") do |directory|
      module_path = File.join(directory, "batch-token-budget-module.rb")
      File.write(module_path, source)
      load module_path
    end
  end

  def test_triage_budget_abbreviation_names_the_coordinator_scope
    triage_skill = File.read(File.expand_path("../../triage/SKILL.md", __dir__), encoding: "UTF-8")

    assert_includes triage_skill, "`A/R/L` is aggregate/coordinator/lane limits"
    refute_includes triage_skill, "`A/R/L` is aggregate/root/lane limits"
  end

  def test_linux_uses_suspend_aware_boottime_and_fails_closed_without_it
    load_batch_token_budget_module
    linux_process = Module.new
    linux_process.const_set(:CLOCK_BOOTTIME, :boottime)
    darwin_process = Module.new
    darwin_process.const_set(:CLOCK_MONOTONIC, :monotonic)

    assert_equal :boottime, BatchTokenBudget.suspend_aware_clock_id("x86_64-linux", linux_process)
    assert_equal :monotonic, BatchTokenBudget.suspend_aware_clock_id("arm64-darwin", darwin_process)
    error = assert_raises(BatchTokenBudget::InvalidInput) do
      BatchTokenBudget.suspend_aware_clock_id("x86_64-linux", Module.new)
    end
    assert_equal "trusted-clock-unavailable", error.message
  end

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

  def host_timestamp(offset_seconds)
    format_timestamp(Time.now.utc + offset_seconds)
  end

  def format_timestamp(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
  end

  def run_helper(state_path, input, **options)
    install_trusted_plan(state_path, input.fetch("budget")) if input["action"] == "initialize" && input["budget"]
    run_helper_raw(state_path, JSON.generate(input), **options)
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

  def run_helper_raw(state_path, input, anchor: trusted_anchor_binding(state_path), env: nil, ruby_arguments: nil)
    clock_options = trusted_clock_options_for_command(input)
    stdout, stderr, status = Open3.capture3(
      env || clock_options.fetch(:env),
      RbConfig.ruby,
      *(ruby_arguments || clock_options.fetch(:ruby_arguments)),
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

  def run_helper_raw_with_watchdog(
    state_path, input, timeout_seconds:, anchor: trusted_anchor_binding(state_path), before_stdin: nil,
    env: nil, ruby_arguments: nil
  )
    clock_options = trusted_clock_options_for_command(input)
    stdout_text = nil
    stderr_text = nil
    status = nil
    Open3.popen3(
      env || clock_options.fetch(:env),
      RbConfig.ruby,
      *(ruby_arguments || clock_options.fetch(:ruby_arguments)),
      HELPER,
      "--state",
      state_path,
      "--trusted-plan",
      anchor.fetch("path"),
      "--trusted-plan-id",
      anchor.fetch("id"),
      "--trusted-plan-digest",
      anchor.fetch("digest")
    ) do |stdin, stdout, stderr, wait_thread|
      before_stdin&.call(wait_thread.pid)
      stdin.write(input)
      stdin.close
      unless wait_thread.join(timeout_seconds)
        Process.kill("TERM", wait_thread.pid)
        Process.kill("KILL", wait_thread.pid) unless wait_thread.join(0.2)
        wait_thread.join
        flunk "helper exceeded #{timeout_seconds}-second watchdog"
      end

      stdout_text = stdout.read
      stderr_text = stderr.read
      status = wait_thread.value
    ensure
      stdin.close unless stdin.closed?
      unless wait_thread.join(0)
        Process.kill("KILL", wait_thread.pid)
        wait_thread.join
      end
    end
    [stdout_text.empty? ? nil : JSON.parse(stdout_text), stderr_text, status]
  end

  def trusted_clock_options(directory, trusted_time)
    preloader = File.join(directory, "trusted-clock.rb")
    File.write(preloader, TRUSTED_CLOCK_SOURCE)
    trusted_clock_options_for_time(trusted_time, preloader: preloader)
  end

  def trusted_clock_options_for_time(trusted_time, preloader: DEFAULT_TRUSTED_CLOCK_PRELOADER)
    {
      env: { "BATCH_TOKEN_BUDGET_TEST_EPOCH" => trusted_time.to_f.to_s },
      ruby_arguments: ["-r", preloader]
    }
  end

  def trusted_clock_options_with_elapsed(directory, trusted_time, elapsed_seconds)
    preloader = File.join(directory, "trusted-clock-with-elapsed.rb")
    File.write(preloader, <<~RUBY)
      class << Time
        def now
          $batch_token_budget_test_wall_captured = true
          at(Float(ENV.fetch("BATCH_TOKEN_BUDGET_TEST_EPOCH"))).utc
        end
      end
      class << Process
        def clock_gettime(_clock_id, *_arguments)
          elapsed = Float(ENV.fetch("BATCH_TOKEN_BUDGET_TEST_ELAPSED"))
          unless defined?(@batch_token_budget_test_monotonic_captured)
            @batch_token_budget_test_monotonic_captured = true
            return $batch_token_budget_test_wall_captured ? elapsed : 0.0
          end

          elapsed
        end
      end
    RUBY
    {
      env: {
        "BATCH_TOKEN_BUDGET_TEST_EPOCH" => trusted_time.to_f.to_s,
        "BATCH_TOKEN_BUDGET_TEST_ELAPSED" => elapsed_seconds.to_s
      },
      ruby_arguments: ["-r", preloader]
    }
  end

  def trusted_clock_options_for_command(input)
    evaluated_at = JSON.parse(input, allow_duplicate_key: true)["evaluated_at"]
    trusted_clock_options_for_time(Time.iso8601(evaluated_at))
  rescue JSON::ParserError, TypeError, ArgumentError
    { env: {}, ruby_arguments: [] }
  end

  def closeout_in_memory(state, evaluated_at)
    unless defined?(BatchTokenBudget)
      source = File.read(HELPER, encoding: "UTF-8")
      module_source = source.split("\noptions = {}\n", 2).fetch(0)
      Dir.mktmpdir("batch-token-budget-module") do |directory|
        module_path = File.join(directory, "batch-token-budget-module.rb")
        File.write(module_path, module_source)
        load module_path
      end
    end
    BatchTokenBudget.closeout_command(state, evaluated_at).last
  end

  def with_state
    Dir.mktmpdir("batch-token-budget-test") do |directory|
      yield File.join(directory, "state.json")
    end
  end

  def initialize_budget(state_path, evaluated_at: "2026-08-12T11:00:00Z")
    install_trusted_plan(state_path)
    run_helper(
      state_path,
      command("initialize", "evaluated_at" => evaluated_at, "budget" => budget(state_path: state_path))
    )
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

  def real_descendants_usage_receipt(state_path, remove_turn_context_for: nil)
    fixture = JSON.parse(File.read(USAGE_FIXTURE, encoding: "UTF-8"))
    fixture.fetch("manifest")["batch_id"] = "batch-399"
    fixture.fetch("window").merge!(
      "from" => "2026-08-12T11:00:00Z",
      "to" => "2026-08-12T12:00:00Z"
    )
    fixture.fetch("rollouts").each_value do |records|
      records.each_with_index do |record, index|
        record["timestamp"] = index.zero? ? "2026-08-12T11:58:00Z" : "2026-08-12T11:59:00Z"
      end
    end
    if remove_turn_context_for
      fixture.dig("rollouts", remove_turn_context_for).reject! { |record| record["type"] == "turn_context" }
    end

    directory = File.dirname(state_path)
    fixture.fetch("rollouts").each do |basename, records|
      File.write(File.join(directory, basename), "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")
    end
    database_path = File.join(directory, "state_5.sqlite")
    sql = +<<~SQL
      CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT,
        model_provider TEXT NOT NULL,
        model TEXT,
        reasoning_effort TEXT
      );
      CREATE TABLE thread_spawn_edges (
        parent_thread_id TEXT NOT NULL,
        child_thread_id TEXT NOT NULL PRIMARY KEY,
        status TEXT NOT NULL
      );
    SQL
    quote = ->(value) { value.nil? ? "NULL" : "'#{value.to_s.gsub("'", "''")}'" }
    fixture.fetch("threads").each do |thread|
      rollout_path = thread["rollout"] && File.join(directory, thread.fetch("rollout"))
      values = [
        thread.fetch("id"), rollout_path, thread.fetch("model_provider"), thread["model"], thread["reasoning_effort"]
      ].map { |value| quote.call(value) }
      sql << "INSERT INTO threads VALUES (#{values.join(', ')});\n"
    end
    fixture.fetch("edges").each do |edge|
      sql << "INSERT INTO thread_spawn_edges VALUES (#{edge.map { |value| quote.call(value) }.join(', ')});\n"
    end
    _stdout, database_stderr, database_status = Open3.capture3("sqlite3", database_path, stdin_data: sql)
    assert database_status.success?, database_stderr

    manifest_path = File.join(directory, "batch-usage-manifest.json")
    File.write(manifest_path, JSON.generate(fixture.fetch("manifest")))
    stdout, stderr, status = Open3.capture3(
      "ruby", USAGE_HELPER,
      "--state-db", database_path,
      "--manifest", manifest_path,
      "--from", fixture.dig("window", "from"),
      "--to", fixture.dig("window", "to")
    )
    assert status.success?, stderr

    receipt = JSON.parse(stdout)
    receipt_artifact(state_path, receipt, "descendants")
  end

  def receipt_artifact(state_path, receipt, name)
    artifact_path = File.join(File.dirname(state_path), "batch-usage-receipt-#{name}.json")
    File.write(artifact_path, JSON.generate(canonicalize(receipt)))
    [receipt, "file://#{artifact_path}", "sha256:#{object_digest(receipt)}"]
  end

  def available_credit_equivalents
    {
      "status" => "available",
      "source" => "https://example.invalid/rate-card/2026-08-04",
      "effective_date" => "2026-08-04",
      "model_values" => [{
        "host" => "codex",
        "model" => "gpt-5.6",
        "status" => "available",
        "credits" => 1
      }],
      "disclaimer" => "Estimate only; not a bill"
    }
  end

  def unknown_credit_equivalents
    available_credit_equivalents.merge(
      "status" => "UNKNOWN",
      "model_values" => [{
        "host" => "codex",
        "model" => "UNKNOWN",
        "status" => "UNKNOWN",
        "code" => "route_identity_unknown"
      }]
    )
  end

  def usage_window(
    receipt, from:, to:, coordinator_tokens:, lane_tokens:, batch_unattributed_tokens: 0,
    coordinator_turns: nil, lane_turns: nil, batch_unattributed_turns: nil
  )
    projected = JSON.parse(JSON.generate(receipt))
    projected.fetch("window").merge!("from_inclusive" => from, "to_exclusive" => to)
    coordinator_turns ||= coordinator_tokens.positive? ? 1 : 0
    batch_unattributed_turns ||= batch_unattributed_tokens.positive? ? 1 : 0
    lane_turns ||= lane_tokens.to_h { |lane_id, tokens| [lane_id, tokens.positive? ? 1 : 0] }
    set_usage_total(projected.dig("coordinator", "usage", "self_only"), coordinator_tokens)
    batch_tokens = coordinator_tokens + batch_unattributed_tokens + lane_tokens.values.sum
    batch_turns = coordinator_turns + batch_unattributed_turns + lane_turns.values.sum
    set_usage_total(projected.dig("coordinator", "usage", "descendant_inclusive"), batch_tokens)
    projected.dig("coordinator", "turns").merge!(
      "self_only" => coordinator_turns,
      "descendant_inclusive" => batch_turns
    )
    projected.fetch("lanes").each do |lane|
      tokens = lane_tokens.fetch(lane.fetch("id"))
      turns = lane_turns.fetch(lane.fetch("id"))
      set_usage_total(lane.dig("usage", "self_only"), tokens)
      set_usage_total(lane.dig("usage", "descendant_inclusive"), tokens)
      set_usage_total(lane.dig("usage", "unattributed"), tokens)
      lane.fetch("turns").merge!("self_only" => turns, "descendant_inclusive" => turns, "unattributed" => turns)
      lane.fetch("workers").each do |worker|
        set_usage_total(worker.dig("usage", "self_only"), 0)
        set_usage_total(worker.dig("usage", "descendant_inclusive"), 0)
        worker.fetch("turns").merge!("self_only" => 0, "descendant_inclusive" => 0)
      end
    end
    set_usage_total(projected.dig("batch", "usage", "descendant_inclusive"), batch_tokens)
    set_usage_total(projected.dig("batch", "usage", "unattributed"), batch_unattributed_tokens)
    projected.fetch("batch").fetch("turns").merge!(
      "descendant_inclusive" => batch_turns,
      "unattributed" => batch_unattributed_turns
    )
    projected
  end

  def lane_component_usage_window(
    state_path, lane_tokens:, lane_turns:, worker_tokens:, worker_turns:,
    unattributed_tokens:, unattributed_turns:,
    worker_self_tokens: worker_tokens, worker_self_turns: worker_turns
  )
    base_receipt, = real_descendants_usage_receipt(state_path)
    receipt = usage_window(
      base_receipt,
      from: "2026-08-12T11:00:00Z",
      to: "2026-08-12T12:00:00Z",
      coordinator_tokens: 0,
      lane_tokens: { "lane-a" => lane_tokens, "lane-b" => 0 },
      lane_turns: { "lane-a" => lane_turns, "lane-b" => 0 }
    )
    lane = receipt.fetch("lanes").find { |candidate| candidate.fetch("id") == "lane-a" }
    worker = lane.fetch("workers").first
    set_usage_total(lane.dig("usage", "self_only"), 0)
    set_usage_total(lane.dig("usage", "unattributed"), unattributed_tokens)
    lane.fetch("turns").merge!("self_only" => 0, "unattributed" => unattributed_turns)
    set_usage_total(worker.dig("usage", "self_only"), worker_self_tokens)
    set_usage_total(worker.dig("usage", "descendant_inclusive"), worker_tokens)
    worker.fetch("turns").merge!(
      "self_only" => worker_self_turns,
      "descendant_inclusive" => worker_turns
    )
    receipt
  end

  def reconcile_receipt(state_path, receipt, name, completed_reservation_ids: [])
    receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, name)
    run_helper(
      state_path,
      command(
        "reconcile",
        "usage_receipt" => receipt,
        "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest,
        "completed_reservation_ids" => completed_reservation_ids
      )
    )
  end

  def reconcile_final_zero_usage_window(
    state_path,
    name:,
    to: "2026-08-12T12:00:00Z",
    evaluated_at: to
  )
    state = JSON.parse(File.read(state_path))
    base_receipt, = real_descendants_usage_receipt(state_path)
    receipt = usage_window(
      base_receipt,
      from: state["usage_cursor"] || state.fetch("usage_initial_cutoff"),
      to: to,
      coordinator_tokens: 0,
      lane_tokens: state.dig("scopes", "lanes").keys.to_h { |lane_id| [lane_id, 0] }
    )
    receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, name)
    run_helper(
      state_path,
      command(
        "reconcile",
        "evaluated_at" => evaluated_at,
        "usage_receipt" => receipt,
        "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest,
        "completed_reservation_ids" => []
      )
    )
  end

  def assert_batch_component_turn_borrowing_rejected(
    name:, coordinator_turns:, batch_unattributed_turns:
  )
    with_state do |state_path|
      initialize_budget(state_path)
      reservation_id = "#{name}-reservation"
      admitted, admitted_stderr, admitted_status = reserve(
        state_path,
        id: reservation_id,
        lane_id: "coordinator",
        tokens: 100
      )
      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted", admitted.fetch("status")

      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 100,
        coordinator_turns: coordinator_turns,
        batch_unattributed_tokens: 400,
        batch_unattributed_turns: batch_unattributed_turns,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      state_before = File.read(state_path)
      blocked, stderr, status = reconcile_receipt(
        state_path,
        receipt,
        name,
        completed_reservation_ids: [reservation_id]
      )

      saved = JSON.parse(File.read(state_path))
      assert_equal(
        {
          "consumed_tokens" => 0,
          "receipt_count" => 0,
          "reservation_status" => "active",
          "usage_cursor" => nil
        },
        {
          "consumed_tokens" => saved.dig("scopes", "aggregate", "consumed_tokens"),
          "receipt_count" => saved.fetch("usage_receipts").length,
          "reservation_status" => saved.dig("reservations", reservation_id, "status"),
          "usage_cursor" => saved["usage_cursor"]
        },
        name
      )
      assert_equal state_before, File.read(state_path), name
      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status"), name
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
    end
  end

  def set_usage_total(usage, tokens)
    usage.merge!(
      "input_tokens" => tokens,
      "output_tokens" => 0,
      "reasoning_output_tokens" => 0,
      "cache_read_tokens" => 0,
      "total_tokens" => tokens
    )
  end

  def set_usage_counter(value, counter, replacement)
    case value
    when Hash
      value[counter] = replacement if value.keys.sort == %w[
        cache_read_tokens input_tokens output_tokens reasoning_output_tokens total_tokens
      ]
      value.each_value { |child| set_usage_counter(child, counter, replacement) }
    when Array
      value.each { |child| set_usage_counter(child, counter, replacement) }
    end
  end

  def legacy_v1_receipt(receipt)
    legacy = JSON.parse(JSON.generate(receipt))
    legacy["schema"] = "batch-usage-receipt-v1"
    legacy.fetch("batch").delete("turns")
    legacy.fetch("coordinator").delete("turns")
    legacy.fetch("lanes").each do |lane|
      lane.delete("turns")
      lane.fetch("workers").each { |worker| worker.delete("turns") }
    end
    legacy
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
      state = JSON.parse(File.read(state_path))
      assert_equal "2026-08-12T11:00:00Z", state.fetch("usage_initial_cutoff")
      assert_equal state.fetch("usage_initial_cutoff"), state.dig("receipts", 0, "usage_initial_cutoff")

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

  def test_initialize_replay_at_a_later_command_time_is_idempotent
    with_state do |state_path|
      first, stderr, status = initialize_budget(state_path)
      assert status.success?, stderr
      assert_equal "initialized", first.fetch("status")
      state_before = File.read(state_path)

      replayed, replay_stderr, replay_status = initialize_budget(
        state_path,
        evaluated_at: "2026-08-12T12:00:00Z"
      )

      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal state_before, File.read(state_path)
      state = JSON.parse(state_before)
      assert_equal "2026-08-12T11:00:00Z", state.fetch("last_evaluated_at")
      assert_equal 1, state.fetch("control_events").length
    end
  end

  def test_runtime_trusted_plan_limit_accepts_the_boundary_and_blocks_oversized_state_creation
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      artifact_json = File.read(anchor.fetch("path"))
      File.write(anchor.fetch("path"), artifact_json.ljust(1_048_576))

      initialized, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        anchor: anchor
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      assert File.file?(state_path)
    end

    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      artifact_json = File.read(anchor.fetch("path"))
      File.write(anchor.fetch("path"), artifact_json.ljust(1_048_577))

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        anchor: anchor
      )

      assert_equal(
        { "state" => false, "lock" => false },
        { "state" => File.exist?(state_path), "lock" => File.exist?("#{state_path}.lock") }
      )
      refute status.success?
      assert_nil output
      assert_equal "trusted-plan-oversized", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_trusted_plan_fifo_is_rejected_boundedly_before_artifact_creation
    Dir.mktmpdir("batch-token-budget-fifo-plan") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      fifo_path = File.join(directory, "trusted-plan.fifo")
      assert system("mkfifo", fifo_path), "mkfifo failed"
      anchor = {
        "path" => fifo_path,
        "id" => candidate.fetch("batch_id"),
        "digest" => "sha256:#{object_digest(candidate)}"
      }

      output, stderr, status = run_helper_raw_with_watchdog(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        timeout_seconds: 1,
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "trusted-plan-unreadable", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_trusted_plan_symlink_to_a_bounded_regular_file_remains_valid
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      regular_anchor = install_trusted_plan(state_path, candidate)
      symlink_path = File.join(File.dirname(state_path), "trusted-plan-link.json")
      File.symlink(regular_anchor.fetch("path"), symlink_path)
      symlink_anchor = regular_anchor.merge("path" => symlink_path)

      initialized, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        anchor: symlink_anchor
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      assert_equal symlink_path, JSON.parse(File.read(state_path)).dig("trusted_plan_binding", "path")
    end
  end

  def test_preplanted_state_lock_symlink_is_rejected_without_following
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      victim_path = File.join(File.dirname(state_path), "lock-victim.txt")
      File.write(victim_path, "lock-victim-sentinel")
      File.symlink(victim_path, "#{state_path}.lock")

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "state-lock-unsafe", JSON.parse(stderr).fetch("reason")
      assert_equal "lock-victim-sentinel", File.read(victim_path)
      refute File.exist?(state_path)
      assert File.symlink?("#{state_path}.lock")
    end
  end

  def test_state_path_swap_to_fifo_is_rejected_boundedly_without_reading_a_different_object
    with_state do |state_path|
      initialize_budget(state_path)
      state_before = File.binread(state_path)
      backup_path = "#{state_path}.swap-backup"
      preloader = File.join(File.dirname(state_path), "state-swap-preloader.rb")
      File.write(
        preloader,
        <<~RUBY
          require "fileutils"
          class << File
            alias_method :batch_budget_original_file?, :file?
            alias_method :batch_budget_original_open, :open

            def batch_budget_swap_state_path(path)
              return unless path.to_s == ENV["BATCH_TOKEN_BUDGET_SWAP_STATE"]
              return if ENV["BATCH_TOKEN_BUDGET_SWAP_DONE"] == "1"

              ENV["BATCH_TOKEN_BUDGET_SWAP_DONE"] = "1"
              rename(path, ENV.fetch("BATCH_TOKEN_BUDGET_SWAP_BACKUP"))
              system("mkfifo", path) or raise "mkfifo failed"
            end

            def file?(path)
              result = batch_budget_original_file?(path)
              if path.to_s == ENV["BATCH_TOKEN_BUDGET_SWAP_STATE"] && result
                count = ENV.fetch("BATCH_TOKEN_BUDGET_STATE_FILE_CHECKS", "0").to_i + 1
                ENV["BATCH_TOKEN_BUDGET_STATE_FILE_CHECKS"] = count.to_s
                batch_budget_swap_state_path(path) if count == 2
              end
              result
            end

            def open(path, *arguments, **options, &block)
              batch_budget_swap_state_path(path)
              batch_budget_original_open(path, *arguments, **options, &block)
            end
          end
        RUBY
      )
      clock_options = trusted_clock_options_for_command(JSON.generate(command("closeout")))
      environment = clock_options.fetch(:env).merge(
        "BATCH_TOKEN_BUDGET_SWAP_STATE" => state_path,
        "BATCH_TOKEN_BUDGET_SWAP_BACKUP" => backup_path
      )

      output, stderr, status = run_helper_raw_with_watchdog(
        state_path,
        JSON.generate(command("closeout")),
        timeout_seconds: 1,
        env: environment,
        ruby_arguments: [*clock_options.fetch(:ruby_arguments), "-r", preloader]
      )

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
      assert_equal state_before, File.binread(backup_path)
      assert File.pipe?(state_path)
    ensure
      File.unlink(state_path) if state_path && File.pipe?(state_path)
      File.rename(backup_path, state_path) if backup_path && File.exist?(backup_path)
    end
  end

  def test_preexisting_state_fifo_is_rejected_boundedly_as_corrupt_persisted_state
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      assert system("mkfifo", state_path), "mkfifo failed"

      output, stderr, status = run_helper_raw_with_watchdog(
        state_path,
        JSON.generate(command("closeout")),
        timeout_seconds: 1,
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
      assert File.pipe?(state_path)
    end
  end

  def test_preexisting_state_symlink_is_rejected_without_following
    with_state do |state_path|
      initialize_budget(state_path)
      state_before = File.binread(state_path)
      victim_path = "#{state_path}.victim"
      File.rename(state_path, victim_path)
      File.symlink(victim_path, state_path)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout"))
      )

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
      assert File.symlink?(state_path)
      assert_equal state_before, File.binread(victim_path)
    ensure
      File.unlink(state_path) if state_path && File.symlink?(state_path)
      File.rename(victim_path, state_path) if victim_path && File.exist?(victim_path)
    end
  end

  def test_regular_persisted_state_is_opened_once_and_eacces_remains_structured_and_mutation_free
    with_state do |state_path|
      initialize_budget(state_path)
      counter_path = "#{state_path}.open-count"
      preloader = File.join(File.dirname(state_path), "state-open-counter.rb")
      File.write(
        preloader,
        <<~RUBY
          class << File
            alias_method :batch_budget_counted_open, :open
            def open(path, *arguments, **options, &block)
              if path.to_s == ENV["BATCH_TOKEN_BUDGET_COUNTED_STATE"]
                count = ENV.fetch("BATCH_TOKEN_BUDGET_STATE_OPEN_COUNT", "0").to_i + 1
                ENV["BATCH_TOKEN_BUDGET_STATE_OPEN_COUNT"] = count.to_s
                raise "state opened more than once" if count > 1
              end
              batch_budget_counted_open(path, *arguments, **options, &block)
            end
          end
          at_exit do
            count = ENV.fetch("BATCH_TOKEN_BUDGET_STATE_OPEN_COUNT", "0")
            File.binwrite(ENV.fetch("BATCH_TOKEN_BUDGET_OPEN_COUNT_PATH"), count)
          end
        RUBY
      )
      clock_options = trusted_clock_options_for_command(JSON.generate(command("closeout")))
      environment = clock_options.fetch(:env).merge(
        "BATCH_TOKEN_BUDGET_COUNTED_STATE" => state_path,
        "BATCH_TOKEN_BUDGET_OPEN_COUNT_PATH" => counter_path
      )

      closed, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        env: environment,
        ruby_arguments: [*clock_options.fetch(:ruby_arguments), "-r", preloader]
      )

      assert status.success?, stderr
      assert_equal "not-complete", closed.fetch("status")
      assert_equal "1", File.binread(counter_path)
      state_before_denied_read = File.binread(state_path)

      denied_preloader = File.join(File.dirname(state_path), "state-eacces-preloader.rb")
      File.write(
        denied_preloader,
        <<~RUBY
          class << File
            alias_method :batch_budget_access_checked_open, :open
            def open(path, *arguments, **options, &block)
              raise Errno::EACCES, path if path.to_s == ENV["BATCH_TOKEN_BUDGET_DENIED_STATE"]

              batch_budget_access_checked_open(path, *arguments, **options, &block)
            end
          end
        RUBY
      )
      denied_environment = clock_options.fetch(:env).merge("BATCH_TOKEN_BUDGET_DENIED_STATE" => state_path)

      output, denied_stderr, denied_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        env: denied_environment,
        ruby_arguments: [*clock_options.fetch(:ruby_arguments), "-r", denied_preloader]
      )

      refute denied_status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(denied_stderr).fetch("reason")
      assert_equal state_before_denied_read, File.binread(state_path)
    end
  end

  def test_preplanted_predictable_temporary_symlink_is_never_followed
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      victim_path = File.join(File.dirname(state_path), "temporary-victim.txt")
      File.write(victim_path, "temporary-victim-sentinel")
      planted_path = nil

      initialized, stderr, status = run_helper_raw_with_watchdog(
        state_path,
        JSON.generate(command("initialize", "budget" => candidate)),
        timeout_seconds: 2,
        anchor: anchor,
        before_stdin: proc do |child_pid|
          planted_path = "#{state_path}.tmp.#{child_pid}"
          File.symlink(victim_path, planted_path)
        end
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      assert_equal "temporary-victim-sentinel", File.read(victim_path)
      assert File.file?(state_path)
      refute File.symlink?(state_path)
      assert_equal 0o600, File.stat(state_path).mode & 0o777
      assert File.symlink?(planted_path)
      assert_equal [File.basename(planted_path)], Dir.children(File.dirname(state_path)).grep(/\.tmp\./)
    end
  end

  def test_fresh_state_wrong_batch_id_leaves_no_state_lock_or_parent_directory
    Dir.mktmpdir("batch-token-budget-fresh-batch-id") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(File.join(directory, "anchor"), candidate)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "batch_id" => "other-batch", "budget" => candidate)),
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "batch-id-mismatch", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_fresh_state_invalid_batch_ids_leave_no_artifacts
    Dir.mktmpdir("batch-token-budget-fresh-invalid-batch-id") do |directory|
      invalid_batch_ids = ["", "   ", "UNKNOWN"]
      observations = invalid_batch_ids.each_with_index.to_h do |invalid_batch_id, index|
        suffix = "invalid-#{index}"
        state_path = File.join(directory, suffix, "state.json")
        candidate = budget(state_path: state_path)
        anchor = install_trusted_plan(File.join(directory, "anchor-#{suffix}"), candidate)
        output, stderr, status = run_helper_raw(
          state_path,
          JSON.generate(command("initialize", "batch_id" => invalid_batch_id, "budget" => candidate)),
          anchor: anchor
        )

        [invalid_batch_id, {
          "success" => status.success?,
          "output" => output,
          "reason" => JSON.parse(stderr).fetch("reason"),
          "state" => File.exist?(state_path),
          "lock" => File.exist?("#{state_path}.lock"),
          "parent" => Dir.exist?(File.dirname(state_path))
        }]
      end
      expected = invalid_batch_ids.to_h do |invalid_batch_id|
        [invalid_batch_id, {
          "success" => false,
          "output" => nil,
          "reason" => "invalid-batch-id",
          "state" => false,
          "lock" => false,
          "parent" => false
        }]
      end

      assert_equal expected, observations
    end
  end

  def test_fresh_state_mismatched_initialize_projection_leaves_no_artifacts
    Dir.mktmpdir("batch-token-budget-fresh-projection") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      mismatched_projection = canonicalize(candidate)
      mismatched_projection.fetch("telemetry")["max_age_seconds"] += 1
      anchor = install_trusted_plan(File.join(directory, "anchor"), candidate)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("initialize", "budget" => mismatched_projection)),
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "initialize-budget-anchor-mismatch", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_far_future_initialization_is_rejected_before_artifact_creation
    Dir.mktmpdir("batch-token-budget-future-initialize") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(File.join(directory, "anchor"), candidate)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(
          command(
            "initialize",
            "evaluated_at" => host_timestamp(3600),
            "budget" => candidate
          )
        ),
        anchor: anchor,
        **trusted_clock_options(directory, Time.now.utc)
      )

      refute status.success?
      assert_nil output
      assert_equal "command-time-future", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_far_past_initialization_is_rejected_before_artifact_creation
    Dir.mktmpdir("batch-token-budget-stale-initialize") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(File.join(directory, "anchor"), candidate)
      trusted_time = Time.utc(2026, 8, 12, 12, 0, 0)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(
          command(
            "initialize",
            "evaluated_at" => format_timestamp(trusted_time - 3600),
            "budget" => candidate
          )
        ),
        anchor: anchor,
        **trusted_clock_options_for_time(trusted_time)
      )

      refute status.success?
      assert_nil output
      assert_equal "command-time-stale", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_command_time_accepts_the_forward_skew_boundary_and_rejects_overage
    Dir.mktmpdir("batch-token-budget-command-skew") do |root_directory|
      directory = File.join(root_directory, "clock seam with spaces")
      FileUtils.mkdir_p(directory)
      assert_includes directory, " "
      trusted_time = Time.utc(2026, 8, 26, 12, 0, 0)
      observations = [-30.001, -30, 29, 30, 30.001, 31].map do |offset|
        state_path = File.join(directory, "offset-#{offset.to_s.tr('.', '-')}.json")
        candidate = budget(state_path: state_path)
        anchor = install_trusted_plan(state_path, candidate)
        output, stderr, status = run_helper_raw(
          state_path,
          JSON.generate(
            command(
              "initialize",
              "evaluated_at" => format_timestamp(trusted_time + offset),
              "budget" => candidate
            )
          ),
          anchor: anchor,
          **trusted_clock_options(directory, trusted_time)
        )
        [offset, output, stderr, status]
      end

      observations.each do |offset, output, stderr, status|
        if offset.between?(-30, 30)
          assert status.success?, "offset #{offset}: #{stderr}"
          assert_equal "initialized", output.fetch("status"), offset
        else
          refute status.success?, offset
          assert_nil output, offset
          reason = offset < -30 ? "command-time-stale" : "command-time-future"
          assert_equal reason, JSON.parse(stderr).fetch("reason"), offset
          refute File.exist?(File.join(directory, "offset-#{offset.to_s.tr('.', '-')}.json")), offset
          refute File.exist?(File.join(directory, "offset-#{offset.to_s.tr('.', '-')}.json.lock")), offset
        end
      end
    end
  end

  def test_monotonic_before_wall_capture_counts_post_lock_gap_at_exact_stale_boundary
    Dir.mktmpdir("batch-token-budget-post-lock-initialize") do |directory|
      trusted_time = Time.utc(2026, 8, 26, 12, 0, 0)
      [30, 30.001].each do |elapsed_seconds|
        state_path = File.join(directory, "elapsed-#{elapsed_seconds}.json")
        candidate = budget(state_path: state_path)
        anchor = install_trusted_plan(state_path, candidate)
        output, stderr, status = run_helper_raw(
          state_path,
          JSON.generate(command("initialize", "evaluated_at" => format_timestamp(trusted_time), "budget" => candidate)),
          anchor: anchor,
          **trusted_clock_options_with_elapsed(directory, trusted_time, elapsed_seconds)
        )

        if elapsed_seconds == 30
          assert status.success?, stderr
          assert_equal "initialized", output.fetch("status")
        else
          refute status.success?
          assert_nil output
          assert_equal "command-time-stale", JSON.parse(stderr).fetch("reason")
          refute File.exist?(state_path)
        end
      end
    end
  end

  def test_post_lock_stale_command_preserves_expired_override_and_state_then_current_time_recovers
    with_state do |state_path|
      initialize_budget(state_path)
      trusted_time = Time.utc(2026, 8, 12, 12, 2, 0)
      override = budget_override(
        state_path,
        id: "post-lock-expired-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 900,
        issued_at: format_timestamp(trusted_time - 120),
        expires_at: format_timestamp(trusted_time - 1)
      )
      overridden, override_stderr, override_status = run_helper(
        state_path,
        command("override", "evaluated_at" => format_timestamp(trusted_time - 60), "override" => override)
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")
      state_before = File.binread(state_path)
      projection_before = JSON.parse(state_before)

      output, stderr, status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => format_timestamp(trusted_time),
          "reservation" => reservation(id: "post-lock-aged-reserve", tokens: 700)
        ),
        **trusted_clock_options_with_elapsed(File.dirname(state_path), trusted_time, 30.001)
      )

      refute status.success?
      assert_nil output
      assert_equal "command-time-stale", JSON.parse(stderr).fetch("reason")
      assert_equal state_before, File.binread(state_path)
      projection_after = JSON.parse(File.binread(state_path))
      assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events")
      assert_equal projection_before.fetch("last_evaluated_at"), projection_after.fetch("last_evaluated_at")
      assert_equal projection_before.fetch("admission_decisions"), projection_after.fetch("admission_decisions")
      assert_equal projection_before.fetch("reservation_decisions"), projection_after.fetch("reservation_decisions")
      assert projection_after.dig("overrides", "post-lock-expired-override", "active")

      recovered, recovered_stderr, recovered_status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => format_timestamp(trusted_time),
          "reservation" => reservation(id: "post-lock-aged-reserve", tokens: 700)
        ),
        **trusted_clock_options_for_time(trusted_time)
      )
      assert recovered_status.success?, recovered_stderr
      assert_equal "budget-exhausted", recovered.fetch("status")
      recovered_state = JSON.parse(File.binread(state_path))
      refute recovered_state.dig("overrides", "post-lock-expired-override", "active")
      assert_equal 600, recovered_state.dig("scopes", "lanes", "lane-a", "limit_tokens")
      refute recovered_state.fetch("reservations").key?("post-lock-aged-reserve")
    end
  end

  def test_far_future_closeout_preserves_state_and_an_active_override_then_normal_time_succeeds
    with_state do |state_path|
      initialize_budget(state_path)
      reference_time = Time.now.utc
      override = budget_override(
        state_path,
        id: "future-command-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700,
        issued_at: format_timestamp(reference_time - 60),
        expires_at: format_timestamp(reference_time + 120)
      )
      overridden, override_stderr, override_status = run_helper(
        state_path,
        command(
          "override",
          "evaluated_at" => format_timestamp(reference_time),
          "override" => override
        )
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")
      state_before = File.read(state_path)
      events_before = JSON.parse(state_before).fetch("control_events").length

      output, stderr, status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => format_timestamp(reference_time + 3600)),
        **trusted_clock_options(File.dirname(state_path), reference_time)
      )

      refute status.success?
      assert_nil output
      assert_equal "command-time-future", JSON.parse(stderr).fetch("reason")
      state_after = File.read(state_path)
      assert_equal state_before, state_after
      assert_equal events_before, JSON.parse(state_after).fetch("control_events").length
      assert JSON.parse(state_after).dig("overrides", "future-command-override", "active")
      assert_equal 700, JSON.parse(state_after).dig("scopes", "lanes", "lane-a", "limit_tokens")

      normal, normal_stderr, normal_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => format_timestamp(reference_time + 1)),
        **trusted_clock_options(File.dirname(state_path), reference_time)
      )
      assert normal_status.success?, normal_stderr
      assert_equal "not-complete", normal.fetch("status")
    end
  end

  def test_persisted_command_time_implausibly_ahead_of_the_same_trusted_clock_fails_closed
    Dir.mktmpdir("batch-token-budget-persisted-future") do |directory|
      state_path = File.join(directory, "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      trusted_time = Time.utc(2026, 8, 26, 12, 0, 0)
      initialized, initialize_stderr, initialize_status = run_helper_raw(
        state_path,
        JSON.generate(
          command(
            "initialize",
            "evaluated_at" => format_timestamp(trusted_time + 30),
            "budget" => candidate
          )
        ),
        anchor: anchor,
        **trusted_clock_options(directory, trusted_time)
      )
      assert initialize_status.success?, initialize_stderr
      assert_equal "initialized", initialized.fetch("status")
      boundary, boundary_stderr, boundary_status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout", "evaluated_at" => format_timestamp(trusted_time + 30))),
        anchor: anchor,
        **trusted_clock_options(directory, trusted_time)
      )
      assert boundary_status.success?, boundary_stderr
      assert_equal "not-complete", boundary.fetch("status")
      state_before = File.read(state_path)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout", "evaluated_at" => format_timestamp(trusted_time - 2))),
        anchor: anchor,
        **trusted_clock_options(directory, trusted_time - 2)
      )

      refute status.success?
      assert_nil output
      assert_equal "persisted-command-time-future", JSON.parse(stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_stale_closeout_equal_to_the_usage_cursor_cannot_complete_and_current_time_recovers
    with_state do |state_path|
      initialize_budget(state_path)
      reconciled, reconcile_stderr, reconcile_status = reconcile_final_zero_usage_window(
        state_path,
        name: "stale-closeout-window"
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")
      state_before = File.read(state_path)
      projection_before = JSON.parse(state_before)
      trusted_time = Time.utc(2026, 8, 12, 12, 0, 30, 1_000)

      stale, stale_stderr, stale_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:00:00Z"),
        **trusted_clock_options_for_time(trusted_time)
      )

      refute stale_status.success?
      assert_nil stale
      assert_equal "command-time-stale", JSON.parse(stale_stderr).fetch("reason")
      state_after = File.read(state_path)
      assert_equal state_before, state_after
      projection_after = JSON.parse(state_after)
      assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events")
      assert_equal projection_before.fetch("last_evaluated_at"), projection_after.fetch("last_evaluated_at")

      recovered, recovered_stderr, recovered_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => format_timestamp(trusted_time)),
        **trusted_clock_options_for_time(trusted_time)
      )
      assert recovered_status.success?, recovered_stderr
      assert_equal "complete", recovered.fetch("status")
      assert_equal "COMPLETE", recovered.fetch("completion")
    end
  end

  def test_stale_approval_cannot_be_stored_or_consumed
    with_state do |state_path|
      initialize_budget(state_path)
      trusted_time = Time.utc(2026, 8, 12, 12, 0, 0)
      expired_approval = approval(
        state_path,
        id: "stale-expired-approval",
        issued_at: "2026-08-12T11:58:00Z",
        expires_at: "2026-08-12T11:59:30Z"
      )
      state_before = File.read(state_path)
      projection_before = JSON.parse(state_before)

      approved, approval_stderr, approval_status = run_helper(
        state_path,
        command(
          "approve",
          "evaluated_at" => "2026-08-12T11:59:29.999Z",
          "approval" => expired_approval
        ),
        **trusted_clock_options_for_time(trusted_time)
      )

      refute approval_status.success?
      assert_nil approved
      assert_equal "command-time-stale", JSON.parse(approval_stderr).fetch("reason")
      state_after = File.read(state_path)
      assert_equal state_before, state_after
      projection_after = JSON.parse(state_after)
      assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events")
      assert_equal projection_before.fetch("last_evaluated_at"), projection_after.fetch("last_evaluated_at")
      refute projection_after.fetch("approvals").key?("stale-expired-approval")

      reservation_result, reservation_stderr, reservation_status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => format_timestamp(trusted_time),
          "reservation" => reservation(
            id: "stale-approval-reservation",
            tokens: 500,
            overrides: { "approval_id" => "stale-expired-approval" }
          )
        ),
        **trusted_clock_options_for_time(trusted_time)
      )
      assert reservation_status.success?, reservation_stderr
      assert_equal "approval-required", reservation_result.fetch("status")
      refute JSON.parse(File.read(state_path)).fetch("approvals").key?("stale-expired-approval")
    end
  end

  def test_exact_approval_replay_precedes_signed_expiry_but_new_admission_rechecks_it
    with_state do |state_path|
      initialize_budget(state_path)
      approval = approval(
        state_path,
        id: "expiring-replay-approval",
        issued_at: "2026-08-12T11:58:00Z",
        expires_at: "2026-08-12T12:00:00Z"
      )
      approved, approval_stderr, approval_status = run_helper(
        state_path,
        command(
          "approve",
          "evaluated_at" => "2026-08-12T11:59:59Z",
          "approval" => approval
        )
      )
      assert approval_status.success?, approval_stderr
      assert_equal "approved", approved.fetch("status")
      original_receipt = approved.fetch("receipt")

      replayed, replay_stderr, replay_status = run_helper(
        state_path,
        command(
          "approve",
          "evaluated_at" => "2026-08-12T12:00:01Z",
          "approval" => approval
        )
      )

      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal original_receipt, replayed.fetch("receipt")

      changed = JSON.parse(JSON.generate(approval))
      changed["reason"] = "Changed replay payload."
      output, changed_stderr, changed_status = run_helper(
        state_path,
        command(
          "approve",
          "evaluated_at" => "2026-08-12T12:00:02Z",
          "approval" => changed
        )
      )
      refute changed_status.success?
      assert_nil output
      assert_equal "approval-replay-mismatch", JSON.parse(changed_stderr).fetch("reason")

      stale, stale_stderr, stale_status = run_helper(
        state_path,
        command(
          "approve",
          "evaluated_at" => "2026-08-12T12:00:01Z",
          "approval" => approval
        ),
        **trusted_clock_options_for_time(Time.utc(2026, 8, 12, 12, 0, 32))
      )
      refute stale_status.success?
      assert_nil stale
      assert_equal "command-time-stale", JSON.parse(stale_stderr).fetch("reason")

      blocked, reservation_stderr, reservation_status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => "2026-08-12T12:00:03Z",
          "reservation" => reservation(
            id: "expired-approval-reservation",
            tokens: 500,
            overrides: { "approval_id" => "expiring-replay-approval" }
          )
        )
      )
      assert reservation_status.success?, reservation_stderr
      assert_equal "approval-required", blocked.fetch("status")
      assert_equal "projected-approval-threshold", blocked.fetch("reason")
    end
  end

  def test_new_admissions_require_scope_matched_and_unconsumed_approval
    with_state do |state_path|
      initialize_budget(state_path)
      lane_approval = approval(state_path, id: "lane-a-only-approval")
      approved, approval_stderr, approval_status = run_helper(
        state_path,
        command("approve", "approval" => lane_approval)
      )
      assert approval_status.success?, approval_stderr
      assert_equal "approved", approved.fetch("status")

      wrong_scope, wrong_scope_stderr, wrong_scope_status = reserve(
        state_path,
        id: "wrong-scope-approval-reservation",
        lane_id: "lane-b",
        tokens: 400,
        overrides: { "approval_id" => "lane-a-only-approval" }
      )
      assert wrong_scope_status.success?, wrong_scope_stderr
      assert_equal "approval-required", wrong_scope.fetch("status")
      assert_equal "projected-approval-threshold", wrong_scope.fetch("reason")
    end

    with_state do |state_path|
      initialize_budget(state_path)
      lane_approval = approval(state_path, id: "single-use-approval")
      run_helper(state_path, command("approve", "approval" => lane_approval))
      admitted, admitted_stderr, admitted_status = reserve(
        state_path,
        id: "approval-consuming-reservation",
        tokens: 500,
        overrides: { "approval_id" => "single-use-approval" }
      )
      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted-with-warning", admitted.fetch("status")
      released, release_stderr, release_status = run_helper(
        state_path,
        command(
          "release",
          "release" => {
            "type" => "batch-token-release",
            "version" => 1,
            "id" => "release-approval-consuming-reservation",
            "reservation_id" => "approval-consuming-reservation",
            "reason" => "End the approved work before checking single-use fencing."
          }
        )
      )
      assert release_status.success?, release_stderr
      assert_equal "released", released.fetch("status")

      consumed, consumed_stderr, consumed_status = reserve(
        state_path,
        id: "consumed-approval-reservation",
        tokens: 500,
        overrides: { "approval_id" => "single-use-approval" }
      )
      assert consumed_status.success?, consumed_stderr
      assert_equal "approval-required", consumed.fetch("status")
      assert_equal "projected-approval-threshold", consumed.fetch("reason")
    end
  end

  def test_stale_command_cannot_keep_an_expired_override_active
    with_state do |state_path|
      initialize_budget(state_path)
      expired_override = budget_override(
        state_path,
        id: "stale-expired-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700,
        issued_at: "2026-08-12T11:58:00Z",
        expires_at: "2026-08-12T11:59:30Z"
      )
      overridden, override_stderr, override_status = run_helper(
        state_path,
        command(
          "override",
          "evaluated_at" => "2026-08-12T11:59:00Z",
          "override" => expired_override
        )
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")
      state_before = File.read(state_path)
      projection_before = JSON.parse(state_before)
      trusted_time = Time.utc(2026, 8, 12, 12, 0, 0)

      stale, stale_stderr, stale_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T11:59:29.999Z"),
        **trusted_clock_options_for_time(trusted_time)
      )

      refute stale_status.success?
      assert_nil stale
      assert_equal "command-time-stale", JSON.parse(stale_stderr).fetch("reason")
      state_after = File.read(state_path)
      assert_equal state_before, state_after
      projection_after = JSON.parse(state_after)
      assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events")
      assert_equal projection_before.fetch("last_evaluated_at"), projection_after.fetch("last_evaluated_at")
      assert projection_after.dig("overrides", "stale-expired-override", "active")
      assert_equal 700, projection_after.dig("scopes", "lanes", "lane-a", "limit_tokens")

      recovered, recovered_stderr, recovered_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => format_timestamp(trusted_time)),
        **trusted_clock_options_for_time(trusted_time)
      )
      assert recovered_status.success?, recovered_stderr
      assert_equal "not-complete", recovered.fetch("status")
      recovered_state = JSON.parse(File.read(state_path))
      refute recovered_state.dig("overrides", "stale-expired-override", "active")
      assert_equal 600, recovered_state.dig("scopes", "lanes", "lane-a", "limit_tokens")
    end
  end

  def test_fresh_state_closeout_without_state_leaves_no_artifacts
    Dir.mktmpdir("batch-token-budget-fresh-closeout") do |directory|
      state_path = File.join(directory, "fresh", "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(File.join(directory, "anchor"), candidate)

      output, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor
      )

      refute status.success?
      assert_nil output
      assert_equal "state-required", JSON.parse(stderr).fetch("reason")
      refute File.exist?(state_path)
      refute File.exist?("#{state_path}.lock")
      refute Dir.exist?(File.dirname(state_path))
    end
  end

  def test_closeout_without_an_authoritative_usage_window_is_not_complete
    with_state do |state_path|
      initialize_budget(state_path)

      closeout, stderr, status = run_helper(state_path, command("closeout"))

      assert status.success?, stderr
      assert_equal "not-complete", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal(
        {
          "status" => "missing",
          "usage_cursor" => nil,
          "age_seconds" => nil,
          "reason" => "usage-cursor-missing"
        },
        closeout.fetch("telemetry")
      )
    end
  end

  def test_closeout_with_a_fresh_authoritative_usage_window_is_complete
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      reconciled, reconcile_stderr, reconcile_status = reconcile_receipt(state_path, receipt, "fresh-closeout")
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      closeout, stderr, status = run_helper(state_path, command("closeout"))

      assert status.success?, stderr
      assert_equal "complete", closeout.fetch("status")
      assert_equal "COMPLETE", closeout.fetch("completion")
      assert_equal(
        {
          "status" => "fresh",
          "usage_cursor" => "2026-08-12T12:00:00Z",
          "age_seconds" => 0,
          "reason" => "usage-cursor-current"
        },
        closeout.fetch("telemetry")
      )
    end
  end

  def test_closeout_accepts_an_authoritative_usage_cursor_at_the_exact_maximum_age
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      reconcile_receipt(state_path, receipt, "boundary-closeout")

      closeout, stderr, status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:15:00Z")
      )

      assert status.success?, stderr
      assert_equal "complete", closeout.fetch("status")
      assert_equal "COMPLETE", closeout.fetch("completion")
      assert_equal(
        {
          "status" => "fresh",
          "usage_cursor" => "2026-08-12T12:00:00Z",
          "age_seconds" => 900,
          "reason" => "usage-cursor-current"
        },
        closeout.fetch("telemetry")
      )
    end
  end

  def test_fully_attributed_closeout_rejects_a_fractionally_stale_usage_cursor
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      reconcile_receipt(state_path, receipt, "fractionally-stale-closeout")

      closeout, stderr, status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:15:00.001Z")
      )

      assert status.success?, stderr
      assert_equal "not-complete", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal 0, closeout.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 0, closeout.fetch("unattributed_tokens")
      assert_equal(
        {
          "status" => "stale",
          "usage_cursor" => "2026-08-12T12:00:00Z",
          "age_seconds" => 900.001,
          "reason" => "usage-cursor-stale"
        },
        closeout.fetch("telemetry")
      )
    end
  end

  def test_closeout_rejects_a_future_usage_cursor
    with_state do |state_path|
      initialize_budget(state_path)
      state = JSON.parse(File.read(state_path))
      state["usage_cursor"] = "2026-08-12T12:00:00.001Z"

      closeout = closeout_in_memory(state, "2026-08-12T12:00:00Z")

      assert_equal "not-complete", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal(
        {
          "status" => "future",
          "usage_cursor" => "2026-08-12T12:00:00.001Z",
          "age_seconds" => -0.001,
          "reason" => "usage-cursor-future"
        },
        closeout.fetch("telemetry")
      )
    end
  end

  def test_closeout_freshness_survives_restart_and_recovers_after_a_new_authoritative_window
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      first_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      reconcile_receipt(state_path, first_receipt, "restart-first-window")

      stale, stale_stderr, stale_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:15:00.001Z")
      )
      assert stale_status.success?, stale_stderr
      assert_equal "not-complete", stale.fetch("status")
      assert_equal "stale", stale.dig("telemetry", "status")

      second_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T12:00:00Z",
        to: "2026-08-12T12:15:00.001Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      second_receipt, receipt_ref, receipt_digest = receipt_artifact(
        state_path,
        second_receipt,
        "restart-second-window"
      )
      reconciled, reconcile_stderr, reconcile_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:15:00.001Z",
          "usage_receipt" => second_receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      recovered, recovered_stderr, recovered_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:15:00.001Z")
      )
      assert recovered_status.success?, recovered_stderr
      assert_equal "complete", recovered.fetch("status")
      assert_equal "fresh", recovered.dig("telemetry", "status")
      assert_equal 0, recovered.dig("telemetry", "age_seconds")
    end
  end

  def test_concurrent_valid_initialization_remains_serialized
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      input = JSON.generate(
        command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => candidate)
      )

      outcomes = 2.times.map do
        Thread.new { run_helper_raw(state_path, input, anchor: anchor) }
      end.map(&:value)

      assert outcomes.all? { |_output, _stderr, status| status.success? }, outcomes.map { |row| row[1] }.join
      assert_equal %w[initialized replayed], outcomes.map { |output, _stderr, _status| output.fetch("status") }.sort
      assert File.file?(state_path)
      assert File.file?("#{state_path}.lock")
      reconciled, reconcile_stderr, reconcile_status = reconcile_final_zero_usage_window(
        state_path,
        name: "concurrent-initialize-closeout"
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      closeout, stderr, status = run_helper_raw(
        state_path,
        JSON.generate(command("closeout")),
        anchor: anchor
      )
      assert status.success?, stderr
      assert_equal "complete", closeout.fetch("status")
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

      actual_directory = File.join(directory, "actual")
      aliased_directory = File.join(directory, "aliased-parent")
      Dir.mkdir(actual_directory)
      File.symlink(actual_directory, aliased_directory)
      nested_plan_path = File.join(actual_directory, "nested-plan.json")
      nested_state_path = File.join(aliased_directory, "nested-plan.json", "state.json")
      nested_budget = budget(state_path: nested_state_path)
      File.write(nested_plan_path, JSON.generate(canonicalize(nested_budget)))
      nested_anchor = {
        "path" => nested_plan_path,
        "id" => nested_budget.fetch("batch_id"),
        "digest" => "sha256:#{object_digest(nested_budget)}"
      }
      nested_plan_before = File.read(nested_plan_path)

      output, nested_stderr, nested_status = run_helper_raw(
        nested_state_path,
        JSON.generate(command("initialize", "budget" => nested_budget)),
        anchor: nested_anchor
      )
      refute nested_status.success?
      assert_nil output
      assert_equal "trusted-plan-state-path-collision", JSON.parse(nested_stderr).fetch("reason")
      assert_equal nested_plan_before, File.read(nested_plan_path)
      refute File.exist?("#{nested_state_path}.lock")
    end
  end

  def test_runtime_rechecks_trusted_plan_state_collision_after_acquiring_the_lock
    Dir.mktmpdir("batch-token-budget-post-lock-collision") do |directory|
      state_path = File.join(directory, "state.json")
      candidate = budget(state_path: state_path)
      anchor = install_trusted_plan(state_path, candidate)
      plan_before = File.binread(anchor.fetch("path"))
      ready_path = File.join(directory, "lock-open-ready")
      continue_path = File.join(directory, "continue-lock-open")
      preloader = File.join(directory, "pause-before-lock-open.rb")
      File.write(preloader, TRUSTED_CLOCK_SOURCE + <<~'RUBY')
        class << File
          alias_method :batch_token_budget_test_original_open, :open

          def open(path, *args, **kwargs, &block)
            if path.to_s == ENV.fetch("BATCH_TOKEN_BUDGET_TEST_LOCK_PATH") &&
               !exist?(ENV.fetch("BATCH_TOKEN_BUDGET_TEST_READY_PATH"))
              batch_token_budget_test_original_open(
                ENV.fetch("BATCH_TOKEN_BUDGET_TEST_READY_PATH"), "w"
              ) { |file| file.write("ready") }
              sleep 0.01 until exist?(ENV.fetch("BATCH_TOKEN_BUDGET_TEST_CONTINUE_PATH"))
            end

            if kwargs.empty?
              batch_token_budget_test_original_open(path, *args, &block)
            else
              batch_token_budget_test_original_open(path, *args, **kwargs, &block)
            end
          end
        end
      RUBY
      input = JSON.generate(command("initialize", "budget" => candidate))
      env = {
        "BATCH_TOKEN_BUDGET_TEST_EPOCH" => Time.iso8601(command("initialize")["evaluated_at"]).to_f.to_s,
        "BATCH_TOKEN_BUDGET_TEST_LOCK_PATH" => "#{state_path}.lock",
        "BATCH_TOKEN_BUDGET_TEST_READY_PATH" => ready_path,
        "BATCH_TOKEN_BUDGET_TEST_CONTINUE_PATH" => continue_path
      }
      stdout_text = stderr_text = nil
      status = nil

      Open3.popen3(
        env,
        RbConfig.ruby,
        "-r", preloader,
        HELPER,
        "--state", state_path,
        "--trusted-plan", anchor.fetch("path"),
        "--trusted-plan-id", anchor.fetch("id"),
        "--trusted-plan-digest", anchor.fetch("digest")
      ) do |stdin, stdout, stderr, wait_thread|
        stdin.write(input)
        stdin.close
        300.times do
          break if File.exist?(ready_path)

          sleep 0.01
        end
        assert File.exist?(ready_path), "helper never reached the state-lock boundary"
        File.symlink(anchor.fetch("path"), state_path)
        File.write(continue_path, "continue")
        assert wait_thread.join(5), "helper did not terminate after the collision was introduced"
        stdout_text = stdout.read
        stderr_text = stderr.read
        status = wait_thread.value
      ensure
        stdin.close unless stdin.closed?
        File.write(continue_path, "continue") unless File.exist?(continue_path)
        unless wait_thread.join(0)
          Process.kill("KILL", wait_thread.pid)
          wait_thread.join
        end
      end

      refute status.success?
      assert_empty stdout_text
      assert_equal "trusted-plan-state-path-collision", JSON.parse(stderr_text).fetch("reason")
      assert File.symlink?(state_path)
      assert_equal anchor.fetch("path"), File.readlink(state_path)
      assert_equal plan_before, File.binread(anchor.fetch("path"))
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

  def test_active_reservations_are_unique_per_scope_while_different_lanes_remain_concurrent
    with_state do |state_path|
      initialize_budget(state_path)
      first, first_stderr, first_status = reserve(
        state_path,
        id: "lane-a-envelope",
        lane_id: "lane-a",
        target_id: "lane-a-root"
      )
      assert first_status.success?, first_stderr
      assert_equal "admitted", first.fetch("status")

      nested, nested_stderr, nested_status = reserve(
        state_path,
        id: "lane-a-nested",
        lane_id: "lane-a",
        target_id: "lane-a-child"
      )
      assert nested_status.success?, nested_stderr
      assert_equal "coalesced", nested.fetch("status")
      assert_equal "lane-a-envelope", nested.fetch("coalesced_reservation_id")
      assert_equal 100, nested.dig("totals", "aggregate", "reserved_tokens")

      other_lane, other_stderr, other_status = reserve(
        state_path,
        id: "lane-b-envelope",
        lane_id: "lane-b",
        target_id: "lane-b-root"
      )
      assert other_status.success?, other_stderr
      assert_equal "admitted", other_lane.fetch("status")
      assert_equal 200, other_lane.dig("totals", "aggregate", "reserved_tokens")
      assert_equal %w[lane-a-envelope lane-b-envelope], JSON.parse(File.read(state_path)).fetch("reservations").keys.sort
    end
  end

  def test_real_batch_usage_receipt_reconciles_every_hierarchical_scope_atomically
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "coordinator-window", lane_id: "coordinator", tokens: 20)
      reserve(state_path, id: "lane-a-window", lane_id: "lane-a", tokens: 100)
      reserve(state_path, id: "lane-b-window", lane_id: "lane-b", tokens: 10)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)

      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => %w[coordinator-window lane-a-window lane-b-window]
        )
      )

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 112, reconciled.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 15, reconciled.dig("totals", "coordinator", "consumed_tokens")
      assert_equal 90, reconciled.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 7, reconciled.dig("totals", "lanes", "lane-b", "consumed_tokens")
      assert_equal 0, reconciled.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 18, reconciled.dig("totals", "aggregate", "released_tokens")

      state = JSON.parse(File.read(state_path))
      assert_equal "root", state.dig("usage_binding", "coordinator", "root_thread_id")
      assert_equal({ "lane-a" => "lane-a", "lane-b" => "lane-b" }, state.dig("usage_binding", "lanes"))
      assert_equal(
        { "coordinator" => 2, "lane-a" => 3, "lane-b" => 1 },
        state.fetch("usage_receipts").values.first.fetch("scope_turns")
      )
    end
  end

  def test_legacy_v1_usage_receipt_is_rejected_as_unsupported_not_malformed
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "legacy-v1-window", tokens: 100)
      current_receipt, = real_descendants_usage_receipt(state_path)
      legacy = legacy_v1_receipt(current_receipt)
      legacy, receipt_ref, receipt_digest = receipt_artifact(state_path, legacy, "legacy-v1")
      state_before = File.read(state_path)
      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => legacy,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => ["legacy-v1-window"]
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-receipt-version-unsupported", blocked.fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_legacy_v1_receipt_is_a_byte_identical_no_op_before_override_expiration_and_generic_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      override = budget_override(
        state_path,
        id: "legacy-v1-expiring-override",
        scope_id: "lane-a",
        old_limit_tokens: 600,
        new_limit_tokens: 700,
        issued_at: "2026-08-12T11:58:00Z",
        expires_at: "2026-08-12T11:59:30Z"
      )
      overridden, override_stderr, override_status = run_helper(
        state_path,
        command("override", "evaluated_at" => "2026-08-12T11:59:00Z", "override" => override)
      )
      assert override_status.success?, override_stderr
      assert_equal "overridden", overridden.fetch("status")

      current_receipt, = real_descendants_usage_receipt(state_path)
      legacy = legacy_v1_receipt(current_receipt)
      legacy["arbitrary_payload"] = {
        "unexpected_content" => ["must-not-persist", { "nested" => "sentinel" }]
      }
      legacy, receipt_ref, receipt_digest = receipt_artifact(state_path, legacy, "legacy-v1-no-op")
      state_before = File.binread(state_path)
      projection_before = JSON.parse(state_before)
      command_for = lambda do |evaluated_at|
        command(
          "reconcile",
          "evaluated_at" => evaluated_at,
          "usage_receipt" => legacy,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      end

      ["2026-08-12T12:00:00Z", "2026-08-12T11:59:00Z"].each do |evaluated_at|
        blocked, stderr, status = run_helper(state_path, command_for.call(evaluated_at))

        assert status.success?, stderr
        assert_equal "blocked", blocked.fetch("status"), evaluated_at
        assert_equal "usage-receipt-version-unsupported", blocked.fetch("reason"), evaluated_at
        assert_equal state_before, File.binread(state_path), evaluated_at
        projection_after = JSON.parse(File.binread(state_path))
        assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events"), evaluated_at
        assert_equal projection_before.fetch("overrides"), projection_after.fetch("overrides"), evaluated_at
        assert_equal projection_before.fetch("receipts"), projection_after.fetch("receipts"), evaluated_at
        assert_equal projection_before.fetch("scopes"), projection_after.fetch("scopes"), evaluated_at
        assert_nil projection_before["usage_cursor"], evaluated_at
        assert_nil projection_after["usage_cursor"], evaluated_at
        assert_equal projection_before.fetch("usage_receipts"), projection_after.fetch("usage_receipts"), evaluated_at
        refute_includes File.binread(state_path), "must-not-persist", evaluated_at
      end

      assert JSON.parse(File.binread(state_path)).dig("overrides", "legacy-v1-expiring-override", "active")
      restarted, restart_stderr, restart_status = run_helper(state_path, command("closeout"))
      assert restart_status.success?, restart_stderr
      assert_equal "not-complete", restarted.fetch("status")
      refute JSON.parse(File.binread(state_path)).dig("overrides", "legacy-v1-expiring-override", "active")
    end
  end

  def test_reconcile_rejects_non_object_usage_receipts_with_a_structured_error
    with_state do |state_path|
      initialize_budget(state_path)
      state_before = File.read(state_path)

      {
        "null" => nil,
        "boolean" => true,
        "integer" => 42,
        "string" => "not-a-receipt",
        "array" => []
      }.each do |name, malformed_receipt|
        output, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "usage_receipt" => malformed_receipt,
            "usage_receipt_ref" => "https://example.invalid/receipt.json",
            "usage_receipt_digest" => "sha256:#{'0' * 64}",
            "completed_reservation_ids" => []
          )
        )

        refute status.success?, name
        assert_nil output, name
        error = JSON.parse(stderr)
        assert_equal "batch-token-budget-error", error.fetch("type"), name
        assert_equal "invalid-input", error.fetch("status"), name
        assert_equal "unsupported-command-contract", error.fetch("reason"), name
        assert_equal state_before, File.read(state_path), name
      end
    end
  end

  def test_legacy_per_target_usage_wrapper_is_not_an_alternate_reconciliation_contract
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "legacy-wrapper", lane_id: "lane-a", tokens: 100)
      state_before = File.read(state_path)

      output, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "reservation_id" => "legacy-wrapper",
          "usage_receipt" => usage_receipt(
            id: "legacy-usage",
            segments: [{
              "id" => "legacy-self",
              "kind" => "self",
              "scope_id" => "lane-a",
              "target_id" => "task-lane-a",
              "tokens" => 80
            }]
          )
        )
      )

      refute status.success?
      assert_nil output
      assert_equal "unsupported-command-contract", JSON.parse(stderr).fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_same_window_with_a_different_receipt_digest_is_rejected_as_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)
      original_command = command(
        "reconcile",
        "usage_receipt" => receipt,
        "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest,
        "completed_reservation_ids" => []
      )
      first, first_stderr, first_status = run_helper(state_path, original_command)
      assert first_status.success?, first_stderr
      assert_equal "reconciled", first.fetch("status")
      state_before_mutation = File.read(state_path)

      mutated_receipt = JSON.parse(JSON.generate(receipt))
      mutated_receipt.fetch("accounting")["usage_samples"] += 1
      mutated_receipt, mutated_ref, mutated_digest = receipt_artifact(state_path, mutated_receipt, "mutated")
      rejected, rejected_stderr, rejected_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => mutated_receipt,
          "usage_receipt_ref" => mutated_ref,
          "usage_receipt_digest" => mutated_digest,
          "completed_reservation_ids" => []
        )
      )

      assert rejected_status.success?, rejected_stderr
      assert_equal "blocked", rejected.fetch("status")
      assert_equal "usage-window-mutation", rejected.fetch("reason")
      assert_equal state_before_mutation, File.read(state_path)
    end
  end

  def test_exact_usage_receipt_replay_at_a_later_command_time_does_not_recount
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)
      reconcile = command(
        "reconcile",
        "usage_receipt" => receipt,
        "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest,
        "completed_reservation_ids" => []
      )
      first, first_stderr, first_status = run_helper(state_path, reconcile)
      assert first_status.success?, first_stderr
      assert_equal 112, first.dig("totals", "aggregate", "consumed_tokens")

      replay, replay_stderr, replay_status = run_helper(
        state_path,
        reconcile.merge("evaluated_at" => "2026-08-12T12:01:00Z")
      )

      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replay.fetch("status")
      assert_equal 112, replay.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 112, JSON.parse(File.read(state_path)).dig("scopes", "aggregate", "consumed_tokens")
    end
  end

  def test_first_usage_window_must_start_at_the_persisted_initialization_cutoff
    with_state do |state_path|
      initialize_budget(state_path, evaluated_at: "2026-08-12T12:00:00Z")
      reserve(state_path, id: "first-window-gap", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      omitted_prefix = usage_window(
        base_receipt,
        from: "2026-08-12T12:10:00Z",
        to: "2026-08-12T12:20:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 10, "lane-b" => 0 }
      )
      omitted_prefix, receipt_ref, receipt_digest = receipt_artifact(state_path, omitted_prefix, "first-window-gap")
      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:20:00Z",
          "usage_receipt" => omitted_prefix,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-window-gap", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
      state = JSON.parse(File.read(state_path))
      assert_equal "2026-08-12T12:00:00Z", state.fetch("usage_initial_cutoff")
      assert_empty state.fetch("usage_receipts")
    end
  end

  def test_restart_rejects_a_rebound_initial_usage_cutoff_even_after_tail_rehash
    with_state do |state_path|
      initialize_budget(state_path)
      state = JSON.parse(File.read(state_path))
      state["usage_initial_cutoff"] = "2026-08-12T10:00:00Z"
      state.dig("receipts", 0)["usage_initial_cutoff"] = "2026-08-12T10:00:00Z"
      rehash_control_tail(state)
      File.write(state_path, JSON.generate(state))

      output, stderr, status = run_helper(state_path, command("closeout"))

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_release_after_a_partial_usage_window_frees_only_remaining_headroom
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "partial-window", lane_id: "lane-a", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 60, "lane-b" => 0 }
      )
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "partial")
      observed, observed_stderr, observed_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )
      assert observed_status.success?, observed_stderr
      assert_equal 60, observed.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 40, observed.dig("totals", "aggregate", "reserved_tokens")

      released, released_stderr, released_status = run_helper(
        state_path,
        command(
          "release",
          "release" => {
            "type" => "batch-token-release",
            "version" => 1,
            "id" => "partial-release",
            "reservation_id" => "partial-window",
            "reason" => "Observed boundary ended early."
          }
        )
      )

      assert released_status.success?, released_stderr
      assert_equal "released", released.fetch("status")
      assert_equal 0, released.dig("totals", "aggregate", "reserved_tokens")
      assert_equal 40, released.dig("totals", "aggregate", "released_tokens")
      assert_equal 60, released.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_idle_usage_window_advances_without_touching_an_active_reservation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "idle-window", lane_id: "lane-a", tokens: 100)
      reserve(state_path, id: "idle-concurrent-lane", lane_id: "lane-b", tokens: 80)
      reservations_before = JSON.parse(File.read(state_path)).fetch("reservations")
      base_receipt, = real_descendants_usage_receipt(state_path)
      idle_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )

      reconciled, stderr, status = reconcile_receipt(state_path, idle_receipt, "idle-window")

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      saved = JSON.parse(File.read(state_path))
      assert_equal "2026-08-12T12:00:00Z", saved.fetch("usage_cursor")
      assert_equal 1, saved.fetch("usage_receipts").length
      assert_equal reservations_before, saved.fetch("reservations")
      assert_equal 180, saved.dig("scopes", "aggregate", "reserved_tokens")

      replayed, replay_stderr, replay_status = reconcile_receipt(state_path, idle_receipt, "idle-window")
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal saved, JSON.parse(File.read(state_path))
    end
  end

  def test_zero_token_window_can_explicitly_complete_an_active_reservation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "zero-token-completion", lane_id: "lane-a", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      idle_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )

      reconciled, stderr, status = reconcile_receipt(
        state_path,
        idle_receipt,
        "zero-token-completion",
        completed_reservation_ids: ["zero-token-completion"]
      )

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      saved = JSON.parse(File.read(state_path))
      assert_equal "reconciled", saved.dig("reservations", "zero-token-completion", "status")
      assert_equal 0, saved.dig("reservations", "zero-token-completion", "observed_tokens")
      assert_equal 100, saved.dig("reservations", "zero-token-completion", "released_tokens")
      assert_equal 0, saved.dig("scopes", "aggregate", "reserved_tokens")
    end
  end

  def test_an_overshoot_envelope_can_be_consumed_only_once
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "multi-window", lane_id: "lane-a", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      first_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 110, "lane-b" => 0 }
      )
      first_receipt, first_ref, first_digest = receipt_artifact(state_path, first_receipt, "overshoot-first")
      first, first_stderr, first_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => first_receipt,
          "usage_receipt_ref" => first_ref,
          "usage_receipt_digest" => first_digest,
          "completed_reservation_ids" => []
        )
      )
      assert first_status.success?, first_stderr
      assert_equal 110, first.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 0, first.dig("totals", "aggregate", "reserved_tokens")

      fenced, fenced_stderr, fenced_status = reserve(
        state_path,
        id: "after-consumed-overshoot-envelope",
        tokens: 1
      )
      assert fenced_status.success?, fenced_stderr
      assert_equal "blocked", fenced.fetch("status")
      assert_equal "overshoot-envelope-consumed", fenced.fetch("reason")
      assert_equal %w[read-only-discovery checkpoint release], fenced.fetch("allowed_actions")

      second_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T12:00:00Z",
        to: "2026-08-12T12:01:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 20, "lane-b" => 0 }
      )
      second_receipt, second_ref, second_digest = receipt_artifact(state_path, second_receipt, "overshoot-second")
      second, second_stderr, second_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:01:00Z",
          "usage_receipt" => second_receipt,
          "usage_receipt_ref" => second_ref,
          "usage_receipt_digest" => second_digest,
          "completed_reservation_ids" => ["multi-window"]
        )
      )
      assert second_status.success?, second_stderr
      assert_equal "blocked", second.fetch("status")
      assert_equal "overshoot-evidence-unsupported", second.fetch("reason")
      assert_equal 110, second.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 0, second.dig("totals", "aggregate", "reserved_tokens")

      closeout, closeout_stderr, closeout_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T12:02:00Z")
      )
      assert closeout_status.success?, closeout_stderr
      assert_equal "not-complete", closeout.fetch("status")
      assert_equal 10, closeout.dig("overshoot", "tokens")
      assert_equal 1, closeout.dig("overshoot", "turn_count")
      assert_equal({ "lane-a" => 10 }, closeout.dig("overshoot", "by_scope"))

      released, release_stderr, release_status = run_helper(
        state_path,
        command(
          "release",
          "evaluated_at" => "2026-08-12T12:03:00Z",
          "release" => {
            "type" => "batch-token-release",
            "version" => 1,
            "id" => "release-consumed-overshoot-envelope",
            "reservation_id" => "multi-window",
            "reason" => "Terminalize the consumed overshoot envelope before a new turn."
          }
        )
      )
      assert release_status.success?, release_stderr
      assert_equal "released", released.fetch("status")
      fresh, fresh_stderr, fresh_status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => "2026-08-12T12:04:00Z",
          "reservation" => reservation(
            id: "fresh-after-overshoot",
            tokens: 1,
            overrides: {
              "telemetry" => reservation(id: "ignored", tokens: 1).fetch("telemetry").merge(
                "observed_at" => "2026-08-12T12:03:59Z"
              )
            }
          )
        )
      )
      assert fresh_status.success?, fresh_stderr
      assert_equal "admitted", fresh.fetch("status")
    end
  end

  def test_overshooting_window_requires_authoritative_per_scope_turn_evidence
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "unproved-overshoot", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      unproved_overshoot = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 500, "lane-b" => 0 },
        lane_turns: { "lane-a" => 2, "lane-b" => 0 }
      )
      unproved_overshoot.fetch("accounting")["usage_samples"] = 25
      unproved_overshoot, receipt_ref, receipt_digest = receipt_artifact(
        state_path, unproved_overshoot, "unproved-overshoot"
      )

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => unproved_overshoot,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => ["unproved-overshoot"]
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "overshoot-evidence-unsupported", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_overshooting_window_with_zero_contributing_turns_fails_closed
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "zero-turn-overshoot", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 500, "lane-b" => 0 },
        lane_turns: { "lane-a" => 0, "lane-b" => 0 }
      )
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "zero-turn-overshoot")

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => ["zero-turn-overshoot"]
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_unknown_turn_context_evidence_from_the_real_usage_helper_fails_closed
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "unknown-turn-evidence", tokens: 100)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(
        state_path, remove_turn_context_for: "lane-a.jsonl"
      )
      assert_equal "UNKNOWN", receipt.dig("lanes", 0, "turns", "descendant_inclusive")

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => ["unknown-turn-evidence"]
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_consumer_rejects_a_forged_balanced_lane_with_unknown_turn_operands_without_accounting
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, = real_descendants_usage_receipt(state_path, remove_turn_context_for: "lane-a.jsonl")
      lane = receipt.fetch("lanes").find { |candidate| candidate.fetch("id") == "lane-a" }
      lane.fetch("reconciliation")["status"] = "balanced"
      assert_equal "UNKNOWN", lane.dig("turns", "descendant_inclusive")
      projection_before = JSON.parse(File.binread(state_path))

      blocked, stderr, status = reconcile_receipt(state_path, receipt, "forged-balanced-unknown-turns")

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      projection_after = JSON.parse(File.binread(state_path))
      assert_equal projection_before.fetch("scopes"), projection_after.fetch("scopes")
      assert_empty projection_after.fetch("usage_receipts")
      assert_nil projection_after["usage_cursor"]
    end
  end

  def test_batch_usage_window_preserves_cross_task_charge_back_without_double_counting
    with_state do |state_path|
      initialize_budget(state_path)
      source = task_identity(task_id: "source-task")
      source["batch_id"] = "source-batch"
      target = task_identity(task_id: "task-lane-a")
      admitted, admitted_stderr, admitted_status = run_helper(
        state_path,
        command(
          "reserve",
          "reservation" => reservation(
            id: "window-delegation",
            tokens: 100,
            kind: "cross-task-delegation",
            overrides: { "source" => source, "target" => target }
          )
        )
      )
      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted", admitted.fetch("status")

      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 80, "lane-b" => 0 }
      )
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "charge-back")
      charge_back = {
        "type" => "batch-token-charge-back",
        "version" => 1,
        "id" => "window-cause",
        "source" => source,
        "target" => target
      }
      reconcile = command(
        "reconcile",
        "usage_receipt" => receipt,
        "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest,
        "completed_reservation_ids" => ["window-delegation"],
        "charge_backs" => [{ "reservation_id" => "window-delegation", "charge_back" => charge_back }]
      )
      reconciled, stderr, status = run_helper(state_path, reconcile)

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 80, reconciled.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 80, reconciled.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 80, reconciled.dig("charge_backs", 0, "tokens")
      assert_equal false, reconciled.dig("charge_backs", 0, "physical_total_incremented")
      assert_equal 80, JSON.parse(File.read(state_path)).dig("charge_backs", "window-cause", "summary", "tokens")

      replayed, replay_stderr, replay_status = run_helper(
        state_path,
        reconcile.merge("evaluated_at" => "2026-08-12T12:01:00Z")
      )
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      assert_equal 80, replayed.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_topology_unknown_cannot_be_hidden_behind_numeric_totals_and_balanced_flags
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt.fetch("evidence")["status"] = "UNKNOWN"
      receipt.fetch("evidence")["unknown"] = [{
        "status" => "UNKNOWN",
        "code" => "lane_scope_overlap",
        "lane_ids" => %w[lane-a lane-b]
      }]
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "topology-unknown")
      state_before = File.read(state_path)

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      state = JSON.parse(File.read(state_path))
      assert_equal JSON.parse(state_before).fetch("scopes"), state.fetch("scopes")
      assert_empty state.fetch("usage_receipts")
    end
  end

  def test_top_level_complete_cannot_hide_incomplete_coordinator_lane_or_worker_evidence
    variants = {
      "coordinator" => proc { |receipt| receipt.dig("coordinator", "evidence")["status"] = "UNKNOWN" },
      "lane" => proc { |receipt| receipt.dig("lanes", 0, "evidence")["status"] = "UNKNOWN" },
      "worker" => proc { |receipt| receipt.dig("lanes", 0, "workers", 0, "evidence")["status"] = "UNKNOWN" }
    }

    variants.each do |name, contradict|
      with_state do |state_path|
        initialize_budget(state_path)
        base_receipt, = real_descendants_usage_receipt(state_path)
        receipt = usage_window(
          base_receipt,
          from: "2026-08-12T11:00:00Z",
          to: "2026-08-12T12:00:00Z",
          coordinator_tokens: 0,
          lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
        )
        assert_equal "complete", receipt.dig("evidence", "status"), name
        contradict.call(receipt)
        state_before = File.read(state_path)
        before = JSON.parse(state_before)

        blocked, stderr, status = reconcile_receipt(state_path, receipt, "incomplete-#{name}")

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_equal state_before, File.read(state_path), name
        saved = JSON.parse(File.read(state_path))
        assert_equal before.fetch("control_events"), saved.fetch("control_events"), name
        assert_nil before["usage_cursor"], name
        assert_nil saved["usage_cursor"], name
        assert_empty saved.fetch("usage_receipts"), name

        closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
        assert closeout_status.success?, "#{name}: #{closeout_stderr}"
        assert_equal "not-complete", closeout.fetch("status"), name
        assert_equal "NOT COMPLETE", closeout.fetch("completion"), name
        assert_equal "usage-cursor-missing", closeout.dig("telemetry", "reason"), name
      end
    end
  end

  def test_reconcile_rejects_malformed_complete_scope_evidence
    scope_evidence = lambda do |receipt, scope|
      case scope
      when :coordinator
        receipt.dig("coordinator", "evidence")
      when :lane
        receipt.dig("lanes", 0, "evidence")
      when :worker
        receipt.dig("lanes", 0, "workers", 0, "evidence")
      else
        flunk "unknown test scope: #{scope}"
      end
    end
    empty_identities = lambda do |evidence|
      evidence["physical_rollout_ids"] = []
      evidence["first_session_ids"] = []
      evidence.delete("first_session_id")
    end
    variants = [
      ["coordinator-empty-identities", :coordinator, empty_identities],
      ["lane-empty-identities", :lane, empty_identities],
      ["worker-empty-identities", :worker, empty_identities],
      ["mismatched-identity-counts", :coordinator, lambda do |evidence|
        evidence["first_session_ids"] = [evidence.fetch("first_session_ids").first, "second-session"]
        evidence["physical_rollout_ids"] = [evidence.fetch("physical_rollout_ids").first]
        evidence.delete("first_session_id")
      end],
      ["missing-singleton-alias", :coordinator, lambda do |evidence|
        evidence["first_session_ids"] = [evidence.fetch("first_session_ids").first]
        evidence["physical_rollout_ids"] = [evidence.fetch("physical_rollout_ids").first]
        evidence.delete("first_session_id")
      end],
      ["incorrect-singleton-alias", :coordinator, lambda do |evidence|
        evidence["first_session_ids"] = [evidence.fetch("first_session_ids").first]
        evidence["physical_rollout_ids"] = [evidence.fetch("physical_rollout_ids").first]
        evidence["first_session_id"] = "wrong-session"
      end],
      ["multiple-identities-with-singleton-alias", :coordinator, lambda do |evidence|
        first_session_id = evidence.fetch("first_session_ids").first
        physical_rollout_id = evidence.fetch("physical_rollout_ids").first
        extra_rollout_id = "sha256:#{'f' * 64}"
        extra_rollout_id = "sha256:#{'e' * 64}" if extra_rollout_id == physical_rollout_id
        evidence["first_session_ids"] = [first_session_id, "second-session"]
        evidence["physical_rollout_ids"] = [physical_rollout_id, extra_rollout_id]
        evidence["first_session_id"] = first_session_id
      end]
    ]

    variants.each do |name, scope, mutate|
      with_state do |state_path|
        initialize_budget(state_path)
        base_receipt, = real_descendants_usage_receipt(state_path)
        receipt = usage_window(
          base_receipt,
          from: "2026-08-12T11:00:00Z",
          to: "2026-08-12T12:00:00Z",
          coordinator_tokens: 0,
          lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
        )
        evidence = scope_evidence.call(receipt, scope)
        assert_equal "complete", evidence.fetch("status"), name
        mutate.call(evidence)
        state_before = File.binread(state_path)

        blocked, stderr, status = reconcile_receipt(state_path, receipt, name)

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_equal state_before, File.binread(state_path), name
        assert_empty JSON.parse(File.binread(state_path)).fetch("usage_receipts"), name
      end
    end
  end

  def test_top_level_unknown_without_a_reason_is_rejected_before_accounting_or_persistence
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt.fetch("evidence").merge!("status" => "UNKNOWN", "unknown" => [])
      state_before = File.binread(state_path)
      projection_before = JSON.parse(state_before)

      blocked, stderr, status = reconcile_receipt(state_path, receipt, "empty-top-level-unknown")

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal state_before, File.binread(state_path)
      projection_after = JSON.parse(File.binread(state_path))
      assert_equal projection_before.fetch("control_events"), projection_after.fetch("control_events")
      assert_equal projection_before.fetch("scopes"), projection_after.fetch("scopes")
      assert_equal projection_before.fetch("usage_receipts"), projection_after.fetch("usage_receipts")
      assert_nil projection_before["usage_cursor"]
      assert_nil projection_after["usage_cursor"]

      restarted, restart_stderr, restart_status = run_helper(state_path, command("closeout"))
      assert restart_status.success?, restart_stderr
      assert_equal "not-complete", restarted.fetch("status")
    end
  end

  def test_lane_reconciliation_equation_is_recomputed_instead_of_trusting_balanced_status
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "forged-lane-equation", tokens: 200)
      receipt, = real_descendants_usage_receipt(state_path)
      worker_usage = receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive")
      worker_usage["total_tokens"] += 1
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "forged-lane-equation")

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_positive_named_worker_self_tokens_require_positive_self_turns
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "worker-self-turn-evidence", tokens: 100)
      receipt = lane_component_usage_window(
        state_path,
        lane_tokens: 500, lane_turns: 1,
        worker_tokens: 500, worker_turns: 1,
        worker_self_tokens: 500, worker_self_turns: 0,
        unattributed_tokens: 0, unattributed_turns: 0
      )
      blocked, stderr, status = reconcile_receipt(
        state_path,
        receipt,
        "worker-self-zero-turns",
        completed_reservation_ids: ["worker-self-turn-evidence"]
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_positive_unattributed_tokens_require_positive_turns_in_a_mixed_lane
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "unattributed-turn-evidence", tokens: 100)
      receipt = lane_component_usage_window(
        state_path,
        lane_tokens: 500, lane_turns: 1,
        worker_tokens: 100, worker_turns: 1,
        unattributed_tokens: 400, unattributed_turns: 0
      )
      blocked, stderr, status = reconcile_receipt(
        state_path,
        receipt,
        "unattributed-zero-turns",
        completed_reservation_ids: ["unattributed-turn-evidence"]
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_lane_component_turns_require_zero_zero_compatibility_and_token_upper_bounds
    scenarios = {
      "zero-worker-tokens-with-a-turn" => {
        "lane_turns" => 2, "worker_tokens" => 0, "worker_turns" => 1,
        "unattributed_tokens" => 10, "unattributed_turns" => 1
      },
      "unattributed-turns-above-tokens" => {
        "lane_turns" => 3, "worker_tokens" => 9, "worker_turns" => 1,
        "unattributed_tokens" => 1, "unattributed_turns" => 2
      }
    }
    scenarios.each do |name, scenario|
      with_state do |state_path|
        initialize_budget(state_path)
        receipt = lane_component_usage_window(
          state_path,
          lane_tokens: 10,
          lane_turns: scenario.fetch("lane_turns"),
          worker_tokens: scenario.fetch("worker_tokens"),
          worker_turns: scenario.fetch("worker_turns"),
          worker_self_tokens: scenario.fetch("worker_tokens"),
          worker_self_turns: scenario.fetch("worker_tokens").positive? ? scenario.fetch("worker_turns") : 0,
          unattributed_tokens: scenario.fetch("unattributed_tokens"),
          unattributed_turns: scenario.fetch("unattributed_turns")
        )
        blocked, stderr, status = reconcile_receipt(state_path, receipt, name)

        assert status.success?, stderr
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts"), name
      end
    end
  end

  def test_batch_unattributed_tokens_cannot_borrow_the_coordinator_turn
    assert_batch_component_turn_borrowing_rejected(
      name: "batch-unattributed-borrows-coordinator-turn",
      coordinator_turns: 1,
      batch_unattributed_turns: 0
    )
  end

  def test_coordinator_tokens_cannot_borrow_the_batch_unattributed_turn
    assert_batch_component_turn_borrowing_rejected(
      name: "coordinator-borrows-batch-unattributed-turn",
      coordinator_turns: 0,
      batch_unattributed_turns: 1
    )
  end

  def test_valid_coordinator_and_batch_unattributed_turn_components_reconcile_and_replay
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "valid-batch-components", lane_id: "coordinator", tokens: 20)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 10,
        coordinator_turns: 2,
        batch_unattributed_tokens: 10,
        batch_unattributed_turns: 1,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )

      reconciled, stderr, status = reconcile_receipt(
        state_path,
        receipt,
        "valid-batch-components",
        completed_reservation_ids: ["valid-batch-components"]
      )
      replayed, replay_stderr, replay_status = reconcile_receipt(
        state_path,
        receipt,
        "valid-batch-components",
        completed_reservation_ids: ["valid-batch-components"]
      )

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 20, reconciled.dig("totals", "aggregate", "consumed_tokens")
      assert replay_status.success?, replay_stderr
      assert_equal "replayed", replayed.fetch("status")
      state = JSON.parse(File.read(state_path))
      assert_equal 20, state.dig("scopes", "aggregate", "consumed_tokens")
      assert_equal 1, state.fetch("usage_receipts").length
      assert_equal 3, state.fetch("usage_receipts").values.first.dig("scope_turns", "coordinator")
    end
  end

  def test_irrelevant_cache_counter_unknown_does_not_hide_known_total_tokens
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, = real_descendants_usage_receipt(state_path)
      set_usage_counter(receipt, "cache_read_tokens", "UNKNOWN")
      physical_rollout_id = receipt.dig("coordinator", "evidence", "physical_rollout_ids").first
      receipt.fetch("evidence")["status"] = "UNKNOWN"
      receipt.fetch("evidence")["unknown"] = [{
        "status" => "UNKNOWN",
        "code" => "usage_counter_missing",
        "thread_id" => receipt.dig("coordinator", "root_thread_id"),
        "physical_rollout_id" => physical_rollout_id,
        "line" => 2,
        "fields" => ["cache_read_tokens"]
      }]
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "cache-unknown")

      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 112, reconciled.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_restart_rejects_a_mutated_durable_usage_receipt_artifact
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)
      reconciled, reconciled_stderr, reconciled_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )
      assert reconciled_status.success?, reconciled_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      artifact_path = receipt_ref.delete_prefix("file://")
      File.write(artifact_path, JSON.generate("schema" => "tampered"))
      output, stderr, status = run_helper(state_path, command("closeout"))

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
    end
  end

  def test_unreserved_observed_scope_usage_is_consumed_unattributed_and_blocks_closeout
    with_state do |state_path|
      initialize_budget(state_path)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)
      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )
      assert status.success?, stderr
      assert_equal 112, reconciled.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 112, reconciled.dig("totals", "aggregate", "unattributed_tokens")
      assert_equal 15, reconciled.dig("totals", "coordinator", "unattributed_tokens")
      assert_equal 90, reconciled.dig("totals", "lanes", "lane-a", "unattributed_tokens")
      assert_equal 7, reconciled.dig("totals", "lanes", "lane-b", "unattributed_tokens")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "not-complete", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal 112, closeout.fetch("unattributed_tokens")
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

  def test_lane_approval_does_not_authorize_an_aggregate_only_approval_threshold
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      candidate["scopes"]["lanes"].transform_values! { { "limit_tokens" => 1_000 } }
      run_helper(state_path, command("initialize", "budget" => candidate))
      reserve(state_path, id: "aggregate-base", lane_id: "lane-b", tokens: 500, target_id: "base")
      lane_approval = approval(state_path, id: "lane-approval")
      run_helper(state_path, command("approve", "approval" => lane_approval))

      blocked, stderr, status = reserve(
        state_path,
        id: "aggregate-only-with-lane-approval",
        lane_id: "lane-a",
        tokens: 300,
        target_id: "aggregate-target",
        overrides: { "approval_id" => "lane-approval" }
      )

      assert status.success?, stderr
      assert_equal "approval-required", blocked.fetch("status")
      assert_equal "projected-approval-threshold", blocked.fetch("reason")
      decision = JSON.parse(File.read(state_path)).fetch("admission_decisions").values.last
      assert_equal ["aggregate"], decision.fetch("blocking_scope_ids")
    end
  end

  def test_lane_approval_does_not_authorize_combined_lane_and_aggregate_approval_thresholds
    with_state do |state_path|
      candidate = budget(state_path: state_path)
      candidate["scopes"]["lanes"]["lane-b"]["limit_tokens"] = 1_000
      run_helper(state_path, command("initialize", "budget" => candidate))
      reserve(state_path, id: "combined-base", lane_id: "lane-b", tokens: 400, target_id: "base")
      lane_approval = approval(state_path, id: "lane-approval")
      run_helper(state_path, command("approve", "approval" => lane_approval))

      blocked, stderr, status = reserve(
        state_path,
        id: "combined-with-lane-approval",
        lane_id: "lane-a",
        tokens: 480,
        target_id: "combined-target",
        overrides: { "approval_id" => "lane-approval" }
      )

      assert status.success?, stderr
      assert_equal "approval-required", blocked.fetch("status")
      assert_equal "projected-approval-threshold", blocked.fetch("reason")
      decision = JSON.parse(File.read(state_path)).fetch("admission_decisions").values.last
      assert_equal %w[aggregate lane-a], decision.fetch("blocking_scope_ids").sort
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
        state_path = File.join(directory, name, "state.json")
        FileUtils.mkdir_p(File.dirname(state_path))
        candidate = budget(state_path: state_path)
        candidate.dig("scopes", "lanes", "lane-a")["limit_tokens"] = scenario["lane_limit"] if scenario["lane_limit"]
        run_helper(
          state_path,
          command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => candidate)
        )
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
        reconciled, reconcile_stderr, reconcile_status = reconcile_final_zero_usage_window(
          state_path,
          name: "#{name}-approval-closeout"
        )
        assert reconcile_status.success?, reconcile_stderr
        assert_equal "reconciled", reconciled.fetch("status"), name

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
      assert_equal "approval-replay-mismatch", JSON.parse(replay_stderr).fetch("reason")

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

      replayed, replay_stderr, replay_status = initialize_budget(
        state_path,
        evaluated_at: "2026-08-12T12:00:00Z"
      )
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
      assert_equal 3, admitted.dig("receipt", "overshoot_envelope", "max_in_flight_turns")

      base_receipt, = real_descendants_usage_receipt(state_path)
      fanout_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 300, "lane-b" => 0 },
        lane_turns: { "lane-a" => 3, "lane-b" => 0 }
      )
      reconciled, reconcile_stderr, reconcile_status = reconcile_receipt(
        state_path,
        fanout_receipt,
        "cross-task-retained-fanout",
        completed_reservation_ids: ["cross-task-1-authorized"]
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 40, reconciled.fetch("receipts").first.fetch("overshoot_tokens")
      assert_equal 3, reconciled.fetch("receipts").first.fetch("overshoot_turn_count")
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
      run_helper(
        state_path,
        command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => retry_budget)
      )
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

      reconciled, reconcile_stderr, reconcile_status = reconcile_final_zero_usage_window(
        state_path,
        name: "retry-after-headroom-closeout"
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "complete", closeout.fetch("status")
      assert_equal "COMPLETE", closeout.fetch("completion")
    end
  end

  def test_batch_usage_identity_drift_is_rejected_without_consuming_the_window
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "identity-bound", tokens: 200)
      first_receipt, first_ref, first_digest = real_descendants_usage_receipt(state_path)
      first, first_stderr, first_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => first_receipt,
          "usage_receipt_ref" => first_ref,
          "usage_receipt_digest" => first_digest,
          "completed_reservation_ids" => []
        )
      )
      assert first_status.success?, first_stderr
      assert_equal 112, first.dig("totals", "aggregate", "consumed_tokens")

      drifted_receipt = usage_window(
        first_receipt,
        from: "2026-08-12T12:00:00Z",
        to: "2026-08-12T12:01:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 10, "lane-b" => 0 }
      )
      drifted_receipt.fetch("lanes").find { |lane| lane["id"] == "lane-a" }["root_thread_id"] = "drifted-root"
      drifted_receipt, drifted_ref, drifted_digest = receipt_artifact(state_path, drifted_receipt, "identity-drift")
      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:01:00Z",
          "usage_receipt" => drifted_receipt,
          "usage_receipt_ref" => drifted_ref,
          "usage_receipt_digest" => drifted_digest,
          "completed_reservation_ids" => []
        )
      )
      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-identity-drift", blocked.fetch("reason")
      assert_equal 112, blocked.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 110, blocked.dig("totals", "aggregate", "reserved_tokens")
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
      run_helper(
        state_path,
        command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => overshoot_budget)
      )
      reserve(state_path, id: "lane-hard-overshoot", tokens: 500)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 650, "lane-b" => 0 }
      )
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "lane-hard")
      reconciled, reconciled_stderr, reconciled_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => ["lane-hard-overshoot"]
        )
      )
      assert reconciled_status.success?, reconciled_stderr
      assert_equal "reconciled", reconciled.fetch("status")
      persisted_stop = JSON.parse(File.read(state_path)).fetch("admission_decisions").values.find do |decision|
        decision["reservation_id"] == "lane-hard-overshoot"
      end
      assert_equal "budget-exhausted", persisted_stop.fetch("status")
      assert_equal "actual-hard-threshold", persisted_stop.fetch("reason")

      next_turn, next_stderr, next_status = reserve(
        state_path,
        id: "lane-hard-next-turn",
        tokens: 1
      )
      assert next_status.success?, next_stderr
      assert_equal "budget-exhausted", next_turn.fetch("status")
      assert_equal "persisted-hard-stop", next_turn.fetch("reason")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "budget-exhausted", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal 650, closeout.dig("totals", "lanes", "lane-a", "consumed_tokens")
      assert_equal 650, closeout.dig("totals", "aggregate", "consumed_tokens")
    end
  end

  def test_reconciled_actual_usage_persists_warning_and_approval_threshold_state
    {
      "warning" => { "tokens" => 300, "next_status" => "admitted-with-warning" },
      "approval" => { "tokens" => 480, "next_status" => "approval-required" }
    }.each do |threshold, expectations|
      with_state do |state_path|
        initialize_budget(state_path)
        reserve(state_path, id: "actual-#{threshold}", tokens: 100)
        base_receipt, = real_descendants_usage_receipt(state_path)
        receipt = usage_window(
          base_receipt,
          from: "2026-08-12T11:00:00Z",
          to: "2026-08-12T12:00:00Z",
          coordinator_tokens: 0,
          lane_tokens: { "lane-a" => expectations.fetch("tokens"), "lane-b" => 0 }
        )
        reconciled, stderr, status = reconcile_receipt(
          state_path,
          receipt,
          "actual-#{threshold}",
          completed_reservation_ids: ["actual-#{threshold}"]
        )
        assert status.success?, stderr
        assert_equal "reconciled", reconciled.fetch("status")

        saved = JSON.parse(File.read(state_path))
        if threshold == "warning"
          checkpoint = saved.fetch("checkpoints").find { |item| item["id"].start_with?("actual-threshold-") }
          assert_equal "warning", checkpoint.fetch("status")
          assert_equal "2026-08-12T12:00:00Z", checkpoint.fetch("receipt_cutoff")
        else
          stop = saved.fetch("admission_decisions").values.find do |decision|
            decision["reservation_id"] == "actual-approval"
          end
          assert_equal "approval-required", stop.fetch("status")
          assert_equal "actual-approval-threshold", stop.fetch("reason")
        end

        next_turn, next_stderr, next_status = reserve(
          state_path,
          id: "after-actual-#{threshold}",
          tokens: 1
        )
        assert next_status.success?, next_stderr
        assert_equal expectations.fetch("next_status"), next_turn.fetch("status")
        assert_equal "persisted-approval-stop", next_turn.fetch("reason") if threshold == "approval"
      end
    end
  end

  def test_reconciled_threshold_replaces_a_stale_approval_decision_with_a_later_hard_stop
    with_state do |state_path|
      initialize_budget(state_path)
      approval_id = "long-lived-threshold-approval"
      approved, approval_stderr, approval_status = run_helper(
        state_path,
        command("approve", "approval" => approval(state_path, id: approval_id))
      )
      assert approval_status.success?, approval_stderr
      assert_equal "approved", approved.fetch("status")

      admitted, admitted_stderr, admitted_status = reserve(
        state_path,
        id: "long-lived-threshold-reservation",
        tokens: 480,
        overrides: { "approval_id" => approval_id }
      )
      assert admitted_status.success?, admitted_stderr
      assert_equal "admitted-with-warning", admitted.fetch("status")

      base_receipt, = real_descendants_usage_receipt(state_path)
      approval_window = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 480, "lane-b" => 0 }
      )
      reconciled, reconcile_stderr, reconcile_status = reconcile_receipt(
        state_path,
        approval_window,
        "long-lived-approval"
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")

      approval_stop = JSON.parse(File.read(state_path)).fetch("admission_decisions").values.find do |decision|
        decision["reservation_id"] == "long-lived-threshold-reservation"
      end
      assert_equal "approval-required", approval_stop.fetch("status")
      assert_equal "actual-approval-threshold", approval_stop.fetch("reason")

      hard_window = usage_window(
        base_receipt,
        from: "2026-08-12T12:00:00Z",
        to: "2026-08-12T13:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 120, "lane-b" => 0 }
      )
      hard_window, hard_ref, hard_digest = receipt_artifact(state_path, hard_window, "long-lived-hard")
      hardened, hard_stderr, hard_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T13:00:00Z",
          "usage_receipt" => hard_window,
          "usage_receipt_ref" => hard_ref,
          "usage_receipt_digest" => hard_digest,
          "completed_reservation_ids" => []
        )
      )
      assert hard_status.success?, hard_stderr
      assert_equal "reconciled", hardened.fetch("status")

      saved = JSON.parse(File.read(state_path))
      hard_stop = saved.fetch("admission_decisions").values.find do |decision|
        decision["reservation_id"] == "long-lived-threshold-reservation"
      end
      assert_equal "budget-exhausted", hard_stop.fetch("status")
      assert_equal "actual-hard-threshold", hard_stop.fetch("reason")
      assert_equal ["lane-a"], hard_stop.fetch("blocking_scope_ids")
      assert(saved.fetch("receipts").any? { |receipt| receipt == hard_stop.fetch("receipt") })
      statuses = saved.dig("reservation_decisions", "long-lived-threshold-reservation", "outcomes").map do |outcome|
        outcome.fetch("status")
      end
      assert_equal %w[approval-required budget-exhausted], statuses.last(2)

      equivalent_window = usage_window(
        base_receipt,
        from: "2026-08-12T13:00:00Z",
        to: "2026-08-12T14:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      equivalent_window, equivalent_ref, equivalent_digest = receipt_artifact(
        state_path,
        equivalent_window,
        "long-lived-equivalent-hard"
      )
      equivalent, equivalent_stderr, equivalent_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T14:00:00Z",
          "usage_receipt" => equivalent_window,
          "usage_receipt_ref" => equivalent_ref,
          "usage_receipt_digest" => equivalent_digest,
          "completed_reservation_ids" => []
        )
      )
      assert equivalent_status.success?, equivalent_stderr
      assert_equal "reconciled", equivalent.fetch("status")
      equivalent_state = JSON.parse(File.read(state_path))
      equivalent_stop = equivalent_state.fetch("admission_decisions").values.find do |decision|
        decision["reservation_id"] == "long-lived-threshold-reservation"
      end
      assert_equal hard_stop.fetch("receipt"), equivalent_stop.fetch("receipt")
      equivalent_statuses = equivalent_state.dig(
        "reservation_decisions",
        "long-lived-threshold-reservation",
        "outcomes"
      ).map { |outcome| outcome.fetch("status") }
      assert_equal statuses, equivalent_statuses

      next_request = reservation(id: "after-long-lived-hard-stop", tokens: 1)
      next_request["telemetry"]["observed_at"] = "2026-08-12T13:59:59Z"
      next_turn, next_stderr, next_status = run_helper(
        state_path,
        command(
          "reserve",
          "evaluated_at" => "2026-08-12T14:00:01Z",
          "reservation" => next_request
        )
      )
      assert next_status.success?, next_stderr
      assert_equal "budget-exhausted", next_turn.fetch("status")
      assert_equal "persisted-hard-stop", next_turn.fetch("reason")
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
        "receipt_cutoff" => "2026-08-12T11:00:00Z",
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

      fabricated = JSON.parse(JSON.generate(checkpoint)).merge(
        "id" => "checkpoint-hard-fabricated",
        "receipt_cutoff" => "2026-08-12T11:00:01Z"
      )
      rejected, rejected_stderr, rejected_status = run_helper(
        state_path,
        command("checkpoint", "checkpoint" => fabricated)
      )
      refute rejected_status.success?
      assert_nil rejected
      assert_equal "invalid-checkpoint", JSON.parse(rejected_stderr).fetch("reason")

      closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
      assert closeout_status.success?, closeout_stderr
      assert_equal "budget-exhausted", closeout.fetch("status")
      assert_equal "NOT COMPLETE", closeout.fetch("completion")
      assert_equal checkpoint, closeout.fetch("latest_checkpoint")
      assert_equal 0, closeout.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 0, closeout.dig("totals", "aggregate", "reserved_tokens")
      assert_equal "missing", closeout.dig("telemetry", "status")

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
      reconciled, reconcile_stderr, reconcile_status = reconcile_final_zero_usage_window(
        state_path,
        name: "hard-checkpoint-recovery-closeout"
      )
      assert reconcile_status.success?, reconcile_stderr
      assert_equal "reconciled", reconciled.fetch("status")
      recovered, = run_helper(state_path, command("closeout"))
      assert_equal "complete", recovered.fetch("status")
      assert_equal "COMPLETE", recovered.fetch("completion")
    end
  end

  def test_stale_relevant_unknown_overlap_and_gap_usage_windows_fail_closed
    with_state do |state_path|
      receipt_budget = budget(state_path: state_path)
      receipt_budget["scopes"]["lanes"]["lane-a"]["limit_tokens"] = 1_000
      run_helper(
        state_path,
        command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => receipt_budget)
      )
      reserve(state_path, id: "receipt-gate", tokens: 300)
      base_receipt, = real_descendants_usage_receipt(state_path)

      stale_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T10:00:00Z",
        to: "2026-08-12T11:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 10, "lane-b" => 0 }
      )
      stale_receipt, stale_ref, stale_digest = receipt_artifact(state_path, stale_receipt, "stale")
      stale, stale_stderr, stale_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => stale_receipt,
          "usage_receipt_ref" => stale_ref,
          "usage_receipt_digest" => stale_digest,
          "completed_reservation_ids" => []
        )
      )
      assert stale_status.success?, stale_stderr
      assert_equal "blocked", stale.fetch("status")
      assert_equal "usage-telemetry-stale", stale.fetch("reason")
      assert_equal 300, stale.dig("totals", "aggregate", "reserved_tokens")

      unknown_receipt = JSON.parse(JSON.generate(base_receipt))
      unknown_receipt.dig("lanes", 0, "usage", "descendant_inclusive")["total_tokens"] = "UNKNOWN"
      unknown_receipt.dig("lanes", 0, "reconciliation")["status"] = "UNKNOWN"
      unknown_receipt, unknown_ref, unknown_digest = receipt_artifact(state_path, unknown_receipt, "unknown-total")
      unknown, unknown_stderr, unknown_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => unknown_receipt,
          "usage_receipt_ref" => unknown_ref,
          "usage_receipt_digest" => unknown_digest,
          "completed_reservation_ids" => []
        )
      )
      assert unknown_status.success?, unknown_stderr
      assert_equal "blocked", unknown.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", unknown.fetch("reason")

      base_receipt, base_ref, base_digest = receipt_artifact(state_path, base_receipt, "continuity-base")
      counted, counted_stderr, counted_status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => base_receipt,
          "usage_receipt_ref" => base_ref,
          "usage_receipt_digest" => base_digest,
          "completed_reservation_ids" => []
        )
      )
      assert counted_status.success?, counted_stderr
      assert_equal "reconciled", counted.fetch("status")
      assert_equal 112, counted.dig("totals", "aggregate", "consumed_tokens")

      overlap_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:59:30Z",
        to: "2026-08-12T12:00:30Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 1, "lane-b" => 0 }
      )
      overlap_receipt, overlap_ref, overlap_digest = receipt_artifact(state_path, overlap_receipt, "overlap")
      overlap, overlap_stderr, overlap_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:01:00Z",
          "usage_receipt" => overlap_receipt,
          "usage_receipt_ref" => overlap_ref,
          "usage_receipt_digest" => overlap_digest,
          "completed_reservation_ids" => []
        )
      )
      assert overlap_status.success?, overlap_stderr
      assert_equal "usage-window-overlap", overlap.fetch("reason")

      gap_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T12:01:00Z",
        to: "2026-08-12T12:02:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 1, "lane-b" => 0 }
      )
      gap_receipt, gap_ref, gap_digest = receipt_artifact(state_path, gap_receipt, "gap")
      gap, gap_stderr, gap_status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:02:00Z",
          "usage_receipt" => gap_receipt,
          "usage_receipt_ref" => gap_ref,
          "usage_receipt_digest" => gap_digest,
          "completed_reservation_ids" => []
        )
      )
      assert gap_status.success?, gap_stderr
      assert_equal "usage-window-gap", gap.fetch("reason")
      assert_equal 112, gap.dig("totals", "aggregate", "consumed_tokens")
      assert_equal 210, gap.dig("totals", "aggregate", "reserved_tokens")
    end
  end

  def test_fractionally_future_usage_window_fails_closed
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      future_receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00.500000Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      future_receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, future_receipt, "fractional-future")

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => future_receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-window-future", blocked.fetch("reason")
      assert_equal 0, blocked.dig("totals", "aggregate", "consumed_tokens")
      saved = JSON.parse(File.read(state_path))
      assert_empty saved.fetch("usage_receipts")
      assert_nil saved.fetch("usage_cursor")
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

  def test_override_expiration_hierarchy_deadlock_fails_closed_without_mutating_state
    load_batch_token_budget_module
    effective_budget = budget(state_path: "/tmp/deadlocked-batch-token-budget.json")
    effective_budget.dig("scopes", "aggregate")["limit_tokens"] = 1_500
    effective_budget.dig("scopes", "lanes", "lane-a")["limit_tokens"] = 1_300
    state = {
      "batch_id" => "batch-399",
      "budget" => effective_budget,
      "effective_budget_digest" => object_digest(effective_budget),
      "revision" => 0,
      "receipts" => [],
      "scopes" => {
        "aggregate" => { "limit_tokens" => 1_500 },
        "coordinator" => { "limit_tokens" => 300 },
        "lanes" => {
          "lane-a" => { "limit_tokens" => 1_300 },
          "lane-b" => { "limit_tokens" => 500 }
        }
      },
      "overrides" => {
        "aggregate-expiration" => {
          "active" => true,
          "scope_id" => "aggregate",
          "old_limit_tokens" => 1_000,
          "new_limit_tokens" => 1_500,
          "expires_at" => "2026-08-12T12:05:00Z"
        },
        "lane-expiration" => {
          "active" => true,
          "scope_id" => "lane-a",
          "old_limit_tokens" => 1_600,
          "new_limit_tokens" => 1_300,
          "expires_at" => "2026-08-12T12:05:00Z"
        }
      }
    }
    before = Marshal.load(Marshal.dump(state))

    error = assert_raises(BatchTokenBudget::InvalidInput) do
      BatchTokenBudget.expire_overrides(state, "2026-08-12T13:00:00Z")
    end

    assert_equal "override-expiration-hierarchy-deadlock", error.message
    assert_equal before, state
  end

  def test_batch_usage_receipt_requires_a_durable_non_self_attested_matching_reference
    variants = {
      "self-attested-uri" => ["self-attested://worker/usage", "usage-receipt-reference-invalid"],
      "worker-self-attested-uri" => ["worker-self-attested://worker/usage", "usage-receipt-reference-invalid"],
      "plain-reference" => ["worker says 100 tokens", "usage-receipt-reference-invalid"],
      "unknown-reference" => %w[UNKNOWN usage-receipt-reference-invalid],
      "missing-file" => ["file:///definitely/missing/batch-usage-receipt.json", "usage-receipt-artifact-mismatch"]
    }
    variants.each do |name, (invalid_ref, reason)|
      with_state do |state_path|
        initialize_budget(state_path)
        reserve(state_path, id: "#{name}-reservation", tokens: 100, target_id: "#{name}-target")
        receipt, _receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)

        blocked, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "usage_receipt" => receipt,
            "usage_receipt_ref" => invalid_ref,
            "usage_receipt_digest" => receipt_digest,
            "completed_reservation_ids" => []
          )
        )

        assert status.success?, stderr
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal reason, blocked.fetch("reason"), name
        assert_equal 100, blocked.dig("totals", "aggregate", "reserved_tokens"), name
        state = JSON.parse(File.read(state_path))
        assert_equal "active", state.dig("reservations", "#{name}-reservation", "status"), name
        assert_empty state.fetch("usage_receipts"), name
      end
    end
  end

  def test_batch_usage_receipt_accepts_a_percent_encoded_space_in_a_file_reference
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "encoded-space-window", tokens: 200)
      receipt, = real_descendants_usage_receipt(state_path)
      artifact_directory = File.join(File.dirname(state_path), "receipt artifacts")
      Dir.mkdir(artifact_directory)
      artifact_path = File.join(artifact_directory, "usage receipt.json")
      File.write(artifact_path, JSON.generate(canonicalize(receipt)))
      encoded_reference = "file://#{artifact_path.gsub(' ', '%20')}"

      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => encoded_reference,
          "usage_receipt_digest" => "sha256:#{object_digest(receipt)}",
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      saved = JSON.parse(File.read(state_path))
      assert_equal encoded_reference, saved.fetch("usage_receipts").values.first.fetch("reference")
    end
  end

  def test_batch_usage_receipt_rejects_ambiguous_or_hostile_file_references_without_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "hostile-reference-window", tokens: 200)
      receipt, receipt_ref, receipt_digest = real_descendants_usage_receipt(state_path)
      artifact_path = receipt_ref.delete_prefix("file://")
      spaced_directory = File.join(File.dirname(state_path), "unescaped receipt artifacts")
      Dir.mkdir(spaced_directory)
      spaced_path = File.join(spaced_directory, "usage receipt.json")
      File.write(spaced_path, JSON.generate(canonicalize(receipt)))
      invalid_references = {
        "unescaped-whitespace" => "file://#{spaced_path}",
        "localhost-authority" => "file://localhost#{artifact_path}",
        "remote-authority" => "file://evil.example#{artifact_path}",
        "encoded-nul" => "#{receipt_ref}%00",
        "encoded-newline" => "#{receipt_ref}%0A",
        "encoded-tab" => "#{receipt_ref}%09",
        "invalid-percent-escape" => "#{receipt_ref}%ZZ",
        "encoded-separator" => "file:///tmp%2F#{File.basename(artifact_path)}",
        "encoded-backslash" => "file:///tmp%5C#{File.basename(artifact_path)}",
        "encoded-traversal" => "file:///tmp/%2e%2e/#{File.basename(artifact_path)}",
        "literal-traversal" => "file:///tmp/../#{File.basename(artifact_path)}",
        "query" => "#{receipt_ref}?download=1",
        "fragment" => "#{receipt_ref}#receipt",
        "ambiguous-root" => "file:////#{artifact_path.delete_prefix('/')}"
      }

      state_before = File.read(state_path)
      invalid_references.each do |name, invalid_reference|
        blocked, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "usage_receipt" => receipt,
            "usage_receipt_ref" => invalid_reference,
            "usage_receipt_digest" => receipt_digest,
            "completed_reservation_ids" => []
          )
        )

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-receipt-reference-invalid", blocked.fetch("reason"), name
        assert_equal state_before, File.read(state_path), name
      end
    end
  end

  def test_batch_usage_receipt_accepts_schema_valid_optional_nested_shapes
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "valid-optional-shapes", tokens: 200)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt["credit_equivalents"] = available_credit_equivalents
      physical_rollout_id = receipt.dig("coordinator", "evidence", "physical_rollout_ids").first
      receipt.fetch("evidence").merge!(
        "status" => "UNKNOWN",
        "unknown" => [{
          "status" => "UNKNOWN",
          "code" => "route_metadata_missing",
          "thread_id" => receipt.dig("coordinator", "root_thread_id"),
          "physical_rollout_id" => physical_rollout_id,
          "line" => 2,
          "fields" => ["model"]
        }]
      )
      receipt.fetch("coordinator").fetch("evidence")["status"] = "UNKNOWN"
      receipt.fetch("lanes").each do |lane|
        lane.fetch("evidence")["status"] = "UNKNOWN"
        lane.fetch("workers").each { |worker| worker.fetch("evidence")["status"] = "UNKNOWN" }
      end

      reconciled, stderr, status = reconcile_receipt(state_path, receipt, "valid-optional-shapes")

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 1, JSON.parse(File.read(state_path)).fetch("usage_receipts").length
    end
  end

  def test_permitted_top_level_unknown_rejects_unproved_positive_nested_scope_identities
    variants = {
      "missing-coordinator-singleton-alias" => lambda do |receipt|
        assert_predicate receipt.dig("coordinator", "usage", "self_only", "total_tokens"), :positive?
        evidence = receipt.dig("coordinator", "evidence")
        evidence["first_session_ids"] = [evidence.fetch("first_session_ids").first]
        evidence["physical_rollout_ids"] = [evidence.fetch("physical_rollout_ids").first]
        evidence.delete("first_session_id")
      end,
      "empty-lane-identities" => lambda do |receipt|
        assert_predicate receipt.dig("lanes", 0, "usage", "descendant_inclusive", "total_tokens"), :positive?
        evidence = receipt.dig("lanes", 0, "evidence")
        evidence["physical_rollout_ids"] = []
        evidence["first_session_ids"] = []
        evidence.delete("first_session_id")
      end,
      "inconsistent-worker-identity-counts" => lambda do |receipt|
        worker = receipt.dig("lanes", 0, "workers", 0)
        assert_predicate worker.dig("usage", "descendant_inclusive", "total_tokens"), :positive?
        evidence = worker.fetch("evidence")
        evidence["first_session_ids"] = [evidence.fetch("first_session_ids").first, "second-session"]
        evidence.delete("first_session_id")
      end
    }

    variants.each do |name, invalidate_identities|
      with_state do |state_path|
        initialize_budget(state_path)
        reserve(state_path, id: "unknown-#{name}", tokens: 200)
        receipt, = real_descendants_usage_receipt(state_path)
        physical_rollout_id = receipt.dig("coordinator", "evidence", "physical_rollout_ids").first
        receipt.fetch("evidence").merge!(
          "status" => "UNKNOWN",
          "unknown" => [{
            "status" => "UNKNOWN",
            "code" => "route_metadata_missing",
            "thread_id" => receipt.dig("coordinator", "root_thread_id"),
            "physical_rollout_id" => physical_rollout_id,
            "line" => 2,
            "fields" => ["model"]
          }]
        )
        receipt.fetch("coordinator").fetch("evidence")["status"] = "UNKNOWN"
        receipt.fetch("lanes").each do |lane|
          lane.fetch("evidence")["status"] = "UNKNOWN"
          lane.fetch("workers").each { |worker| worker.fetch("evidence")["status"] = "UNKNOWN" }
        end
        invalidate_identities.call(receipt)
        state_before = File.binread(state_path)

        blocked, stderr, status = reconcile_receipt(state_path, receipt, "unknown-#{name}")

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_equal state_before, File.binread(state_path), name
        assert_empty JSON.parse(File.binread(state_path)).fetch("usage_receipts"), name
      end
    end
  end

  def test_permitted_top_level_unknown_allows_empty_nested_identities_for_zero_usage
    with_state do |state_path|
      initialize_budget(state_path)
      base_receipt, = real_descendants_usage_receipt(state_path)
      receipt = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
      )
      physical_rollout_id = receipt.dig("coordinator", "evidence", "physical_rollout_ids").first
      receipt.fetch("evidence").merge!(
        "status" => "UNKNOWN",
        "unknown" => [{
          "status" => "UNKNOWN",
          "code" => "route_metadata_missing",
          "thread_id" => receipt.dig("coordinator", "root_thread_id"),
          "physical_rollout_id" => physical_rollout_id,
          "line" => 2,
          "fields" => ["model"]
        }]
      )
      nested_scopes = [receipt.fetch("coordinator"), *receipt.fetch("lanes")]
      nested_scopes.concat(receipt.fetch("lanes").flat_map { |lane| lane.fetch("workers") })
      nested_scopes.each do |scope|
        evidence = scope.fetch("evidence")
        evidence["status"] = "UNKNOWN"
        evidence["physical_rollout_ids"] = []
        evidence["first_session_ids"] = []
        evidence.delete("first_session_id")
      end

      reconciled, stderr, status = reconcile_receipt(state_path, receipt, "zero-usage-unknown-identities")

      assert status.success?, stderr
      assert_equal "reconciled", reconciled.fetch("status")
      assert_equal 1, JSON.parse(File.binread(state_path)).fetch("usage_receipts").length
    end
  end

  def test_batch_usage_receipt_rejects_noncanonical_unknown_reason_metadata_before_any_state_mutation
    invalid_metadata = {
      "nested-sentinel" => { "unexpected_content" => { "nested" => ["secret-payload"] } },
      "extra-scalar" => { "unexpected_scalar" => "secret-payload" },
      "extra-object" => { "unexpected_object" => { "payload" => "secret-payload" } },
      "extra-array" => { "unexpected_array" => ["secret-payload"] },
      "wrong-code-metadata" => { "detail" => "ArgumentError" }
    }

    invalid_metadata.each do |name, extra|
      with_state do |state_path|
        initialize_budget(state_path)
        base_receipt, = real_descendants_usage_receipt(state_path)
        receipt = usage_window(
          base_receipt,
          from: "2026-08-12T11:00:00Z",
          to: "2026-08-12T12:00:00Z",
          coordinator_tokens: 0,
          lane_tokens: { "lane-a" => 0, "lane-b" => 0 }
        )
        receipt.fetch("evidence").merge!(
          "status" => "UNKNOWN",
          "unknown" => [{
            "status" => "UNKNOWN",
            "code" => "route_metadata_missing",
            "thread_id" => receipt.dig("coordinator", "root_thread_id"),
            "physical_rollout_id" => receipt.dig("coordinator", "evidence", "physical_rollout_ids").first,
            "line" => 2,
            "fields" => ["model"]
          }.merge(extra)]
        )
        state_before = File.binread(state_path)
        parsed_before = JSON.parse(state_before)

        blocked, stderr, status = reconcile_receipt(state_path, receipt, "invalid-unknown-#{name}")

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        assert_equal state_before, File.binread(state_path), name
        saved = JSON.parse(File.binread(state_path))
        assert_equal parsed_before.fetch("control_events"), saved.fetch("control_events"), name
        assert_nil parsed_before["usage_cursor"], name
        assert_nil saved["usage_cursor"], name
        assert_empty saved.fetch("usage_receipts"), name

        closeout, closeout_stderr, closeout_status = run_helper(state_path, command("closeout"))
        assert closeout_status.success?, "#{name}: #{closeout_stderr}"
        assert_equal "not-complete", closeout.fetch("status"), name
        assert_equal "NOT COMPLETE", closeout.fetch("completion"), name
        assert_equal "usage-cursor-missing", closeout.dig("telemetry", "reason"), name
      end
    end
  end

  def test_batch_usage_receipt_rejects_a_fifo_even_when_it_serves_matching_json
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "fifo-receipt", tokens: 100)
      receipt, = real_descendants_usage_receipt(state_path)
      fifo_path = File.join(File.dirname(state_path), "usage-receipt.fifo")
      assert system("mkfifo", fifo_path), "mkfifo failed"
      ready_reader, ready_writer = IO.pipe
      writer_pid = Process.spawn(
        RbConfig.ruby,
        "-e",
        "$stdout.write('1'); $stdout.flush; " \
        "loop do; File.open(ARGV.fetch(0), 'w') { |file| file.write(ARGV.fetch(1)) }; " \
        "sleep 0.05; rescue Errno::EPIPE; end",
        fifo_path,
        JSON.generate(canonicalize(receipt)),
        out: ready_writer,
        err: File::NULL
      )
      ready_writer.close
      assert_equal "1", ready_reader.read(1)
      ready_reader.close
      state_before = File.read(state_path)

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => "file://#{fifo_path}",
          "usage_receipt_digest" => "sha256:#{object_digest(receipt)}",
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-receipt-artifact-mismatch", blocked.fetch("reason")
      assert_equal state_before, File.read(state_path)
    ensure
      ready_reader&.close unless ready_reader&.closed?
      ready_writer&.close unless ready_writer&.closed?
      if writer_pid && Process.waitpid(writer_pid, Process::WNOHANG).nil?
        Process.kill("KILL", writer_pid)
        Process.wait(writer_pid)
      end
    end
  end

  def test_batch_usage_receipt_rejects_an_oversized_regular_artifact
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "oversized-receipt", tokens: 100)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt.fetch("privacy").fetch("excluded") << ("x" * (1024 * 1024))
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "oversized")
      artifact_path = receipt_ref.delete_prefix("file://")
      assert_operator File.size(artifact_path), :>, 1024 * 1024
      state_before = File.read(state_path)

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-receipt-artifact-mismatch", blocked.fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_caller_digest_and_unverified_https_reference_cannot_authorize_fabricated_usage
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "fabricated-https", tokens: 100)
      base_receipt, = real_descendants_usage_receipt(state_path)
      fabricated = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 500, "lane-b" => 0 }
      )
      state_before = File.read(state_path)

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => fabricated,
          "usage_receipt_ref" => "https://example.invalid/fabricated.json",
          "usage_receipt_digest" => "sha256:#{object_digest(fabricated)}",
          "completed_reservation_ids" => ["fabricated-https"]
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-receipt-reference-invalid", blocked.fetch("reason")
      assert_equal state_before, File.read(state_path)
    end
  end

  def test_batch_usage_receipt_rejects_unlisted_fields_without_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "extra-receipt-field", tokens: 200)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt["self_attested_total"] = 100
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "extra-field")

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      assert_equal 200, blocked.dig("totals", "aggregate", "reserved_tokens")
      assert_empty JSON.parse(File.read(state_path)).fetch("usage_receipts")
    end
  end

  def test_batch_usage_receipt_rejects_unlisted_lane_fields_without_mutation
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "extra-lane-field", tokens: 200)
      receipt, = real_descendants_usage_receipt(state_path)
      receipt.fetch("lanes").first["unexpected_content"] = "secret-payload"
      receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "extra-lane-field")
      state_before = File.read(state_path)

      blocked, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "evaluated_at" => "2026-08-12T12:01:00Z",
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        )
      )

      assert status.success?, stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason")
      state_after = File.read(state_path)
      assert_equal state_before, state_after
      assert_equal JSON.parse(state_before).fetch("control_events").length,
                   JSON.parse(state_after).fetch("control_events").length
      refute_includes state_after, "secret-payload"
    end
  end

  def test_batch_usage_receipt_rejects_extensions_in_schema_closed_nested_objects
    closed_objects = {
      "window" => ->(receipt) { receipt.fetch("window") },
      "accounting" => ->(receipt) { receipt.fetch("accounting") },
      "evidence" => ->(receipt) { receipt.fetch("evidence") },
      "privacy" => ->(receipt) { receipt.fetch("privacy") },
      "batch" => ->(receipt) { receipt.fetch("batch") },
      "batch-usage" => ->(receipt) { receipt.dig("batch", "usage") },
      "batch-usage-counter" => ->(receipt) { receipt.dig("batch", "usage", "descendant_inclusive") },
      "batch-turns" => ->(receipt) { receipt.dig("batch", "turns") },
      "batch-reconciliation" => ->(receipt) { receipt.dig("batch", "reconciliation") },
      "coordinator" => ->(receipt) { receipt.fetch("coordinator") },
      "coordinator-requested-route" => ->(receipt) { receipt.dig("coordinator", "requested_route") },
      "coordinator-observed-route" => ->(receipt) { receipt.dig("coordinator", "observed_routes", 0) },
      "coordinator-observed-usage" => ->(receipt) { receipt.dig("coordinator", "observed_routes", 0, "usage") },
      "coordinator-usage" => ->(receipt) { receipt.dig("coordinator", "usage") },
      "coordinator-usage-counter" => ->(receipt) { receipt.dig("coordinator", "usage", "self_only") },
      "coordinator-turns" => ->(receipt) { receipt.dig("coordinator", "turns") },
      "coordinator-evidence" => ->(receipt) { receipt.dig("coordinator", "evidence") },
      "lane-requested-route" => ->(receipt) { receipt.dig("lanes", 0, "requested_route") },
      "lane-observed-route" => ->(receipt) { receipt.dig("lanes", 0, "observed_routes", 0) },
      "lane-observed-usage" => ->(receipt) { receipt.dig("lanes", 0, "observed_routes", 0, "usage") },
      "lane-usage" => ->(receipt) { receipt.dig("lanes", 0, "usage") },
      "lane-usage-counter" => ->(receipt) { receipt.dig("lanes", 0, "usage", "self_only") },
      "lane-turns" => ->(receipt) { receipt.dig("lanes", 0, "turns") },
      "lane-evidence" => ->(receipt) { receipt.dig("lanes", 0, "evidence") },
      "lane-reconciliation" => ->(receipt) { receipt.dig("lanes", 0, "reconciliation") },
      "worker" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0) },
      "worker-requested-route" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "requested_route") },
      "worker-observed-route" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "observed_routes", 0) },
      "worker-observed-usage" => lambda do |receipt|
        receipt.dig("lanes", 0, "workers", 0, "observed_routes", 0, "usage")
      end,
      "worker-usage" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "usage") },
      "worker-usage-counter" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "usage", "self_only") },
      "worker-turns" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "turns") },
      "worker-evidence" => ->(receipt) { receipt.dig("lanes", 0, "workers", 0, "evidence") },
      "credit-equivalents" => lambda do |receipt|
        receipt["credit_equivalents"] = available_credit_equivalents
      end,
      "available-credit-model-value" => lambda do |receipt|
        receipt["credit_equivalents"] = available_credit_equivalents
        receipt.dig("credit_equivalents", "model_values", 0)
      end,
      "unknown-credit-model-value" => lambda do |receipt|
        receipt["credit_equivalents"] = unknown_credit_equivalents
        receipt.dig("credit_equivalents", "model_values", 0)
      end
    }

    closed_objects.each do |name, target|
      with_state do |state_path|
        initialize_budget(state_path)
        reserve(state_path, id: "extra-#{name}", tokens: 200)
        receipt, = real_descendants_usage_receipt(state_path)
        target.call(receipt)["unexpected_content"] = "secret-payload"
        receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "extra-#{name}")
        state_before = File.read(state_path)

        blocked, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "evaluated_at" => "2026-08-12T12:01:00Z",
            "usage_receipt" => receipt,
            "usage_receipt_ref" => receipt_ref,
            "usage_receipt_digest" => receipt_digest,
            "completed_reservation_ids" => []
          )
        )

        assert status.success?, "#{name}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), name
        assert_equal "usage-telemetry-malformed-or-unknown", blocked.fetch("reason"), name
        state_after = File.read(state_path)
        assert_equal state_before, state_after, name
        assert_equal JSON.parse(state_before).fetch("control_events").length,
                     JSON.parse(state_after).fetch("control_events").length, name
        refute_includes state_after, "secret-payload", name
      end
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
    corruptions = {
      "deleted-reservation" => proc do |state|
        state.fetch("reservations").delete("ledger-reservation")
      end,
      "usage-ledger-total" => proc do |state|
        state.fetch("usage_receipts").values.first.fetch("scope_tokens")["lane-a"] += 1
      end,
      "usage-ledger-turn-total" => proc do |state|
        state.fetch("usage_receipts").values.first.fetch("scope_turns")["lane-a"] += 1
      end,
      "reservation-reconciliation" => proc do |state|
        state.dig("reservations", "ledger-reservation", "reconciliation_receipt")["actual_tokens"] += 1
      end
    }
    corruptions.each do |name, corrupt|
      with_state do |state_path|
        initialize_budget(state_path)
        reserve(state_path, id: "ledger-reservation", tokens: 200)
        base_receipt, = real_descendants_usage_receipt(state_path)
        receipt = usage_window(
          base_receipt,
          from: "2026-08-12T11:00:00Z",
          to: "2026-08-12T12:00:00Z",
          coordinator_tokens: 0,
          lane_tokens: { "lane-a" => 120, "lane-b" => 0 }
        )
        receipt, receipt_ref, receipt_digest = receipt_artifact(state_path, receipt, "ledger")
        reconciled, stderr, status = run_helper(
          state_path,
          command(
            "reconcile",
            "usage_receipt" => receipt,
            "usage_receipt_ref" => receipt_ref,
            "usage_receipt_digest" => receipt_digest,
            "completed_reservation_ids" => ["ledger-reservation"]
          )
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

  def test_restart_rejects_a_widened_reservation_overshoot_envelope
    with_state do |state_path|
      initialize_budget(state_path)
      reserve(state_path, id: "widened-envelope", tokens: 100)
      state = JSON.parse(File.read(state_path))
      state.dig("reservations", "widened-envelope", "receipt", "overshoot_envelope")["max_in_flight_turns"] = 2
      receipt = state.fetch("receipts").find do |candidate|
        candidate["type"] == "batch-token-budget-reservation-receipt" &&
          candidate["reservation_id"] == "widened-envelope"
      end
      receipt.fetch("overshoot_envelope")["max_in_flight_turns"] = 2
      rehash_control_tail(state)
      File.write(state_path, JSON.generate(state))

      output, stderr, status = run_helper(state_path, command("closeout"))

      refute status.success?
      assert_nil output
      assert_equal "corrupt-persisted-state", JSON.parse(stderr).fetch("reason")
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
      run_helper(
        state_path,
        command("initialize", "evaluated_at" => "2026-08-12T11:00:00Z", "budget" => cross_budget)
      )
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
      base_receipt, = real_descendants_usage_receipt(state_path)
      usage = usage_window(
        base_receipt,
        from: "2026-08-12T11:00:00Z",
        to: "2026-08-12T12:00:00Z",
        coordinator_tokens: 0,
        lane_tokens: { "lane-a" => 100, "lane-b" => 0 }
      )
      usage, usage_ref, usage_digest = receipt_artifact(state_path, usage, "restart-charge-back")
      charge_back = {
        "type" => "batch-token-charge-back",
        "version" => 1,
        "id" => "charge-cause",
        "source" => source,
        "target" => target
      }
      reconciled, stderr, status = run_helper(
        state_path,
        command(
          "reconcile",
          "usage_receipt" => usage,
          "usage_receipt_ref" => usage_ref,
          "usage_receipt_digest" => usage_digest,
          "completed_reservation_ids" => ["charge-reservation"],
          "charge_backs" => [{ "reservation_id" => "charge-reservation", "charge_back" => charge_back }]
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
        command(
          "reserve",
          "evaluated_at" => "2026-08-12T13:59:59Z",
          "reservation" => reservation(id: "backdated")
        )
      )
      refute backdated_status.success?
      assert_nil backdated
      assert_equal "command-time-rollback", JSON.parse(backdated_stderr).fetch("reason")

      fractional_backdated, fractional_stderr, fractional_status = run_helper(
        state_path,
        command("closeout", "evaluated_at" => "2026-08-12T13:59:59.999999Z")
      )
      refute fractional_status.success?
      assert_nil fractional_backdated
      assert_equal "command-time-rollback", JSON.parse(fractional_stderr).fetch("reason")
    end
  end

  def test_command_timestamp_requires_a_complete_datetime_with_an_explicit_offset
    Dir.mktmpdir("batch-token-budget-timestamps") do |directory|
      ["12:30", "2026-08-12", "2026-08-12T12:30:00"].each_with_index do |timestamp, index|
        state_path = File.join(directory, "invalid-#{index}.json")
        output, stderr, status = run_helper(
          state_path,
          command("initialize", "evaluated_at" => timestamp, "budget" => budget(state_path: state_path))
        )

        refute status.success?, timestamp
        assert_nil output, timestamp
        assert_equal "invalid-evaluated-at", JSON.parse(stderr).fetch("reason"), timestamp
      end

      valid_state_path = File.join(directory, "valid.json")
      initialized, stderr, status = run_helper(
        valid_state_path,
        command(
          "initialize",
          "evaluated_at" => "2026-08-12T17:30:00.123456+05:30",
          "budget" => budget(state_path: valid_state_path)
        )
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      assert_equal "2026-08-12T17:30:00.123456+05:30", JSON.parse(File.read(valid_state_path)).fetch("last_evaluated_at")
    end
  end

  def test_invalid_command_timestamps_are_rejected_before_lock_artifact_creation
    Dir.mktmpdir("batch-token-budget-invalid-timestamps") do |directory|
      invalid_timestamps = ["2016-12-31T23:59:60Z", "2026-08-12T12:30:60Z", "12:30"]
      invalid_timestamps.each_with_index do |timestamp, index|
        state_path = File.join(directory, "invalid-#{index}", "state.json")
        candidate = budget(state_path: state_path)
        anchor = install_trusted_plan(File.join(directory, "anchor-#{index}"), candidate)
        output, stderr, status = run_helper_raw(
          state_path,
          JSON.generate(command("initialize", "evaluated_at" => timestamp, "budget" => candidate)),
          anchor: anchor
        )

        refute status.success?, timestamp
        assert_nil output, timestamp
        assert_equal "invalid-evaluated-at", JSON.parse(stderr).fetch("reason"), timestamp
        refute File.exist?(state_path), timestamp
        refute File.exist?("#{state_path}.lock"), timestamp
        refute Dir.exist?(File.dirname(state_path)), timestamp
      end

      valid_state_path = File.join(directory, "valid", "state.json")
      valid_budget = budget(state_path: valid_state_path)
      valid_anchor = install_trusted_plan(File.join(directory, "valid-anchor"), valid_budget)
      initialized, stderr, status = run_helper_raw(
        valid_state_path,
        JSON.generate(command(
                        "initialize",
                        "evaluated_at" => "2026-08-12T12:30:59.999999-05:30",
                        "budget" => valid_budget
                      )),
        anchor: valid_anchor
      )

      assert status.success?, stderr
      assert_equal "initialized", initialized.fetch("status")
      assert File.file?(valid_state_path)
      assert File.file?("#{valid_state_path}.lock")
    end
  end
end
