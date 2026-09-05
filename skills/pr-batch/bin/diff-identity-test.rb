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
  DIFF_BASE_SHA = "b" * 40
  HEAD_SHA = "a" * 40

  def test_derives_sha256_from_versioned_length_delimited_serialization
    serialization = [
      "diff-identity-v1",
      "base_ref", "4", "main",
      "diff_base_sha", "40", DIFF_BASE_SHA,
      "head_sha", "40", HEAD_SHA,
      ""
    ].join("\0").b

    assert_equal Digest::SHA256.hexdigest(serialization), DiffIdentity.derive(
      base_ref: "main", diff_base_sha: DIFF_BASE_SHA, head_sha: HEAD_SHA
    )
  end

  def test_changing_any_member_changes_the_identity
    original = identity
    variants = [
      identity(base_ref: "release"),
      identity(diff_base_sha: "c" * 40),
      identity(head_sha: "d" * 40)
    ]

    refute_includes variants, original
    assert_equal variants.length, variants.uniq.length
  end

  def test_rejects_noncanonical_refs
    invalid_refs = [
      " main", "-main", "/main", "foo/", ".", ".foo", "foo.lock",
      "foo//bar", "foo..bar", "foo@{1}", "foo~bar", "foo^bar", "foo:bar",
      "foo?bar", "foo*bar", "foo[bar", "foo\\bar", "foo\0bar", "\xFF".b
    ]

    invalid_refs.each do |base_ref|
      assert_raises(DiffIdentity::Error, base_ref.inspect) { identity(base_ref:) }
    end
  end

  def test_rejects_noncanonical_shas
    ["a" * 39, "A" * 40, "g" * 40, nil].each do |value|
      assert_raises(DiffIdentity::Error, value.inspect) { identity(diff_base_sha: value) }
      assert_raises(DiffIdentity::Error, value.inspect) { identity(head_sha: value) }
    end
  end

  def test_cli_json_emits_the_canonical_members_and_identity
    out, err, status = Open3.capture3(
      RbConfig.ruby, SCRIPT,
      "--base-ref", "feature/café",
      "--diff-base-sha", DIFF_BASE_SHA,
      "--head-sha", HEAD_SHA,
      "--json"
    )

    assert status.success?, err
    assert_empty err
    assert_equal(
      {
        "contract" => "diff-identity",
        "version" => 1,
        "base_ref" => "feature/café",
        "diff_base_sha" => DIFF_BASE_SHA,
        "head_sha" => HEAD_SHA,
        "diff_identity" => identity(base_ref: "feature/café")
      },
      JSON.parse(out)
    )
  end

  def test_cli_rejects_invalid_utf8_without_a_backtrace
    _out, err, status = Open3.capture3(
      { "LC_ALL" => "C" }, RbConfig.ruby, SCRIPT,
      "--base-ref", "feature/\xFF".b,
      "--diff-base-sha", DIFF_BASE_SHA,
      "--head-sha", HEAD_SHA
    )

    refute status.success?
    assert_equal "Error: --base-ref must contain valid UTF-8 bytes\n", err
  end

  private

  def identity(base_ref: "main", diff_base_sha: DIFF_BASE_SHA, head_sha: HEAD_SHA)
    DiffIdentity.derive(base_ref:, diff_base_sha:, head_sha:)
  end
end
