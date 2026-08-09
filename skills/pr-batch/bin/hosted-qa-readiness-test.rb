#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
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
      verifier = <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        arguments = ARGV.each_slice(2).to_h
        File.write(ENV.fetch("HOSTED_QA_ARGV_LOG"), JSON.generate(ARGV))
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
      argv_log = File.join(root, "verifier-argv.json")
      deployment_id = "production-#{head_sha}"
      deployment_url = "https://deployments.example.test/#{head_sha}"

      result, status = run_readiness(
        root,
        base_sha:,
        head_sha:,
        evidence: hosted_evidence(head_sha:, deployment_id:, deployment_url:),
        env: { "HOSTED_QA_ARGV_LOG" => argv_log }
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
    capture = lambda do |command, input:, timeout:|
      test_case.assert_equal observed_tempfile.path, command.first
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
        repo: "/unused",
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
