#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tempfile"

load File.expand_path("process-gap-mechanism-target", __dir__)

class ProcessGapMechanismTargetTest < Minitest::Test
  VALID_TARGETS = ProcessGapMechanismTarget::VALID_TARGETS

  def test_accepts_only_each_closed_vocabulary_value
    VALID_TARGETS.each do |target|
      assert_equal "valid", check(form_body(target)).fetch("status"), target
    end
  end

  def test_flags_the_exact_default_sentinel
    status = check(form_body(ProcessGapMechanismTarget::UNANSWERED)).fetch("status")

    assert_equal "unanswered", status
  end

  def test_rejects_a_value_outside_the_closed_vocabulary
    assert_equal "invalid", check(form_body("Script")).fetch("status")
  end

  def test_fails_closed_when_the_target_value_is_blank
    assert_equal "malformed", check(form_body("\n")).fetch("status")
  end

  def test_fails_closed_when_the_target_has_multiple_values
    assert_equal "malformed", check(form_body("script\nschema")).fetch("status")
  end

  def test_fails_closed_when_the_target_heading_is_missing
    body = form_body("script").sub("### Mechanism target\n\nscript\n\n", "")

    assert_equal "malformed", check(body).fetch("status")
  end

  def test_fails_closed_when_the_target_heading_is_duplicated
    body = form_body("script").sub("### Motivating miss", "### Mechanism target\n\npark\n\n### Motivating miss")

    assert_equal "malformed", check(body).fetch("status")
  end

  def test_ignores_an_issue_without_the_process_gap_form_signature
    body = "### Mechanism target\n\nscript\n\n### Notes\n\nUnrelated issue.\n"

    assert_equal "not_process_gap", check(body).fetch("status")
  end

  def test_runner_reads_only_the_event_body_and_emits_the_fixed_contract
    Tempfile.create("process-gap-event") do |file|
      file.write(JSON.generate("issue" => { "body" => form_body("schema") }))
      file.flush
      out = StringIO.new
      err = StringIO.new

      exit_code = ProcessGapMechanismTarget::Runner.new(out:, err:).run([file.path])

      assert_equal 0, exit_code
      assert_empty err.string
      assert_equal(
        { "contract" => "process-gap-mechanism-target", "version" => 1, "status" => "valid" },
        JSON.parse(out.string)
      )
    end
  end

  private

  def check(body)
    ProcessGapMechanismTarget.check(body)
  end

  def form_body(target)
    <<~BODY
      ### Gap

      A recurring process miss.

      ### Mechanism target

      #{target}

      ### Motivating miss

      #495

      ### Replay evidence or park reason

      Run the focused test.

      ### Non-goal

      Do not lint unrelated issue fields.
    BODY
  end
end
