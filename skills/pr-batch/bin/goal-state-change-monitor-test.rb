#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("../../..", __dir__)
HELPER = File.join(ROOT, "skills/pr-batch/bin/goal-state-change-monitor")

class GoalStateChangeMonitorTest < Minitest::Test
  def observation(overrides = {})
    {
      "contract" => "goal-state-change-observation",
      "version" => 1,
      "monitor_id" => "thread-393:checks",
      "capability" => "deterministic-watcher",
      "task_status" => "resumable",
      "dependency_status" => "nonterminal",
      "blocker_state" => { "head" => "a" * 40, "pending" => ["validate"] },
      "usage_delta" => { "model_calls" => 0, "tokens" => 0 },
      "resume_instruction" => "Resume task thread-393.",
      "probe_sequence" => 0,
      "observed_at" => "2026-08-09T00:00:00Z"
    }.merge(overrides)
  end

  def run_helper(state_path, input)
    stdout, stderr, status = Open3.capture3(
      HELPER,
      "--state",
      state_path,
      stdin_data: JSON.generate(input)
    )
    [stdout.empty? ? nil : JSON.parse(stdout), stderr, status]
  end

  def canonicalize_for_digest(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonicalize_for_digest(value.fetch(key))] }
    when Array
      value.map { |item| canonicalize_for_digest(item) }
           .uniq { |item| JSON.generate(item) }
           .sort_by { |item| JSON.generate(item) }
    else
      value
    end
  end

  def observation_digest(input, include_observed_at:)
    ignored_keys = ["acknowledged_wake_id"]
    ignored_keys << "observed_at" unless include_observed_at
    digest_input = input.reject { |key, _value| ignored_keys.include?(key) }
    Digest::SHA256.hexdigest(JSON.generate(canonicalize_for_digest(digest_input)))
  end

  def acknowledge_wake(state_path, input, decision)
    acknowledged, stderr, status = run_helper(
      state_path,
      input.merge("acknowledged_wake_id" => decision.fetch("wake_id"))
    )
    assert status.success?, stderr
    assert_equal "suppress-acknowledgement-retry", acknowledged.fetch("action")
    refute acknowledged.fetch("wake_parent")
    acknowledged
  end

  def derived_wake_id(input, action)
    fingerprint = Digest::SHA256.hexdigest(
      JSON.generate(canonicalize_for_digest(input.fetch("blocker_state")))
    )
    Digest::SHA256.hexdigest(
      JSON.generate(
        canonicalize_for_digest(
          "monitor_id" => input.fetch("monitor_id"),
          "probe_sequence" => input.fetch("probe_sequence"),
          "fingerprint" => fingerprint,
          "action" => action
        )
      )
    )
  end

  def test_deterministic_watcher_suppresses_unchanged_parent_wakes
    observations = Array.new(3) do |index|
      observation(
        "probe_sequence" => index,
        "observed_at" => format("2026-08-09T00:%02d:00Z", index)
      )
    end

    # Synthetic worst case: every scheduled probe reloads the full parent context.
    baseline_unchanged_wakes = observations.length
    puts "BASELINE_UNCHANGED_WAKE_COUNT=#{baseline_unchanged_wakes}"
    assert_operator baseline_unchanged_wakes, :>, 0
    assert File.file?(HELPER), "state-change monitor helper is missing"

    candidate_unchanged_wakes = 0
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      observations.each do |observation|
        decision, stderr, status = run_helper(state_path, observation)
        assert status.success?, stderr
        candidate_unchanged_wakes += 1 if decision.fetch("wake_parent")
      end
    end

    puts "CANDIDATE_UNCHANGED_WAKE_COUNT=#{candidate_unchanged_wakes}"
    assert_equal 0, candidate_unchanged_wakes
  end

  def test_matched_sanitized_replay_reduces_parent_context_tokens_without_missing_a_transition
    parent_context_tokens = Array.new(5, 160_000)
    replay = parent_context_tokens.each_index.map do |index|
      blocker_state = if index == parent_context_tokens.length - 1
                        { "head" => "b" * 40, "pending" => [] }
                      else
                        { "head" => "a" * 40, "pending" => ["validate"] }
                      end
      observation(
        "blocker_state" => blocker_state,
        "probe_sequence" => index,
        "observed_at" => format("2026-08-09T%02d:00:00Z", index)
      )
    end

    candidate_decisions = Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      replay.map do |current_observation|
        decision, stderr, status = run_helper(state_path, current_observation)
        assert status.success?, stderr
        decision
      end
    end
    # Synthetic worst case: every scheduled probe reloads the modeled parent token count.
    scheduled_probe_tokens = parent_context_tokens.drop(1)
    baseline_tokens = scheduled_probe_tokens.sum
    candidate_tokens = candidate_decisions.drop(1).each_with_index.sum do |decision, index|
      decision.fetch("wake_parent") ? scheduled_probe_tokens.fetch(index) : 0
    end
    expected_transitions = 1
    transition_wakes = candidate_decisions.count { |decision| decision["action"] == "wake-state-change" }
    receipt = {
      "contract" => "goal-state-change-token-receipt",
      "version" => 1,
      "source" => "deterministic-sanitized-replay",
      "matched_scheduled_probes" => scheduled_probe_tokens.length,
      "baseline_parent_context_tokens" => baseline_tokens,
      "candidate_parent_context_tokens" => candidate_tokens,
      "reduction_percent" => ((baseline_tokens - candidate_tokens) * 100.0 / baseline_tokens).round(1),
      "expected_transitions" => expected_transitions,
      "candidate_transition_wakes" => transition_wakes,
      "missed_transitions" => expected_transitions - transition_wakes
    }

    puts "MATCHED_RUN_TOKEN_RECEIPT=#{JSON.generate(receipt)}"
    assert_operator receipt.fetch("reduction_percent"), :>=, 75.0
    assert_equal 0, receipt.fetch("missed_transitions")
  end

  def test_changed_fingerprint_wakes_parent_with_compact_delta
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      assert_equal false, baseline.fetch("wake_parent")

      changed_state = { "head" => "b" * 40, "pending" => [] }
      decision, stderr, status = run_helper(
        state_path,
        observation(
          "blocker_state" => changed_state,
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )

      assert status.success?, stderr
      assert_equal "wake-state-change", decision.fetch("action")
      assert decision.fetch("wake_parent")
      assert_equal(
        {
          "changes" => [
            { "path" => "/head", "previous" => "a" * 40, "current" => "b" * 40 },
            { "path" => "/pending", "previous" => ["validate"], "current" => [] }
          ]
        },
        decision.fetch("state_delta")
      )
    end
  end

  def test_changed_fingerprint_emits_only_compact_leaf_changes
    checks = (1..100).to_h { |index| ["check-#{index}", "pending"] }
    initial_state = { "head" => "a" * 40, "checks" => checks }
    changed_state = JSON.parse(JSON.generate(initial_state))
    changed_state.fetch("checks")["check-1"] = "passed"

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(
        state_path,
        observation("blocker_state" => initial_state)
      )
      assert baseline_status.success?, baseline_stderr

      decision, stderr, status = run_helper(
        state_path,
        observation(
          "blocker_state" => changed_state,
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert status.success?, stderr
      assert_equal(
        { "changes" => [{ "path" => "/checks/check-1", "previous" => "pending", "current" => "passed" }] },
        decision.fetch("state_delta")
      )
      assert_operator JSON.generate(decision.fetch("state_delta")).bytesize, :<, 160
    end
  end

  def test_model_polling_fallback_uses_a_bounded_fast_window_then_exponential_backoff
    fallback = observation(
      "capability" => "model-polling-only",
      "polling_policy" => {
        "fast_interval_seconds" => 900,
        "fast_attempts" => 2,
        "max_interval_seconds" => 7200
      }
    )

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      baseline, baseline_stderr, baseline_status = run_helper(state_path, fallback)
      assert baseline_status.success?, baseline_stderr
      assert_equal "baseline-recorded", baseline.fetch("action")
      assert_equal false, baseline.fetch("wake_parent")

      intervals = 5.times.map do |index|
        current_observation = fallback.merge(
          "probe_sequence" => index + 1,
          "observed_at" => format("2026-08-09T%02d:00:00Z", index + 1)
        )
        decision, stderr, status = run_helper(state_path, current_observation)
        assert status.success?, stderr
        assert_equal "fallback-model-poll", decision.fetch("action")
        assert decision.fetch("wake_parent")
        interval = decision.fetch("next_interval_seconds")
        acknowledge_wake(state_path, current_observation, decision)
        interval
      end

      assert_equal [900, 1800, 3600, 7200, 7200], intervals
    end
  end

  def test_model_polling_fallback_defaults_to_four_fast_polls_then_the_four_hour_cap
    fallback = observation("capability" => "model-polling-only")

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      baseline, baseline_stderr, baseline_status = run_helper(state_path, fallback)
      assert baseline_status.success?, baseline_stderr
      intervals = [baseline.fetch("next_interval_seconds")]

      8.times do |index|
        current_observation = fallback.merge(
          "probe_sequence" => index + 1,
          "observed_at" => format("2026-08-09T%02d:00:00Z", index + 1)
        )
        decision, stderr, status = run_helper(state_path, current_observation)
        assert status.success?, stderr
        assert_equal "fallback-model-poll", decision.fetch("action")
        assert decision.fetch("wake_parent")
        intervals << decision.fetch("next_interval_seconds")
        acknowledge_wake(state_path, current_observation, decision)
      end

      assert_equal [900, 900, 900, 900, 1800, 3600, 7200, 14_400, 14_400], intervals
    end
  end

  def test_model_polling_fallback_rejects_policy_values_beyond_contract_bounds
    {
      "fast_interval_seconds" => 901,
      "fast_attempts" => 5,
      "max_interval_seconds" => 14_401
    }.each do |field, value|
      Dir.mktmpdir do |directory|
        decision, stderr, status = run_helper(
          File.join(directory, "monitor.json"),
          observation(
            "capability" => "model-polling-only",
            "polling_policy" => {
              "fast_interval_seconds" => 900,
              "fast_attempts" => 4,
              "max_interval_seconds" => 14_400,
              field => value
            }
          )
        )

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"invalid-polling-policy"'
      end
    end
  end

  def test_terminal_dependency_stops_monitor_and_wakes_parent_once
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr

      decision, stderr, status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => { "head" => "a" * 40, "pending" => [], "result" => "passed" },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )

      assert status.success?, stderr
      assert_equal "stop-dependency-terminal", decision.fetch("action")
      assert_equal "stopped", decision.fetch("monitor_status")
      assert decision.fetch("wake_parent")
      refute decision.key?("next_interval_seconds")
      terminal_observation = observation(
        "dependency_status" => "terminal",
        "blocker_state" => { "head" => "a" * 40, "pending" => [], "result" => "passed" },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      replay, replay_stderr, replay_status = run_helper(state_path, terminal_observation)
      assert replay_status.success?, replay_stderr
      assert_equal "redeliver-pending-wake", replay.fetch("action")
      assert_equal "stop-dependency-terminal", replay.fetch("replayed_action")
      assert replay.fetch("wake_parent")
      acknowledge_wake(state_path, terminal_observation, decision)

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "head" => "b" * 40, "pending" => ["new"] },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )
      assert later_status.success?, later_stderr
      assert_equal "already-stopped", later.fetch("action")
      assert_equal "stopped", later.fetch("monitor_status")
      assert_equal false, later.fetch("wake_parent")
    end
  end

  def test_task_handoffs_supersede_an_acknowledged_dependency_stop
    {
      "terminal" => %w[stop-task-terminal stopped],
      "not-resumable" => %w[stop-task-not-resumable stopped],
      "blocked-user-input" => %w[pause-user-input paused]
    }.each do |task_status, (expected_action, expected_monitor_status)|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr
        dependency_observation = observation(
          "dependency_status" => "terminal",
          "blocker_state" => { "head" => "a" * 40, "pending" => [], "result" => "passed" },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
        dependency_stop, stop_stderr, stop_status = run_helper(state_path, dependency_observation)
        assert stop_status.success?, stop_stderr
        assert_equal "stop-dependency-terminal", dependency_stop.fetch("action")
        acknowledge_wake(state_path, dependency_observation, dependency_stop)

        blocker_state = if task_status == "blocked-user-input"
                          { "question" => "Which terminal outcome should be recorded?" }
                        else
                          { "head" => "b" * 40, "pending" => [] }
                        end
        resume_instruction = "Resume task thread-393 after #{task_status}."
        current, current_stderr, current_status = run_helper(
          state_path,
          observation(
            "task_status" => task_status,
            "dependency_status" => "terminal",
            "blocker_state" => blocker_state,
            "resume_instruction" => resume_instruction,
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z"
          )
        )

        assert current_status.success?, current_stderr
        assert_equal expected_action, current.fetch("action")
        assert_equal expected_monitor_status, current.fetch("monitor_status")
        refute current.fetch("wake_parent")
        assert_equal "task-#{task_status}", current.dig("handoff", "reason") unless task_status == "blocked-user-input"
        assert_equal "blocked-user-input", current.dig("handoff", "reason") if task_status == "blocked-user-input"
        assert_equal blocker_state, current.dig("handoff", "blocker_state")
        assert_equal resume_instruction, current.dig("handoff", "resume_instruction")
        assert_equal current.fetch("handoff"), JSON.parse(File.read(state_path)).dig("last_decision", "handoff")
      end
    end
  end

  def test_task_handoffs_supersede_an_unacknowledged_dependency_stop
    {
      "terminal" => %w[stop-task-terminal stopped],
      "not-resumable" => %w[stop-task-not-resumable stopped],
      "blocked-user-input" => %w[pause-user-input paused]
    }.each do |task_status, (expected_action, expected_monitor_status)|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr
        dependency_observation = observation(
          "dependency_status" => "terminal",
          "blocker_state" => { "head" => "a" * 40, "pending" => [], "result" => "passed" },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
        dependency_stop, stop_stderr, stop_status = run_helper(state_path, dependency_observation)
        assert stop_status.success?, stop_stderr
        assert_equal "stop-dependency-terminal", dependency_stop.fetch("action")

        blocker_state = if task_status == "blocked-user-input"
                          { "question" => "Which terminal outcome should be recorded?" }
                        else
                          { "head" => "b" * 40, "pending" => [] }
                        end
        resume_instruction = "Resume task thread-393 after #{task_status}."
        current, current_stderr, current_status = run_helper(
          state_path,
          observation(
            "task_status" => task_status,
            "dependency_status" => "terminal",
            "blocker_state" => blocker_state,
            "resume_instruction" => resume_instruction,
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z"
          )
        )

        assert current_status.success?, current_stderr
        assert_equal expected_action, current.fetch("action")
        assert_equal expected_monitor_status, current.fetch("monitor_status")
        refute current.fetch("wake_parent")
        assert_equal blocker_state, current.dig("handoff", "blocker_state")
        assert_equal resume_instruction, current.dig("handoff", "resume_instruction")
        persisted = JSON.parse(File.read(state_path))
        refute persisted.key?("pending_wake")
        refute persisted.key?("acknowledged_wake_ids")
        assert_equal current.fetch("handoff"), persisted.dig("last_decision", "handoff")

        delayed, delayed_stderr, delayed_status = run_helper(
          state_path,
          dependency_observation.merge("acknowledged_wake_id" => dependency_stop.fetch("wake_id"))
        )
        assert delayed_status.success?, delayed_stderr
        assert_equal "suppress-acknowledgement-retry", delayed.fetch("action")
        refute delayed.fetch("wake_parent")
      end
    end
  end

  def test_task_handoffs_supersede_unsupported_dependency_terminal_handoff_and_stay_sticky
    {
      "terminal" => %w[stop-task-terminal stopped already-stopped],
      "not-resumable" => %w[stop-task-not-resumable stopped already-stopped],
      "blocked-user-input" => %w[pause-user-input paused manual-resume-required]
    }.each do |task_status, (expected_action, expected_monitor_status, expected_restart_action)|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        unsupported_stop, unsupported_stderr, unsupported_status = run_helper(
          state_path,
          observation("capability" => "unsupported", "dependency_status" => "terminal")
        )
        assert unsupported_status.success?, unsupported_stderr
        assert_equal "dependency-terminal-while-unsupported", unsupported_stop.dig("handoff", "reason")

        blocker_state = if task_status == "blocked-user-input"
                          { "question" => "Which terminal outcome should be recorded?" }
                        else
                          { "head" => "b" * 40, "pending" => [] }
                        end
        resume_instruction = "Resume task thread-393 after #{task_status}."
        current, current_stderr, current_status = run_helper(
          state_path,
          observation(
            "task_status" => task_status,
            "dependency_status" => "terminal",
            "blocker_state" => blocker_state,
            "resume_instruction" => resume_instruction,
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )

        assert current_status.success?, current_stderr
        assert_equal expected_action, current.fetch("action")
        assert_equal expected_monitor_status, current.fetch("monitor_status")
        refute current.fetch("wake_parent")
        expected_reason = task_status == "blocked-user-input" ? task_status : "task-#{task_status}"
        assert_equal expected_reason, current.dig("handoff", "reason")
        assert_equal blocker_state, current.dig("handoff", "blocker_state")
        assert_equal resume_instruction, current.dig("handoff", "resume_instruction")
        assert_equal current.fetch("handoff"), JSON.parse(File.read(state_path)).dig("last_decision", "handoff")

        restarted, restarted_stderr, restarted_status = run_helper(
          state_path,
          observation("probe_sequence" => 2, "observed_at" => "2026-08-09T00:30:00Z")
        )
        assert restarted_status.success?, restarted_stderr
        assert_equal expected_restart_action, restarted.fetch("action")
        assert_equal current.fetch("handoff"), restarted.fetch("handoff")
        assert_equal restarted.fetch("handoff"), JSON.parse(File.read(state_path)).dig("last_decision", "handoff")
      end
    end
  end

  def test_nonresumable_task_states_stop_or_pause_without_a_parent_wake
    {
      "terminal" => %w[stop-task-terminal stopped],
      "not-resumable" => %w[stop-task-not-resumable stopped],
      "blocked-user-input" => %w[pause-user-input paused]
    }.each do |task_status, (action, monitor_status)|
      Dir.mktmpdir do |directory|
        overrides = { "task_status" => task_status }
        if task_status == "blocked-user-input"
          overrides["blocker_state"] = {
            "question" => "Should this task remain paused?",
            "resume_instruction" => "Resume task thread-393 after answering the question."
          }
          overrides["resume_instruction"] = overrides.dig("blocker_state", "resume_instruction")
        end
        decision, stderr, status = run_helper(
          File.join(directory, "monitor.json"),
          observation(overrides)
        )

        assert status.success?, stderr
        assert_equal action, decision.fetch("action")
        assert_equal monitor_status, decision.fetch("monitor_status")
        refute decision.fetch("wake_parent")
        refute decision.key?("next_interval_seconds")
      end
    end
  end

  def test_terminal_task_states_preserve_exact_restart_safe_handoffs
    {
      "terminal" => "stop-task-terminal",
      "not-resumable" => "stop-task-not-resumable"
    }.each do |task_status, expected_action|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        blocker_state = { "head" => "a" * 40, "pending" => ["maintainer-action"] }
        resume_instruction = "Resume task thread-393 after #{task_status}."
        decision, stderr, status = run_helper(
          state_path,
          observation(
            "task_status" => task_status,
            "blocker_state" => blocker_state,
            "resume_instruction" => resume_instruction
          )
        )

        assert status.success?, stderr
        assert_equal expected_action, decision.fetch("action")
        assert_equal false, decision.fetch("wake_parent")
        assert_equal "goal-state-change-monitor-handoff", decision.dig("handoff", "contract")
        assert_equal 1, decision.dig("handoff", "version")
        assert_equal "thread-393:checks", decision.dig("handoff", "monitor_id")
        assert_equal "task-#{task_status}", decision.dig("handoff", "reason")
        assert_equal decision.fetch("fingerprint"), decision.dig("handoff", "fingerprint")
        assert_equal blocker_state, decision.dig("handoff", "blocker_state")
        assert_equal resume_instruction, decision.dig("handoff", "resume_instruction")
        assert_equal "manual-resume-required", decision.dig("handoff", "resume")

        persisted = JSON.parse(File.read(state_path))
        assert_equal decision.fetch("handoff"), persisted.dig("last_decision", "handoff")

        later, later_stderr, later_status = run_helper(
          state_path,
          observation(
            "blocker_state" => { "head" => "b" * 40, "pending" => [] },
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert later_status.success?, later_stderr
        assert_equal "already-stopped", later.fetch("action")
        assert_equal decision.fetch("handoff"), later.fetch("handoff")
        refute later.fetch("wake_parent")
      end
    end
  end

  def test_task_stopped_monitor_does_not_replace_its_terminal_handoff
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      terminal, terminal_stderr, terminal_status = run_helper(
        state_path,
        observation(
          "task_status" => "terminal",
          "resume_instruction" => "Resume after the terminal task is reopened."
        )
      )
      assert terminal_status.success?, terminal_stderr

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          "task_status" => "blocked-user-input",
          "blocker_state" => { "question" => "Should this task be reopened?" },
          "resume_instruction" => "Answer to reopen the task.",
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )

      assert later_status.success?, later_stderr
      assert_equal "already-stopped", later.fetch("action")
      assert_equal "stopped", later.fetch("monitor_status")
      assert_equal terminal.fetch("handoff"), later.fetch("handoff")
      assert_equal terminal.fetch("handoff"), JSON.parse(File.read(state_path)).dig("last_decision", "handoff")
    end
  end

  def test_stopped_monitor_ignores_later_configuration_framing_drift
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _stopped, stopped_stderr, stopped_status = run_helper(
        state_path,
        observation("task_status" => "terminal")
      )
      assert stopped_status.success?, stopped_stderr

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          "limits" => { "max_unchanged_runs" => 9, "max_model_calls" => 8, "max_tokens" => 7_000 },
          "polling_policy" => {
            "fast_interval_seconds" => 60,
            "fast_attempts" => 2,
            "max_interval_seconds" => 600
          },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )

      assert later_status.success?, later_stderr
      assert_equal "already-stopped", later.fetch("action")
      assert_equal "stopped", later.fetch("monitor_status")
      refute later.fetch("wake_parent")
    end
  end

  def test_task_handoff_after_dependency_stop_preserves_monitor_configuration
    original_limits = { "max_unchanged_runs" => 32, "max_model_calls" => 16, "max_tokens" => 1_000_000 }
    original_polling_policy = {
      "fast_interval_seconds" => 900,
      "fast_attempts" => 4,
      "max_interval_seconds" => 14_400
    }

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      terminal_observation = observation(
        "dependency_status" => "terminal",
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      dependency_stop, stop_stderr, stop_status = run_helper(state_path, terminal_observation)
      assert stop_status.success?, stop_stderr
      acknowledge_wake(state_path, terminal_observation, dependency_stop)

      current, current_stderr, current_status = run_helper(
        state_path,
        observation(
          "task_status" => "blocked-user-input",
          "blocker_state" => { "question" => "Should this task be reopened?" },
          "resume_instruction" => "Resume after answering the question.",
          "limits" => { "max_unchanged_runs" => 2, "max_model_calls" => 2, "max_tokens" => 2 },
          "polling_policy" => {
            "fast_interval_seconds" => 60,
            "fast_attempts" => 1,
            "max_interval_seconds" => 120
          },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )
      assert current_status.success?, current_stderr
      assert_equal "pause-user-input", current.fetch("action")

      persisted = JSON.parse(File.read(state_path))
      assert_equal original_limits, persisted.fetch("limits")
      assert_equal original_polling_policy, persisted.fetch("polling_policy")
    end
  end

  def test_blocked_user_input_preserves_the_exact_restart_safe_handoff
    blocker_state = {
      "question" => "Should this target wait for the configured reviewer?",
      "resume_instruction" => "Resume task thread-393 after answering the question."
    }

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      decision, stderr, status = run_helper(
        state_path,
        observation(
          "task_status" => "blocked-user-input",
          "blocker_state" => blocker_state,
          "resume_instruction" => blocker_state.fetch("resume_instruction")
        )
      )
      assert status.success?, stderr
      assert_equal "pause-user-input", decision.fetch("action")
      assert_equal false, decision.fetch("wake_parent")
      assert_equal "blocked-user-input", decision.dig("handoff", "reason")
      assert_equal blocker_state, decision.dig("handoff", "blocker_state")
      assert_equal "manual-resume-required", decision.dig("handoff", "resume")
      assert_equal blocker_state.fetch("resume_instruction"), decision.dig("handoff", "resume_instruction")

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          "task_status" => "resumable",
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert later_status.success?, later_stderr
      assert_equal decision.fetch("handoff"), later.fetch("handoff")
      assert_equal false, later.fetch("wake_parent")
    end
  end

  def test_paused_monitor_ignores_configuration_drift_and_terminal_transition_wins
    blocker_state = {
      "question" => "Should this target remain paused?",
      "resume_instruction" => "Resume task thread-393 after answering the question."
    }
    changed_configuration = {
      "limits" => { "max_unchanged_runs" => 9, "max_model_calls" => 8, "max_tokens" => 7_000 },
      "polling_policy" => {
        "fast_interval_seconds" => 60,
        "fast_attempts" => 2,
        "max_interval_seconds" => 600
      }
    }

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      paused, paused_stderr, paused_status = run_helper(
        state_path,
        observation(
          "task_status" => "blocked-user-input",
          "blocker_state" => blocker_state,
          "resume_instruction" => blocker_state.fetch("resume_instruction")
        )
      )
      assert paused_status.success?, paused_stderr

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          changed_configuration.merge(
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
      )
      assert later_status.success?, later_stderr
      assert_equal "manual-resume-required", later.fetch("action")
      assert_equal paused.fetch("handoff"), later.fetch("handoff")
      refute later.fetch("wake_parent")

      terminal, terminal_stderr, terminal_status = run_helper(
        state_path,
        observation(
          changed_configuration.merge(
            "task_status" => "terminal",
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z"
          )
        )
      )
      assert terminal_status.success?, terminal_stderr
      assert_equal "stop-task-terminal", terminal.fetch("action")
      assert_equal "stopped", terminal.fetch("monitor_status")
      refute terminal.fetch("wake_parent")
    end
  end

  def test_active_monitor_fails_closed_on_configuration_drift
    drift_cases = {
      "limits" => {
        "limits" => { "max_unchanged_runs" => 9, "max_model_calls" => 8, "max_tokens" => 7_000 }
      },
      "polling-policy" => {
        "polling_policy" => {
          "fast_interval_seconds" => 60,
          "fast_attempts" => 2,
          "max_interval_seconds" => 600
        }
      }
    }

    drift_cases.each_value do |drift|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr

        decision, stderr, status = run_helper(
          state_path,
          observation(
            drift.merge(
              "probe_sequence" => 1,
              "observed_at" => "2026-08-09T00:15:00Z"
            )
          )
        )

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"monitor-configuration-drift"'
      end
    end
  end

  def test_budget_ceiling_pauses_with_an_exact_restart_safe_handoff
    limited = observation(
      "capability" => "model-polling-only",
      "limits" => {
        "max_unchanged_runs" => 10,
        "max_model_calls" => 1,
        "max_tokens" => 1_000
      }
    )

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, limited)
      assert baseline_status.success?, baseline_stderr

      budget_observation = limited.merge(
        "probe_sequence" => 1,
        "usage_delta" => { "model_calls" => 1, "tokens" => 100 },
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      decision, stderr, status = run_helper(state_path, budget_observation)
      assert status.success?, stderr
      assert_equal "pause-budget", decision.fetch("action")
      refute decision.fetch("wake_parent")
      assert_equal "paused", decision.fetch("monitor_status")
      assert_equal(
        {
          "contract" => "goal-state-change-budget-handoff",
          "version" => 1,
          "monitor_id" => "thread-393:checks",
          "reason" => "model-calls-ceiling",
          "fingerprint" => decision.fetch("fingerprint"),
          "usage" => { "model_calls" => 1, "tokens" => 100 },
          "blocker_state" => { "head" => "a" * 40, "pending" => ["validate"] },
          "limits" => {
            "max_unchanged_runs" => 10,
            "max_model_calls" => 1,
            "max_tokens" => 1_000
          },
          "resume_instruction" => "Resume task thread-393.",
          "resume" => "manual-resume-required"
        },
        decision.fetch("handoff")
      )

      replay, replay_stderr, replay_status = run_helper(state_path, budget_observation)
      assert replay_status.success?, replay_stderr
      assert_equal decision.fetch("handoff"), replay.fetch("handoff")
      assert_equal "suppress-replayed-probe", replay.fetch("action")
      assert_equal "pause-budget", replay.fetch("replayed_action")
      assert replay.fetch("replayed")
      refute replay.fetch("wake_parent")

      later, later_stderr, later_status = run_helper(
        state_path,
        limited.merge(
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )
      assert later_status.success?, later_stderr
      assert_equal "manual-resume-required", later.fetch("action")
      assert_equal "paused", later.fetch("monitor_status")
      assert_equal false, later.fetch("wake_parent")
      assert_equal decision.fetch("handoff"), later.fetch("handoff")
    end
  end

  def test_model_call_and_token_ceilings_apply_to_the_initial_probe
    {
      "model-calls-ceiling" => {
        "limits" => { "max_unchanged_runs" => 5, "max_model_calls" => 1, "max_tokens" => 1_000 },
        "usage_delta" => { "model_calls" => 1, "tokens" => 0 }
      },
      "token-ceiling" => {
        "limits" => { "max_unchanged_runs" => 5, "max_model_calls" => 5, "max_tokens" => 100 },
        "usage_delta" => { "model_calls" => 0, "tokens" => 100 }
      }
    }.each do |expected_reason, values|
      Dir.mktmpdir do |directory|
        decision, stderr, status = run_helper(
          File.join(directory, "monitor.json"),
          observation(
            "capability" => "model-polling-only",
            "limits" => values.fetch("limits"),
            "usage_delta" => values.fetch("usage_delta")
          )
        )

        assert status.success?, stderr
        assert_equal "pause-budget", decision.fetch("action")
        assert_equal "paused", decision.fetch("monitor_status")
        assert_equal false, decision.fetch("wake_parent")
        assert_equal expected_reason, decision.dig("handoff", "reason")
        refute decision.key?("next_interval_seconds")
      end
    end
  end

  def test_unsupported_watcher_capability_uses_exact_manual_resume_handoff
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      decision, stderr, status = run_helper(
        state_path,
        observation("capability" => "unsupported")
      )

      assert status.success?, stderr
      assert_equal "manual-resume-required", decision.fetch("action")
      assert_equal "paused", decision.fetch("monitor_status")
      refute decision.fetch("wake_parent")
      assert_equal "unsupported-capability", decision.dig("handoff", "reason")
      assert_equal "manual-resume-required", decision.dig("handoff", "resume")
      assert_equal "Resume task thread-393.", decision.dig("handoff", "resume_instruction")

      later, later_stderr, later_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert later_status.success?, later_stderr
      assert_equal "manual-resume-required", later.fetch("action")
      assert_equal "paused", later.fetch("monitor_status")
      assert_equal false, later.fetch("wake_parent")
      assert_equal decision.fetch("handoff"), later.fetch("handoff")
    end
  end

  def test_unsupported_capability_preserves_exhausted_budget_context
    limits = {
      "max_unchanged_runs" => 10,
      "max_model_calls" => 1,
      "max_tokens" => 1_000
    }

    Dir.mktmpdir do |directory|
      decision, stderr, status = run_helper(
        File.join(directory, "monitor.json"),
        observation(
          "capability" => "unsupported",
          "limits" => limits,
          "usage_delta" => { "model_calls" => 1, "tokens" => 100 }
        )
      )

      assert status.success?, stderr
      assert_equal "manual-resume-required", decision.fetch("action")
      assert_equal "unsupported-capability", decision.dig("handoff", "reason")
      assert_equal "model-calls-ceiling", decision.dig("handoff", "budget_reason")
      assert_equal({ "model_calls" => 1, "tokens" => 100 }, decision.dig("handoff", "usage"))
      assert_equal limits, decision.dig("handoff", "limits")
    end
  end

  def test_unsupported_terminal_dependency_preserves_every_budget_ceiling_context
    cases = {
      "unchanged-runs-ceiling" => {
        "limits" => { "max_unchanged_runs" => 1, "max_model_calls" => 5, "max_tokens" => 1_000 },
        "usage_delta" => { "model_calls" => 0, "tokens" => 0 },
        "baseline" => true
      },
      "model-calls-ceiling" => {
        "limits" => { "max_unchanged_runs" => 5, "max_model_calls" => 1, "max_tokens" => 1_000 },
        "usage_delta" => { "model_calls" => 1, "tokens" => 100 }
      },
      "token-ceiling" => {
        "limits" => { "max_unchanged_runs" => 5, "max_model_calls" => 5, "max_tokens" => 100 },
        "usage_delta" => { "model_calls" => 0, "tokens" => 100 }
      }
    }

    cases.each do |expected_reason, values|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        if values["baseline"]
          _baseline, baseline_stderr, baseline_status = run_helper(
            state_path,
            observation("limits" => values.fetch("limits"))
          )
          assert baseline_status.success?, baseline_stderr
        end

        sequence = values["baseline"] ? 1 : 0
        decision, stderr, status = run_helper(
          state_path,
          observation(
            "capability" => "unsupported",
            "dependency_status" => "terminal",
            "limits" => values.fetch("limits"),
            "usage_delta" => values.fetch("usage_delta"),
            "probe_sequence" => sequence,
            "observed_at" => "2026-08-09T00:#{format('%02d', sequence * 15)}:00Z"
          )
        )

        assert status.success?, stderr
        assert_equal "manual-resume-required", decision.fetch("action")
        assert_equal "stopped", decision.fetch("monitor_status")
        refute decision.fetch("wake_parent")
        refute decision.key?("wake_id")
        assert_equal "dependency-terminal-while-unsupported", decision.dig("handoff", "reason")
        assert_equal expected_reason, decision.dig("handoff", "budget_reason")
        assert_equal values.fetch("limits"), decision.dig("handoff", "limits")
        assert_equal values.fetch("usage_delta"), decision.dig("handoff", "usage")
      end
    end
  end

  def test_capability_loss_preserves_changed_and_terminal_transitions_in_the_handoff
    {
      "state-change-while-unsupported" => {
        "dependency_status" => "nonterminal",
        "blocker_state" => { "head" => "b" * 40, "pending" => [] }
      },
      "dependency-terminal-while-unsupported" => {
        "dependency_status" => "terminal",
        "blocker_state" => { "head" => "a" * 40, "pending" => [], "result" => "passed" }
      }
    }.each do |expected_reason, transition|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr

        decision, stderr, status = run_helper(
          state_path,
          observation(
            **transition,
            "capability" => "unsupported",
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert status.success?, stderr
        assert_equal "manual-resume-required", decision.fetch("action")
        refute decision.fetch("wake_parent")
        refute decision.key?("wake_id")
        assert_equal "manual-resume-required", decision.dig("handoff", "resume")
        assert_equal expected_reason, decision.dig("handoff", "reason")
        assert_equal transition.fetch("dependency_status"), decision.dig("handoff", "dependency_status")
        assert_equal transition.fetch("blocker_state"), decision.dig("handoff", "blocker_state")
        refute_empty decision.dig("handoff", "state_delta", "changes")
      end
    end
  end

  def test_wake_replay_remains_pending_until_acknowledged_then_is_non_waking
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      changed_observation = observation(
        "blocker_state" => { "head" => "b" * 40, "pending" => [] },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      first, first_stderr, first_status = run_helper(state_path, changed_observation)
      assert first_status.success?, first_stderr
      assert_equal "wake-state-change", first.fetch("action")
      assert_equal true, first.fetch("wake_parent")
      assert_match(/\A[0-9a-f]{64}\z/, first.fetch("wake_id"))

      replay, replay_stderr, replay_status = run_helper(state_path, changed_observation)
      assert replay_status.success?, replay_stderr
      assert_equal "redeliver-pending-wake", replay.fetch("action")
      assert_equal "wake-state-change", replay.fetch("replayed_action")
      assert_equal true, replay.fetch("replayed")
      assert_equal true, replay.fetch("wake_parent")
      assert_equal first.fetch("wake_id"), replay.fetch("wake_id")

      acknowledged, acknowledged_stderr, acknowledged_status = run_helper(
        state_path,
        changed_observation.merge(
          "acknowledged_wake_id" => first.fetch("wake_id"),
          "observed_at" => "2026-08-09T00:15:01Z"
        )
      )
      assert acknowledged_status.success?, acknowledged_stderr
      assert_equal "suppress-acknowledgement-retry", acknowledged.fetch("action")
      refute acknowledged.fetch("wake_parent")

      retried_ack, retried_ack_stderr, retried_ack_status = run_helper(
        state_path,
        changed_observation.merge(
          "acknowledged_wake_id" => first.fetch("wake_id"),
          "observed_at" => "2026-08-09T00:15:01Z"
        )
      )
      assert retried_ack_status.success?, retried_ack_stderr
      assert_equal "suppress-acknowledgement-retry", retried_ack.fetch("action")
      assert_equal false, retried_ack.fetch("wake_parent")

      post_ack, post_ack_stderr, post_ack_status = run_helper(state_path, changed_observation)
      assert post_ack_status.success?, post_ack_stderr
      assert_equal "suppress-replayed-probe", post_ack.fetch("action")
      assert_equal false, post_ack.fetch("wake_parent")
    end
  end

  def test_redelivery_persists_the_original_canonical_acknowledgement_payload
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      waking_observation = observation(
        "blocker_state" => { "head" => "b" * 40, "pending" => [] },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      wake, wake_stderr, wake_status = run_helper(state_path, waking_observation)
      assert wake_status.success?, wake_stderr
      assert_equal "wake-state-change", wake.fetch("action")

      current_observation = observation(
        "blocker_state" => { "head" => "c" * 40, "pending" => ["review"] },
        "probe_sequence" => 2,
        "observed_at" => "2026-08-09T00:30:00Z"
      )
      redelivery, redelivery_stderr, redelivery_status = run_helper(state_path, current_observation)
      assert redelivery_status.success?, redelivery_stderr
      assert_equal "redeliver-pending-wake", redelivery.fetch("action")

      acknowledgement_payload = redelivery.fetch("acknowledgement_payload")
      expected_payload = canonicalize_for_digest(
        waking_observation.reject { |key, _value| key == "observed_at" }
                          .merge("acknowledged_wake_id" => wake.fetch("wake_id"))
      )
      assert_equal expected_payload, acknowledgement_payload
      assert_equal(
        acknowledgement_payload,
        JSON.parse(File.read(state_path)).dig("pending_wake", "acknowledgement_payload")
      )

      acknowledged, acknowledged_stderr, acknowledged_status = run_helper(state_path, acknowledgement_payload)
      assert acknowledged_status.success?, acknowledged_stderr
      assert_equal "suppress-acknowledgement-retry", acknowledged.fetch("action")
      refute acknowledged.fetch("wake_parent")
    end
  end

  def test_pending_wake_acknowledgement_rejects_unrelated_newer_evidence_before_mutation
    [
      {},
      {
        "limits" => { "max_unchanged_runs" => 9, "max_model_calls" => 8, "max_tokens" => 7_000 },
        "polling_policy" => {
          "fast_interval_seconds" => 60,
          "fast_attempts" => 2,
          "max_interval_seconds" => 600
        }
      }
    ].each do |newer_overrides|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr
        changed_observation = observation(
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
        pending, pending_stderr, pending_status = run_helper(state_path, changed_observation)
        assert pending_status.success?, pending_stderr
        assert_equal "wake-state-change", pending.fetch("action")
        persisted_before = File.binread(state_path)

        unrelated, unrelated_stderr, unrelated_status = run_helper(
          state_path,
          observation(
            **newer_overrides,
            "blocker_state" => { "head" => "c" * 40, "pending" => ["new-check"] },
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z",
            "acknowledged_wake_id" => pending.fetch("wake_id")
          )
        )

        assert_nil unrelated
        refute unrelated_status.success?
        assert_includes unrelated_stderr, '"reason":"invalid-wake-acknowledgement"'
        assert_equal persisted_before, File.binread(state_path)
        assert_equal pending.fetch("wake_id"), JSON.parse(File.read(state_path)).dig("pending_wake", "wake_id")
      end
    end
  end

  def test_repeated_changed_wake_ack_cycles_keep_restart_state_bounded
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      baseline_bytes = File.size(state_path)
      one_ack_bytes = nil
      one_ack_count = nil

      1.upto(50) do |probe_sequence|
        current_observation = observation(
          "blocker_state" => {
            "head" => (probe_sequence.odd? ? "b" : "a") * 40,
            "pending" => []
          },
          "probe_sequence" => probe_sequence,
          "observed_at" => format(
            "2026-08-09T%<hour>02d:%<minute>02d:00Z",
            hour: probe_sequence / 60,
            minute: probe_sequence % 60
          )
        )
        wake, wake_stderr, wake_status = run_helper(state_path, current_observation)
        assert wake_status.success?, wake_stderr
        assert_equal "wake-state-change", wake.fetch("action")
        acknowledge_wake(state_path, current_observation, wake)
        unless one_ack_bytes
          one_ack_bytes = File.size(state_path)
          one_ack_count = JSON.parse(File.read(state_path)).fetch("acknowledged_wake_ids", []).length
        end
      end

      persisted = JSON.parse(File.read(state_path))
      acknowledged_count = persisted.fetch("acknowledged_wake_ids", []).length
      final_bytes = File.size(state_path)
      puts "ACK_STATE_BASELINE_COUNT_BYTES=0/#{baseline_bytes}"
      puts "ACK_STATE_AFTER_1_COUNT_BYTES=#{one_ack_count}/#{one_ack_bytes}"
      puts "ACK_STATE_AFTER_50_COUNT_BYTES=#{acknowledged_count}/#{final_bytes}"
      assert_equal 0, acknowledged_count
      assert_operator final_bytes, :<=, one_ack_bytes + 128
    end
  end

  def test_same_sequence_acknowledgement_rejects_a_substantive_replay_change
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      changed_observation = observation(
        "blocker_state" => { "head" => "b" * 40, "pending" => [] },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      wake, wake_stderr, wake_status = run_helper(state_path, changed_observation)
      assert wake_status.success?, wake_stderr

      decision, stderr, status = run_helper(
        state_path,
        changed_observation.merge(
          "blocker_state" => { "head" => "c" * 40, "pending" => ["new-check"] },
          "resume_instruction" => "A different instruction at the same sequence.",
          "acknowledged_wake_id" => wake.fetch("wake_id")
        )
      )

      assert_nil decision
      refute status.success?
      assert_includes stderr, '"reason":"probe-replay-mismatch"'
      persisted = JSON.parse(File.read(state_path))
      assert_equal wake.fetch("wake_id"), persisted.dig("pending_wake", "wake_id")
      refute persisted.key?("acknowledged_wake_ids")
    end
  end

  def test_pending_wake_rejects_a_substantively_changed_same_sequence_replay_without_mutating_state
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      waking_observation = observation(
        "blocker_state" => { "head" => "b" * 40, "pending" => [] },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      wake, wake_stderr, wake_status = run_helper(state_path, waking_observation)
      assert wake_status.success?, wake_stderr
      assert_equal "wake-state-change", wake.fetch("action")
      persisted_before_replay = File.read(state_path)

      decision, stderr, status = run_helper(
        state_path,
        waking_observation.merge(
          "blocker_state" => { "head" => "c" * 40, "pending" => ["new-check"] },
          "resume_instruction" => "A different instruction at the same sequence."
        )
      )

      assert_nil decision
      refute status.success?
      assert_includes stderr, '"reason":"probe-replay-mismatch"'
      assert_equal persisted_before_replay, File.read(state_path)
    end
  end

  def test_same_sequence_replay_ignores_an_informational_timestamp_refresh
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr

      replay, replay_stderr, replay_status = run_helper(
        state_path,
        observation("observed_at" => "2026-08-09T00:15:00Z")
      )

      assert replay_status.success?, replay_stderr
      assert_equal "suppress-replayed-probe", replay.fetch("action")
      assert_equal baseline.fetch("action"), replay.fetch("replayed_action")
      assert replay.fetch("replayed")
      refute replay.fetch("wake_parent")
    end
  end

  def test_same_sequence_replay_rejects_a_substantive_observation_change
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr

      decision, stderr, status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )

      assert_nil decision
      refute status.success?
      assert_includes stderr, '"reason":"probe-replay-mismatch"'
    end
  end

  def test_exact_legacy_replay_migrates_the_digest_before_timestamp_only_retries
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      first_observation = observation
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, first_observation)
      assert baseline_status.success?, baseline_stderr
      legacy_state = JSON.parse(File.read(state_path))
      legacy_state.delete("observation_digest_version")
      legacy_state["last_observation_digest"] = observation_digest(
        first_observation,
        include_observed_at: true
      )
      File.write(state_path, JSON.generate(legacy_state))

      replay, replay_stderr, replay_status = run_helper(state_path, first_observation)
      assert replay_status.success?, replay_stderr
      assert_equal "suppress-replayed-probe", replay.fetch("action")
      refute replay.fetch("wake_parent")
      migrated_state = JSON.parse(File.read(state_path))
      assert_equal 2, migrated_state.fetch("observation_digest_version")
      assert_equal observation_digest(first_observation, include_observed_at: false),
                   migrated_state.fetch("last_observation_digest")

      timestamp_retry, timestamp_stderr, timestamp_status = run_helper(
        state_path,
        first_observation.merge("observed_at" => "2026-08-09T00:15:00Z")
      )
      assert timestamp_status.success?, timestamp_stderr
      assert_equal "suppress-replayed-probe", timestamp_retry.fetch("action")
      refute timestamp_retry.fetch("wake_parent")
    end
  end

  def test_invalid_acknowledgement_does_not_persist_a_legacy_digest_migration
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      first_observation = observation
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, first_observation)
      assert baseline_status.success?, baseline_stderr
      legacy_state = JSON.parse(File.read(state_path))
      legacy_state.delete("observation_digest_version")
      legacy_state["last_observation_digest"] = observation_digest(
        first_observation,
        include_observed_at: true
      )
      legacy_state["acknowledged_wake_ids"] = ["f" * 64]
      File.write(state_path, JSON.generate(legacy_state))
      persisted_before = File.binread(state_path)

      decision, stderr, status = run_helper(
        state_path,
        first_observation.merge("acknowledged_wake_id" => "e" * 64)
      )

      assert_nil decision
      refute status.success?
      assert_includes stderr, '"reason":"invalid-wake-acknowledgement"'
      assert_equal persisted_before, File.binread(state_path)
    end
  end

  def test_legacy_replay_with_a_restamped_timestamp_fails_closed
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      first_observation = observation
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, first_observation)
      assert baseline_status.success?, baseline_stderr
      legacy_state = JSON.parse(File.read(state_path))
      legacy_state.delete("observation_digest_version")
      legacy_state["last_observation_digest"] = observation_digest(
        first_observation,
        include_observed_at: true
      )
      File.write(state_path, JSON.generate(legacy_state))

      decision, stderr, status = run_helper(
        state_path,
        first_observation.merge("observed_at" => "2026-08-09T00:15:00Z")
      )
      assert_nil decision
      refute status.success?
      assert_includes stderr, '"reason":"probe-replay-mismatch"'
      refute JSON.parse(File.read(state_path)).key?("observation_digest_version")
    end
  end

  def test_terminal_task_states_supersede_a_budget_paused_monitor
    %w[terminal not-resumable].each do |task_status|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        limited = observation(
          "capability" => "model-polling-only",
          "limits" => { "max_unchanged_runs" => 10, "max_model_calls" => 1, "max_tokens" => 1_000 },
          "usage_delta" => { "model_calls" => 1, "tokens" => 0 }
        )
        paused, paused_stderr, paused_status = run_helper(state_path, limited)
        assert paused_status.success?, paused_stderr
        assert_equal "pause-budget", paused.fetch("action")

        terminal, terminal_stderr, terminal_status = run_helper(
          state_path,
          limited.merge(
            "task_status" => task_status,
            "usage_delta" => { "model_calls" => 0, "tokens" => 0 },
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert terminal_status.success?, terminal_stderr
        assert_equal "stop-task-#{task_status}", terminal.fetch("action")
        assert_equal "stopped", terminal.fetch("monitor_status")
        refute terminal.fetch("wake_parent")
        assert_equal "task-#{task_status}", terminal.dig("handoff", "reason")
        assert_equal "manual-resume-required", terminal.dig("handoff", "resume")
      end
    end
  end

  def test_pending_wake_fences_newer_probes_until_delivery_is_acknowledged
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      changed_observation = observation(
        "blocker_state" => { "head" => "b" * 40, "pending" => [] },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      wake, wake_stderr, wake_status = run_helper(state_path, changed_observation)
      assert wake_status.success?, wake_stderr

      newer, newer_stderr, newer_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "head" => "c" * 40, "pending" => ["review"] },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )
      assert newer_status.success?, newer_stderr
      assert_equal "redeliver-pending-wake", newer.fetch("action")
      assert_equal wake.fetch("wake_id"), newer.fetch("wake_id")
      assert newer.fetch("wake_parent")

      persisted = JSON.parse(File.read(state_path))
      assert_equal 1, persisted.fetch("probe_sequence")
      assert_equal "b" * 40, persisted.dig("blocker_state", "head")
    end
  end

  def test_task_stop_states_supersede_an_unacknowledged_pending_wake
    {
      "terminal" => %w[stop-task-terminal stopped],
      "not-resumable" => %w[stop-task-not-resumable stopped],
      "blocked-user-input" => %w[pause-user-input paused]
    }.each do |task_status, (expected_action, expected_monitor_status)|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr
        pending, pending_stderr, pending_status = run_helper(
          state_path,
          observation(
            "blocker_state" => { "head" => "b" * 40, "pending" => [] },
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert pending_status.success?, pending_stderr
        assert pending.fetch("wake_parent")

        blocker_state = if task_status == "blocked-user-input"
                          {
                            "question" => "Should this task remain paused?",
                            "resume_instruction" => "Resume task thread-393 after answering the question."
                          }
                        else
                          { "head" => "b" * 40, "pending" => [] }
                        end
        current, current_stderr, current_status = run_helper(
          state_path,
          observation(
            "task_status" => task_status,
            "blocker_state" => blocker_state,
            "resume_instruction" => blocker_state.fetch("resume_instruction", "Resume task thread-393."),
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z"
          )
        )
        assert current_status.success?, current_stderr
        assert_equal expected_action, current.fetch("action")
        assert_equal expected_monitor_status, current.fetch("monitor_status")
        assert_equal false, current.fetch("wake_parent")
      end
    end
  end

  def test_dependency_terminal_supersedes_pending_and_paused_monitor_state
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "pending-monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      pending, pending_stderr, pending_status = run_helper(
        state_path,
        observation("blocker_state" => { "value" => 1 }, "probe_sequence" => 1)
      )
      assert pending_status.success?, pending_stderr
      assert_equal "wake-state-change", pending.fetch("action")

      terminal, terminal_stderr, terminal_status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => { "value" => 2 },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )
      assert terminal_status.success?, terminal_stderr
      assert_equal "stop-dependency-terminal", terminal.fetch("action")
      assert_equal "stopped", terminal.fetch("monitor_status")
      assert terminal.fetch("wake_parent")
      refute_equal pending.fetch("wake_id"), terminal.fetch("wake_id")

      late_ack, late_ack_stderr, late_ack_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "value" => 1 },
          "probe_sequence" => 1,
          "acknowledged_wake_id" => pending.fetch("wake_id")
        )
      )
      assert late_ack_status.success?, late_ack_stderr
      assert_equal "redeliver-pending-wake", late_ack.fetch("action")
      assert_equal terminal.fetch("wake_id"), late_ack.fetch("wake_id")
      assert late_ack.fetch("wake_parent")
    end

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "paused-monitor.json")
      limited = observation(
        "capability" => "model-polling-only",
        "limits" => { "max_unchanged_runs" => 10, "max_model_calls" => 1, "max_tokens" => 1_000 },
        "usage_delta" => { "model_calls" => 1, "tokens" => 0 }
      )
      paused, paused_stderr, paused_status = run_helper(state_path, limited)
      assert paused_status.success?, paused_stderr
      assert_equal "pause-budget", paused.fetch("action")

      terminal, terminal_stderr, terminal_status = run_helper(
        state_path,
        limited.merge(
          "dependency_status" => "terminal",
          "limits" => { "max_unchanged_runs" => 9, "max_model_calls" => 8, "max_tokens" => 7_000 },
          "polling_policy" => {
            "fast_interval_seconds" => 60,
            "fast_attempts" => 2,
            "max_interval_seconds" => 600
          },
          "usage_delta" => { "model_calls" => 0, "tokens" => 0 },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert terminal_status.success?, terminal_stderr
      assert_equal "stop-dependency-terminal", terminal.fetch("action")
      assert_equal "stopped", terminal.fetch("monitor_status")
      assert terminal.fetch("wake_parent")
      refute terminal.key?("handoff")
    end
  end

  def test_newer_dependency_terminal_replaces_the_unacknowledged_terminal_wake
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      first_observation = observation(
        "dependency_status" => "terminal",
        "blocker_state" => { "result" => "failed" },
        "probe_sequence" => 1,
        "observed_at" => "2026-08-09T00:15:00Z"
      )
      first, first_stderr, first_status = run_helper(state_path, first_observation)
      assert first_status.success?, first_stderr
      assert_equal "stop-dependency-terminal", first.fetch("action")

      second, second_stderr, second_status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => { "result" => "passed" },
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )

      assert second_status.success?, second_stderr
      assert_equal "stop-dependency-terminal", second.fetch("action")
      assert second.fetch("wake_parent")
      refute_equal first.fetch("wake_id"), second.fetch("wake_id")
      persisted = JSON.parse(File.read(state_path))
      assert_equal second.fetch("wake_id"), persisted.dig("pending_wake", "wake_id")
      refute persisted.key?("acknowledged_wake_ids")
      assert_equal 2, persisted.fetch("probe_sequence")
      assert_equal({ "result" => "passed" }, persisted.fetch("blocker_state"))
    end
  end

  def test_unchanged_newer_dependency_terminal_redelivers_the_pending_wake
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      terminal_state = { "result" => "failed" }
      first, first_stderr, first_status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => terminal_state,
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert first_status.success?, first_stderr
      assert_equal "stop-dependency-terminal", first.fetch("action")

      second, second_stderr, second_status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => terminal_state,
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )

      assert second_status.success?, second_stderr
      assert_equal "redeliver-pending-wake", second.fetch("action")
      assert_equal "stop-dependency-terminal", second.fetch("replayed_action")
      assert_equal first.fetch("wake_id"), second.fetch("wake_id")
      assert second.fetch("wake_parent")
      persisted = JSON.parse(File.read(state_path))
      assert_equal first.fetch("wake_id"), persisted.dig("pending_wake", "wake_id")
      assert_equal 1, persisted.fetch("probe_sequence")
      assert_equal terminal_state, persisted.fetch("blocker_state")
    end
  end

  def test_newer_dependency_terminal_capability_loss_supersedes_the_pending_wake
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      terminal_state = { "result" => "failed" }
      first, first_stderr, first_status = run_helper(
        state_path,
        observation(
          "dependency_status" => "terminal",
          "blocker_state" => terminal_state,
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert first_status.success?, first_stderr
      assert_equal "stop-dependency-terminal", first.fetch("action")

      resume_instruction = "Resume task thread-393 manually after restoring watcher support."
      second, second_stderr, second_status = run_helper(
        state_path,
        observation(
          "capability" => "unsupported",
          "dependency_status" => "terminal",
          "blocker_state" => terminal_state,
          "resume_instruction" => resume_instruction,
          "probe_sequence" => 2,
          "observed_at" => "2026-08-09T00:30:00Z"
        )
      )

      assert second_status.success?, second_stderr
      assert_equal "manual-resume-required", second.fetch("action")
      refute second.fetch("wake_parent")
      assert_equal "dependency-terminal-while-unsupported", second.dig("handoff", "reason")
      assert_equal terminal_state, second.dig("handoff", "blocker_state")
      assert_equal resume_instruction, second.dig("handoff", "resume_instruction")

      persisted = JSON.parse(File.read(state_path))
      refute persisted.key?("pending_wake")
      assert_equal "unsupported", persisted.fetch("capability")
      assert_equal 2, persisted.fetch("probe_sequence")
      assert_equal second.fetch("handoff"), persisted.dig("last_decision", "handoff")
    end
  end

  def test_delayed_acknowledgements_remain_idempotent_after_later_wakes
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr

      first_observation = observation("blocker_state" => { "value" => 1 }, "probe_sequence" => 1)
      first, first_stderr, first_status = run_helper(state_path, first_observation)
      assert first_status.success?, first_stderr
      acknowledge_wake(state_path, first_observation, first)

      second_observation = observation("blocker_state" => { "value" => 2 }, "probe_sequence" => 2)
      unrelated, unrelated_stderr, unrelated_status = run_helper(
        state_path,
        second_observation.merge("acknowledged_wake_id" => first.fetch("wake_id"))
      )
      assert_nil unrelated
      refute unrelated_status.success?
      assert_includes unrelated_stderr, '"reason":"invalid-wake-acknowledgement"'

      second, second_stderr, second_status = run_helper(state_path, second_observation)
      assert second_status.success?, second_stderr
      acknowledge_wake(state_path, second_observation, second)

      delayed, delayed_stderr, delayed_status = run_helper(
        state_path,
        first_observation.merge("acknowledged_wake_id" => first.fetch("wake_id"))
      )
      assert delayed_status.success?, delayed_stderr
      assert_equal "suppress-acknowledgement-retry", delayed.fetch("action")
      assert_equal false, delayed.fetch("wake_parent")

      persisted_before_retry = File.read(state_path)
      retried, retried_stderr, retried_status = run_helper(
        state_path,
        first_observation.merge("acknowledged_wake_id" => first.fetch("wake_id"))
      )
      assert retried_status.success?, retried_stderr
      assert_equal "suppress-acknowledgement-retry", retried.fetch("action")
      refute retried.fetch("wake_parent")
      assert_equal persisted_before_retry, File.read(state_path)
    end
  end

  def test_last_wake_retry_requires_the_original_probe_sequence_and_evidence
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      wake_observation = observation("blocker_state" => { "value" => 1 }, "probe_sequence" => 1)
      wake, wake_stderr, wake_status = run_helper(state_path, wake_observation)
      assert wake_status.success?, wake_stderr
      acknowledge_wake(state_path, wake_observation, wake)

      exact_retry, exact_retry_stderr, exact_retry_status = run_helper(
        state_path,
        wake_observation.merge("acknowledged_wake_id" => wake.fetch("wake_id"))
      )
      assert exact_retry_status.success?, exact_retry_stderr
      assert_equal "suppress-acknowledgement-retry", exact_retry.fetch("action")
      refute exact_retry.fetch("wake_parent")

      persisted_before_unrelated_retry = File.read(state_path)
      unrelated, unrelated_stderr, unrelated_status = run_helper(
        state_path,
        observation("acknowledged_wake_id" => wake.fetch("wake_id"))
      )
      assert_nil unrelated
      refute unrelated_status.success?
      assert_includes unrelated_stderr, '"reason":"invalid-wake-acknowledgement"'
      assert_equal persisted_before_unrelated_retry, File.read(state_path)
    end
  end

  def test_stale_acknowledgements_fail_closed_for_impossible_waking_actions
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      first_observation = observation("blocker_state" => { "value" => 1 }, "probe_sequence" => 1)
      first, first_stderr, first_status = run_helper(state_path, first_observation)
      assert first_status.success?, first_stderr
      acknowledge_wake(state_path, first_observation, first)
      second_observation = observation("blocker_state" => { "value" => 2 }, "probe_sequence" => 2)
      second, second_stderr, second_status = run_helper(state_path, second_observation)
      assert second_status.success?, second_stderr
      acknowledge_wake(state_path, second_observation, second)

      impossible_acknowledgements = [
        first_observation.merge(
          "capability" => "unsupported",
          "acknowledged_wake_id" => first.fetch("wake_id")
        ),
        first_observation.merge(
          "task_status" => "terminal",
          "acknowledged_wake_id" => first.fetch("wake_id")
        ),
        first_observation.merge(
          "acknowledged_wake_id" => derived_wake_id(first_observation, "fallback-model-poll")
        ),
        first_observation.merge(
          "acknowledged_wake_id" => derived_wake_id(first_observation, "stop-dependency-terminal")
        )
      ]

      impossible_acknowledgements.each do |invalid_observation|
        decision, stderr, status = run_helper(state_path, invalid_observation)
        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"invalid-wake-acknowledgement"'
      end
    end
  end

  def test_legacy_acknowledgement_history_is_read_for_migration_then_dropped_on_persist
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      current_observation = observation("probe_sequence" => 2, "observed_at" => "2026-08-09T00:30:00Z")
      _current, current_stderr, current_status = run_helper(state_path, current_observation)
      assert current_status.success?, current_stderr
      legacy_wake_id = "f" * 64
      legacy_state = JSON.parse(File.read(state_path)).merge("acknowledged_wake_ids" => [legacy_wake_id])
      File.write(state_path, JSON.generate(legacy_state))

      unrelated, unrelated_stderr, unrelated_status = run_helper(
        state_path,
        observation(
          "probe_sequence" => 3,
          "observed_at" => "2026-08-09T00:45:00Z",
          "acknowledged_wake_id" => legacy_wake_id
        )
      )
      assert_nil unrelated
      refute unrelated_status.success?
      assert_includes unrelated_stderr, '"reason":"invalid-wake-acknowledgement"'

      legacy_retry, legacy_stderr, legacy_status = run_helper(
        state_path,
        observation(
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z",
          "acknowledged_wake_id" => legacy_wake_id
        )
      )
      assert legacy_status.success?, legacy_stderr
      assert_equal "suppress-acknowledgement-retry", legacy_retry.fetch("action")
      assert JSON.parse(File.read(state_path)).key?("acknowledged_wake_ids")

      _next, next_stderr, next_status = run_helper(
        state_path,
        observation("probe_sequence" => 3, "observed_at" => "2026-08-09T00:45:00Z")
      )
      assert next_status.success?, next_stderr
      refute JSON.parse(File.read(state_path)).key?("acknowledged_wake_ids")
    end
  end

  def test_restart_sequence_suppresses_stale_probes_and_fences_duplicate_monitor_identity
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
      assert baseline_status.success?, baseline_stderr
      _current, current_stderr, current_status = run_helper(
        state_path,
        observation("probe_sequence" => 2, "observed_at" => "2026-08-09T00:30:00Z")
      )
      assert current_status.success?, current_stderr

      stale, stale_stderr, stale_status = run_helper(
        state_path,
        observation("probe_sequence" => 1, "observed_at" => "2026-08-09T00:15:00Z")
      )
      assert stale_status.success?, stale_stderr
      assert_equal "suppress-stale-probe", stale.fetch("action")
      refute stale.fetch("wake_parent")
      assert_equal 2, stale.fetch("last_probe_sequence")

      rejected, rejected_stderr, rejected_status = run_helper(
        state_path,
        observation("monitor_id" => "thread-393:duplicate", "probe_sequence" => 3)
      )
      assert_nil rejected
      refute rejected_status.success?
      assert_includes rejected_stderr, '"reason":"monitor-id-collision"'

      persisted = JSON.parse(File.read(state_path))
      assert_equal "thread-393:checks", persisted.fetch("monitor_id")
      assert_equal 2, persisted.fetch("probe_sequence")
    end
  end

  def test_token_and_unchanged_run_ceilings_are_bounded
    cases = {
      "token-ceiling" => {
        "limits" => { "max_unchanged_runs" => 5, "max_model_calls" => 5, "max_tokens" => 100 },
        "usage_delta" => { "model_calls" => 0, "tokens" => 100 }
      },
      "unchanged-runs-ceiling" => {
        "limits" => { "max_unchanged_runs" => 1, "max_model_calls" => 5, "max_tokens" => 1_000 },
        "usage_delta" => { "model_calls" => 0, "tokens" => 0 }
      }
    }

    cases.each do |expected_reason, values|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        initial = observation("limits" => values.fetch("limits"))
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, initial)
        assert baseline_status.success?, baseline_stderr

        decision, stderr, status = run_helper(
          state_path,
          initial.merge(
            "probe_sequence" => 1,
            "usage_delta" => values.fetch("usage_delta"),
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert status.success?, stderr
        assert_equal "pause-budget", decision.fetch("action")
        assert_equal expected_reason, decision.dig("handoff", "reason")
      end
    end
  end

  def test_model_polling_conservatively_counts_each_fallback_continuation
    limited = observation(
      "capability" => "model-polling-only",
      "limits" => { "max_unchanged_runs" => 10, "max_model_calls" => 2, "max_tokens" => 1_000 },
      "usage_delta" => { "model_calls" => 0, "tokens" => 0 }
    )

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, limited)
      assert baseline_status.success?, baseline_stderr

      first_observation = limited.merge("probe_sequence" => 1, "observed_at" => "2026-08-09T00:15:00Z")
      first, first_stderr, first_status = run_helper(state_path, first_observation)
      assert first_status.success?, first_stderr
      assert_equal "fallback-model-poll", first.fetch("action")
      acknowledge_wake(state_path, first_observation, first)

      second, second_stderr, second_status = run_helper(
        state_path,
        limited.merge("probe_sequence" => 2, "observed_at" => "2026-08-09T00:30:00Z")
      )
      assert second_status.success?, second_stderr
      assert_equal "pause-budget", second.fetch("action")
      assert_equal "model-calls-ceiling", second.dig("handoff", "reason")
      assert_equal 2, second.dig("handoff", "usage", "model_calls")
      assert_equal false, second.fetch("wake_parent")
    end
  end

  def test_changed_probe_at_a_usage_ceiling_wakes_once_then_pauses_without_rescheduling
    limited = observation(
      "capability" => "model-polling-only",
      "limits" => { "max_unchanged_runs" => 10, "max_model_calls" => 1, "max_tokens" => 100 }
    )

    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      _baseline, baseline_stderr, baseline_status = run_helper(state_path, limited)
      assert baseline_status.success?, baseline_stderr

      changed, changed_stderr, changed_status = run_helper(
        state_path,
        limited.merge(
          "blocker_state" => { "head" => "b" * 40, "pending" => [] },
          "usage_delta" => { "model_calls" => 1, "tokens" => 100 },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert changed_status.success?, changed_stderr
      assert_equal "wake-state-change", changed.fetch("action")
      assert changed.fetch("wake_parent")
      assert_equal "paused", changed.fetch("monitor_status")
      assert_equal "model-calls-ceiling", changed.dig("handoff", "reason")
      refute changed.key?("next_interval_seconds")
    end
  end

  def test_fingerprint_is_stable_across_object_key_order
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      first, first_stderr, first_status = run_helper(
        state_path,
        observation("blocker_state" => { "head" => "a" * 40, "pending" => ["validate"] })
      )
      assert first_status.success?, first_stderr

      second, second_stderr, second_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "pending" => ["validate"], "head" => "a" * 40 },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert second_status.success?, second_stderr
      assert_equal first.fetch("fingerprint"), second.fetch("fingerprint")
      assert_equal "suppress-unchanged", second.fetch("action")
      refute second.fetch("wake_parent")
    end
  end

  def test_fingerprint_is_stable_across_set_valued_array_order
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "monitor.json")
      first, first_stderr, first_status = run_helper(
        state_path,
        observation("blocker_state" => { "head" => "a" * 40, "pending" => %w[lint test] })
      )
      assert first_status.success?, first_stderr

      second, second_stderr, second_status = run_helper(
        state_path,
        observation(
          "blocker_state" => { "head" => "a" * 40, "pending" => %w[test lint lint] },
          "probe_sequence" => 1,
          "observed_at" => "2026-08-09T00:15:00Z"
        )
      )
      assert second_status.success?, second_stderr
      assert_equal first.fetch("fingerprint"), second.fetch("fingerprint")
      assert_equal "suppress-unchanged", second.fetch("action")
      refute second.fetch("wake_parent")
    end
  end

  def test_corrupt_persisted_state_is_rejected
    ["{", JSON.generate([])].each do |persisted_state|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        File.write(state_path, persisted_state)

        decision, stderr, status = run_helper(state_path, observation)

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"corrupt-persisted-state"'
      end
    end
  end

  def test_partial_or_malformed_persisted_state_is_structurally_rejected
    corruptions = {
      "partial-state" => lambda { |_state|
        { "monitor_id" => "adversarial:393" }
      },
      "missing-probe-sequence" => lambda { |state|
        state.reject { |key, _value| key == "probe_sequence" }
      },
      "invalid-pending-wake" => lambda { |state|
        state.merge("pending_wake" => [])
      },
      "invalid-acknowledgement-history" => lambda { |state|
        state.merge("acknowledged_wake_ids" => ["not-a-wake-id"])
      },
      "invalid-acknowledgement-history-type" => lambda { |state|
        state.merge("acknowledged_wake_ids" => "not-an-array")
      },
      "invalid-last-decision" => lambda { |state|
        state.merge("last_decision" => [])
      },
      "invalid-usage" => lambda { |state|
        state.merge("usage" => {})
      },
      "invalid-observation-digest-version" => lambda { |state|
        state.merge("observation_digest_version" => 99)
      }
    }

    corruptions.each_value do |corrupt|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        monitored_observation = observation("monitor_id" => "adversarial:393")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, monitored_observation)
        assert baseline_status.success?, baseline_stderr
        persisted_state = JSON.parse(File.read(state_path))
        File.write(state_path, JSON.generate(corrupt.call(persisted_state)))

        decision, stderr, status = run_helper(
          state_path,
          monitored_observation.merge(
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"corrupt-persisted-state"'
      end
    end
  end

  def test_pending_wake_requires_one_consistent_waking_decision_id
    corruptions = {
      "missing-inner-wake-id" => lambda { |state|
        state.dig("pending_wake", "decision").delete("wake_id")
      },
      "mismatched-inner-wake-id" => lambda { |state|
        state.dig("pending_wake", "decision")["wake_id"] = "f" * 64
      },
      "non-waking-inner-decision" => lambda { |state|
        state.dig("pending_wake", "decision")["wake_parent"] = false
      },
      "non-waking-inner-action" => lambda { |state|
        state.dig("pending_wake", "decision")["action"] = "suppress-unchanged"
      },
      "missing-acknowledgement-payload" => lambda { |state|
        state.fetch("pending_wake").delete("acknowledgement_payload")
      },
      "mismatched-acknowledgement-payload" => lambda { |state|
        state.dig("pending_wake", "acknowledgement_payload")["blocker_state"] = { "head" => "c" * 40 }
      }
    }

    corruptions.each_value do |corrupt|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr
        _wake, wake_stderr, wake_status = run_helper(
          state_path,
          observation(
            "blocker_state" => { "head" => "b" * 40, "pending" => [] },
            "probe_sequence" => 1,
            "observed_at" => "2026-08-09T00:15:00Z"
          )
        )
        assert wake_status.success?, wake_stderr
        persisted_state = JSON.parse(File.read(state_path))
        corrupt.call(persisted_state)
        File.write(state_path, JSON.generate(persisted_state))

        decision, stderr, status = run_helper(
          state_path,
          observation(
            "blocker_state" => { "head" => "b" * 40, "pending" => [] },
            "probe_sequence" => 2,
            "observed_at" => "2026-08-09T00:30:00Z"
          )
        )

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"corrupt-persisted-state"'
      end
    end
  end

  def test_invalid_wake_acknowledgements_are_rejected
    acknowledgements = ["not-a-wake-id", "f" * 64]

    acknowledgements.each do |acknowledged_wake_id|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "monitor.json")
        _baseline, baseline_stderr, baseline_status = run_helper(state_path, observation)
        assert baseline_status.success?, baseline_stderr

        decision, stderr, status = run_helper(
          state_path,
          observation("acknowledged_wake_id" => acknowledged_wake_id)
        )

        assert_nil decision
        refute status.success?
        assert_includes stderr, '"reason":"invalid-wake-acknowledgement"'
      end
    end
  end

  def test_invalid_json_shapes_return_structured_invalid_input
    invalid_inputs = {
      "top-level-object-required" => [],
      "polling-policy-object-required" => observation("polling_policy" => nil),
      "limits-object-required" => observation("limits" => []),
      "usage-delta-object-required" => observation("usage_delta" => "none"),
      "blocked-user-input-question-required" => observation(
        "task_status" => "blocked-user-input",
        "blocker_state" => { "resume_instruction" => "Resume task thread-393." }
      ),
      "resume-instruction-required" => observation(
        "resume_instruction" => ""
      ),
      "wrong-contract" => observation("contract" => "goal-state-change-observation-v2"),
      "invalid-monitor-id" => observation("monitor_id" => ""),
      "invalid-capability" => observation("capability" => "watcher"),
      "invalid-task-status" => observation("task_status" => "running"),
      "invalid-dependency-status" => observation("dependency_status" => "pending"),
      "blocker-state-object-required" => observation("blocker_state" => []),
      "invalid-probe-sequence" => observation("probe_sequence" => -1),
      "invalid-limits" => observation("limits" => { "max_unchanged_runs" => 0 }),
      "invalid-usage-delta" => observation("usage_delta" => { "tokens" => -1 })
    }

    invalid_inputs.each do |expected_reason, input|
      Dir.mktmpdir do |directory|
        stdout, stderr, status = Open3.capture3(
          HELPER,
          "--state",
          File.join(directory, "monitor.json"),
          stdin_data: JSON.generate(input)
        )
        refute status.success?
        assert_empty stdout
        decision = JSON.parse(stderr)
        assert_equal "goal-state-change-decision", decision.fetch("contract")
        assert_equal "invalid-input", decision.fetch("status")
        assert_equal expected_reason, decision.fetch("reason")
      end
    end
  end
end
