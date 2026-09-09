#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the shared GitHub actor trust module.
# Run with: ruby .agents/skills/pr-batch/bin/github-actor-trust-test.rb

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "../lib/github_actor_trust"

class GithubActorTrustTest < Minitest::Test
  def config(yaml, global: false)
    Dir.mktmpdir("actor-trust") do |dir|
      path = File.join(dir, "trusted-github-actors.yml")
      File.write(path, yaml)
      return GithubActorTrust.load(path:, global:)
    end
  end

  def classify(login, yaml: "trusted_users: [justin808]\n", **kwargs)
    GithubActorTrust.classify(repo: "owner/repo", login:, config: config(yaml), **kwargs)
  end

  def test_trusted_user_is_actionable
    assert_equal :trusted, classify("justin808")
  end

  def test_login_matching_is_case_insensitive_and_ignores_an_at_prefix
    assert_equal :trusted, classify("JUSTIN808")
    assert_equal :trusted, classify("@justin808")
  end

  def test_unknown_actor_is_untrusted
    assert_equal :untrusted, classify("drive-by")
  end

  def test_missing_or_hidden_login_is_untrusted
    assert_equal :untrusted, classify(nil)
    assert_equal :untrusted, classify("")
  end

  def test_packaged_metadata_bot_is_metadata_only_even_when_unlisted
    assert_equal :metadata_only, classify("github-actions[bot]")
  end

  def test_metadata_only_bot_does_not_require_a_team_membership_probe
    yaml = "trusted_teams: [owner/reviewers]\n"
    resolver = ->(**) { flunk "metadata-only bots cannot belong to GitHub teams" }

    assert_equal :metadata_only, classify("github-actions[bot]", yaml:, team_resolver: resolver)
  end

  # A human squatting on a bot's base name must not inherit the bot's trust.
  def test_bot_trust_requires_the_bot_suffix
    yaml = "trusted_bots: [coderabbitai]\n"
    assert_equal :trusted, classify("coderabbitai[bot]", yaml:)
    assert_equal :untrusted, classify("coderabbitai", yaml:)
  end

  def test_overlapping_bot_classification_fails_closed
    error = assert_raises(GithubActorTrust::Error) do
      config("trusted_bots: [dup]\ntrusted_metadata_bots: [dup]\n")
    end

    assert_match(/listed in both/, error.message)
  end

  # A stray blank list item parses to nil; that must not crash out of the
  # Error contract both callers rescue on.
  def test_blank_team_entry_is_ignored_rather_than_crashing
    loaded = config("trusted_teams:\n  - \n  - owner/reviewers\n")

    assert_equal [{ owner: "owner", slug: "reviewers" }], loaded.fetch(:trusted_teams)
  end

  def test_malformed_yaml_fails_closed
    error = assert_raises(GithubActorTrust::Error) { config("trusted_users: [\n") }

    assert_match(/malformed YAML/, error.message)
  end

  def test_unreadable_trust_path_uses_the_module_error_contract
    Dir.mktmpdir("actor-trust-directory") do |dir|
      error = assert_raises(GithubActorTrust::Error) do
        GithubActorTrust.load(path: dir, global: true)
      end

      assert_match(/Invalid trust config/, error.message)
      assert_match(/directory|read/i, error.message)
    end
  end

  def test_non_mapping_config_fails_closed
    error = assert_raises(GithubActorTrust::Error) { config("- just-a-list\n") }

    assert_match(/expected a YAML mapping/, error.message)
  end

  def test_digest_is_over_the_bytes_that_were_parsed
    loaded = config("trusted_users: [justin808]\n")
    expected = "sha256:#{Digest::SHA256.hexdigest("trusted_users: [justin808]\n")}"

    assert_equal expected, loaded.fetch(:content_digest)
  end

  # Guessing membership would either invent trust or drop a configured
  # reviewer, so a config naming teams must be given a resolver.
  def test_teams_without_a_resolver_fail_closed
    error = assert_raises(GithubActorTrust::Error) do
      classify("member", yaml: "trusted_teams: [reviewers]\n")
    end

    assert_match(/team_resolver/, error.message)
  end

  def test_team_member_is_trusted_through_the_resolver
    resolver = ->(owner:, slug:, login:) { [owner, slug, login] == %w[owner reviewers member] }

    assert_equal :trusted, classify("member", yaml: "trusted_teams: [reviewers]\n", team_resolver: resolver)
    assert_equal :untrusted, classify("stranger", yaml: "trusted_teams: [reviewers]\n", team_resolver: resolver)
  end

  # A transient failed membership lookup must not demote a configured reviewer
  # for the rest of a long-running preflight invocation.
  def test_negative_team_membership_result_is_retried
    cache = {}
    results = [false, true]
    resolver = ->(**) { results.shift }
    loaded = config("trusted_teams: [reviewers]\n")

    assert_equal :untrusted,
                 GithubActorTrust.classify(
                   repo: "owner/repo", login: "member", config: loaded,
                   team_cache: cache, team_resolver: resolver
                 )
    assert_equal :trusted,
                 GithubActorTrust.classify(
                   repo: "owner/repo", login: "member", config: loaded,
                   team_cache: cache, team_resolver: resolver
                 )
    assert_empty results
  end

  def test_a_team_owned_by_another_org_is_ignored
    resolver = ->(**) { true }

    assert_equal :untrusted,
                 classify("member", yaml: "trusted_teams: [other-org/reviewers]\n", team_resolver: resolver)
  end

  def test_global_config_ignores_an_unqualified_team_slug
    loaded = nil
    _out, err = capture_io do
      loaded = config("trusted_teams: [reviewers]\n", global: true)
    end

    assert_empty loaded.fetch(:trusted_teams)
    assert_match(/unqualified team slug/, err)
  end

  def test_resolve_path_prefers_a_repo_local_config
    Dir.mktmpdir("actor-trust-root") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      path = File.join(root, GithubActorTrust::DEFAULT_TRUST_CONFIG)
      File.write(path, "trusted_users: []\n")

      resolved = GithubActorTrust.resolve_path(nil, repo_root: root)

      assert_equal path, resolved.fetch(:path)
      assert_equal "repo-local", resolved.fetch(:source)
    end
  end

  # Without proof that a config belongs to the scanned repo, an unqualified
  # trusted_teams slug would be rebound to whatever owner the caller passed.
  def test_repo_local_config_is_global_until_a_verifier_proves_otherwise
    Dir.mktmpdir("actor-trust-root") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, GithubActorTrust::DEFAULT_TRUST_CONFIG), "trusted_users: []\n")

      assert GithubActorTrust.resolve_path(nil, repo_root: root).fetch(:global)
      refute GithubActorTrust.resolve_path(
        nil, repo_root: root, repo_local_verifier: ->(_path) { true }
      ).fetch(:global)
    end
  end

  def test_explicit_config_is_global_when_the_verifier_rejects_it
    Dir.mktmpdir("actor-trust-explicit") do |dir|
      path = File.join(dir, "trusted-github-actors.yml")
      File.write(path, "trusted_users: []\n")

      assert GithubActorTrust.resolve_path(path, repo_local_verifier: ->(_path) { false }).fetch(:global)
      refute GithubActorTrust.resolve_path(path, repo_local_verifier: ->(_path) { true }).fetch(:global)
    end
  end

  def test_repository_locality_verifier_requires_matching_repo_and_host
    Dir.mktmpdir("actor-trust-locality") do |root|
      path = File.join(root, GithubActorTrust::DEFAULT_TRUST_CONFIG)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "trusted_teams: [reviewers]\n")
      system("git", "-C", root, "init", "--quiet", exception: true)
      system(
        "git", "-C", root, "remote", "add", "origin", "https://github.company.example/owner/repo.git",
        exception: true
      )
      capture = ->(*command) { Open3.capture3(*command) }

      matching = GithubActorTrust.repository_locality_verifier(
        repo: "owner/repo", github_host: "github.company.example", git_capture: capture
      )
      wrong_host = GithubActorTrust.repository_locality_verifier(
        repo: "owner/repo", github_host: "github.com", git_capture: capture
      )
      wrong_repo = GithubActorTrust.repository_locality_verifier(
        repo: "other/repo", github_host: "github.company.example", git_capture: capture
      )

      assert matching.call(path)
      refute wrong_host.call(path)
      refute wrong_repo.call(path)
    end
  end

  def test_repository_locality_verifier_resolves_ssh_aliases
    Dir.mktmpdir("actor-trust-locality-alias") do |root|
      path = File.join(root, GithubActorTrust::DEFAULT_TRUST_CONFIG)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "trusted_teams: [reviewers]\n")
      system("git", "-C", root, "init", "--quiet", exception: true)
      system("git", "-C", root, "remote", "add", "origin", "git@github.com-work:owner/repo.git", exception: true)
      capture = ->(*command) { Open3.capture3(*command) }
      resolved_aliases = []
      resolver = lambda do |host|
        resolved_aliases << host
        "github.com"
      end
      verifier = GithubActorTrust.repository_locality_verifier(
        repo: "owner/repo", github_host: "github.com", git_capture: capture, ssh_host_resolver: resolver
      )

      assert verifier.call(path)
      assert_equal ["github.com-work"], resolved_aliases
    end
  end

  def test_ssh_uri_alias_resolution_uses_the_host_without_its_explicit_port
    resolved_aliases = []
    remote = GithubActorTrust.github_remote_from_remote_url(
      "ssh://git@github.com-work:2222/owner/repo.git",
      ssh_host_resolver: lambda do |host|
        resolved_aliases << host
        "github.com"
      end
    )

    assert_equal "github.com", remote.fetch(:host)
    assert_equal 2222, remote.fetch(:port)
    assert_equal ["github.com-work"], resolved_aliases
  end

  def test_ssh_uri_keeps_its_transport_port_when_ssh_resolves_to_the_same_host
    remote = GithubActorTrust.github_remote_from_remote_url(
      "ssh://git@github.company.example:8443/owner/repo.git",
      ssh_host_resolver: ->(host) { host }
    )

    assert_equal "github.company.example:8443", remote.fetch(:host)
    assert_equal 8443, remote.fetch(:port)
  end

  def test_canonical_ssh_remote_survives_an_unavailable_ssh_config_probe
    remote = GithubActorTrust.github_remote_from_remote_url(
      "git@github.com:owner/repo.git",
      ssh_host_resolver: ->(_host) {}
    )

    assert_equal "github.com", remote.fetch(:host)
    assert_equal "owner/repo", remote.fetch(:repo)
  end

  def test_ssh_transport_port_is_not_inferred_as_the_github_api_port
    remote = GithubActorTrust.github_remote_from_remote_url(
      "ssh://git@github.company.example:2222/owner/repo.git"
    )

    assert_equal "github.company.example", GithubActorTrust.github_api_host(remote)
    assert GithubActorTrust.remote_matches_github_host?(remote, "github.company.example")
  end

  def test_resolve_path_rejects_a_missing_explicit_config
    error = assert_raises(GithubActorTrust::Error) do
      GithubActorTrust.resolve_path("/nonexistent/trusted-github-actors.yml")
    end

    assert_match(/Trust config not found/, error.message)
  end

  def test_resolve_path_falls_back_to_the_packaged_allowlist
    Dir.mktmpdir("actor-trust-empty") do |root|
      resolved = with_env(GithubActorTrust::USER_TRUST_CONFIG_ENV => nil, "HOME" => root) do
        GithubActorTrust.resolve_path(nil, repo_root: root)
      end

      assert_equal "packaged-fallback", resolved.fetch(:source)
      assert_equal GithubActorTrust::PACKAGED_TRUST_CONFIG, resolved.fetch(:path)
    end
  end

  private

  def with_env(overrides)
    previous = overrides.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
