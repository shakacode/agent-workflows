#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("../../..", __dir__)
SKILL_PATH = File.join(ROOT, "skills/tdd/SKILL.md")
WORKFLOW_PATH = File.join(ROOT, "workflows/tdd.md")
REFERENCE_PATH = File.join(ROOT, "skills/tdd/references/writing-good-tests.md")
VALIDATE_PATH = File.join(ROOT, "bin/validate")
NOTICE_PATH = File.join(ROOT, "THIRD_PARTY-NOTICES.md")

class TddQualityContractTest < Minitest::Test
  PUBLISHER_EXAMPLE = <<~'RUBY'
    mutation, receipt_path, invoice_id = ARGV
    published_id = mutation == "wrong_argument" ? "invoice-41" : invoice_id
    File.write(receipt_path, "#{published_id}\n") unless mutation == "missing_side_effect"
    print "published #{published_id}\n" unless mutation == "empty_default_result"
    exit(mutation == "failure_status" ? 1 : 0)
  RUBY

  def read(path)
    File.read(path, encoding: "UTF-8")
  end

  def normalized_reference
    read(REFERENCE_PATH).gsub(/\s+/, " ").strip
  end

  def run_publisher_example(mutation)
    Dir.mktmpdir("tdd-quality") do |directory|
      receipt_path = File.join(directory, "receipt.txt")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-e",
        PUBLISHER_EXAMPLE,
        mutation,
        receipt_path,
        "invoice-42"
      )
      receipt = File.exist?(receipt_path) ? File.read(receipt_path, encoding: "UTF-8") : ""

      return { stdout: stdout, stderr: stderr, exit_status: status.exitstatus, receipt: receipt }
    end
  end

  def assert_publisher_behavior(result)
    assert_equal "published invoice-42\n", result.fetch(:stdout)
    assert_equal "", result.fetch(:stderr)
    assert_equal 0, result.fetch(:exit_status)
    assert_equal "invoice-42\n", result.fetch(:receipt)
  end

  def test_entrypoints_route_to_a_registered_reference_and_keep_the_core_loop_synchronized
    skill = read(SKILL_PATH)
    workflow = read(WORKFLOW_PATH)
    validation = read(VALIDATE_PATH)

    # These assertions prove source and packaging invariants, not agent behavior.
    assert_path_exists REFERENCE_PATH
    assert_includes skill, "[Writing Good Tests](references/writing-good-tests.md)"
    assert_includes workflow, "[Writing Good Tests](../skills/tdd/references/writing-good-tests.md)"
    assert_equal skill[skill.index("## Core Loop")..], workflow[workflow.index("## Core Loop")..]
    assert_includes validation, "ruby skills/tdd/bin/tdd-quality-contract-test.rb"

    [skill, workflow].each do |entrypoint|
      assert_includes entrypoint, "RED -> GREEN -> REFACTOR -> repeat"
      assert_includes entrypoint, "Prefer tests through public interfaces and real code paths"
      assert_includes entrypoint, "Never claim a bug is fixed without evidence"
      assert_includes entrypoint, "Only when a direct automated regression test is not practical"
      assert_includes entrypoint, "If the change affects a developer workflow"
      assert_includes entrypoint, "If the change affects app-facing behavior"
      assert_includes entrypoint, "run `.agents/bin/validate`"
    end
  end

  def test_reference_defines_the_falsifiable_test_quality_contract
    reference = normalized_reference

    # Exact prose checks protect the documented contract only.
    assert_includes reference, "Before writing a test body, name one realistic production break it should catch"
    assert_includes reference, "wrong branch, value, or argument"
    assert_includes reference, "missing side effect"
    assert_includes reference, "boundary or validation failure"
    assert_includes reference, "empty or default result"
    assert_includes reference, "redesign the test around observable behavior"
    assert_includes reference, "literal expected values or independently hand-checked fixtures"
    assert_includes reference, "explicitly named characterization test backed by independent evidence"
    assert_includes reference, "prove only source or packaging invariants"
    assert_includes reference, "cannot prove runtime behavior or that an agent follows prose"
    assert_includes reference, "outputs, side effects, exit status, or consuming-agent behavior"
    assert_includes reference, "Reject constant and private-structure change detectors"
    assert_includes reference, "Mock only slow or external boundaries"
    assert_includes reference, "realistic and complete doubles"
    assert_includes reference, "The existence of a mock is not behavioral proof"
    assert_includes reference, "small, finite set of realistic failure modes"
    assert_includes reference, "Do not require mutation-testing software"
    assert_includes reference, "Superpowers v6.2.0"
    assert_includes reference, "44c9b2d6e889982ac18c27d05a19fefe335194e1"
    assert_includes reference, "MIT License"
  end

  def test_substantial_adaptation_routes_to_the_complete_pack_notice
    reference = read(REFERENCE_PATH)
    notice = read(NOTICE_PATH)

    # These assertions prove source and packaging invariants, not license compliance.
    assert_includes reference, "[third-party notice](../../../THIRD_PARTY-NOTICES.md)"
    assert_includes notice, "## obra/superpowers"
    assert_includes notice, "Copyright (c) 2025 Jesse Vincent"
    assert_includes notice, "The above copyright notice and this permission notice"
    assert_includes notice, "44c9b2d6e889982ac18c27d05a19fefe335194e1/LICENSE"
  end

  def test_one_behavior_assertion_rejects_realistic_script_mutations
    assert_includes normalized_reference, "the same behavior assertion"

    assert_publisher_behavior(run_publisher_example("none"))
    %w[wrong_argument missing_side_effect empty_default_result failure_status].each do |mutation|
      assert_raises(Minitest::Assertion, mutation) do
        assert_publisher_behavior(run_publisher_example(mutation))
      end
    end
  end

  def test_reference_classifies_delete_substring_checks_as_source_only
    reference = normalized_reference

    assert_includes reference, "deletion guarantees the absence assertion"
    assert_includes reference, "It exercises no artifact or consumer"
  end
end
