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

  def test_contract_version_and_serialization_domain_are_locked_to_v1
    assert_equal "diff-identity", DiffIdentity::CONTRACT
    assert_equal 1, DiffIdentity::VERSION
    assert_equal "diff-identity-v1", DiffIdentity::SERIALIZATION_TAG
    assert_equal "diff-identity-v1", DiffIdentity.serialization(
      base_ref: "main", base_sha: BASE_SHA, head_sha: HEAD_SHA
    ).split("\0", 2).first
  end

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

  def test_rejects_every_forbidden_ref_character_and_leading_dash
    invalid_refs = [
      "feature~name", "feature^name", "feature:name", "feature?name",
      "feature*name", "feature[name", "feature\\name", "-main"
    ]

    invalid_refs.each do |base_ref|
      assert_raises(DiffIdentity::Error, base_ref.inspect) do
        DiffIdentity.derive(base_ref:, base_sha: BASE_SHA, head_sha: HEAD_SHA)
      end
    end
  end

  def test_accepts_bare_at_as_a_canonical_git_branch_name
    identity = DiffIdentity.derive(base_ref: "@", base_sha: BASE_SHA, head_sha: HEAD_SHA)

    assert_match(/\A[0-9a-f]{64}\z/, identity)
  end

  def test_rejects_embedded_reflog_syntax
    assert_raises(DiffIdentity::Error) do
      DiffIdentity.derive(base_ref: "main@{1}", base_sha: BASE_SHA, head_sha: HEAD_SHA)
    end
  end

  def test_rejects_ascii_control_space_and_delete_bytes
    ((0x00..0x20).to_a + [0x7f]).each do |byte|
      base_ref = "a#{byte.chr}b".force_encoding(Encoding::UTF_8)

      assert_raises(DiffIdentity::Error, "byte 0x#{byte.to_s(16)}") do
        DiffIdentity.derive(base_ref:, base_sha: BASE_SHA, head_sha: HEAD_SHA)
      end
    end
  end

  def test_cli_accepts_git_valid_unicode_ref_bytes_independent_of_locale
    ["a\u00A0b", "a\u0085b"].each do |base_ref|
      out, err, status = Open3.capture3(
        { "LC_ALL" => "C" }, RbConfig.ruby, SCRIPT,
        "--base-ref", base_ref, "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA
      )

      assert status.success?, "#{base_ref.inspect}: #{err}"
      assert_empty err
      assert_equal DiffIdentity.derive(base_ref:, base_sha: BASE_SHA, head_sha: HEAD_SHA), out.strip
    end
  end

  def test_cli_interprets_canonical_ref_bytes_as_utf8_independent_of_locale
    ["main", "feature/café"].each do |base_ref|
      out, err, status = Open3.capture3(
        { "LC_ALL" => "C" }, RbConfig.ruby, SCRIPT,
        "--base-ref", base_ref, "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA
      )

      assert status.success?, err
      assert_empty err
      assert_equal DiffIdentity.derive(base_ref:, base_sha: BASE_SHA, head_sha: HEAD_SHA), out.strip
    end
  end

  def test_cli_rejects_invalid_utf8_ref_bytes_independent_of_locale
    _out, err, status = Open3.capture3(
      { "LC_ALL" => "C" }, RbConfig.ruby, SCRIPT,
      "--base-ref", "feature/\xFF".b, "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA
    )

    refute status.success?
    assert_equal "Error: --base-ref must contain valid UTF-8 bytes\n", err
  end

  def test_cli_rejects_invalid_utf8_sha_bytes_without_a_backtrace
    environments = [{ "name" => "inherited", "variables" => {} }]
    locales, locale_status = Open3.capture2e("locale", "-a")
    if locale_status.success? && locales.lines.any? { |locale| locale.strip.casecmp?("C.UTF-8") }
      environments << { "name" => "C.UTF-8", "variables" => { "LC_ALL" => "C.UTF-8" } }
    end

    environments.product(%w[--base-sha --head-sha]).each do |environment, option|
      arguments = ["--base-ref", "main", "--base-sha", BASE_SHA, "--head-sha", HEAD_SHA]
      arguments[arguments.index(option) + 1] = "\xFF".b
      _out, err, status = Open3.capture3(environment.fetch("variables"), RbConfig.ruby, SCRIPT, *arguments)

      label = "#{environment.fetch('name')} #{option}"
      refute status.success?, label
      assert_equal "Error: #{option} must contain valid UTF-8 bytes\n", err, label
      refute_match(/optparse\.rb|diff-identity:\d+|ArgumentError/, err, label)
    end
  end
end
