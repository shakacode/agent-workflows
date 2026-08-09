#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "etc"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

SCRIPT = File.expand_path("hosted-qa-readiness", __dir__)
load SCRIPT unless defined?(HostedQaReadiness)

class HostedQaReadinessTest < Minitest::Test
  def with_repo
    Dir.mktmpdir("hosted-qa-readiness-test") do |root|
      run_git!(root, "init", "-q")
      run_git!(root, "config", "user.name", "Test User")
      run_git!(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      yield root
    end
  end

  def write(root, path, content, executable: false)
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
    File.chmod(0o755, absolute) if executable
  end

  def commit!(root, message)
    run_git!(root, "add", "--all")
    run_git!(root, "commit", "-q", "-m", message)
    run_git!(root, "rev-parse", "HEAD").strip
  end

  def run_git!(root, *arguments)
    out, status = Open3.capture2e(
      { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL },
      "git", *arguments,
      chdir: root
    )
    raise "git fixture failed: #{out}" unless status.success?

    out
  end

  def with_environment(overrides)
    originals = overrides.to_h { |name, _value| [name, ENV[name]] }
    overrides.each { |name, value| ENV[name] = value }
    yield
  ensure
    originals&.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  def run_readiness(root, base_sha:, head_sha:, evidence: "", env: {})
    out, status = Open3.capture2e(
      env,
      "ruby", SCRIPT,
      "--repo", root,
      "--base-sha", base_sha,
      "--head-sha", head_sha,
      "--evidence", "-",
      stdin_data: evidence
    )
    [JSON.parse(out), status]
  end

  def hosted_policy(change_paths: ["app/**"], waiver_mode: "forbidden")
    {
      "hosted_qa_gate" => {
        "version" => 1,
        "change_paths" => change_paths,
        "target" => "production",
        "deployment_verifier" => ".agents/bin/verify-hosted-deployment",
        "acceptance_criteria" => %w[sign-in checkout],
        "waiver_mode" => waiver_mode
      }
    }.to_yaml
  end

  def hosted_evidence(
    head_sha:,
    deployed_head_sha: head_sha,
    status: "satisfied",
    criteria: %w[sign-in checkout],
    deployment_id: "production-#{head_sha}",
    deployment_url: "https://deployments.example.test/#{head_sha}"
  )
    rows = criteria.map do |criterion|
      "criterion: id=#{criterion} | status=passed | evidence=https://evidence.example.test/#{criterion}-#{head_sha}"
    end
    <<~MARKDOWN
      <!-- hosted-qa-evidence v1
      status: #{status}
      head_sha: #{head_sha}
      deployed_head_sha: #{deployed_head_sha}
      deployment_id: #{deployment_id}
      deployment_url: #{deployment_url}
      target: production
      #{rows.join("\n")}
      -->
    MARKDOWN
  end

  def hosted_waiver_evidence(head_sha:, waiver_url:)
    <<~MARKDOWN
      <!-- hosted-qa-evidence v1
      status: waived
      head_sha: #{head_sha}
      target: production
      maintainer_waiver: #{waiver_url}
      -->
    MARKDOWN
  end

  def test_trusted_base_na_policy_is_not_applicable_without_an_adoption_change
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, "README.md", "documentation only\n")
      head_sha = commit!(root, "head")

      result, status = run_readiness(root, base_sha:, head_sha:)

      assert status.success?, result
      assert_equal "NOT_APPLICABLE", result.fetch("verdict")
      assert_equal "trusted_base", result.fetch("policy_source")
      assert_equal base_sha, result.fetch("base_sha")
      assert_equal head_sha, result.fetch("head_sha")
    end
  end

  def test_git_capture_uses_only_a_sanitized_guarded_direct_environment
    with_repo do |root|
      captured = nil
      successful_status = Struct.new(:success?).new(true)
      original_capture = Open3.method(:capture3)
      capture = lambda do |environment, command, *arguments, **options|
        captured = { environment:, command:, arguments:, options: }
        ["", "", successful_status]
      end
      hostile_environment = {
        "PATH" => File.join(root, "repo-bin"),
        "GIT_SSH_COMMAND" => File.join(root, "steal-ssh"),
        "GIT_ASKPASS" => File.join(root, "steal-credentials"),
        "GIT_CONFIG_GLOBAL" => File.join(root, "hostile.gitconfig"),
        "GIT_CONFIG_SYSTEM" => File.join(root, "hostile-system.gitconfig"),
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "alias.status",
        "GIT_CONFIG_VALUE_0" => "!false",
        "GIT_CONFIG_PARAMETERS" => "'alias.status=!false'"
      }

      begin
        Open3.singleton_class.send(:define_method, :capture3, capture)
        with_environment(hostile_environment) do
          HostedQaReadiness.git_capture(root, "status", "--short")
        end
      ensure
        Open3.singleton_class.send(:define_method, :capture3, original_capture)
      end

      account = Etc.getpwuid(Process.uid)
      expected_environment = {
        "HOME" => account.dir,
        "USER" => account.name,
        "LOGNAME" => account.name,
        "PATH" => %w[/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin].join(File::PATH_SEPARATOR),
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_TERMINAL_PROMPT" => "0"
      }
      assert_equal expected_environment, captured.fetch(:environment)
      assert_equal ["-C", root, "status", "--short"], captured.fetch(:arguments)
      assert_equal({ chdir: root, unsetenv_others: true }, captured.fetch(:options))
      refute_includes captured.dig(:environment, "PATH").split(File::PATH_SEPARATOR), File.join(root, "repo-bin")
    end
  end

  def test_git_capture_rejects_system_git_resolving_inside_the_candidate_repository
    with_repo do |root|
      repository_git = File.join(root, "repo-controlled-git")
      outside_link = "#{root}-system-git"
      write(root, "repo-controlled-git", "#!/bin/sh\nexit 0\n", executable: true)
      File.symlink(repository_git, outside_link)
      original_system_git = HostedQaReadiness::SYSTEM_GIT

      begin
        HostedQaReadiness.send(:remove_const, :SYSTEM_GIT)
        HostedQaReadiness.const_set(:SYSTEM_GIT, outside_link)

        error = assert_raises(Errno::ENOENT) do
          HostedQaReadiness.git_capture(root, "status", "--short")
        end
        assert_includes error.message, "trusted system git is unavailable"
      ensure
        HostedQaReadiness.send(:remove_const, :SYSTEM_GIT)
        HostedQaReadiness.const_set(:SYSTEM_GIT, original_system_git)
        FileUtils.rm_f(outside_link)
      end
    end
  end

  def test_first_adoption_allows_only_the_policy_and_its_verifier
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      head_sha = commit!(root, "bootstrap hosted QA")

      result, status = run_readiness(root, base_sha:, head_sha:)

      assert status.success?, result
      assert_equal "BOOTSTRAP_ALLOWED", result.fetch("verdict")
      assert_equal [
        ".agents/agent-workflow.yml",
        ".agents/bin/verify-hosted-deployment"
      ], result.fetch("changed_paths").sort
      assert_empty result.fetch("blockers")
    end
  end

  def test_first_adoption_does_not_treat_managed_bootstrap_paths_as_broad_runtime_changes
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, ".agents/agent-workflow.yml", hosted_policy(change_paths: ["**"]))
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      head_sha = commit!(root, "bootstrap broad hosted QA policy")

      result, status = run_readiness(root, base_sha:, head_sha:)

      assert status.success?, result
      assert_equal "BOOTSTRAP_ALLOWED", result.fetch("verdict")
      assert_empty result.fetch("blockers")
    end
  end

  def test_first_adoption_blocks_mixed_policy_and_runtime_changes
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/controllers/session_controller.rb", "runtime change\n")
      head_sha = commit!(root, "mixed bootstrap and runtime")

      result, status = run_readiness(root, base_sha:, head_sha:)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_equal [
        "hosted QA policy bootstrap is mixed with configured runtime changes: app/controllers/session_controller.rb"
      ], result.fetch("blockers")
    end
  end

  def test_first_adoption_requires_the_declared_verifier_in_the_bootstrap_diff
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      head_sha = commit!(root, "incomplete bootstrap")

      result, status = run_readiness(root, base_sha:, head_sha:)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"),
                      "hosted QA policy bootstrap must add or update its declared verifier: .agents/bin/verify-hosted-deployment"
    end
  end

  def test_first_adoption_requires_the_candidate_verifier_to_be_present_and_executable_at_head
    observed = []
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      base_sha = commit!(root, "base")
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n")
      head_sha = commit!(root, "bootstrap with non-executable verifier")

      result, status = run_readiness(root, base_sha:, head_sha:)
      observed << [result.fetch("verdict"), status.success?, result.fetch("blockers")]
    end
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", "---\nhosted_qa_gate: n/a\n")
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      base_sha = commit!(root, "base with an unconfigured verifier")
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      FileUtils.rm_f(File.join(root, ".agents/bin/verify-hosted-deployment"))
      head_sha = commit!(root, "bootstrap deleting the declared verifier")

      result, status = run_readiness(root, base_sha:, head_sha:)
      observed << [result.fetch("verdict"), status.success?, result.fetch("blockers")]
    end

    expected_blocker = "candidate hosted QA deployment verifier must be a tracked executable regular file"
    assert_equal [
      ["BLOCKED", false, [expected_blocker]],
      ["BLOCKED", false, [expected_blocker]]
    ], observed
  end

  def test_generic_qa_evidence_cannot_satisfy_an_applicable_hosted_gate
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with hosted policy")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")
      generic_evidence = <<~MARKDOWN
        <!-- qa-evidence v2
        required: yes
        status: satisfied
        head_sha: #{head_sha}
        -->
      MARKDOWN

      result, status = run_readiness(root, base_sha:, head_sha:, evidence: generic_evidence)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"),
                      "hosted-qa-evidence v1 marker is required; qa-evidence markers are not hosted deployment proof"
    end
  end

  def test_trusted_policy_changes_are_always_applicable
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy(change_paths: ["app/**"]))
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      base_sha = commit!(root, "base with hosted policy")
      write(
        root,
        ".agents/agent-workflow.yml",
        hosted_policy(change_paths: ["app/**"], waiver_mode: "maintainer")
      )
      head_sha = commit!(root, "change hosted policy")

      result, status = run_readiness(root, base_sha:, head_sha:)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_equal [".agents/agent-workflow.yml"], result.fetch("applicable_paths")
      assert_includes result.fetch("blockers"), "hosted-qa-evidence v1 marker is required; " \
                                                "qa-evidence markers are not hosted deployment proof"
    end
  end

  def test_trusted_deployment_verifier_changes_are_always_applicable
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy(change_paths: ["app/**"]))
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\nputs 'base'\n", executable: true)
      base_sha = commit!(root, "base with hosted policy")
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\nputs 'head'\n", executable: true)
      head_sha = commit!(root, "change hosted deployment verifier")

      result, status = run_readiness(root, base_sha:, head_sha:)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_equal [".agents/bin/verify-hosted-deployment"], result.fetch("applicable_paths")
      assert_includes result.fetch("blockers"), "hosted-qa-evidence v1 marker is required; " \
                                                "qa-evidence markers are not hosted deployment proof"
    end
  end

  def test_deployed_head_must_equal_the_exact_current_head
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with hosted policy")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:, deployed_head_sha: base_sha)
      )

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"),
                      "hosted QA evidence is not structurally replayable: deployed_head_sha"
    end
  end

  def test_every_configured_acceptance_criterion_requires_exactly_one_row
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with hosted policy")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:, criteria: ["sign-in"])
      )

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"),
                      "hosted QA criterion coverage mismatch: missing checkout"
    end
  end

  def test_duplicate_acceptance_criterion_rows_fail_closed
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with hosted policy")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:, criteria: %w[sign-in checkout checkout])
      )

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert result.fetch("blockers").any? { |blocker| blocker.include?("duplicate criterion id: checkout") }, result
    end
  end

  def test_invokes_only_the_trusted_base_verifier_with_explicit_argv
    with_repo do |root|
      argv_log = File.join(root, "verifier-argv.json")
      verifier = <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        arguments = ARGV.each_slice(2).to_h
        File.write(#{argv_log.dump}, JSON.generate(ARGV))
        puts JSON.generate(
          "version" => 1,
          "verified" => true,
          "deployment_id" => arguments.fetch("--deployment-id"),
          "deployment_url" => arguments.fetch("--deployment-url"),
          "deployed_head_sha" => arguments.fetch("--expected-head-sha"),
          "target" => arguments.fetch("--target")
        )
      RUBY
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", verifier, executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with hosted policy")
      write(root, "app/model.rb", "runtime change\n")
      write(
        root,
        ".agents/bin/verify-hosted-deployment",
        "#!/usr/bin/env ruby\nabort 'untrusted head verifier executed'\n",
        executable: true
      )
      head_sha = commit!(root, "runtime and untrusted verifier changes")
      deployment_id = "production-#{head_sha}"
      deployment_url = "https://deployments.example.test/#{head_sha}"

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:, deployment_id:, deployment_url:)
      )

      assert status.success?, result
      assert_equal "READY", result.fetch("verdict")
      assert_equal [
        "--deployment-id", deployment_id,
        "--deployment-url", deployment_url,
        "--expected-head-sha", head_sha,
        "--target", "production"
      ], JSON.parse(File.read(argv_log))
      assert_equal "trusted_base", result.dig("deployment_verification", "verifier_source")
    end
  end

  def test_rejects_a_trusted_verifier_interpreter_inside_the_candidate_repository
    with_repo do |root|
      interpreter_path = File.join(root, "tools", "repo-ruby")
      execution_log = File.join(root, "untrusted-interpreter-executed")
      verifier = <<~RUBY
        #!#{interpreter_path}
        deployment_id=""
        deployment_url=""
        expected_head_sha=""
        target=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --deployment-id) deployment_id="$2" ;;
            --deployment-url) deployment_url="$2" ;;
            --expected-head-sha) expected_head_sha="$2" ;;
            --target) target="$2" ;;
          esac
          shift 2
        done
        printf 'executed\n' > #{execution_log.dump}
        printf '{"version":1,"verified":true,"deployment_id":"%s","deployment_url":"%s","deployed_head_sha":"%s","target":"%s"}\n' \
          "$deployment_id" "$deployment_url" "$expected_head_sha" "$target"
      RUBY
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", verifier, executable: true)
      FileUtils.mkdir_p(File.join(root, "tools"))
      File.symlink(RbConfig.ruby, interpreter_path)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with repository-local verifier interpreter")

      FileUtils.rm_f(interpreter_path)
      File.symlink("/bin/sh", interpreter_path)
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "replace repository-local interpreter")

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:)
      )

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"),
                      "trusted-base deployment verifier interpreter must resolve outside the candidate repository"
      refute_path_exists execution_log
    end
  end

  def test_accepts_a_trusted_absolute_interpreter_outside_the_candidate_repository
    with_repo do |root|
      verifier = <<~RUBY
        #!#{File.realpath(RbConfig.ruby)}
        require "json"
        arguments = ARGV.each_slice(2).to_h
        puts JSON.generate(
          "version" => 1,
          "verified" => true,
          "deployment_id" => arguments.fetch("--deployment-id"),
          "deployment_url" => arguments.fetch("--deployment-url"),
          "deployed_head_sha" => arguments.fetch("--expected-head-sha"),
          "target" => arguments.fetch("--target")
        )
      RUBY
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", verifier, executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with absolute trusted interpreter")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:)
      )

      assert status.success?, result
      assert_equal "READY", result.fetch("verdict")
    end
  end

  def test_rejects_missing_relative_ambiguous_and_options_bearing_verifier_shebangs
    with_repo do |root|
      malformed = {
        "missing" => "puts 'missing shebang'\n",
        "relative" => "#!ruby\n",
        "env without program" => "#!/usr/bin/env\n",
        "env with options" => "#!/usr/bin/env -S ruby\n",
        "env with multiple arguments" => "#!/usr/bin/env ruby -w\n",
        "absolute with arguments" => "#!#{File.realpath(RbConfig.ruby)} -w\n",
        "alternate env path" => "#!/bin/env ruby\n"
      }

      errors = malformed.to_h do |label, blob|
        interpreter, error = HostedQaReadiness.trusted_verifier_interpreter(root, blob)
        assert_nil interpreter, label
        [label, error]
      end

      assert_includes errors.fetch("missing"), "supported explicit shebang"
      ["relative", "env with options", "env with multiple arguments"].each do |label|
        assert_includes errors.fetch(label), "unsupported shebang", label
      end
      assert_includes errors.fetch("env without program"), "must name one fixed program"
      assert_includes errors.fetch("absolute with arguments"), "must not include arguments"
      assert_includes errors.fetch("alternate env path"), "must not include arguments"
    end
  end

  def test_closes_the_verifier_tempfile_before_process_invocation
    head_sha = "1" * 40
    fields = {
      "deployment_id" => "production-#{head_sha}",
      "deployment_url" => "https://deployments.example.test/#{head_sha}",
      "head_sha" => head_sha,
      "target" => "production"
    }
    observed_tempfile = nil
    original_tempfile_create = Tempfile.method(:create)
    tempfile_create = lambda do |*arguments, &block|
      original_tempfile_create.call(*arguments) do |file|
        observed_tempfile = file
        block.call(file)
      end
    end
    success_status = Object.new
    success_status.define_singleton_method(:success?) { true }
    test_case = self
    capture = lambda do |command, input:, timeout:, **_options|
      test_case.assert_equal File.realpath(RbConfig.ruby), command.first
      test_case.assert_equal observed_tempfile.path, command[1]
      test_case.assert observed_tempfile.closed?, "verifier tempfile must be closed before execution"
      test_case.assert_equal "", input
      test_case.assert_equal 30, timeout
      receipt = fields.slice("deployment_id", "deployment_url", "target").merge(
        "version" => 1,
        "verified" => true,
        "deployed_head_sha" => head_sha
      )
      [JSON.generate(receipt), "", success_status]
    end

    original_blob_reader = HostedQaReadiness.method(:trusted_executable_blob)
    original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
    begin
      Tempfile.singleton_class.send(:define_method, :create, tempfile_create)
      HostedQaReadiness.singleton_class.send(:define_method, :trusted_executable_blob) do |*_arguments|
        ["#!/usr/bin/env ruby\n", nil]
      end
      CompletedBatchPublicationPreflight.singleton_class.send(:define_method, :capture_process, capture)

      verification, error = HostedQaReadiness.verify_deployment(
        repo: Dir.tmpdir,
        base_sha: "0" * 40,
        verifier_path: ".agents/bin/verify-hosted-deployment",
        fields:
      )
    ensure
      Tempfile.singleton_class.send(:define_method, :create, original_tempfile_create)
      HostedQaReadiness.singleton_class.send(:define_method, :trusted_executable_blob, original_blob_reader)
      CompletedBatchPublicationPreflight.singleton_class.send(:define_method, :capture_process, original_capture)
    end

    assert_nil error
    assert_equal "trusted_base", verification.fetch("verifier_source")
    refute_path_exists observed_tempfile.path
  end

  def test_trusted_verifier_runs_with_only_controlled_environment_in_a_safe_temporary_directory
    with_repo do |root|
      environment_log = File.join(root, "verifier-environment.json")
      verifier = <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        arguments = ARGV.each_slice(2).to_h
        File.write(
          #{environment_log.dump},
          JSON.generate("cwd" => Dir.pwd, "environment" => ENV.to_h)
        )
        puts JSON.generate(
          "version" => 1,
          "verified" => true,
          "deployment_id" => arguments.fetch("--deployment-id"),
          "deployment_url" => arguments.fetch("--deployment-url"),
          "deployed_head_sha" => arguments.fetch("--expected-head-sha"),
          "target" => arguments.fetch("--target")
        )
      RUBY
      write(root, ".agents/agent-workflow.yml", hosted_policy)
      write(root, ".agents/bin/verify-hosted-deployment", verifier, executable: true)
      base_sha = commit!(root, "base with hosted verifier")
      repo_bin = File.join(root, "repo-bin")
      FileUtils.mkdir_p(repo_bin)
      fields = {
        "deployment_id" => "production-#{base_sha}",
        "deployment_url" => "https://deployments.example.test/#{base_sha}",
        "head_sha" => base_sha,
        "target" => "production"
      }

      verification = error = nil
      with_environment(
        "PATH" => [repo_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "RUBYOPT" => "-W0",
        "RUBYLIB" => File.join(root, "repo-lib"),
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile.hostile")
      ) do
        verification, error = HostedQaReadiness.verify_deployment(
          repo: root,
          base_sha:,
          verifier_path: ".agents/bin/verify-hosted-deployment",
          fields:
        )
      end

      assert_nil error
      assert_equal "trusted_base", verification.fetch("verifier_source")
      observed = JSON.parse(File.read(environment_log))
      observed_cwd = observed.fetch("cwd")
      account = Etc.getpwuid(Process.uid)
      assert_equal observed_cwd, observed.dig("environment", "HOME")
      assert_equal account.name, observed.dig("environment", "USER")
      assert_equal account.name, observed.dig("environment", "LOGNAME")
      expected_path = [
        File.dirname(File.realpath(RbConfig.ruby)),
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
      ].filter_map do |directory|
        File.realpath(directory)
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end.uniq.join(File::PATH_SEPARATOR)
      assert_equal expected_path, observed.dig("environment", "PATH")
      %w[BUNDLE_GEMFILE RUBYLIB RUBYOPT].each do |name|
        refute observed.fetch("environment").key?(name), name
      end
      refute_includes observed.dig("environment", "PATH").split(File::PATH_SEPARATOR), repo_bin
      repository_realpath = File.realpath(root)
      refute_equal repository_realpath, observed_cwd
      refute observed_cwd.start_with?("#{repository_realpath}#{File::SEPARATOR}"), observed_cwd
      refute_path_exists observed_cwd
    end
  end

  def test_forbidden_waiver_mode_blocks_a_hosted_qa_waiver
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy(waiver_mode: "forbidden"))
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with forbidden waivers")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")
      waiver_url = "https://github.com/example/repo/pull/123#issuecomment-456"

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_waiver_evidence(head_sha:, waiver_url:)
      )

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert_includes result.fetch("blockers"), "trusted-base hosted QA policy forbids waivers"
    end
  end

  def test_maintainer_waiver_uses_the_existing_authenticated_exact_head_machinery
    with_repo do |root|
      write(root, ".agents/agent-workflow.yml", hosted_policy(waiver_mode: "maintainer"))
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      write(root, "app/model.rb", "base\n")
      base_sha = commit!(root, "base with maintainer waivers")
      write(root, "app/model.rb", "runtime change\n")
      head_sha = commit!(root, "runtime change")
      review_target_url = "https://github.com/example/repo/pull/123"
      waiver_url = "#{review_target_url}#issuecomment-456"
      waiver_marker = <<~MARKDOWN.chomp
        <!-- qa-maintainer-waiver v1
        target: #{review_target_url}
        head_sha: #{head_sha}
        decision: waived
        -->
      MARKDOWN
      authenticated_comment = {
        "id" => 456,
        "html_url" => waiver_url,
        "issue_url" => "https://api.github.com/repos/example/repo/issues/123",
        "created_at" => "2026-08-08T12:00:00Z",
        "updated_at" => "2026-08-08T12:00:00Z",
        "author_association" => "MEMBER",
        "user" => { "login" => "maintainer", "type" => "User" },
        "body" => waiver_marker
      }
      verifier_calls = []
      waiver_verifier = lambda do |host:, repo:, comment_id:|
        verifier_calls << [host, repo, comment_id]
        authenticated_comment
      end

      result = HostedQaReadiness.assess(
        repo: root,
        base_sha:,
        head_sha:,
        evidence: hosted_waiver_evidence(head_sha:, waiver_url:),
        review_target_url:,
        waiver_verifier:
      )

      assert result.fetch("eligible"), result
      assert_equal "WAIVED", result.fetch("verdict")
      assert_equal [["github.com", "example/repo", 456]], verifier_calls
      assert_equal "authenticated gh api", result.dig("maintainer_waiver", "verification_source")
      assert_equal head_sha, result.dig("maintainer_waiver", "head_sha")
    end
  end

  def test_malformed_or_duplicate_trusted_base_policy_blocks_even_when_paths_do_not_apply
    with_repo do |root|
      duplicate_policy = hosted_policy.sub(
        "  target: production\n",
        "  target: production\n  target: shadow-production\n"
      )
      write(root, ".agents/agent-workflow.yml", duplicate_policy)
      write(root, ".agents/bin/verify-hosted-deployment", "#!/usr/bin/env ruby\n", executable: true)
      base_sha = commit!(root, "base with duplicate hosted policy")
      write(root, "README.md", "documentation only\n")
      head_sha = commit!(root, "documentation change")

      result, status = run_readiness(root, base_sha:, head_sha:)

      refute status.success?
      assert_equal "BLOCKED", result.fetch("verdict")
      assert result.fetch("blockers").any? { |blocker| blocker.include?("duplicate key \"target\"") }, result
    end
  end
end
