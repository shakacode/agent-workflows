#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
HOSTED_QA_GATE_KEY = "hosted_qa_gate"
HOSTED_QA_GATE_RULE = "When `hosted_qa_gate` applies, only exact-current-head hosted runtime QA " \
                      "with every required acceptance criterion observed may satisfy readiness; " \
                      "a successful deployment, local tests, system tests, or static review cannot substitute."
NON_WAIVABLE_RULE = "A `hosted_qa_gate` that declares itself non-waivable remains a hard blocker " \
                    "until satisfied; hosted-CI waivers, maintainer risk acceptance, and application-level " \
                    "readiness do not bypass it."

class HostedQaGateContractTest < Minitest::Test
  def test_seam_requires_a_hosted_qa_gate_policy
    doctor = File.read(File.join(ROOT, "bin/agent-workflow-seam-doctor"), encoding: "UTF-8")
    example = File.read(File.join(ROOT, "examples/agent-workflow.yml"), encoding: "UTF-8")
    seam_docs = File.read(File.join(ROOT, "docs/seam-design.md"), encoding: "UTF-8")

    assert_includes doctor, HOSTED_QA_GATE_KEY
    assert_includes example, "#{HOSTED_QA_GATE_KEY}:"
    assert_includes seam_docs, "`#{HOSTED_QA_GATE_KEY}`"
  end

  def test_readiness_entry_points_fail_closed_on_required_hosted_qa
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/pr-monitoring/SKILL.md
      skills/manual-testing/SKILL.md
    ].each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8").gsub(/\s+/, " ")

      assert_includes text, HOSTED_QA_GATE_RULE, path
      assert_includes text, NON_WAIVABLE_RULE, path
    end
  end
end
