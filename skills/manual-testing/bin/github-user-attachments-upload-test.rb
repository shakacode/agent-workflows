#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

SCRIPT = File.expand_path("github-user-attachments-upload", __dir__)
load SCRIPT

class GitHubUserAttachmentsUploadTest < Minitest::Test
  ATTACHMENT_URL = "https://github.com/user-attachments/assets/12345678-1234-1234-1234-123456789abc"

  FakeResult = Data.define(:stdout, :stderr, :status, :timed_out, :output_too_large, :process_group_leaked)

  class FakeStatus
    def initialize(success: true, exitstatus: 0)
      @success = success
      @exitstatus = exitstatus
    end

    attr_reader :exitstatus

    def success?
      @success
    end

    def signaled?
      false
    end
  end

  class SuccessfulRunner
    attr_reader :commands

    def initialize(url, http_status: "201")
      @url = url
      @http_status = http_status
      @commands = []
    end

    def capture(command, **options)
      @commands << [command, options]
      stdout = case command.first
               when "gh"
                 command[1, 2] == %w[auth token] ? "github_pat_fixture\n" : "12345\n"
               when "git"
                 "git@github.com:shakacode/agent-workflows.git\n"
               when "curl"
                 %({"url":#{@url.inspect}}\n#{@http_status})
               else
                 raise "unexpected command: #{command.inspect}"
               end
      FakeResult.new(
        stdout:,
        stderr: "",
        status: FakeStatus.new,
        timed_out: false,
        output_too_large: false,
        process_group_leaked: false
      )
    end
  end

  class FailingAuthRunner
    attr_reader :commands

    def initialize
      @commands = []
    end

    def capture(command, **options)
      @commands << [command, options]
      FakeResult.new(
        stdout: "secret-token-that-must-not-leak\n",
        stderr: "auth failure with secret-token-that-must-not-leak\n",
        status: FakeStatus.new(success: false, exitstatus: 1),
        timed_out: false,
        output_too_large: false,
        process_group_leaked: false
      )
    end
  end

  def test_upload_returns_exact_github_attachment_url_without_a_live_request
    Tempfile.create(["before", ".png"]) do |artifact|
      runner = SuccessfulRunner.new(ATTACHMENT_URL)

      result = GitHubUserAttachmentsUpload.upload(artifact.path, runner:)

      assert_equal ATTACHMENT_URL, result
      commands = runner.commands.map { |command, _options| command.first }
      assert_equal %w[gh git gh curl], commands
      curl_command = runner.commands.last.first
      assert_includes curl_command, "--data-binary"
      assert_includes curl_command, "@#{File.realpath(artifact.path)}"
      refute curl_command.join(" ").include?("github_pat_fixture")
    end
  end

  def test_unsupported_type_is_rejected_before_authentication
    Tempfile.create(["notes", ".txt"]) do |artifact|
      runner = SuccessfulRunner.new(ATTACHMENT_URL)

      error = assert_raises(GitHubUserAttachmentsUpload::Error) do
        GitHubUserAttachmentsUpload.upload(artifact.path, runner:)
      end

      assert_equal "unsupported file type", error.message
      assert_empty runner.commands
    end
  end

  def test_authentication_failure_does_not_expose_token_output
    Tempfile.create(["before", ".png"]) do |artifact|
      runner = FailingAuthRunner.new

      error = assert_raises(GitHubUserAttachmentsUpload::Error) do
        GitHubUserAttachmentsUpload.upload(artifact.path, runner:)
      end

      assert_equal "GitHub authentication failed", error.message
      refute_includes error.message, "secret-token"
      assert_equal [%w[gh auth token]], runner.commands.map(&:first)
    end
  end

  def test_non_201_response_fails_closed_without_returning_a_url
    Tempfile.create(["before", ".png"]) do |artifact|
      runner = SuccessfulRunner.new(ATTACHMENT_URL, http_status: "403")

      error = assert_raises(GitHubUserAttachmentsUpload::Error) do
        GitHubUserAttachmentsUpload.upload(artifact.path, runner:)
      end

      assert_equal "GitHub attachment upload returned HTTP 403", error.message
    end
  end

  def test_returned_url_must_have_the_exact_github_user_attachments_shape
    invalid_urls = [
      "http://github.com/user-attachments/assets/1234",
      "https://www.github.com/user-attachments/assets/1234",
      "https://github.com/user-attachments/assets/1234?token=secret",
      "https://github.com/user-attachments/assets/1234/extra",
      "https://evil.example/user-attachments/assets/1234"
    ]

    invalid_urls.each do |url|
      Tempfile.create(["before", ".png"]) do |artifact|
        error = assert_raises(GitHubUserAttachmentsUpload::Error) do
          GitHubUserAttachmentsUpload.upload(artifact.path, runner: SuccessfulRunner.new(url))
        end

        assert_equal "GitHub attachment upload returned an invalid URL", error.message, url
      end
    end
  end

  def test_symlink_artifact_is_rejected
    Tempfile.create(["before", ".png"]) do |artifact|
      Dir.mktmpdir("github-upload-symlink") do |root|
        symlink = File.join(root, "before.png")
        File.symlink(artifact.path, symlink)

        error = assert_raises(GitHubUserAttachmentsUpload::Error) do
          GitHubUserAttachmentsUpload.upload(symlink, runner: SuccessfulRunner.new(ATTACHMENT_URL))
        end

        assert_equal "artifact must be a non-symlink regular file", error.message
      end
    end
  end

  def test_inaccessible_artifact_is_rejected
    Dir.mktmpdir("github-upload-inaccessible") do |root|
      artifact = File.join(root, "before.png")
      File.write(artifact, "fixture")
      File.chmod(0o000, root)

      error = assert_raises(GitHubUserAttachmentsUpload::Error) do
        GitHubUserAttachmentsUpload.upload(artifact, runner: SuccessfulRunner.new(ATTACHMENT_URL))
      end

      assert_equal "artifact must be an existing non-symlink regular file", error.message
    ensure
      File.chmod(0o700, root) if root && File.exist?(root)
    end
  end
end
