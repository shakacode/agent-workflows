# frozen_string_literal: true

require "uri"

module AgentDoctor
  class Sanitizer
    SECRET_ENV_NAME_PATTERN = /(?:\A|_)(?:TOKEN|SECRET|PASSWORD|COOKIE|CREDENTIALS?|AUTH)(?:_|\z)|(?:\A|_)(?:API|PRIVATE|ACCESS)_KEY(?:_|\z)/i
    URI_PATTERN = %r{(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+}
    SENSITIVE_QUERY_KEY_PATTERN = /\A(?:(?:api|access|private)[_-]?key|(?:access|auth|id|refresh)[_-]?token|client[_-]?secret|password|passwd|token|secret|credentials?|key|auth|jwt|session|signature)\z|(?:\A|[_-])(?:token|secret|password|passwd|key|credential|auth|jwt|session|signature)(?:[_-]|\z)/i
    REDACTED_PATH_SEGMENT = "%5BREDACTED%5D"
    LONG_HEX_PATH_SEGMENT_PATTERN = /\A[0-9a-f]{32,}\z/i
    UUID_PATH_SEGMENT_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

    def initialize(environment = ENV)
      secrets = environment.each_with_object([]) do |(key, value), values|
        values << value if key.match?(SECRET_ENV_NAME_PATTERN) && value.to_s.bytesize >= 4
      end
      @secret_values = secrets.sort_by { |value| -value.bytesize }
    end

    def sanitize(value)
      case value
      when Hash then value.to_h { |key, item| [string(key), sanitize(item)] }
      when Array then value.map { |item| sanitize(item) }
      when String then string(value)
      else value
      end
    end

    def component(item)
      {
        "schema_version" => 1,
        "component" => item.fetch("component"),
        "status" => item.fetch("status"),
        "checks" => item.fetch("checks").map { |check| check_record(check) }
      }
    end

    def string(value)
      text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
      text = redact_secrets(text)
      text = text.gsub(%r{\e\[[0-?]*[ -/]*[@-~]}, "")
      text = text.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\r\n]/) do |char|
        "\\x#{char.ord.to_s(16).upcase.rjust(2, '0')}"
      end
      text = text.gsub(URI_PATTERN) { |candidate| sanitize_url(candidate) }
      redact_secrets(text)
    end

    private

    def check_record(item)
      {
        "id" => string(item.fetch("id")),
        "status" => item.fetch("status"),
        "summary" => string(item.fetch("summary")),
        "details" => sanitize(item.fetch("details")),
        "guidance" => item["guidance"] && string(item["guidance"])
      }
    end

    def sanitize_url(candidate)
      match = candidate.match(%r{\A([A-Za-z][A-Za-z0-9+.-]*://)([^/?#\s]*)(.*)\z})
      return candidate unless match

      authority, had_userinfo = scrub_userinfo(match[2])
      scrubbed = "#{match[1]}#{authority}#{match[3]}"
      uri = URI.parse(scrubbed)
      raise URI::InvalidURIError, "URI has no host" unless uri.host

      uri.user = nil
      uri.password = nil
      uri.path = sanitized_path(uri)
      uri.query = sanitized_query(uri.query) if uri.query
      uri.fragment = sanitized_fragment(uri.fragment) if uri.fragment
      restore_redaction_marker(uri.to_s, had_userinfo)
    rescue URI::InvalidURIError, ArgumentError
      fallback = sanitize_fallback_path(scrubbed)
      fallback = fallback.sub(/\?.*(?=#|\z)/, "?[REDACTED]").sub(/#.*\z/, "#[REDACTED]")
      restore_redaction_marker(fallback, had_userinfo)
    end

    def scrub_userinfo(authority)
      separator = authority.rindex("@")
      separator ||= authority.downcase.rindex("%40")
      return [authority, false] unless separator

      width = authority[separator, 3].to_s.downcase == "%40" ? 3 : 1
      [authority[(separator + width)..], true]
    end

    def restore_redaction_marker(uri, had_userinfo)
      return uri unless had_userinfo

      uri.sub(%r{\A([A-Za-z][A-Za-z0-9+.-]*://)}, '\\1[REDACTED]@')
    end

    def sanitized_query(query)
      sanitized_parameters(query)
    end

    def sanitized_path(uri)
      sanitize_path(uri.path.to_s, slack: uri.host.casecmp?("hooks.slack.com"))
    end

    def sanitize_fallback_path(url)
      match = url.match(%r{\A([A-Za-z][A-Za-z0-9+.-]*://)([^/?#\s]*)([^?#]*)(.*)\z})
      return url unless match

      slack = match[2].match?(/\Ahooks\.slack\.com(?::\d+)?\z/i)
      "#{match[1]}#{match[2]}#{sanitize_path(match[3], slack: slack)}#{match[4]}"
    end

    def sanitize_path(path, slack:)
      return "/services/#{REDACTED_PATH_SEGMENT}" if slack && path.start_with?("/services/")

      path.split("/", -1).map { |segment| high_entropy_path_segment?(segment) ? REDACTED_PATH_SEGMENT : segment }.join("/")
    end

    def high_entropy_path_segment?(segment)
      decoded = decode_path_segment(segment)
      return false if decoded.bytesize < 24
      return true if decoded.match?(LONG_HEX_PATH_SEGMENT_PATTERN)
      return false if decoded.match?(UUID_PATH_SEGMENT_PATTERN)

      character_classes = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].count { |pattern| decoded.match?(pattern) }
      character_classes >= 3 && decoded.each_char.uniq.length >= 12
    end

    def decode_path_segment(segment)
      URI.decode_uri_component(segment).scrub("?")
    rescue ArgumentError
      segment
    end

    def sanitized_fragment(fragment)
      fragment.include?("=") ? sanitized_parameters(fragment) : string(fragment)
    end

    def sanitized_parameters(parameters)
      pairs = URI.decode_www_form(parameters).map do |key, value|
        redacted = key.match?(SENSITIVE_QUERY_KEY_PATTERN) ? "[REDACTED]" : string(value)
        [key, redacted]
      end
      URI.encode_www_form(pairs)
    end

    def redact_secrets(text)
      @secret_values.each { |secret| text = text.gsub(secret, "[REDACTED]") }
      text
    end
  end
end
