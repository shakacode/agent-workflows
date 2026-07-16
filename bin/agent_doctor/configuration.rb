# frozen_string_literal: true

require "uri"

module AgentDoctor
  module Configuration
    class UsageError < StandardError; end

    module_function

    def dashboard_uri(value)
      uri = URI.parse(value)
      allowed_hosts = ["localhost", "127.0.0.1", "::1"]
      valid = uri.scheme == "http" && allowed_hosts.include?(uri.hostname) && uri.userinfo.nil? && uri.fragment.nil?
      raise UsageError, "--dashboard-url must use loopback HTTP without credentials" unless valid

      uri.path = "" if uri.path == "/"
      raise UsageError, "--dashboard-url must not include a query or endpoint path" unless uri.query.nil? && uri.path.to_s.empty?

      uri
    rescue URI::InvalidURIError
      raise UsageError, "--dashboard-url must be a valid loopback HTTP URL"
    end

    def host_and_target(host, target, environment: ENV, home: Dir.home)
      codex_override = environment["CODEX_HOME"].to_s
      claude_override = environment["CLAUDE_HOME"].to_s
      codex_home = File.expand_path(codex_override.empty? ? File.join(home, ".codex") : codex_override)
      claude_home = File.expand_path(claude_override.empty? ? File.join(home, ".claude") : claude_override)
      return explicit_target(host, target, codex_home, claude_home) if target
      return [host, host == "claude" ? claude_home : codex_home] unless host == "auto"

      candidates = []
      candidates << ["codex", codex_home] unless codex_override.empty? && !File.directory?(codex_home)
      candidates << ["claude", claude_home] unless claude_override.empty? && !File.directory?(claude_home)
      return ["codex", codex_home] if candidates.empty?
      return candidates.first if candidates.one?

      raise UsageError, "auto host detection found both Codex and Claude homes; pass --host"
    end

    def coordination_selector(runtime_root, environment: ENV, home: Dir.home)
      direct = [
        ["AGENT_COORD_STATE_ROOT", "--state-root", true],
        ["AGENT_COORD_API_URL", "--api-url", false],
        ["AGENT_COORD_BACKEND", "--backend", false],
        ["AGENT_COORD_STATUS_STATE_ROOT", "--state-root", true]
      ].find { |name,| !environment[name].to_s.strip.empty? }
      return [direct[1], direct[2] ? File.expand_path(environment[direct[0]].strip) : environment[direct[0]].strip] if direct

      runtime_state = File.join(runtime_root, "state")
      return ["--state-root", runtime_state] if File.directory?(runtime_state)

      xdg_root = environment["XDG_STATE_HOME"].to_s.empty? ? File.join(home, ".local", "state") : environment["XDG_STATE_HOME"]
      implicit_state = File.join(xdg_root, "agent-coordination")
      File.directory?(implicit_state) ? ["--state-root", implicit_state] : nil
    end

    def command_available?(name, environment: ENV)
      return File.executable?(name) if name.include?(File::SEPARATOR)

      environment.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end

    def explicit_target(host, target, codex_home, claude_home)
      expanded = File.expand_path(target)
      return [host, expanded] unless host == "auto"

      codex_marker = expanded == codex_home || File.file?(File.join(expanded, "config.toml"))
      claude_marker = expanded == claude_home || File.file?(File.join(expanded, "settings.json")) ||
                      File.file?(File.join(expanded, "plugins", "installed_plugins.json"))
      raise UsageError, "explicit target has both Codex and Claude markers; pass --host" if codex_marker && claude_marker

      [claude_marker ? "claude" : "codex", expanded]
    end
    private_class_method :explicit_target
  end
end
