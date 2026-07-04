#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
VALIDATOR = File.join(ROOT, "bin/validate-host-adapter-syntax")

class HostAdapterSyntaxTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@tmp, "skills/demo"))
    FileUtils.mkdir_p(File.join(@tmp, "workflows"))
    File.write(File.join(@tmp, "skills/demo/SKILL.md"), <<~MARKDOWN)
      ---
      name: demo
      description: Demo.
      ---

      Use `git worktree add` and `isolation: 'worktree'`.

      <!-- host-branch: codex-only start -->
      Use `/goal` in Codex.
      <!-- host-branch: codex-only end -->

      Run `codex review` only when available; otherwise record the fallback.
      Run `/simplify` only when available; otherwise skip with reason.
    MARKDOWN
    File.write(File.join(@tmp, "workflows/demo.md"), "No host-specific syntax.\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_validator
    Open3.capture3(VALIDATOR, @tmp)
  end

  def test_fixture_passes
    stdout, stderr, status = run_validator

    assert status.success?, stderr
    assert_includes stdout, "PASS host adapter syntax"
  end

  def test_goal_must_be_inside_codex_branch
    File.write(File.join(@tmp, "workflows/demo.md"), "Use `/goal` here.\n")

    _stdout, stderr, status = run_validator

    refute status.success?
    assert_includes stderr, "/goal must be inside a codex-only host branch"
  end

  def test_single_line_codex_allow_marker_permits_goal
    File.write(File.join(@tmp, "workflows/demo.md"), "Use `/goal` here. <!-- host-allow: codex-only -->\n")

    stdout, stderr, status = run_validator

    assert status.success?, stderr
    assert_includes stdout, "PASS host adapter syntax"
  end

  def test_worktree_pair_must_include_both_hosts
    path = File.join(@tmp, "skills/demo/SKILL.md")
    text = File.read(path).sub(" and `isolation: 'worktree'`", "")
    File.write(path, text)

    _stdout, stderr, status = run_validator

    refute status.success?
    assert_includes stderr, "worktree isolation must mention both"
  end

  def test_available_tool_needs_fallback_language
    path = File.join(@tmp, "skills/demo/SKILL.md")
    text = <<~MARKDOWN
      ---
      name: demo
      description: Demo.
      ---

      Run `codex review`.
    MARKDOWN
    File.write(path, text)

    _stdout, stderr, status = run_validator

    refute status.success?
    assert_includes stderr, "codex review needs availability-check"
  end

  def test_host_specific_slash_command_needs_fallback_language
    path = File.join(@tmp, "skills/demo/SKILL.md")
    text = <<~MARKDOWN
      ---
      name: demo
      description: Demo.
      ---

      Run `/address-review`.
    MARKDOWN
    File.write(path, text)

    _stdout, stderr, status = run_validator

    refute status.success?
    assert_includes stderr, "/address-review needs availability-check"
  end

  def test_host_branch_markers_must_be_balanced
    File.write(File.join(@tmp, "workflows/demo.md"), <<~MARKDOWN)
      <!-- host-branch: codex-only start -->
      Use `/goal` here.
    MARKDOWN

    _stdout, stderr, status = run_validator

    refute status.success?
    assert_includes stderr, "codex-only host branch start missing end"
  end
end
