#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"

SCRIPT = File.expand_path("check-control-tower-prompt-size", __dir__)
load SCRIPT

class CheckControlTowerPromptSizeTest < Minitest::Test
  def with_doc(markdown)
    Dir.mktmpdir("control-tower-prompt-size-test") do |root|
      path = File.join(root, ControlTowerPromptSize::DOCUMENT)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, markdown)
      yield root
    end
  end

  def run_check(markdown)
    out = StringIO.new
    err = StringIO.new
    status = nil
    with_doc(markdown) do |root|
      original_out = $stdout
      original_err = $stderr
      $stdout = out
      $stderr = err
      begin
        status = ControlTowerPromptSize.run(root)
      ensure
        $stdout = original_out
        $stderr = original_err
      end
    end
    [status, out.string, err.string]
  end

  def prompt_section(heading, body)
    "## #{heading}\n\nIntro.\n\n```text\n#{body}\n```\n\n"
  end

  def test_passes_when_every_prompt_is_within_budget
    doc = prompt_section("Agent Workflows Control Tower Goal", "a" * 10) +
          prompt_section("Dashboard Goal — Run Later", "b" * 20) +
          prompt_section("Generic Repository Control Tower Template", "c" * 30) +
          "## Snapshot And Desk Contract\n\n```text\n#{'x' * 5_000}\n```\n"
    status, out, err = run_check(doc)

    assert_equal 0, status, err
    assert_includes out, "OK Agent Workflows Control Tower Goal: 10/3000 chars"
    assert_includes out, "OK Dashboard Goal — Run Later: 20/3000 chars"
    assert_includes out, "OK Generic Repository Control Tower Template: 30/3000 chars"
    refute_includes out, "5000"
  end

  def test_counts_newlines_between_lines_but_not_fence_lines
    doc = prompt_section("Human Attention Desk Goal", "ab\ncd")
    status, out, = run_check(doc)

    assert_equal 0, status
    assert_includes out, "OK Human Attention Desk Goal: 5/3000 chars"
  end

  def test_fails_when_a_prompt_exceeds_the_budget
    doc = prompt_section("Agent Coordination Control Tower Goal", "a" * 3_001)
    status, out, err = run_check(doc)

    assert_equal 1, status
    assert_includes out, "FAIL Agent Coordination Control Tower Goal: 3001/3000 chars"
    assert_includes err, "Agent Coordination Control Tower Goal exceeds 3000 characters"
  end

  def test_fails_when_a_prompt_section_has_no_text_block
    doc = "## Agent Workflows Control Tower Goal\n\nProse only.\n\n" \
          "## Snapshot And Desk Contract\n"
    status, _out, err = run_check(doc)

    assert_equal 1, status
    assert_includes err, "Agent Workflows Control Tower Goal has no ```text prompt block"
  end

  def test_fails_when_no_prompt_block_exists
    status, _out, err = run_check("# Title\n\n## Snapshot And Desk Contract\n")

    assert_equal 1, status
    assert_includes err, "no prompt block found"
  end

  def test_ignores_non_prompt_sections_and_non_text_fences
    doc = "## What Each Surface Is For\n\n```json\n{}\n```\n\n#{prompt_section('Human Attention Desk Goal', 'ok')}"
    status, out, = run_check(doc)

    assert_equal 0, status
    refute_includes out, "What Each Surface Is For"
    assert_includes out, "OK Human Attention Desk Goal: 2/3000 chars"
  end
end
