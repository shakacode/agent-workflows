#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

class HooksInstallContractTest < Minitest::Test
  HOOKS_JSON = File.expand_path("hooks.json", __dir__)
  PACK_ROOT = File.expand_path("../../..", __dir__)
  PLUGIN_MANIFEST = File.join(PACK_ROOT, ".claude-plugin/plugin.json")
  DOCS = File.join(PACK_ROOT, "docs/host-adapter/README.md")

  def setup
    @hooks = JSON.parse(File.read(HOOKS_JSON)).fetch("hooks")
  end

  def test_registers_exactly_the_two_documented_events
    assert_equal %w[PreToolUse SessionEnd].sort, @hooks.keys.sort
  end

  def test_pre_tool_use_gate_targets_bash_and_points_at_an_executable_adapter
    entry = @hooks.fetch("PreToolUse").fetch(0)

    assert_equal "Bash", entry.fetch("matcher")
    assert_equal 1, entry.fetch("hooks").length
    assert_adapter(entry.fetch("hooks").fetch(0), "block-merge-without-ci-readiness")
  end

  def test_session_end_matcher_covers_the_stopping_reasons_and_excludes_resume
    entry = @hooks.fetch("SessionEnd").fetch(0)
    matcher = Regexp.new(entry.fetch("matcher"))

    %w[clear logout prompt_input_exit other].each do |reason|
      assert_match matcher, reason, "SessionEnd must fire for #{reason}"
    end
    refute_match matcher, "resume", "SessionEnd must not fire for a resumed session"
    assert_adapter(entry.fetch("hooks").fetch(0), "close-lane-on-session-end")
  end

  # The adapter must reach its own blocking decision before the host's
  # registered timeout can fire, otherwise "readiness could not be established
  # in time" is decided by the host rather than by the gate.
  def test_merge_gate_internal_budget_stays_under_its_registered_timeout
    load File.expand_path("block-merge-without-ci-readiness", __dir__)
    registered = @hooks.fetch("PreToolUse").fetch(0).fetch("hooks").fetch(0).fetch("timeout")
    budget = BlockMergeWithoutCiReadiness::DEFAULT_TOTAL_BUDGET_SECONDS

    assert_operator budget, :<, registered,
                    "internal budget #{budget}s must be below the registered #{registered}s timeout"
    assert_operator registered - budget, :>=, 10,
                    "leave at least 10s of margin for process teardown and hook startup"
    assert_operator BlockMergeWithoutCiReadiness::DEFAULT_TIMEOUT_SECONDS, :<=, budget,
                    "a single stage must not be able to consume more than the whole budget"
  end

  # A literal NUL byte makes git classify a source file as binary, so it renders
  # as "Bin 0 -> N bytes" and its contents vanish from every diff-based review --
  # the defect and its own invisibility arrive together, which is why no reviewer
  # or bot catches it. It also breaks `grep` without `-a` and `git diff --check`.
  # This happened twice while writing these adapters, so it is asserted rather
  # than remembered.
  def test_no_shipped_hook_source_contains_a_nul_byte
    offenders = Dir.glob(File.join(__dir__, "**/*"), File::FNM_DOTMATCH).select do |path|
      File.file?(path) && File.binread(path).include?(0.chr)
    end

    assert_empty offenders.map { |path| path.sub("#{PACK_ROOT}/", "") },
                 "a NUL byte makes these files binary to git and invisible in review diffs"
  end

  def test_every_adapter_has_a_finite_timeout
    @hooks.each_value do |entries|
      entries.each do |entry|
        entry.fetch("hooks").each do |hook|
          timeout = hook.fetch("timeout")

          assert_kind_of Integer, timeout
          assert_operator timeout, :>, 0
        end
      end
    end
  end

  # The adapters ship opt-in and off by default. A `hooks` key in the plugin
  # manifest would activate them for everyone who enables the pack, which is
  # exactly what issue #276 asked us not to do.
  def test_the_plugin_manifest_does_not_activate_the_hooks
    manifest = JSON.parse(File.read(PLUGIN_MANIFEST))

    refute manifest.key?("hooks"), "registering hooks in plugin.json would make them on by default"
  end

  def test_the_enable_steps_are_documented
    documentation = File.read(DOCS)

    assert_includes documentation, "block-merge-without-ci-readiness"
    assert_includes documentation, "close-lane-on-session-end"
    assert_includes documentation, "intercom/2x-skills"
    assert_includes documentation, "Codex"
  end

  private

  def assert_adapter(hook, basename)
    assert_equal "command", hook.fetch("type")
    command = hook.fetch("command")

    assert_includes command, "${CLAUDE_PLUGIN_ROOT}/"
    path = command.sub("${CLAUDE_PLUGIN_ROOT}", PACK_ROOT)

    assert_equal basename, File.basename(path)
    assert File.executable?(path), "#{path} must be executable"
  end
end
