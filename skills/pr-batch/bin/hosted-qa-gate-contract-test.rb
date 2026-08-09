#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("../../..", __dir__)
DELEGATION = "Use the trusted-base `hosted-qa-readiness` helper and the canonical hosted QA contract " \
             "in `workflows/pr-processing.md`; do not reproduce or reinterpret that contract here."

class HostedQaGateContractTest < Minitest::Test
  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def test_first_phase_seam_is_optional_and_example_is_n_a
    doctor = read("bin/agent-workflow-seam-doctor")
    required_keys = doctor[/REQUIRED_POLICY_KEYS = %w\[(.*?)\]\.freeze/m, 1]
    example = YAML.safe_load(read("examples/agent-workflow.yml"), aliases: false)

    refute_includes required_keys, "hosted_qa_gate"
    assert_equal "n/a", example.fetch("hosted_qa_gate")
    assert_includes read("docs/seam-design.md"), "optional closed mapping"
  end

  def test_canonical_workflow_owns_the_executable_contract
    workflow = read("workflows/pr-processing.md")

    assert_includes workflow, "hosted-qa-evidence v1"
    assert_includes workflow, "Generic `qa-evidence v2` never proves a hosted deployment"
    assert_includes workflow, "hosted-qa-readiness"
    assert_includes workflow, "BOOTSTRAP_ALLOWED"
    assert_includes workflow, "qa-maintainer-waiver v1"
  end

  def test_entry_point_skills_delegate_without_copying_the_contract
    %w[
      skills/pr-batch/SKILL.md
      skills/pr-monitoring/SKILL.md
      skills/manual-testing/SKILL.md
    ].each do |path|
      text = read(path).gsub(/\s+/, " ")

      assert_includes text, DELEGATION, path
      refute_includes text, "criterion: id=", path
    end
  end
end
