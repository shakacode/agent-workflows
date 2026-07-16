# frozen_string_literal: true

require "json"
require "optparse"
require_relative "contract"
require_relative "orchestrator"
require_relative "process_runner"
require_relative "renderer"
require_relative "sanitizer"
require_relative "timeout_budget"

module AgentDoctor
  class StackCLI
    def initialize(environment: ENV, home: Dir.home)
      @environment = environment
      @home = home
    end

    def run(arguments, output: $stdout, error: $stderr)
      options = defaults
      parser = parser_for(options)
      parser.parse!(arguments)
      validate!(options, arguments)

      sanitizer = Sanitizer.new(@environment)
      runner = ProcessRunner.new(timeout: TimeoutBudget.stack_component(@environment))
      payload = Orchestrator.new(options, runner: runner, sanitizer: sanitizer, environment: @environment).call
      options[:json] ? output.puts(JSON.generate(payload)) : Renderer.human(payload, output: output)
      Contract::EXIT_FOR_STATUS.fetch(payload["status"])
    rescue OptionParser::ParseError, Configuration::UsageError => e
      sanitizer ||= Sanitizer.new(@environment)
      error.puts "agent-stack doctor: #{sanitizer.string(e.message)}"
      error.puts usage
      64
    end

    def usage
      <<~TEXT
        Usage: agent-stack doctor [options]

          --source-root DIR              source checkout root (default: ~/src)
          --compat-root DIR              compatibility symlink root (default: ~/codex/agent-repos)
          --runtime-root DIR             private runtime/config root (default: ~/.agent-workflows)
          --host codex|claude|auto       workflow install host (default: codex)
          --target DIR                   workflow install target
          --agent-coord-install-dir DIR  agent-coord install dir (default: ~/.local/bin)
          --dashboard-url URL            loopback dashboard URL (default: http://127.0.0.1:${PORT:-4319})
          --deep                         run component deep checks
          --json                         emit JSON only
      TEXT
    end

    private

    def defaults
      dashboard_port = @environment["PORT"].to_s
      dashboard_port = "4319" if dashboard_port.empty?
      { source_root: environment_path("AGENT_STACK_SOURCE_ROOT", File.join(@home, "src")),
        compat_root: environment_path("AGENT_STACK_COMPAT_ROOT", File.join(@home, "codex", "agent-repos")),
        runtime_root: environment_path("AGENT_STACK_RUNTIME_ROOT", File.join(@home, ".agent-workflows")),
        host: "codex", target: nil, install_dir: File.join(@home, ".local", "bin"),
        dashboard_url: "http://127.0.0.1:#{dashboard_port}", deep: false, json: false }
    end

    def environment_path(name, fallback)
      @environment[name].to_s.empty? ? fallback : @environment[name]
    end

    def validate!(options, arguments)
      raise Configuration::UsageError, "unexpected arguments" unless arguments.empty?
      raise Configuration::UsageError, "--host must be codex, claude, or auto" unless %w[codex claude auto].include?(options[:host])

      empty_path = { source_root: "--source-root", compat_root: "--compat-root", runtime_root: "--runtime-root",
                     target: "--target", install_dir: "--agent-coord-install-dir" }.find { |key,| options[key] == "" }
      raise Configuration::UsageError, "#{empty_path[1]} must not be empty" if empty_path
    end

    def parser_for(options)
      OptionParser.new do |parser|
        parser.on("--source-root DIR") { |value| options[:source_root] = value }
        parser.on("--compat-root DIR") { |value| options[:compat_root] = value }
        parser.on("--runtime-root DIR") { |value| options[:runtime_root] = value }
        parser.on("--host HOST") { |value| options[:host] = value }
        parser.on("--target DIR") { |value| options[:target] = value }
        parser.on("--agent-coord-install-dir DIR") { |value| options[:install_dir] = value }
        parser.on("--dashboard-url URL") { |value| options[:dashboard_url] = value }
        parser.on("--deep") { options[:deep] = true }
        parser.on("--json") { options[:json] = true }
        parser.on("-h", "--help") do
          puts usage
          exit 0
        end
      end
    end
  end
end
