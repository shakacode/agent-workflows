#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "agent_workflows_source_contract"

class AgentWorkflowsSourceContractTest < Minitest::Test
  def with_repository
    Dir.mktmpdir("agent-workflows-source-contract") do |root|
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "init", "-q", "-b", "main", exception: true)
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "config", "user.name", "Test", exception: true)
      system(
        AgentWorkflowsSourceContract.git_executable,
        "-C", root, "config", "user.email", "test@example.com",
        exception: true
      )
      File.write(File.join(root, "README.md"), "one\n")
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "add", ".", exception: true)
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "commit", "-qm", "initial", exception: true)
      system(
        AgentWorkflowsSourceContract.git_executable,
        "-C", root, "remote", "add", "origin", AgentWorkflowsSourceContract::CANONICAL_URL,
        exception: true
      )
      system(
        AgentWorkflowsSourceContract.git_executable,
        "-C", root, "update-ref", AgentWorkflowsSourceContract::REMOTE_REF, "HEAD",
        exception: true
      )
      yield root
    end
  end

  def test_offline_managed_install_accepts_only_clean_main_at_the_cached_ref
    with_repository do |root|
      head = AgentWorkflowsSourceContract.git(root, "rev-parse", "HEAD")
      assert_equal head, AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false)

      File.write(File.join(root, "dirty"), "dirty\n")
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
      assert_includes error.message, "clean"
      FileUtils.rm_f(File.join(root, "dirty"))

      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "switch", "-qc", "feature", exception: true)
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
      assert_includes error.message, "main"
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "switch", "-q", "main", exception: true)

      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "checkout", "-q", "--detach", exception: true)
      assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
    end
  end

  def test_managed_install_refreshes_the_hardcoded_canonical_ref_by_default
    with_repository do |root|
      fetched = false
      original = AgentWorkflowsSourceContract.method(:fetch!)
      AgentWorkflowsSourceContract.define_singleton_method(:fetch!) do |source|
        fetched = true
        cached_revision!(source)
      end

      AgentWorkflowsSourceContract.validate_managed_install!(root)

      assert fetched
    ensure
      AgentWorkflowsSourceContract.define_singleton_method(:fetch!, original)
    end
  end

  def test_canonical_network_fetch_runs_outside_the_candidate_repository
    with_repository do |root|
      revision = AgentWorkflowsSourceContract.git(root, "rev-parse", "HEAD")
      calls = []
      original = AgentWorkflowsSourceContract.method(:git)
      AgentWorkflowsSourceContract.define_singleton_method(:git) do |repository, *arguments|
        calls << [repository, arguments]
        case arguments.first
        when "rev-parse"
          revision
        when "bundle", "init", "fetch", "update-ref"
          ""
        else
          raise "unexpected secure Git command: #{arguments.inspect}"
        end
      end

      assert_equal revision, AgentWorkflowsSourceContract.fetch!(root)

      network_fetch = calls.find { |_repository, arguments| arguments.first == "fetch" }
      refute_nil network_fetch
      refute_equal root, network_fetch.first
      assert_includes network_fetch.last, AgentWorkflowsSourceContract::CANONICAL_URL
      assert(calls.any? { |repository, arguments| repository == root && arguments.take(2) == %w[bundle unbundle] })
      assert(calls.any? do |repository, arguments|
        repository == root && arguments.take(2) == %w[update-ref refs/remotes/origin/main]
      end)
    ensure
      AgentWorkflowsSourceContract.define_singleton_method(:git, original)
    end
  end

  def test_managed_install_rejects_wrong_origin_and_ahead_or_behind_main
    with_repository do |root|
      system(
        AgentWorkflowsSourceContract.git_executable,
        "-C", root, "remote", "set-url", "origin", "https://github.com/example/fork.git",
        exception: true
      )
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
      assert_includes error.message, "origin"
    end

    with_repository do |root|
      File.write(File.join(root, "README.md"), "ahead\n")
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "commit", "-qam", "ahead", exception: true)
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
      assert_includes error.message, "equal"
    end

    with_repository do |root|
      first = AgentWorkflowsSourceContract.git(root, "rev-parse", "HEAD")
      File.write(File.join(root, "README.md"), "remote\n")
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "commit", "-qam", "remote", exception: true)
      remote = AgentWorkflowsSourceContract.git(root, "rev-parse", "HEAD")
      system(
        AgentWorkflowsSourceContract.git_executable,
        "-C", root, "update-ref", AgentWorkflowsSourceContract::REMOTE_REF, remote,
        exception: true
      )
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "checkout", "-q", "--detach", first, exception: true)
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "branch", "-f", "main", first, exception: true)
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "switch", "-q", "main", exception: true)
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.validate_managed_install!(root, fetch: false) }
      assert_includes error.message, "equal"
    end
  end

  def test_managed_metadata_and_fetch_contract_are_exact
    assert_nil AgentWorkflowsSourceContract.validate_managed_metadata!(
      "provider_repository" => AgentWorkflowsSourceContract::REPOSITORY,
      "provider_ref" => AgentWorkflowsSourceContract::REF
    )
    assert_raises(RuntimeError) do
      AgentWorkflowsSourceContract.validate_managed_metadata!(
        "provider_repository" => "example/fork",
        "provider_ref" => AgentWorkflowsSourceContract::REF
      )
    end
    assert_equal(
      "+refs/heads/main:refs/remotes/origin/main",
      AgentWorkflowsSourceContract::FETCH_REFSPEC
    )
  end

  def test_no_fetch_upgrade_never_follows_an_arbitrary_upstream
    with_repository do |root|
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "branch", "--set-upstream-to", "origin/main", exception: true)
      assert_match(/\A[0-9a-f]{40}\z/, AgentWorkflowsSourceContract.fast_forward_main!(root, fetch: false))

      File.write(File.join(root, "README.md"), "ahead\n")
      system(AgentWorkflowsSourceContract.git_executable, "-C", root, "commit", "-qam", "ahead", exception: true)
      error = assert_raises(RuntimeError) { AgentWorkflowsSourceContract.fast_forward_main!(root, fetch: false) }
      assert_includes error.message, "--no-fetch"
    end
  end
end
