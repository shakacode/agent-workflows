#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

PREFLIGHT_PATH = File.expand_path("untrusted-contributor-intake-preflight", __dir__)
PREFLIGHT_SOURCE = File.read(PREFLIGHT_PATH, encoding: "UTF-8")

# Ambient values that must never authorize or influence a preflight run.
AMBIENT_ENV_KEYS = %w[
  GH_HOST GH_REPO PR_REF PR_INPUT_KIND PR_NUMBER PR_REF_NUMBER REPO CANONICAL_URL
  TRUSTED_GH_HOST TRUSTED_GH_SCHEME TRUSTED_GH_REPO
  UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_HOST
  UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_SCHEME
  UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_REPO
].freeze

TRUSTED_ORIGIN_BLOCKED = /BLOCKED: trusted origin is invalid/
PR_REF_BLOCKED = /BLOCKED: exact PR reference is invalid/
METADATA_BLOCKED = /BLOCKED: metadata resolution is invalid/
CANONICAL_BLOCKED = /BLOCKED: canonical authority absent or invalid/
CANONICAL_UNTRUSTED = /BLOCKED: canonical authority is not trusted/

GH_STUB = <<~SH
  #!/bin/sh
  printf 'GH_HOST=%s GH_REPO=%s %s\\n' "${GH_HOST-unset}" "${GH_REPO-unset}" "$*" >> "${GH_LOG}"
  printf '%s' "${GH_STUB_OUTPUT}"
  exit "${GH_STUB_STATUS}"
SH

# Runs the real helper with a stubbed `gh` on PATH and a scrubbed environment.
# Returns [success, stdout-or-stderr, recorded gh invocations].
def run_preflight(
  pr_ref: nil,
  trusted_host: "github.com",
  trusted_scheme: "https",
  trusted_repo: "octo-org/hello-world",
  gh_output: "",
  gh_status: 0,
  argv: nil,
  ambient: {},
  install_gh: true
)
  Dir.mktmpdir("untrusted-contributor-intake-preflight") do |directory|
    log_path = File.join(directory, "gh.log")

    if install_gh
      gh_path = File.join(directory, "gh")
      File.write(gh_path, GH_STUB, encoding: "UTF-8")
      File.chmod(0o755, gh_path)
    end

    environment = AMBIENT_ENV_KEYS.to_h { |key| [key, nil] }.merge(
      "GH_LOG" => log_path,
      "GH_STUB_OUTPUT" => gh_output,
      "GH_STUB_STATUS" => gh_status.to_s,
      "PATH" => "#{directory}:#{ENV.fetch('PATH')}"
    ).merge(ambient)
    environment["UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_HOST"] = trusted_host if trusted_host
    environment["UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_SCHEME"] = trusted_scheme if trusted_scheme
    environment["UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_REPO"] = trusted_repo if trusted_repo

    arguments = argv || (pr_ref.nil? ? [] : ["--pr-ref", pr_ref])
    stdout, stderr, status = Open3.capture3(environment, PREFLIGHT_PATH, *arguments)
    calls = File.exist?(log_path) ? File.readlines(log_path, chomp: true) : []

    [status.success?, status.success? ? stdout : stderr, calls]
  end
end

def preflight_values(output)
  output.lines(chomp: true).to_h { |line| line.split("=", 2) }
end

class UntrustedContributorIntakePreflightTest < Minitest::Test
  def test_helper_is_an_executable_stdlib_only_ruby_script
    assert File.executable?(PREFLIGHT_PATH), "the helper must be executable from a trusted base checkout"
    assert PREFLIGHT_SOURCE.start_with?("#!/usr/bin/env ruby\n")
    assert_equal ['require "open3"'], PREFLIGHT_SOURCE.scan(/^require .*$/)
  end

  def test_resolves_a_numeric_reference_with_one_metadata_only_lookup
    success, output, calls = run_preflight(
      pr_ref: "42",
      trusted_host: "ghe.example:8443",
      gh_output: "42|https://ghe.example:8443/octo-org/hello-world/pull/42"
    )

    assert success, output
    assert_equal(
      {
        "TRUSTED_GH_SCHEME" => "https",
        "TRUSTED_GH_HOST" => "ghe.example:8443",
        "TRUSTED_GH_REPO" => "octo-org/hello-world",
        "PR_INPUT_KIND" => "number",
        "PR_NUMBER" => "42",
        "PR_REF_NUMBER" => "",
        "REPO" => "octo-org/hello-world",
        "GH_HOST" => "ghe.example:8443",
        "CANONICAL_URL" => "https://ghe.example:8443/octo-org/hello-world/pull/42"
      },
      preflight_values(output)
    )
    assert_equal 1, calls.length
    assert_includes calls.first, "GH_HOST=ghe.example:8443"
    assert_includes calls.first, "GH_REPO=unset"
    assert_includes calls.first, "pr view 42 --repo octo-org/hello-world --json number,url"
    refute_includes calls.first, "repo view"
  end

  def test_resolves_an_exact_url_reference_by_validated_numeric_target
    success, output, calls = run_preflight(
      pr_ref: "https://ghe.example:8443/octo-org/hello-world/pull/42",
      trusted_host: "ghe.example:8443",
      gh_output: "42|https://ghe.example:8443/octo-org/hello-world/pull/42"
    )

    assert success, output
    values = preflight_values(output)

    assert_equal "url", values.fetch("PR_INPUT_KIND")
    assert_equal "42", values.fetch("PR_NUMBER")
    assert_equal "42", values.fetch("PR_REF_NUMBER")
    assert_equal "octo-org/hello-world", values.fetch("REPO")
    assert_equal 1, calls.length
    assert_includes calls.first, "pr view 42 --repo octo-org/hello-world --json number,url"
    refute_includes calls.first, "https://ghe.example:8443/octo-org/hello-world/pull/42"
  end

  def test_accepts_the_reference_from_the_environment_and_rejects_other_argument_shapes
    success, output, = run_preflight(
      argv: [],
      ambient: { "PR_REF" => "42" },
      gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
    )

    assert success, output
    assert_equal "number", preflight_values(output).fetch("PR_INPUT_KIND")

    [["42"], ["--pr-ref"], ["--pr-ref", "42", "extra"], ["--reference", "42"]].each do |argv|
      success, output, calls = run_preflight(
        argv: argv,
        gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{argv.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match PR_REF_BLOCKED, output
      assert_empty calls
    end
  end

  def test_normalizes_repository_and_host_identity_without_discarding_a_non_default_port
    success, output, calls = run_preflight(
      pr_ref: "https://ghe.example:8443/Octo-Org/Hello-World/pull/42",
      trusted_host: "GHE.EXAMPLE:8443",
      trusted_repo: "Octo-Org/Hello-World",
      gh_output: "42|https://ghe.example:8443/Octo-Org/Hello-World/pull/42"
    )

    assert success, output
    values = preflight_values(output)

    assert_equal "octo-org/hello-world", values.fetch("REPO")
    assert_equal "ghe.example:8443", values.fetch("GH_HOST")
    assert_equal "https://ghe.example:8443/Octo-Org/Hello-World/pull/42", values.fetch("CANONICAL_URL")
    assert_equal 1, calls.length
    assert_includes calls.first, "GH_HOST=ghe.example:8443"
  end

  def test_strips_only_the_https_default_port
    success, output, calls = run_preflight(
      pr_ref: "https://GHE.Example:443/octo-org/hello-world/pull/42",
      trusted_host: "GHE.EXAMPLE:443",
      gh_output: "42|https://GHE.Example:443/octo-org/hello-world/pull/42"
    )

    assert success, output
    assert_equal "ghe.example", preflight_values(output).fetch("GH_HOST")
    assert_includes calls.first, "GH_HOST=ghe.example"

    success, output, = run_preflight(
      pr_ref: "https://ghe.example:80/octo-org/hello-world/pull/42",
      trusted_host: "ghe.example:80",
      gh_output: "42|https://ghe.example:80/octo-org/hello-world/pull/42"
    )

    assert success, output
    assert_equal "ghe.example:80", preflight_values(output).fetch("GH_HOST")
  end

  def test_accepts_ipv4_and_maximum_length_dns_labels
    label_at_limit = "a" * 63

    [["127.0.0.1:8443", "127.0.0.1:8443"], ["#{label_at_limit}.example", "#{label_at_limit}.example"]].each do |host, expected|
      success, output, = run_preflight(
        pr_ref: "https://#{host}/octo-org/hello-world/pull/42",
        trusted_host: host,
        gh_output: "42|https://#{host}/octo-org/hello-world/pull/42"
      )

      assert success, output
      assert_equal expected, preflight_values(output).fetch("GH_HOST")
    end
  end

  def test_requires_complete_explicit_https_trusted_policy_before_any_network_call
    [
      { trusted_host: nil },
      { trusted_scheme: nil },
      { trusted_repo: nil },
      { trusted_host: nil, trusted_scheme: nil },
      { trusted_host: nil, trusted_repo: nil },
      { trusted_scheme: nil, trusted_repo: nil },
      { trusted_host: nil, trusted_scheme: nil, trusted_repo: nil },
      { trusted_host: "" },
      { trusted_scheme: "" },
      { trusted_repo: "" },
      { trusted_scheme: "http" },
      { trusted_scheme: "HTTPS" },
      { trusted_scheme: "ssh" }
    ].each do |policy|
      success, output, calls = run_preflight(
        **policy,
        pr_ref: "42",
        gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{policy.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match TRUSTED_ORIGIN_BLOCKED, output
      assert_empty calls
    end
  end

  def test_blocks_a_malformed_trusted_host_before_pr_ref_classification_or_network
    [
      "ghe..example",
      ".ghe.example",
      "ghe.example.",
      "-ghe.example",
      "ghe-.example",
      "#{'a' * 64}.example",
      "git_hub.example",
      "user@ghe.example",
      "ghe.example/octo-org",
      "ghe.example?query",
      "ghe.example#fragment",
      "ghe.example\ncontrol",
      "ghe.example]",
      "[2001:db8::1]",
      "ghe example",
      "ghe.example:abc",
      "ghe.example:",
      "ghe.example:8443:9443",
      "ghe.example:0",
      "ghe.example:65536",
      "ghe.example:999999999999999999999999"
    ].each do |trusted_host|
      success, output, calls = run_preflight(
        pr_ref: "not-an-exact-pr-reference",
        trusted_host: trusted_host,
        gh_output: "42|https://ghe.example/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{trusted_host.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match TRUSTED_ORIGIN_BLOCKED, output
      assert_empty calls
    end
  end

  def test_blocks_an_incomplete_or_unsafe_trusted_repository_before_any_network_call
    %w[
      octo-org
      octo-org/
      /hello-world
      octo-org/hello/world
      ../hello-world
      octo-org/..
      ./hello-world
      octo-org/.
      octo-org/hello;world
      octo$org/hello-world
      octo-org/hello%2Fworld
    ].each do |trusted_repo|
      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_repo: trusted_repo,
        gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{trusted_repo.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match TRUSTED_ORIGIN_BLOCKED, output
      assert_empty calls
    end
  end

  def test_ambient_intake_state_cannot_authorize_or_redirect_a_run
    hostile = {
      "TRUSTED_GH_HOST" => "ambient.example:8443",
      "TRUSTED_GH_SCHEME" => "https",
      "TRUSTED_GH_REPO" => "ambient-org/ambient-repo",
      "GH_HOST" => "ambient.example",
      "GH_REPO" => "ambient-org/ambient-repo",
      "PR_NUMBER" => "999",
      "REPO" => "ambient-org/ambient-repo",
      "CANONICAL_URL" => "https://ambient.example/ambient-org/ambient-repo/pull/999"
    }

    success, output, calls = run_preflight(
      pr_ref: "42",
      trusted_host: nil,
      trusted_scheme: nil,
      trusted_repo: nil,
      ambient: hostile,
      gh_output: "42|https://ambient.example/ambient-org/ambient-repo/pull/999"
    )

    refute success, "ambient TRUSTED_GH_* state must not authorize intake"
    assert_match TRUSTED_ORIGIN_BLOCKED, output
    assert_empty calls

    success, output, calls = run_preflight(
      pr_ref: "42",
      ambient: hostile,
      gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
    )

    assert success, output
    assert_equal "github.com", preflight_values(output).fetch("GH_HOST")
    assert_equal 1, calls.length
    assert_includes calls.first, "GH_HOST=github.com"
    assert_includes calls.first, "GH_REPO=unset"
  end

  def test_blocks_every_inexact_pr_reference_before_any_network_call
    [
      "",
      "main",
      "feature/name",
      "owner/repo#branch",
      "refs/heads/main",
      "42main",
      "ftp://github.com/octo-org/hello-world/pull/42",
      "http://github.com/octo-org/hello-world/pull/42",
      "github.com/octo-org/hello-world/pull/42",
      "https:///octo-org/hello-world/pull/42",
      "https://github.example:abc/octo-org/hello-world/pull/42",
      "https://github.example:/octo-org/hello-world/pull/42",
      "https://github.example:8443:9443/octo-org/hello-world/pull/42",
      "https://[2001:db8::1]/octo-org/hello-world/pull/42",
      "https://github example/octo-org/hello-world/pull/42",
      "https://github\\example/octo-org/hello-world/pull/42",
      "https://github%2Eexample/octo-org/hello-world/pull/42",
      "https://-github.example/octo-org/hello-world/pull/42",
      "https://github-.example/octo-org/hello-world/pull/42",
      "https://github..example/octo-org/hello-world/pull/42",
      "https://#{'a' * 64}.example/octo-org/hello-world/pull/42",
      "https://github.com/octo-org/hello-world/issues/42",
      "https://github.com/octo-org/hello-world/pull",
      "https://github.com/octo-org/hello-world/pull/42/extra",
      "https://github.com/octo-org/hello-world/pull/42?query",
      "https://github.com/octo-org/hello-world/pull/42#fragment",
      "https://github.com/octo-org/hello-world/pull/42/",
      "https://github.com/octo-org/hello-world/pull/not-a-number",
      "https://github.com/octo%2Dorg/hello-world/pull/42",
      "https://github.com/octo%2Forg/hello-world/pull/42",
      "https://github.com/octo%5Corg/hello-world/pull/42",
      "https://github.com/../hello-world/pull/42",
      "https://github.com/octo-org/../pull/42",
      "https://github.com/./hello-world/pull/42",
      "https://github.com//hello-world/pull/42",
      "https://github.com/octo-org//pull/42",
      "https://user@github.com/octo-org/hello-world/pull/42",
      "https://github.com/octo$org/hello-world/pull/42",
      "https://github.com/octo-org/hello;world/pull/42",
      "https://github.com/octo\norg/hello-world/pull/42",
      "https://github.com/octo-org/hello\tworld/pull/42"
    ].each do |pr_ref|
      success, output, calls = run_preflight(
        pr_ref: pr_ref,
        gh_output: "42|https://github.com/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{pr_ref.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match PR_REF_BLOCKED, output
      assert_empty calls
    end
  end

  def test_url_input_must_target_the_trusted_authority_and_repository_before_any_network_call
    [
      "https://untrusted.example/octo-org/hello-world/pull/42",
      "https://github.com/octo-org/hello-world/pull/42",
      "https://ghe.example/octo-org/hello-world/pull/42",
      "https://ghe.example:9443/octo-org/hello-world/pull/42",
      "https://ghe.example:8443/other-org/hello-world/pull/42",
      "https://ghe.example:8443/octo-org/other-repo/pull/42"
    ].each do |pr_ref|
      success, output, calls = run_preflight(
        pr_ref: pr_ref,
        trusted_host: "ghe.example:8443",
        gh_output: "42|https://ghe.example:8443/octo-org/hello-world/pull/42"
      )

      refute success, "expected #{pr_ref.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match METADATA_BLOCKED, output
      assert_empty calls
    end
  end

  def test_blocks_malformed_or_failed_metadata_records_after_exactly_one_lookup
    [
      { gh_output: "", gh_status: 1 },
      { gh_output: "42|https://github.com/octo-org/hello-world/pull/42", gh_status: 1 },
      { gh_output: "" },
      { gh_output: "42" },
      { gh_output: "|https://github.com/octo-org/hello-world/pull/42" },
      { gh_output: "42|" },
      { gh_output: "42|https://github.com/octo-org/hello-world/pull/42|extra" },
      { gh_output: "42|https://github.com/o/r/pull/42\n43|https://github.com/o/r/pull/43" },
      { gh_output: "not-a-number|https://github.com/octo-org/hello-world/pull/42" },
      { gh_output: "43|https://github.com/octo-org/hello-world/pull/43" },
      { gh_output: "42|ftp://github.com/octo-org/hello-world/pull/42" },
      { gh_output: "42|http://github.com/octo-org/hello-world/pull/42" },
      { gh_output: "octo-org/hello-world|https://github.com/octo-org/hello-world" }
    ].each do |scenario|
      success, output, calls = run_preflight(pr_ref: "42", **scenario)

      refute success, "expected #{scenario.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match METADATA_BLOCKED, output
      assert_equal 1, calls.length
    end
  end

  def test_blocks_when_the_gh_command_is_unavailable
    Dir.mktmpdir("untrusted-contributor-intake-preflight") do |directory|
      environment = AMBIENT_ENV_KEYS.to_h { |key| [key, nil] }.merge(
        "PATH" => directory,
        "UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_HOST" => "github.com",
        "UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_SCHEME" => "https",
        "UNTRUSTED_CONTRIBUTOR_INTAKE_TRUSTED_GITHUB_REPO" => "octo-org/hello-world"
      )
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        PREFLIGHT_PATH,
        "--pr-ref",
        "42"
      )

      refute status.success?
      assert_match METADATA_BLOCKED, stderr
    end
  end

  def test_blocks_a_canonical_url_whose_authority_is_not_the_trusted_host
    success, output, calls = run_preflight(
      pr_ref: "42",
      trusted_host: "ghe.example:8443",
      gh_output: "42|https://other.example/octo-org/hello-world/pull/42"
    )

    refute success
    assert_match CANONICAL_UNTRUSTED, output
    assert_equal 1, calls.length

    success, output, = run_preflight(
      pr_ref: "42",
      trusted_host: "ghe.example:8443",
      gh_output: "42|https://ghe.example/octo-org/hello-world/pull/42"
    )

    refute success
    assert_match CANONICAL_UNTRUSTED, output
  end

  def test_blocks_a_malformed_or_retargeted_canonical_url
    [
      "42|https://ghe.example:8443/renamed-org/renamed-repo/pull/42",
      "42|https://ghe.example:8443/octo-org/hello-world/pull/43",
      "42|https://ghe.example:8443/octo-org/hello-world/issues/42",
      "42|https://ghe.example:8443/octo-org/hello-world/42",
      "42|https://ghe.example:8443/octo-org/pull/42",
      "42|https://ghe.example:8443/octo-org/hello-world/pull/42/extra",
      "42|https://ghe.example:8443/octo-org/hello-world/pull/42?query",
      "42|https://ghe.example:8443/octo-org/hello-world/pull/42#fragment",
      "42|https://ghe.example:8443/octo-org//pull/42",
      "42|https://ghe.example:8443//hello-world/pull/42",
      "42|https://ghe.example:8443/../hello-world/pull/42",
      "42|https://ghe.example:8443/octo-org/../pull/42",
      "42|https://ghe.example:8443/octo%2Dorg/hello-world/pull/42",
      "42|https://ghe.example:abc/octo-org/hello-world/pull/42",
      "42|https://ghe.example:8443:9443/octo-org/hello-world/pull/42",
      "42|https://[2001:db8::1]/octo-org/hello-world/pull/42",
      "42|https://user@ghe.example:8443/octo-org/hello-world/pull/42",
      "42|https://ghe.example:8443",
      "42|https://ghe.example:0/octo-org/hello-world/pull/42",
      "42|https://ghe.example:65536/octo-org/hello-world/pull/42"
    ].each do |gh_output|
      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_host: "ghe.example:8443",
        gh_output: gh_output
      )

      refute success, "expected #{gh_output.inspect} to be BLOCKED, got #{output.inspect}"
      assert_match CANONICAL_BLOCKED, output
      assert_equal 1, calls.length
    end
  end

  def test_accepts_dotted_repository_segments_that_github_permits
    success, output, = run_preflight(
      pr_ref: "https://github.com/.github/repo.name/pull/42",
      trusted_repo: ".github/repo.name",
      gh_output: "42|https://github.com/.github/repo.name/pull/42"
    )

    assert success, output
    assert_equal ".github/repo.name", preflight_values(output).fetch("REPO")
  end

  # Deduplication contract: one authority validator, one port rule, one DNS
  # label rule, one repository validator, and one exact-PR-URL parser serve the
  # trusted origin, the PR_REF URL, and the canonical URL.
  def test_shares_one_authority_repository_and_url_implementation
    assert_equal 1, PREFLIGHT_SOURCE.scan(/def normalize_authority\b/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/def split_host_port\b/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/def validate_host\b/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/def normalize_repository\b/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/def parse_pull_request_url\b/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/MAX_PORT = /).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/MAX_LABEL_LENGTH = /).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/\(1\.\.MAX_PORT\)\.cover\?/).length

    call_lines = PREFLIGHT_SOURCE.lines.reject { |line| line.strip.start_with?("def ", "#") }
    call_sites = lambda do |name|
      call_lines.count { |line| line.include?("#{name}(") }
    end

    # Trusted origin host, PR_REF URL authority, and canonical URL authority.
    assert_equal 3, call_sites.call("normalize_authority")
    # Trusted policy repository plus the shared exact-PR-URL target.
    assert_equal 2, call_sites.call("normalize_repository")
    # Raw PR_REF URL form and the server-returned canonical URL.
    assert_equal 2, call_sites.call("parse_pull_request_url")
  end

  def test_applies_the_same_port_bounds_to_every_authority_it_parses
    %w[1 8443 65535].each do |port|
      success, output, calls = run_preflight(
        pr_ref: "https://ghe.example:#{port}/octo-org/hello-world/pull/42",
        trusted_host: "ghe.example:#{port}",
        gh_output: "42|https://ghe.example:#{port}/octo-org/hello-world/pull/42"
      )

      assert success, output
      assert_equal "ghe.example:#{port}", preflight_values(output).fetch("GH_HOST")
      assert_equal 1, calls.length
    end

    %w[0 65536 999999999999999999999999].each do |port|
      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_host: "ghe.example:#{port}",
        gh_output: "42|https://ghe.example/octo-org/hello-world/pull/42"
      )
      refute success, "trusted host port #{port} must be BLOCKED"
      assert_match TRUSTED_ORIGIN_BLOCKED, output
      assert_empty calls

      success, output, calls = run_preflight(
        pr_ref: "https://ghe.example:#{port}/octo-org/hello-world/pull/42",
        trusted_host: "ghe.example:8443",
        gh_output: "42|https://ghe.example:8443/octo-org/hello-world/pull/42"
      )
      refute success, "PR_REF port #{port} must be BLOCKED"
      assert_match PR_REF_BLOCKED, output
      assert_empty calls

      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_host: "ghe.example:8443",
        gh_output: "42|https://ghe.example:#{port}/octo-org/hello-world/pull/42"
      )
      refute success, "canonical URL port #{port} must be BLOCKED"
      assert_match CANONICAL_BLOCKED, output
      assert_equal 1, calls.length
    end
  end

  def test_applies_the_same_dns_label_rules_to_every_authority_it_parses
    ["ghe..example", "-ghe.example", "ghe-.example", "#{'a' * 64}.example"].each do |host|
      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_host: host,
        gh_output: "42|https://ghe.example/octo-org/hello-world/pull/42"
      )
      refute success, "trusted host #{host.inspect} must be BLOCKED"
      assert_match TRUSTED_ORIGIN_BLOCKED, output
      assert_empty calls

      success, output, calls = run_preflight(
        pr_ref: "https://#{host}/octo-org/hello-world/pull/42",
        trusted_host: "ghe.example",
        gh_output: "42|https://ghe.example/octo-org/hello-world/pull/42"
      )
      refute success, "PR_REF host #{host.inspect} must be BLOCKED"
      assert_match PR_REF_BLOCKED, output
      assert_empty calls

      success, output, calls = run_preflight(
        pr_ref: "42",
        trusted_host: "ghe.example",
        gh_output: "42|https://#{host}/octo-org/hello-world/pull/42"
      )
      refute success, "canonical host #{host.inspect} must be BLOCKED"
      assert_match CANONICAL_BLOCKED, output
      assert_equal 1, calls.length
    end
  end

  # Metadata-only boundary: the helper must never request or read PR bodies,
  # issue text, comments, review text, or fork content.
  def test_requests_only_number_and_url_metadata
    assert_equal 1, PREFLIGHT_SOURCE.scan(/"gh",/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/Open3\.capture3/).length
    assert_equal 1, PREFLIGHT_SOURCE.scan(/"number,url"/).length

    code = PREFLIGHT_SOURCE.lines.reject { |line| line.strip.start_with?("#") }.join

    [
      "body",
      "comments",
      "reviews",
      "reviewThreads",
      "closingIssuesReferences",
      "authorAssociation",
      "graphql",
      "pr diff",
      "checkout",
      "clone",
      "system(",
      "exec(",
      "IO.popen",
      "`"
    ].each do |forbidden|
      refute_includes code, forbidden, "the metadata-only helper must not reference #{forbidden.inspect}"
    end
  end

  def test_documents_the_host_enforced_boundary_it_cannot_itself_guarantee
    assert_includes PREFLIGHT_SOURCE, "Security boundary: metadata only, and fail closed."
    assert_includes PREFLIGHT_SOURCE, "never reads PR bodies"
    assert_includes PREFLIGHT_SOURCE, "read-only, no-execution, no-secrets, and no-writes boundaries documented in"
    assert_includes PREFLIGHT_SOURCE, "this helper is a validator, not a sandbox."
  end

  def test_repo_validation_registers_this_helper_test
    root = File.expand_path("../../..", __dir__)
    validator = File.read(File.join(root, "bin/validate"), encoding: "UTF-8")

    assert_includes validator, "ruby skills/untrusted-contributor-intake/bin/untrusted-contributor-intake-preflight-test.rb"
  end
end
