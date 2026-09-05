#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

SCRIPT = File.expand_path("verification-evidence-reuse", __dir__)
load SCRIPT

class VerificationEvidenceReuseTest < Minitest::Test
  def request
    context = {
      "head_sha" => "a" * 40, "base_sha" => "b" * 40,
      "environment" => "ruby-3.4/macos/dependencies-sha256:abc",
      "configuration" => "sha256:def", "command" => ["ruby", "test/example.rb"],
      "covered_paths" => ["src/example.rb", "test/example.rb"], "working_tree" => "clean"
    }
    {
      "version" => 1, "repeat_required" => false, "current" => context,
      "evidence" => context.merge("kind" => "local-command", "outcome" => "pass", "evidence_ref" => "/verified/run-1.log")
    }
  end

  def test_same_verified_command_can_be_consumed_by_the_next_stage
    result = VerificationEvidenceReuse.call(request)

    assert_equal "reusable", result["status"]
    assert_equal "/verified/run-1.log", result["evidence_ref"]
    assert_equal "local-command-only", result["scope"]
  end

  def test_each_context_change_invalidates_evidence
    VerificationEvidenceReuse::CONTEXT_FIELDS.each do |field|
      input = request
      value = input["current"][field]
      input["current"][field] = value.is_a?(Array) ? value + ["new"] : "c" * 40

      assert_equal "rerun", VerificationEvidenceReuse.call(input)["status"], field
    end
  end

  def test_missing_unknown_and_malformed_context_never_reuses
    VerificationEvidenceReuse::CONTEXT_FIELDS.each do |field|
      [nil, "UNKNOWN", "", {}, []].each do |value|
        input = request
        input["evidence"][field] = value
        input["current"][field] = value

        assert_equal "rerun", VerificationEvidenceReuse.call(input)["status"], "#{field}: #{value.inspect}"
      end
    end
  end

  def test_required_repeat_dirty_tree_failure_and_hosted_evidence_rerun
    [
      [[], "repeat_required", true], [[], "repeat_required", nil],
      [["current"], "working_tree", "dirty"], [["evidence"], "working_tree", "dirty"],
      [["evidence"], "outcome", "fail"], [["evidence"], "outcome", "partial"],
      [["evidence"], "kind", "hosted-ci"],
      [["evidence"], "kind", "independent-review"], [["evidence"], "evidence_ref", "UNKNOWN"]
    ].each do |path, key, value|
      input = request
      target = path.empty? ? input : input.dig(*path)
      target[key] = value

      assert_equal "rerun", VerificationEvidenceReuse.call(input)["status"], [path, key, value].inspect
    end
  end

  def test_cli_returns_reusable_evidence_and_rejects_duplicate_keys
    output, _error, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: JSON.generate(request))
    assert status.success?
    assert_equal "reusable", JSON.parse(output)["status"]

    ['{"version":1,"version":1}', '{"current":{"head_sha":"a","head_sha":"b"}}', "not-json"].each do |input|
      output, _error, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: input)
      refute status.success?
      assert_equal "rerun", JSON.parse(output)["status"]
    end
  end
end
