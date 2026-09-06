#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("configured-evidence-upload", __dir__)
load SCRIPT

class ConfiguredEvidenceUploadTest < Minitest::Test
  ATTACHMENT_URL = "https://github.com/user-attachments/assets/12345678-1234-1234-1234-123456789abc"

  def test_configured_trusted_wrapper_returns_attachment_url
    with_repo do |root|
      write_policy(root, configured: true)
      expected_skill_root = File.expand_path("..", __dir__)
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        abort "manual-testing skill root missing" unless ENV["MANUAL_TESTING_SKILL_DIR"] == #{expected_skill_root.inspect}
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      base_sha = commit!(root, "configure evidence uploader")
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      assert status.success?, stderr
      assert_equal "#{ATTACHMENT_URL}\n", stdout
      assert_empty stderr
    end
  end

  def test_absent_configuration_fails_closed_without_running_a_wrapper
    with_repo do |root|
      write_policy(root, configured: false)
      marker = File.join(root, "wrapper-ran")
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        File.write(#{marker.inspect}, "ran")
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      base_sha = commit!(root, "leave evidence uploader disabled")
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      assert_equal 69, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "is absent or not the exact verified version 1 configuration"
      refute_path_exists marker
    end
  end

  def test_configured_wrapper_failure_fails_closed_without_forwarding_its_output
    with_repo do |root|
      write_policy(root, configured: true)
      write_wrapper(root, <<~'RUBY')
        #!/usr/bin/env ruby
        puts "not-a-url"
        warn "potentially sensitive child output"
        exit 9
      RUBY
      base_sha = commit!(root, "configure failing evidence uploader")
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "configured uploader failed with exit 9"
      refute_includes stderr, "potentially sensitive"
    end
  end

  def test_hostile_or_noncanonical_wrapper_output_fails_closed
    invalid_outputs = [
      "https://github.com/user-attachments/assets/good?token=secret",
      "https://evil.example/user-attachments/assets/good",
      "#{ATTACHMENT_URL}\nextra-output"
    ]

    invalid_outputs.each do |output|
      with_repo do |root|
        write_policy(root, configured: true)
        write_wrapper(root, <<~RUBY)
          #!/usr/bin/env ruby
          puts #{output.inspect}
        RUBY
        base_sha = commit!(root, "configure hostile evidence uploader")
        artifact = write_artifact(root)

        stdout, stderr, status = run_upload(root, base_sha, artifact)

        refute status.success?, output
        assert_empty stdout, output
        assert_includes stderr, "invalid GitHub user-attachments URL", output
      end
    end
  end

  def test_trusted_base_wrapper_bytes_run_even_when_the_live_wrapper_changes
    with_repo do |root|
      write_policy(root, configured: true)
      wrapper = <<~RUBY
        #!/usr/bin/env ruby
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      write_wrapper(root, wrapper)
      base_sha = commit!(root, "configure evidence uploader")
      write_wrapper(root, wrapper.sub(ATTACHMENT_URL, "https://evil.example/asset"))
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      assert status.success?, stderr
      assert_equal "#{ATTACHMENT_URL}\n", stdout
      assert_empty stderr
    end
  end

  def test_missing_policy_file_returns_absent_configuration_without_an_uncaught_throw
    with_repo do |root|
      write_wrapper(root, "#!/usr/bin/env ruby\nabort 'must not run'\n")
      base_sha = commit!(root, "omit policy file")
      artifact = write_artifact(root)
      code = nil
      arguments = ["--repo-root", root, "--trusted-base", base_sha, artifact]

      stdout, stderr = capture_io do
        code = ConfiguredEvidenceUpload.run(arguments)
      end

      assert_equal 69, code
      assert_empty stdout
      assert_includes stderr, "configuration is absent"
      refute_includes stderr, "UncaughtThrowError"
    end
  end

  def test_symlink_artifact_is_rejected_before_the_wrapper_runs
    with_repo do |root|
      write_policy(root, configured: true)
      marker = File.join(root, "wrapper-ran")
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        File.write(#{marker.inspect}, "ran")
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      base_sha = commit!(root, "configure evidence uploader")
      artifact = write_artifact(root)
      symlink = File.join(root, "artifacts", "linked.png")
      File.symlink(artifact, symlink)

      stdout, stderr, status = run_upload(root, base_sha, symlink)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "artifact must be a non-symlink regular file"
      refute_path_exists marker
    end
  end

  def test_inaccessible_artifact_is_rejected_before_the_wrapper_runs
    with_repo do |root|
      write_policy(root, configured: true)
      marker = File.join(root, "wrapper-ran")
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        File.write(#{marker.inspect}, "ran")
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      base_sha = commit!(root, "configure evidence uploader")
      artifact = write_artifact(root)
      artifact_directory = File.dirname(artifact)
      File.chmod(0o000, artifact_directory)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "artifact must be an existing non-symlink regular file"
      refute_path_exists marker
    ensure
      File.chmod(0o700, artifact_directory) if artifact_directory && File.exist?(artifact_directory)
    end
  end

  def test_configured_wrapper_composes_with_reference_uploader_using_stubbed_tools
    with_repo do |root|
      write_policy(root, configured: true)
      stub_directory = File.join(root, "stub-tools")
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        ENV["PATH"] = #{stub_directory.inspect} + File::PATH_SEPARATOR + ENV.fetch("PATH")
        exec File.join(ENV.fetch("MANUAL_TESTING_SKILL_DIR"), "bin", "github-user-attachments-upload"), *ARGV
      RUBY
      base_sha = commit!(root, "configure reference evidence uploader")
      write_stub(root, "gh", <<~'RUBY')
        #!/usr/bin/env ruby
        case ARGV
        when ["auth", "token"]
          puts "github_pat_fixture"
        when ["api", "repos/shakacode/agent-workflows", "--jq", ".id"]
          puts "12345"
        else
          exit 2
        end
      RUBY
      write_stub(root, "git", <<~'RUBY')
        #!/usr/bin/env ruby
        abort "unexpected git invocation" unless ARGV == ["remote", "get-url", "origin"]
        puts "git@github.com:shakacode/agent-workflows.git"
      RUBY
      write_stub(root, "curl", <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts({ "url" => #{ATTACHMENT_URL.inspect} }.to_json)
        print "201"
      RUBY
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact)

      assert status.success?, stderr
      assert_equal "#{ATTACHMENT_URL}\n", stdout
      assert_empty stderr
    end
  end

  def test_configured_wrapper_invocation_has_a_hard_timeout
    with_repo do |root|
      write_policy(root, configured: true)
      write_wrapper(root, <<~'RUBY')
        #!/usr/bin/env ruby
        sleep 10
      RUBY
      base_sha = commit!(root, "configure slow evidence uploader")
      artifact = write_artifact(root)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      stdout, stderr, status = run_upload(root, base_sha, artifact, timeout: 0.05)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "configured uploader timed out"
      assert_operator elapsed, :<, 3
    end
  end

  def test_successful_wrapper_cannot_leave_a_background_process_running
    with_repo do |root|
      write_policy(root, configured: true)
      marker = File.join(root, "background-child-survived")
      write_wrapper(root, <<~RUBY)
        #!/usr/bin/env ruby
        fork do
          sleep 0.5
          File.write(#{marker.inspect}, "survived")
        end
        puts #{ATTACHMENT_URL.inspect}
      RUBY
      base_sha = commit!(root, "configure backgrounding evidence uploader")
      artifact = write_artifact(root)

      stdout, stderr, status = run_upload(root, base_sha, artifact, timeout: 5)
      sleep 0.6

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "configured uploader left a running process group"
      refute_path_exists marker
    end
  end

  private

  def with_repo
    Dir.mktmpdir("configured-evidence-upload-test") do |root|
      run_git!(root, "init", "-q")
      run_git!(root, "config", "user.name", "Test User")
      run_git!(root, "config", "user.email", "test@example.test")
      yield root
    end
  end

  def write_policy(root, configured:)
    value = if configured
              <<~YAML
                visual_evidence_uploader:
                  version: 1
                  provider: github_user_attachments
                  verified: true
              YAML
            else
              "base_branch: main\n"
            end
    write(root, ".agents/agent-workflow.yml", value)
  end

  def write_wrapper(root, content)
    path = write(root, ".agents/bin/upload-evidence", content)
    File.chmod(0o755, path)
  end

  def write_artifact(root, name = "before.png")
    write(root, File.join("artifacts", name), "fixture image bytes")
  end

  def write_stub(root, name, content)
    path = write(root, File.join("stub-tools", name), content)
    File.chmod(0o755, path)
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def commit!(root, message)
    run_git!(root, "add", "--all")
    run_git!(root, "commit", "-q", "-m", message)
    run_git!(root, "rev-parse", "HEAD").strip
  end

  def run_git!(root, *arguments)
    stdout, stderr, status = Open3.capture3(
      { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL },
      "git", *arguments, chdir: root
    )
    raise "git fixture failed: #{stderr}" unless status.success?

    stdout
  end

  def run_upload(root, base_sha, artifact, timeout: nil)
    timeout_args = timeout ? ["--timeout", timeout.to_s] : []
    Open3.capture3(
      "ruby", SCRIPT,
      "--repo-root", root,
      "--trusted-base", base_sha,
      *timeout_args,
      artifact
    )
  end
end
