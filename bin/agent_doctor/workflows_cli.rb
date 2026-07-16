# frozen_string_literal: true

require "json"
require "optparse"
require_relative "contract"
require_relative "process_runner"
require_relative "sanitizer"
require_relative "timeout_budget"
require_relative "workflows_component"

module AgentDoctor
  class WorkflowsCLI
    def initialize(environment: ENV)
      @environment = environment
    end

    def run(arguments, output: $stdout, error: $stderr)
      sanitizer = Sanitizer.new(@environment)
      options = { host: "codex", target: nil, source: nil, deep: false, stack_json: false }
      parser = parser_for(options)
      parser.parse!(arguments)
      validate!(options, arguments)
      timeout = TimeoutBudget.workflow_status(@environment)
      payload = WorkflowsComponent.new(runner: ProcessRunner.new(timeout: timeout)).call(
        host: options[:host], target: File.expand_path(options[:target]),
        source: File.expand_path(options[:source]), deep: options[:deep]
      )
      output.puts JSON.generate(sanitizer.component(payload))
      Contract::EXIT_FOR_STATUS.fetch(payload["status"])
    rescue OptionParser::ParseError => e
      sanitizer ||= Sanitizer.new(@environment)
      error.puts "agent-workflows-doctor: #{sanitizer.string(e.message)}"
      error.puts parser
      64
    end

    private

    def parser_for(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: agent-workflows-doctor --stack-json [options]"
        parser.on("--stack-json") { options[:stack_json] = true }
        parser.on("--host HOST") { |value| options[:host] = value }
        parser.on("--target DIR") { |value| options[:target] = value }
        parser.on("--source DIR") { |value| options[:source] = value }
        parser.on("--deep") { options[:deep] = true }
      end
    end

    def validate!(options, arguments)
      raise OptionParser::InvalidOption, "--stack-json is required" unless options[:stack_json]
      raise OptionParser::InvalidOption, "--target is required" unless options[:target]
      raise OptionParser::InvalidArgument, "--target must not be empty" if options[:target].empty?
      raise OptionParser::InvalidOption, "--source is required" unless options[:source]
      raise OptionParser::InvalidArgument, "--source must not be empty" if options[:source].empty?
      raise OptionParser::InvalidOption, "--host must be codex, claude, or auto" unless %w[codex claude auto].include?(options[:host])
      raise OptionParser::InvalidOption, "unexpected arguments" unless arguments.empty?
    end
  end
end
