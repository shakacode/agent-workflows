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

  def test_registers_exactly_the_session_end_event
    assert_equal %w[SessionEnd], @hooks.keys
    refute @hooks.key?("PreToolUse"), "the opt-in pack must not ship the withdrawn merge-command gate"
  end

  def test_session_end_matcher_covers_the_stopping_reasons_and_excludes_resume
    entry = @hooks.fetch("SessionEnd").fetch(0)
    matcher_source = entry.fetch("matcher")
    matcher = Regexp.new(matcher_source)

    assert_equal %w[clear logout prompt_input_exit other].sort, matcher_source.split("|").sort
    %w[clear logout prompt_input_exit other].each do |reason|
      assert_match matcher, reason, "SessionEnd must fire for #{reason}"
    end
    refute_match matcher, "resume", "SessionEnd must not fire for a resumed session"
    refute_match matcher, "bypass_permissions_disabled",
                 "SessionEnd must use only the reasons in the current host contract"
    assert_adapter(entry.fetch("hooks").fetch(0), "close-lane-on-session-end")
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

  # The adapter must finish on its own terms rather than being killed mid-write
  # by the host.
  def test_session_end_budget_stays_under_its_registered_timeout
    load File.expand_path("close-lane-on-session-end", __dir__)
    registered = @hooks.fetch("SessionEnd").fetch(0).fetch("hooks").fetch(0).fetch("timeout")
    cap = CloseLaneOnSessionEnd::MAX_TIMEOUT_SECONDS
    grace = HookSupport::PROCESS_GROUP_TERMINATION_GRACE_SECONDS
    fixed_budget = HookSupport::PAYLOAD_READ_TIMEOUT_SECONDS + cap + (2 * grace)
    startup_dispatch_margin = CloseLaneOnSessionEnd::HOST_STARTUP_DISPATCH_MARGIN_SECONDS

    assert_operator cap, :<, registered,
                    "emission cap #{cap}s must be below the registered #{registered}s timeout"
    assert_operator fixed_budget + startup_dispatch_margin, :<=, registered,
                    "payload read, emission, double process-group grace, and startup/dispatch margin must fit"
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

  # The adapter ships opt-in and off by default. A `hooks` key in the plugin
  # manifest would activate it for everyone who enables the pack.
  def test_the_plugin_manifest_does_not_activate_the_hooks
    manifest = JSON.parse(File.read(PLUGIN_MANIFEST))

    refute manifest.key?("hooks"), "registering hooks in plugin.json would make them on by default"
  end

  def test_the_enable_steps_are_documented
    documentation = File.read(DOCS)

    assert_includes documentation, "close-lane-on-session-end"
    refute_includes documentation, "block-merge-without-ci-readiness"
    refute_includes documentation, "bypass_permissions_disabled"
    assert_includes documentation, '"args": ["--project-dir", "${CLAUDE_PROJECT_DIR}"]'
    assert_includes documentation, "AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV"
    assert_includes documentation, "atomically verifies the expected holder, generation or instance, and live lease or heartbeat"
    assert_includes documentation, "Exit 3 means no current live claim"
    assert_includes documentation, "append-only `agent-coord record-event` is unsupported"
    assert_includes documentation, "The hook payload's `cwd` is not trusted"
    assert_includes documentation, "clamped to 2"
    assert_includes documentation, "Emitter stdin is bound"
    assert_includes documentation, "null device and stdout is discarded"
    assert_includes documentation, "structurally accounts for the payload read"
    assert_includes documentation, "both process-group termination grace periods"
    refute_includes documentation, "AGENT_WORKFLOWS_DRAIN_EVENT_ARGV"
    refute_includes documentation, "AGENT_WORKFLOWS_DRAIN_EVENT_CLAIM_MARKER"
    assert_includes documentation, "Codex"
  end

  def test_the_withdrawn_merge_gate_is_documented_as_structured_only
    documentation = File.read(DOCS)
    normalized = documentation.gsub(/\s+/, " ")

    assert_includes normalized, "No merge-text gate"
    assert_includes normalized, "withdrawn `PreToolUse` merge-command gate"
    assert_includes normalized, "structured host tool/argv identity"
    assert_includes normalized, "Direct `gh pr merge` can remain usable"
    assert_includes normalized, "Wrapper invocations (`env`, `sh -c`, `bash -lc`, `nohup`,"
    assert_includes normalized, "command substitution/backticks"
    assert_includes normalized, "quoted subcommand tokens"
    assert_includes normalized, "arithmetic expansion"
    assert_includes normalized, "heredocs"
    assert_includes normalized, "URL selectors"
    assert_includes normalized, "redirections"
    assert_includes normalized, "unknown flags"
    assert_includes normalized, "NUL-bearing argv/cwd values"
    assert_includes normalized, "fail closed"
  end

  private

  def assert_adapter(hook, basename)
    assert_equal "command", hook.fetch("type")
    assert_equal ["--project-dir", "${CLAUDE_PROJECT_DIR}"], hook.fetch("args"),
                 "command hooks must use exec form and bind the stable launch project"
    command = hook.fetch("command")

    assert_includes command, "${CLAUDE_PLUGIN_ROOT}/"
    path = command.sub("${CLAUDE_PLUGIN_ROOT}", PACK_ROOT)

    assert_equal basename, File.basename(path)
    assert File.executable?(path), "#{path} must be executable"
  end
end
