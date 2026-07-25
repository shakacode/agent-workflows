#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

require_relative "agent_workflows_operation/resolver"
require_relative "agent_workflows_operation/runner"

class AgentWorkflowsOperationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BOUND_SKILLS = %w[
    address_review
    adversarial_pr_review
    autoreview
    evaluate_issue
    pause
    plan_issue_triage
    plan_pr_batch
    post_merge_audit
    pr_batch
    pr_monitoring
    run_ci
    spec
    tdd
    triage
    update_changelog
    verify
  ].freeze

  def setup
    @tmp = Dir.mktmpdir("agent-workflows-operation")
    FileUtils.chmod(0o700, @tmp)
    @source = File.join(@tmp, "source")
    @target = File.join(@tmp, "codex")
    @server_pid = nil
    @old_codex_executable = ENV["AGENT_WORKFLOWS_CODEX_EXECUTABLE"]
    @old_gh_executable = ENV["AGENT_WORKFLOWS_GH_EXECUTABLE"]
    create_source_repository
    install_provider
    ENV["AGENT_WORKFLOWS_CODEX_EXECUTABLE"] = @fake_codex
    ENV["AGENT_WORKFLOWS_GH_EXECUTABLE"] = @fake_gh
  end

  def teardown
    Process.kill("TERM", @server_pid) if @server_pid
    Process.wait(@server_pid) if @server_pid
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    if @old_codex_executable
      ENV["AGENT_WORKFLOWS_CODEX_EXECUTABLE"] = @old_codex_executable
    else
      ENV.delete("AGENT_WORKFLOWS_CODEX_EXECUTABLE")
    end
    if @old_gh_executable
      ENV["AGENT_WORKFLOWS_GH_EXECUTABLE"] = @old_gh_executable
    else
      ENV.delete("AGENT_WORKFLOWS_GH_EXECUTABLE")
    end
    if File.exist?(@tmp)
      Find.find(@tmp) do |path|
        stat = File.lstat(path)
        File.chmod(stat.directory? ? 0o700 : 0o600, path) unless stat.symlink?
      end
      FileUtils.remove_entry(@tmp)
    end
  end

  def test_legacy_and_explicit_pinned_profiles_never_begin_a_rolling_operation
    [nil, "pinned"].each do |profile|
      metadata = read_metadata
      profile ? metadata["provider_profile"] = profile : metadata.delete("provider_profile")
      write_metadata(metadata)

      error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
      assert_includes error.message, "PINNED_PROVIDER_OPERATION_UNAVAILABLE"
      assert_empty operation_directories
    end
  end

  def test_unknown_provider_profile_fails_before_fetch_or_publication
    metadata = read_metadata
    metadata["provider_profile"] = "surprise"
    write_metadata(metadata)

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "unsupported provider profile"
    assert_empty operation_directories
  end

  def test_fetch_ignores_url_rewrites_custom_refspecs_alternates_hooks_and_replacements
    evil = File.join(@tmp, "evil")
    FileUtils.mkdir_p(evil)
    system("git", "-C", evil, "init", "--quiet", "--bare", exception: true)
    malicious_home = File.join(@tmp, "malicious-home")
    FileUtils.mkdir_p(malicious_home)
    File.write(
      File.join(malicious_home, ".gitconfig"),
      <<~CONFIG
        [url "#{evil}"]
          insteadOf = #{@fixture_url}
        [remote "origin"]
          fetch = +refs/replace/*:refs/agent-workflows/canonical-main
        [core]
          hooksPath = #{File.join(@tmp, 'hooks')}
        [init]
          templateDir = #{File.join(@tmp, 'template')}
      CONFIG
    )
    replacement = commit_file("REPLACED", "replacement")
    system("git", "-C", @source, "replace", @revision, replacement, exception: true)
    system("git", "-C", @source, "push", "--quiet", @served_repo, "refs/replace/#{@revision}", exception: true)

    with_environment(
      "HOME" => malicious_home,
      "GIT_CONFIG_GLOBAL" => File.join(malicious_home, ".gitconfig"),
      "GIT_ALTERNATE_OBJECT_DIRECTORIES" => evil,
      "GIT_OBJECT_DIRECTORY" => evil
    ) do
      operation = begin_current_operation
      assert_equal @revision, operation.fetch("revision")
      assert_equal "fixture\n", File.read(operation.dig("assets", "docs").fetch("coordination_backend"))
    end
  end

  def test_stale_native_provider_fails_before_operation_publication_with_reload_action
    advance_source("new-main")

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "PROVIDER_UPDATE_REQUIRED"
    assert_includes error.message, "codex plugin marketplace upgrade agent-workflows"
    assert_includes error.message, "restart Codex"
    assert_empty operation_directories
  end

  def test_native_and_companion_revision_mismatch_fails_closed
    metadata = read_metadata
    metadata["source_revision"] = "0" * 40
    write_metadata(metadata)

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "native and companion provider revisions"
    assert_empty operation_directories
  end

  def test_multiple_native_roots_fail_closed
    second_root = File.join(@target, "plugins/cache/agent-workflows/scw/0.2.0")
    system("git", "clone", "--quiet", @source, second_root, exception: true)
    system("git", "-C", second_root, "checkout", "--quiet", @revision, exception: true)
    File.write(
      @fake_codex,
      <<~SH
        #!/bin/sh
        printf '%s\n' 'scw@agent-workflows  installed, enabled  0.1.0  https://github.com/shakacode/agent-workflows.git'
        printf '%s\n' 'scw@agent-workflows  installed, enabled  0.2.0  https://github.com/shakacode/agent-workflows.git'
      SH
    )

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "unavailable or ambiguous"
    assert_empty operation_directories
  end

  def test_extra_missing_and_mutated_native_content_are_rejected
    native_root = native_provider_root
    mutations = [
      -> { File.write(File.join(native_root, "EXTRA"), "extra\n") },
      -> { FileUtils.rm_f(File.join(native_root, "docs/coordination-backend.md")) },
      -> { File.write(File.join(native_root, "docs/coordination-backend.md"), "mutated\n") }
    ]

    mutations.each_with_index do |mutation, index|
      reset_native_provider
      mutation.call
      error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
      assert_includes error.message, "active native provider content"
      assert_empty operation_directories, "mutation #{index} published an operation"
    end
  end

  def test_mutated_companion_content_is_rejected
    File.write(File.join(@target, "workflows/pr-processing.md"), "mutated companion\n")

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "companion bootstrap content"
    assert_empty operation_directories
  end

  def test_degraded_operation_cannot_run_a_current_only_mutation
    begin_current_operation
    operation = fixture_resolver.begin!(degraded: true)

    error = assert_raises(AgentWorkflowsOperation::RunnerError) do
      AgentWorkflowsOperation::Runner.new(target: @target).run!(
        handle: operation.fetch("operation"),
        capability: "pr-merge-submit",
        arguments: []
      )
    end
    assert_includes error.message, "CURRENT_PROVIDER_REQUIRED"
  end

  def test_handles_are_opaque_and_state_permissions_are_private
    operation = begin_current_operation
    handle = operation.fetch("operation")
    operation_root = operation_root(handle)

    assert_match(/\A[0-9a-f]{64}\z/, handle)
    assert_equal 0o700, File.stat(operation_root).mode & 0o777
    assert_equal 0o600, File.stat(File.join(operation_root, "operation.json")).mode & 0o777
    assert_equal 0o500, File.stat(File.join(operation_root, "launcher")).mode & 0o777

    FileUtils.chmod(0o755, operation_root)
    error = assert_raises(AgentWorkflowsOperation::RunnerError) do
      AgentWorkflowsOperation::Runner.new(target: @target).run!(
        handle: handle,
        capability: "pr-merge-submit",
        arguments: []
      )
    end
    assert_includes error.message, "mode 0700"
  end

  def test_operation_metadata_tampering_is_rejected_against_canonical_store
    operation = begin_current_operation
    metadata_path = File.join(operation_root(operation.fetch("operation")), "operation.json")
    metadata = JSON.parse(File.binread(metadata_path))
    metadata["revision"] = "f" * 40
    File.write(metadata_path, JSON.pretty_generate(metadata))
    FileUtils.chmod(0o600, metadata_path)

    error = assert_raises(AgentWorkflowsOperation::RunnerError) do
      AgentWorkflowsOperation::Runner.new(target: @target).run!(
        handle: operation.fetch("operation"),
        capability: "pr-merge-submit",
        arguments: []
      )
    end
    assert_includes error.message, "canonical content store"
  end

  def test_staging_cleanup_preserves_a_swapped_directory
    resolver = fixture_resolver
    resolver.cleanup_probe = lambda do |stage|
      replacement = "#{stage}.replacement"
      File.rename(stage, replacement)
      FileUtils.mkdir_p(stage)
      File.write(File.join(stage, "DO_NOT_REMOVE"), "replacement\n")
      raise AgentWorkflowsOperation::StoreError, "forced staging failure"
    end

    error = assert_raises(AgentWorkflowsOperation::CleanupError) { resolver.begin! }
    assert_includes error.message, "staging identity changed"
    replacement = Dir.glob(File.join(state_root, "quarantine", "*", "DO_NOT_REMOVE"))
    assert_equal 1, replacement.length
  end

  def test_private_state_initialization_verifies_a_concurrent_winner
    original_mkdir = Dir.method(:mkdir)
    expected_state_root = state_root
    raced = false
    concurrent_mkdir = lambda do |path, mode = 0o777|
      if path == expected_state_root && !raced
        raced = true
        original_mkdir.call(path, mode)
        raise Errno::EEXIST, path
      end

      original_mkdir.call(path, mode)
    end

    stub_singleton_method(Dir, :mkdir, concurrent_mkdir) do
      assert_equal expected_state_root, AgentWorkflowsOperation::SecurePaths.prepare_state_root!(@target)
    end
    assert raced
    assert_equal 0o700, File.stat(expected_state_root).mode & 0o777
  end

  def test_state_target_allows_only_known_root_platform_aliases
    secure_paths = AgentWorkflowsOperation::SecurePaths

    assert secure_paths.platform_directory_alias?("/tmp", 0, "/private/tmp")
    assert secure_paths.platform_directory_alias?("/var", 0, "/private/var")
    refute secure_paths.platform_directory_alias?("/tmp", 1, "/private/tmp")
    refute secure_paths.platform_directory_alias?("/tmp", 0, "/attacker")
  end

  def test_store_publication_verifies_a_concurrent_winner
    original_rename = File.method(:rename)
    expected_store = File.join(state_root, "store", @revision)
    raced = false
    concurrent_rename = lambda do |source, destination|
      if source.include?("/quarantine/") && destination == expected_store && !raced
        raced = true
        FileUtils.cp_r(source, destination, preserve: true)
        raise Errno::EEXIST, destination
      end

      original_rename.call(source, destination)
    end

    operation = stub_singleton_method(File, :rename, concurrent_rename) { begin_current_operation }
    assert raced
    assert_equal @revision, operation.fetch("revision")
    assert_equal [File.join(@target, "bin/agent-workflows-run"), "--operation", operation.fetch("operation")],
                 operation.fetch("runner").last(3)
  end

  def test_failed_post_rename_verification_removes_the_owned_store
    resolver = fixture_resolver
    original_verify = resolver.store.method(:verify_store!)
    calls = 0
    failing_verify = lambda do |root, revision|
      calls += 1
      raise AgentWorkflowsOperation::StoreError, "forced post-rename verification failure" if calls == 1

      original_verify.call(root, revision)
    end

    error = assert_raises(AgentWorkflowsOperation::StoreError) do
      stub_singleton_method(resolver.store, :verify_store!, failing_verify) { resolver.begin! }
    end
    assert_includes error.message, "forced post-rename verification failure"
    refute_path_exists File.join(state_root, "store", @revision)

    operation = begin_current_operation
    assert_equal @revision, operation.fetch("revision")
  end

  def test_runner_rejects_capability_inode_and_hash_swaps
    operation = begin_current_operation
    executable = File.join(operation_root(operation.fetch("operation")), "capabilities", "pr-merge-submit")
    original = File.binread(executable)

    replacement = "#{executable}.replacement"
    File.write(replacement, original)
    FileUtils.chmod(0o500, replacement)
    File.rename(replacement, executable)
    error = run_error(operation)
    assert_includes error.message, "inode"

    operation = begin_current_operation
    executable = File.join(operation_root(operation.fetch("operation")), "capabilities", "pr-merge-submit")
    content = File.binread(executable)
    FileUtils.chmod(0o700, executable)
    content.setbyte(content.bytesize - 2, content.getbyte(content.bytesize - 2) ^ 1)
    File.binwrite(executable, content)
    FileUtils.chmod(0o500, executable)
    error = run_error(operation)
    assert_includes error.message, "published operation hash"
  end

  def test_installed_runner_rejects_an_operation_launcher_swap
    operation = begin_current_operation
    launcher = File.join(operation_root(operation.fetch("operation")), "launcher")
    replacement = "#{launcher}.replacement"
    File.write(replacement, File.binread(launcher))
    FileUtils.chmod(0o500, replacement)
    File.rename(replacement, launcher)

    error = assert_raises(AgentWorkflowsOperation::RunnerError) do
      AgentWorkflowsOperation::Runner.new(target: @target).launch!(
        handle: operation.fetch("operation"),
        capability: "pr-merge-submit",
        arguments: []
      )
    end
    assert_includes error.message, "operation launcher"
    assert_includes error.message, "inode"
  end

  def test_provider_movement_after_begin_blocks_execution
    operation = begin_current_operation
    File.write(File.join(native_provider_root, "MOVED"), "moved\n")

    error = run_error(operation)
    assert_includes error.message, "provider moved after operation begin"
  end

  def test_changed_bound_gh_executable_blocks_capability_execution
    operation = begin_current_operation
    File.write(@fake_gh, "#!/bin/sh\nexit 99\n")
    FileUtils.chmod(0o755, @fake_gh)
    _output, error, status = Open3.capture3(
      *operation.fetch("runner"), "pr-merge-submit", "--", "--probe"
    )

    refute status.success?
    assert_includes error, "bound gh executable"
    assert_match(/inode|hash/, error)
  end

  def test_installed_runner_executes_the_operation_copy
    operation = begin_current_operation
    trusted_env_paths = %w[/usr/bin/env /bin/env].select { |path| File.exist?(path) }.map { |path| File.realpath(path) }
    assert_includes trusted_env_paths, operation.fetch("runner").first
    assert_includes operation.fetch("runner"), "RUBYOPT"
    assert_includes operation.fetch("runner"), "RUBYLIB"
    assert_includes operation.fetch("runner"), File.realpath(RbConfig.ruby)
    assert_equal File.join(@target, "bin/agent-workflows-run"), operation.fetch("runner")[-3]
    assert_equal ["--operation", operation.fetch("operation")], operation.fetch("runner").last(2)
    output, error, status = Open3.capture3(
      { "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex }, *operation.fetch("runner"),
      "pr-merge-submit", "--", "--probe"
    )

    assert status.success?, "#{output}#{error}"
    assert_equal "fixture-helper --probe\n", output
  end

  def test_copied_ruby_entrypoints_ignore_hostile_path_and_ruby_injection
    operation = begin_current_operation
    hostile = File.join(@tmp, "hostile-bin")
    FileUtils.mkdir_p(hostile)
    ruby_probe = File.join(hostile, "ruby")
    gh_probe = File.join(hostile, "gh")
    sentinel = File.join(@tmp, "ruby-injection-ran")
    injection = File.join(@tmp, "injection.rb")
    File.write(ruby_probe, "#!/bin/sh\nprintf 'hostile ruby\\n' >&2\nexit 91\n")
    File.write(gh_probe, "#!/bin/sh\nprintf 'hostile gh\\n' >&2\nexit 92\n")
    File.write(injection, "File.write(#{sentinel.dump}, 'injected')\n")
    FileUtils.chmod(0o755, ruby_probe)
    FileUtils.chmod(0o755, gh_probe)
    output, error, status = Open3.capture3(
      {
        "PATH" => hostile,
        "RUBYOPT" => "-r#{injection}",
        "RUBYLIB" => File.dirname(injection),
        "AGENT_WORKFLOWS_GH_EXECUTABLE" => gh_probe
      },
      *operation.fetch("runner"), "pr-merge-submit", "--", "--probe"
    )

    assert status.success?, "#{output}#{error}"
    assert_equal "fixture-helper --probe\n", output
    refute_path_exists sentinel
  end

  def test_gh_binding_comes_only_from_explicit_install_metadata
    hostile_gh = File.join(@tmp, "hostile-gh")
    File.write(hostile_gh, "#!/bin/sh\nexit 93\n")
    FileUtils.chmod(0o755, hostile_gh)
    ENV["AGENT_WORKFLOWS_GH_EXECUTABLE"] = hostile_gh

    operation = begin_current_operation
    _root, metadata = AgentWorkflowsOperation::State.new(target: @target).load_operation!(
      operation.fetch("operation")
    )

    assert_equal File.realpath(@fake_gh), metadata.dig("tools", "gh", "path")
  end

  def test_managed_begin_rejects_missing_explicit_gh_install_binding
    metadata = read_metadata
    metadata.delete("gh_executable")
    write_metadata(metadata)

    error = assert_raises(AgentWorkflowsOperation::ProviderError) { begin_current_operation }
    assert_includes error.message, "explicit absolute gh"
    assert_empty operation_directories
  end

  def test_snapshot_paths_are_operation_owned_and_do_not_fall_back_to_live_repo_files
    operation = begin_current_operation
    assets = operation.fetch("assets")
    expected_root = File.join(state_root, "store", @revision, "tree")

    assert_equal expected_root, assets.fetch("root")
    assert assets.fetch("skill").start_with?("#{expected_root}/")
    assert assets.fetch("workflow").start_with?("#{expected_root}/")
    assert_equal BOUND_SKILLS, assets.fetch("skills").keys.sort
    assets.fetch("skills").each do |name, path|
      assert_equal File.join(expected_root, "skills", name.tr("_", "-"), "SKILL.md"), path
    end
    assets.fetch("docs").each_value { |path| assert path.start_with?("#{expected_root}/") }
    refute_includes File.read(assets.fetch("skill")), ".agents/workflows"
    refute_includes File.read(assets.fetch("workflow")), "PR_BATCH_SKILL_DIR"
  end

  def test_published_instruction_snapshot_rejects_ordinary_overwrite_and_rename
    operation = begin_current_operation
    skill = operation.dig("assets", "skills", "pr_batch")
    original = File.binread(skill)

    assert_raises(Errno::EACCES) { File.write(skill, "mutated\n") }
    assert_raises(Errno::EACCES) { File.rename(skill, "#{skill}.moved") }
    assert_equal original, File.binread(skill)
    assert_equal "current", operation.fetch("freshness")
  end

  def test_claude_begin_returns_bound_assets_and_executes_through_its_installed_runner
    claude_target = File.join(@tmp, "claude")
    install_claude_provider(claude_target)
    operation = TestResolver.new(host: "claude", target: claude_target, fixture_url: @fixture_url).begin!

    assert_equal "managed", operation.fetch("provider_profile")
    assert_equal @revision, operation.fetch("revision")
    assert_equal BOUND_SKILLS, operation.dig("assets", "skills").keys.sort
    assert_equal File.join(claude_target, "bin/agent-workflows-run"), operation.fetch("runner")[-3]
    output, error, status = Open3.capture3(
      *operation.fetch("runner"), "pr-merge-submit", "--", "--claude-probe"
    )
    assert status.success?, "#{output}#{error}"
    assert_equal "fixture-helper --claude-probe\n", output
  end

  def test_source_instructions_require_resolver_first_and_operation_only_paths
    skill = File.binread(File.join(ROOT, "skills/pr-batch/SKILL.md"))
    workflow = File.binread(File.join(ROOT, "workflows/pr-processing.md"))
    contract = File.binread(File.join(ROOT, "docs/host-adapter/contract.md"))

    assert_operator skill.index("bin/agent-workflows-resolve"), :<, skill.index("## Single-Target Mode")
    assert_includes skill, "assets.skills.pr_batch"
    assert_includes skill, "assets.root"
    assert_includes skill, "AGENT_WORKFLOWS_RUNNER"
    assert_includes skill, "${CODEX_HOME:-$HOME/.codex}/bin/agent-workflows-resolve begin"
    refute_match(/^agent-workflows-resolve begin/, skill)
    refute_includes skill, 'PR_BATCH_SKILL_DIR="${PR_BATCH_SKILL_DIR:-.agents/skills/pr-batch}"'
    assert_operator workflow.index("## Required Provider Operation"), :<, workflow.index("## Default Operating Model")
    assert_includes workflow, "AGENT_WORKFLOWS_RUNNER"
    refute_includes workflow, 'PR_BATCH_SKILL_DIR="${PR_BATCH_SKILL_DIR:-.agents/skills/pr-batch}"'
    assert_includes contract, "same-uid integrity boundary"
    assert_includes contract, "cannot prove that a language model"
  end

  def test_production_cli_has_no_remote_override
    resolver_cli = File.binread(File.join(ROOT, "bin/agent-workflows-resolve"))

    assert_equal(
      "https://github.com/shakacode/agent-workflows.git",
      AgentWorkflowsOperation::SecureGit::CANONICAL_URL
    )
    refute_includes resolver_cli, "--remote"
    refute_includes resolver_cli, "AGENT_WORKFLOWS_REMOTE"
  end

  def test_registry_rejects_traversal_nonexecutables_and_missing_instruction_dependencies
    cases = [
      ["../escape", ["skills/pr-batch/SKILL.md"]],
      ["docs/coordination-backend.md", ["skills/pr-batch/SKILL.md"]],
      ["skills/pr-batch/bin/pr-merge-submit", ["docs/missing.md"]]
    ]

    cases.each do |executable, dependencies|
      reset_source_to(@revision)
      registry = JSON.parse(File.binread(File.join(@source, "operation-capabilities.json")))
      capability = registry.fetch("capabilities").fetch("pr-merge-submit")
      capability["executable"] = executable
      capability["instruction_dependencies"] = dependencies
      File.write(File.join(@source, "operation-capabilities.json"), JSON.pretty_generate(registry))
      commit_all("invalid registry")
      publish_source

      assert_raises(AgentWorkflowsOperation::RegistryError) { fixture_resolver.begin! }
      assert_empty operation_directories
    end
  end

  def test_registry_requires_named_skill_assets
    payload = JSON.parse(File.binread(File.join(@source, "operation-capabilities.json")))
    payload.fetch("assets").delete("skills")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "assets.skills"
  end

  def test_registry_rejects_missing_named_skill_asset
    payload = registry_with_skills("missing_skill" => "skills/missing/SKILL.md")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "assets.skills.missing_skill"
  end

  def test_registry_rejects_traversing_named_skill_asset
    payload = registry_with_skills("escape" => "../skills/pr-batch/SKILL.md")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "assets.skills.escape"
  end

  def test_registry_rejects_malformed_named_skill_asset
    payload = registry_with_skills("not-kebab-case" => "skills/pr-batch/SKILL.md")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "snake_case"
  end

  def test_registry_rejects_symlinked_named_skill_asset
    symlink = File.join(@source, "skills/symlinked/SKILL.md")
    FileUtils.mkdir_p(File.dirname(symlink))
    File.symlink(File.join(@source, "skills/pr-batch/SKILL.md"), symlink)
    payload = registry_with_skills("symlinked" => "skills/symlinked/SKILL.md")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "regular non-symlink"
  end

  def test_registry_rejects_symlinked_named_skill_ancestor
    File.symlink("pr-batch", File.join(@source, "skills/aliased"))
    payload = registry_with_skills("aliased" => "skills/aliased/SKILL.md")

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "symlink ancestor"
  end

  def test_registry_rejects_symlinked_nested_document_ancestor
    FileUtils.mkdir_p(File.join(@source, "docs/nested"))
    File.symlink("..", File.join(@source, "docs/nested/aliased"))
    payload = JSON.parse(File.binread(File.join(@source, "operation-capabilities.json")))
    payload.fetch("assets").fetch("docs")["nested_alias"] = "docs/nested/aliased/coordination-backend.md"

    error = assert_raises(AgentWorkflowsOperation::RegistryError) do
      AgentWorkflowsOperation::Registry.new(payload, @source)
    end
    assert_includes error.message, "symlink ancestor"
  end

  private

  def stub_singleton_method(object, name, replacement)
    original = object.method(name)
    object.singleton_class.define_method(name, replacement)
    yield
  ensure
    object.singleton_class.define_method(name, original)
  end

  def begin_current_operation
    fixture_resolver.begin!
  end

  def registry_with_skills(skills)
    JSON.parse(File.binread(File.join(@source, "operation-capabilities.json"))).tap do |payload|
      payload.fetch("assets")["skills"] = skills
    end
  end

  def fixture_resolver
    TestResolver.new(host: "codex", target: @target, fixture_url: @fixture_url).tap do |resolver|
      resolver.cleanup_probe = nil
    end
  end

  def run_error(operation)
    assert_raises(AgentWorkflowsOperation::RunnerError) do
      AgentWorkflowsOperation::Runner.new(target: @target).run!(
        handle: operation.fetch("operation"),
        capability: "pr-merge-submit",
        arguments: []
      )
    end
  end

  def state_root
    File.join(@target, ".agent-workflows-operation-state")
  end

  def operation_root(handle)
    File.join(state_root, "operations", handle)
  end

  def operation_directories
    Dir.glob(File.join(state_root, "operations", "*"))
  end

  def native_provider_root
    File.join(@target, "plugins/cache/agent-workflows/scw/0.1.0")
  end

  def create_source_repository
    FileUtils.mkdir_p(@source)
    write_source_files
    system("git", "-C", @source, "init", "--quiet", "--initial-branch=main", exception: true)
    system("git", "-C", @source, "config", "user.name", "Operation Test", exception: true)
    system("git", "-C", @source, "config", "user.email", "operation@example.com", exception: true)
    @revision = commit_all("fixture source")
    @served_repo = File.join(@tmp, "served.git")
    system("git", "clone", "--quiet", "--bare", @source, @served_repo, exception: true)
    start_http_server
  end

  def write_source_files
    files = {
      ".codex-plugin/plugin.json" => JSON.generate(
        "name" => "scw",
        "version" => "0.1.0",
        "repository" => "https://github.com/shakacode/agent-workflows",
        "skills" => "./skills/"
      ),
      ".claude-plugin/plugin.json" => JSON.generate("name" => "scw", "skills" => "./skills/"),
      "skills/pr-batch/bin/pr-merge-submit" => <<~RUBY,
        #!/usr/bin/env ruby
        # frozen_string_literal: true

        puts(["fixture-helper", *ARGV].join(" "))
      RUBY
      "workflows/pr-processing.md" => "operation snapshot workflow\n",
      "workflows/address-review.md" => "address review\n",
      "workflows/adversarial-pr-review.md" => "adversarial review\n",
      "workflows/continuous-evaluation-loop.md" => "evaluation loop\n",
      "workflows/evaluate-issue.md" => "evaluate issue\n",
      "workflows/post-merge-audit.md" => "post merge audit\n",
      "workflows/tdd.md" => "tdd\n",
      "docs/agent-workflows-model-routing.md" => "model routing\n",
      "docs/coordination-backend.md" => "fixture\n",
      "docs/host-adapter/contract.md" => "host contract\n",
      "docs/pr-batch-skills.md" => "pr batch skills\n",
      "docs/release-branching.md" => "release branching\n",
      "docs/review-finding-schema.md" => "review finding schema\n",
      "docs/security-posture.md" => "security posture\n",
      "docs/trust-and-preflight.md" => "trust and preflight\n",
      "LICENSE" => "fixture license\n",
      "bin/agent-workflow-seam-doctor" => "#!/bin/sh\n",
      "bin/agent-workflows-delivery-state" => File.binread(File.join(ROOT, "bin/agent-workflows-delivery-state")),
      "bin/agent-workflows-doctor" => "#!/bin/sh\n",
      "bin/agent-workflows-status" => "#!/bin/sh\n",
      "bin/agent-workflows-trust-audit" => "#!/bin/sh\n",
      "bin/agent_doctor/timeout_budget.rb" => File.binread(File.join(ROOT, "bin/agent_doctor/timeout_budget.rb")),
      "bin/agent-workflows-resolve" => File.binread(File.join(ROOT, "bin/agent-workflows-resolve")),
      "bin/agent-workflows-run" => File.binread(File.join(ROOT, "bin/agent-workflows-run")),
      "bin/agent-workflows-operation-launcher" => File.binread(File.join(ROOT, "bin/agent-workflows-operation-launcher")),
      "bin/install-agent-workflows" => "#!/bin/sh\n",
      "bin/upgrade-agent-workflows" => "#!/bin/sh\n",
      "operation-capabilities.json" => File.binread(File.join(ROOT, "operation-capabilities.json"))
    }
    BOUND_SKILLS.each do |name|
      files["skills/#{name.tr('_', '-')}/SKILL.md"] = "operation snapshot #{name} skill\n"
    end
    Dir.glob(File.join(ROOT, "bin/agent_workflows_operation", "*.rb")).each do |path|
      files["bin/agent_workflows_operation/#{File.basename(path)}"] = File.binread(path)
    end
    files.each do |relative, content|
      path = File.join(@source, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, content)
    end
    FileUtils.chmod(0o755, File.join(@source, "skills/pr-batch/bin/pr-merge-submit"))
    %w[
      agent-workflow-seam-doctor
      agent-workflows-delivery-state
      agent-workflows-doctor
      agent-workflows-resolve
      agent-workflows-run
      agent-workflows-status
      agent-workflows-trust-audit
      agent-workflows-operation-launcher
      install-agent-workflows
      upgrade-agent-workflows
    ].each do |name|
      FileUtils.chmod(0o755, File.join(@source, "bin", name))
    end
  end

  def install_provider
    reset_native_provider
    FileUtils.mkdir_p(File.join(@target, "bin"))
    AgentWorkflowsOperation::Provider::COMPANION_BIN_FILES.each do |relative|
      name = File.basename(relative)
      FileUtils.cp(File.join(@source, "bin", name), File.join(@target, "bin", name), preserve: true)
    end
    FileUtils.cp_r(
      File.join(@source, "bin/agent_workflows_operation"),
      File.join(@target, "bin/agent_workflows_operation"),
      preserve: true
    )
    FileUtils.mkdir_p(File.join(@target, "bin/agent_doctor"))
    FileUtils.cp(
      File.join(@source, "bin/agent_doctor/timeout_budget.rb"),
      File.join(@target, "bin/agent_doctor/timeout_budget.rb")
    )
    FileUtils.cp_r(File.join(@source, "workflows"), File.join(@target, "workflows"))
    FileUtils.mkdir_p(File.join(@target, "docs"))
    AgentWorkflowsOperation::Provider::COMPANION_DOC_FILES.each do |relative|
      FileUtils.cp(File.join(@source, relative), File.join(@target, relative))
    end
    FileUtils.cp(File.join(@source, "LICENSE"), File.join(@target, "LICENSE"))
    @fake_gh = File.join(@tmp, "fake-gh")
    File.write(@fake_gh, "#!/bin/sh\nprintf 'fixture-gh\\n'\n")
    FileUtils.chmod(0o755, @fake_gh)
    write_metadata(
      "host" => "codex",
      "mode" => "copy",
      "delivery_mode" => "plugin-companion",
      "provider_profile" => "managed",
      "source_revision" => @revision,
      "gh_executable" => @fake_gh
    )
    @fake_codex = File.join(@tmp, "fake-codex")
    File.write(
      @fake_codex,
      "#!/bin/sh\n" \
      "printf '%s\\n' " \
      "'scw@agent-workflows  installed, enabled  0.1.0  https://github.com/shakacode/agent-workflows.git'\n"
    )
    FileUtils.chmod(0o755, @fake_codex)
  end

  def install_claude_provider(target)
    native_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
    FileUtils.mkdir_p(File.dirname(native_root))
    system("git", "clone", "--quiet", @source, native_root, exception: true)
    system("git", "-C", native_root, "checkout", "--quiet", @revision, exception: true)
    FileUtils.rm_rf(File.join(native_root, ".git"))
    FileUtils.mkdir_p(File.join(target, "plugins"))
    File.write(
      File.join(target, "settings.json"),
      "#{JSON.pretty_generate('enabledPlugins' => { 'scw@agent-workflows' => true })}\n"
    )
    File.write(
      File.join(target, "plugins/installed_plugins.json"),
      "#{JSON.pretty_generate(
        'version' => 2,
        'plugins' => {
          'scw@agent-workflows' => [{
            'scope' => 'user',
            'installPath' => native_root,
            'version' => 'unknown',
            'gitCommitSha' => @revision
          }]
        }
      )}\n"
    )
    install_companion_files(target)
    write_metadata_at(
      target,
      "host" => "claude",
      "mode" => "copy",
      "delivery_mode" => "plugin-companion",
      "provider_profile" => "managed",
      "source_revision" => @revision,
      "gh_executable" => @fake_gh
    )
  end

  def install_companion_files(target)
    FileUtils.mkdir_p(File.join(target, "bin"))
    AgentWorkflowsOperation::Provider::COMPANION_BIN_FILES.each do |relative|
      FileUtils.cp(File.join(@source, relative), File.join(target, "bin", File.basename(relative)), preserve: true)
    end
    FileUtils.cp_r(
      File.join(@source, "bin/agent_workflows_operation"),
      File.join(target, "bin/agent_workflows_operation"),
      preserve: true
    )
    FileUtils.mkdir_p(File.join(target, "bin/agent_doctor"))
    FileUtils.cp(
      File.join(@source, "bin/agent_doctor/timeout_budget.rb"),
      File.join(target, "bin/agent_doctor/timeout_budget.rb")
    )
    FileUtils.cp_r(File.join(@source, "workflows"), File.join(target, "workflows"))
    FileUtils.mkdir_p(File.join(target, "docs"))
    AgentWorkflowsOperation::Provider::COMPANION_DOC_FILES.each do |relative|
      FileUtils.cp(File.join(@source, relative), File.join(target, relative))
    end
    FileUtils.cp(File.join(@source, "LICENSE"), File.join(target, "LICENSE"))
  end

  def reset_native_provider
    FileUtils.rm_rf(native_provider_root)
    FileUtils.mkdir_p(File.dirname(native_provider_root))
    system("git", "clone", "--quiet", @source, native_provider_root, exception: true)
    system("git", "-C", native_provider_root, "checkout", "--quiet", @revision, exception: true)
    FileUtils.mkdir_p(@target)
    File.write(File.join(@target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
  end

  def read_metadata
    JSON.parse(File.binread(File.join(@target, ".agent-workflows-install.json")))
  end

  def write_metadata(metadata)
    write_metadata_at(@target, metadata)
  end

  def write_metadata_at(target, metadata)
    File.write(File.join(target, ".agent-workflows-install.json"), "#{JSON.pretty_generate(metadata)}\n")
  end

  def commit_all(message)
    system("git", "-C", @source, "add", ".", exception: true)
    system("git", "-C", @source, "commit", "--quiet", "-m", message, exception: true)
    Open3.capture2("git", "-C", @source, "rev-parse", "HEAD").first.strip
  end

  def commit_file(name, message)
    File.write(File.join(@source, name), "#{name}\n")
    commit_all(message)
  end

  def advance_source(name)
    @revision = commit_file(name, name)
    publish_source
  end

  def reset_source_to(revision)
    system("git", "-C", @source, "reset", "--hard", "--quiet", revision, exception: true)
    @revision = revision
  end

  def publish_source
    system("git", "-C", @source, "push", "--quiet", "--force", @served_repo, "main", exception: true)
    system("git", "--git-dir", @served_repo, "update-server-info", exception: true)
  end

  def start_http_server
    publish_source
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    @server_pid = Process.spawn(
      "python3", "-m", "http.server", port.to_s, "--bind", "127.0.0.1", "--directory", @tmp,
      out: File::NULL, err: File::NULL
    )
    @fixture_url = "http://127.0.0.1:#{port}/served.git"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Errno::ECONNREFUSED
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def with_environment(values)
    old = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  class TestResolver < AgentWorkflowsOperation::Resolver
    attr_accessor :cleanup_probe

    def initialize(host:, target:, fixture_url:)
      @fixture_url = fixture_url
      super(host: host, target: target)
    end

    private

    def fetch_current_store!
      store.send(:fetch_url!, @fixture_url, cleanup_probe: cleanup_probe)
    end
  end
end
