#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class TddContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SKILL = File.join(ROOT, "skills/tdd/SKILL.md")
  WORKFLOW = File.join(ROOT, "workflows/tdd.md")

  def test_skill_and_workflow_pin_the_three_requested_refinements
    [SKILL, WORKFLOW].each do |path|
      text = File.read(path, encoding: "UTF-8").gsub(/\s+/, " ")

      phrases = [
        "record `NO_HARNESS` honestly; do not invent fake prose coverage for `skills/**` or `workflows/**` changes",
        "revert the smallest self-consistent set of hunks that still runs",
        "fall back to the full local revert of the behavior's files rather than forcing a broken partial revert",
        "For a two-behavior change, report two receipts",
        "one `COVERAGE` line for the runnable behavior",
        "one `COVERAGE SKIPPED NO_HARNESS` line for the prose-only behavior"
      ]

      positions = phrases.map do |phrase|
        position = text.index(phrase)
        assert position, "#{path}: expected #{phrase.inspect}"
        position
      end

      positions.each_cons(2) { |before, after| assert_operator before, :<, after, path }
    end
  end
end
