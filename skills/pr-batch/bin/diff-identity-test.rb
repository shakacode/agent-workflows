#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"

SCRIPT = File.expand_path("diff-identity", __dir__)
load SCRIPT

class DiffIdentityTest < Minitest::Test
  BASE_SHA = "b" * 40
  HEAD_SHA = "a" * 40

  def test_derives_sha256_from_the_versioned_length_delimited_serialization
    serialization = [
      "diff-identity-v1",
      "base_ref", "4", "main",
      "base_sha", "40", BASE_SHA,
      "head_sha", "40", HEAD_SHA,
      ""
    ].join("\0")

    assert_equal Digest::SHA256.hexdigest(serialization.b), DiffIdentity.derive(
      base_ref: "main", base_sha: BASE_SHA, head_sha: HEAD_SHA
    )
  end

  def test_changing_any_bound_component_changes_the_identity
    original = DiffIdentity.derive(base_ref: "main", base_sha: BASE_SHA, head_sha: HEAD_SHA)
    variants = [
      DiffIdentity.derive(base_ref: "release", base_sha: BASE_SHA, head_sha: HEAD_SHA),
      DiffIdentity.derive(base_ref: "main", base_sha: "c" * 40, head_sha: HEAD_SHA),
      DiffIdentity.derive(base_ref: "main", base_sha: BASE_SHA, head_sha: "d" * 40)
    ]

    refute_includes variants, original
    assert_equal variants.length, variants.uniq.length
  end

  def test_cli_rejects_noncanonical_sha_and_ref_inputs
    cases = [
      ["--base-ref", " main", "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA],
      ["--base-ref", "main", "--base-sha", BASE_SHA.upcase, "--head-sha", HEAD_SHA],
      ["--base-ref", "main", "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA[0, 39]]
    ]

    cases.each do |arguments|
      _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *arguments)

      refute status.success?, arguments.inspect
      assert_match(/Error:/, err, arguments.inspect)
    end
  end

  def test_rejects_noncanonical_git_ref_inputs
    invalid_refs = [
      "foo//bar",
      "foo/",
      ".",
      "foo.lock",
      "foo\0bar",
      "\xFF".b
    ]

    invalid_refs.each do |base_ref|
      assert_raises(DiffIdentity::Error, base_ref.inspect) do
        DiffIdentity.derive(base_ref:, base_sha: BASE_SHA, head_sha: HEAD_SHA)
      end
    end
  end
end
