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
      homes = host_homes(environment: environment, home: home)
      return explicit_target(host, target, homes) if target
      return [host, homes.fetch(host)] unless host == "auto"

      candidates = []
      candidates << ["codex", homes.fetch("codex")] unless environment["CODEX_HOME"].to_s.empty? && !File.directory?(homes.fetch("codex"))
      candidates << ["claude", homes.fetch("claude")] unless environment["CLAUDE_HOME"].to_s.empty? && !File.directory?(homes.fetch("claude"))
      candidates << ["cursor", homes.fetch("cursor")] unless environment["CURSOR_HOME"].to_s.empty? && !File.directory?(homes.fetch("cursor"))
      return ["codex", homes.fetch("codex")] if candidates.empty?
      return candidates.first if candidates.one?

      raise UsageError, "auto host detection found multiple agent homes; pass --host"
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

    def host_homes(environment:, home:)
      {
        "codex" => expand_host_home(environment["CODEX_HOME"], File.join(home, ".codex")),
        "claude" => expand_host_home(environment["CLAUDE_HOME"], File.join(home, ".claude")),
        "cursor" => expand_host_home(environment["CURSOR_HOME"], File.join(home, ".cursor"))
      }
    end
    private_class_method :host_homes

    def expand_host_home(override, fallback)
      File.expand_path(override.to_s.empty? ? fallback : override)
    end
    private_class_method :expand_host_home

    def explicit_target(host, target, homes)
      expanded = File.expand_path(target)
      raise UsageError, "refusing to install into Cursor builtins directory skills-cursor" if File.basename(expanded) == "skills-cursor"
      return [host, expanded] unless host == "auto"

      markers = {
        "codex" => expanded == homes.fetch("codex") || File.file?(File.join(expanded, "config.toml")),
        "claude" => expanded == homes.fetch("claude") || File.file?(File.join(expanded, "settings.json")) ||
                    File.file?(File.join(expanded, "plugins", "installed_plugins.json")),
        "cursor" => expanded == homes.fetch("cursor") || File.file?(File.join(expanded, "cli-config.json")) ||
                    File.directory?(File.join(expanded, "skills-cursor"))
      }
      matched = markers.filter_map { |name, present| name if present }
      raise UsageError, "explicit target has markers for more than one host; pass --host" if matched.length > 1

      [matched.first || "codex", expanded]
    end
    private_class_method :explicit_target
  end
end
