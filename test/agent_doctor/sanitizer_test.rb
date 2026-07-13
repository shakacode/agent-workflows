# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/sanitizer"

class AgentDoctorSanitizerTest < Minitest::Test
  def test_redacts_secret_and_credential_adjacent_environment_values
    sanitizer = AgentDoctor::Sanitizer.new(
      "SENTINEL_API_TOKEN" => "token-material",
      "AWS_ACCESS_KEY_ID" => "access-material",
      "SESSION_COOKIE" => "cookie-material",
      "SERVICE_CREDENTIALS" => "credential-material",
      "BASIC_AUTH" => "auth-material"
    )
    output = sanitizer.string("token-material access-material cookie-material credential-material auth-material")

    assert_equal "[REDACTED] [REDACTED] [REDACTED] [REDACTED] [REDACTED]", output
  end

  def test_does_not_redact_trusted_contract_status_fields
    sanitizer = AgentDoctor::Sanitizer.new("SENTINEL_API_TOKEN" => "healthy")
    component = sanitizer.component(
      "component" => "agent-workflows", "status" => "healthy",
      "checks" => [{ "id" => "workflows.installation", "status" => "healthy", "summary" => "healthy",
                     "details" => {}, "guidance" => nil }]
    )

    assert_equal "healthy", component["status"]
    assert_equal "healthy", component.dig("checks", 0, "status")
    assert_equal "[REDACTED]", component.dig("checks", 0, "summary")
  end

  def test_redacts_plain_and_encoded_userinfo_across_uri_schemes
    sanitizer = AgentDoctor::Sanitizer.new

    values = [
      sanitizer.string("http://user:password@localhost:4319/path"),
      sanitizer.string("http://user%3Apassword%40localhost:4319/path"),
      sanitizer.string("postgres://user:password@db.example/app"),
      sanitizer.string("ssh://user:password@host.example/path")
    ]

    values.each do |output|
      assert_includes output, "[REDACTED]@"
      refute_includes output, "password"
      refute_includes output, "user"
    end
  end

  def test_redacts_sensitive_query_keys_without_redacting_safe_key_substrings
    output = AgentDoctor::Sanitizer.new.string(
      "ssh://host.example/path?access_token=token-value&apiKey=key-value&jwt=jwt-value" \
      "&session=session-value&signature=signature-value&monkey=visible"
    )

    assert_includes output, "access_token=%5BREDACTED%5D"
    assert_includes output, "apiKey=%5BREDACTED%5D"
    assert_includes output, "jwt=%5BREDACTED%5D"
    assert_includes output, "session=%5BREDACTED%5D"
    assert_includes output, "signature=%5BREDACTED%5D"
    assert_includes output, "monkey=visible"
    refute_includes output, "token-value"
    refute_includes output, "key-value"
    refute_includes output, "jwt-value"
    refute_includes output, "session-value"
    refute_includes output, "signature-value"
  end

  def test_malformed_query_is_redacted_without_losing_safe_url_structure
    sanitizer = AgentDoctor::Sanitizer.new("SENTINEL_TOKEN" => "sentinel-secret")
    output = sanitizer.string("http://localhost:4319/path?token=%73entinel-secret%ZZ&next=visible")

    assert_includes output, "http://localhost:4319/path?[REDACTED]"
    refute_includes output, "sentinel-secret"
    refute_includes output, "%ZZ"
  end

  def test_strips_terminal_controls_and_encodes_newlines
    output = AgentDoctor::Sanitizer.new.string("bad\n\e[31mtext")

    assert_equal "bad\\x0Atext", output
  end
end
