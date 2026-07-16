# frozen_string_literal: true

require "json"
require_relative "contract"

module AgentDoctor
  module Renderer
    module_function

    def human(payload, output: $stdout)
      counts = payload["components"].group_by { |item| item["status"] }.transform_values(&:length)
      output.puts "Agent Stack Doctor: #{payload['status'].upcase}"
      output.puts "#{payload['components'].length} components: #{counts.fetch('healthy', 0)} healthy, #{counts.fetch('degraded', 0)} degraded, #{counts.fetch('failed', 0)} failed"
      payload["components"].sort_by { |item| -Contract::SEVERITY.fetch(item["status"]) }.each do |component|
        output.puts
        output.puts "[#{component['status'].upcase}] #{component['component']}"
        component["checks"].sort_by { |check| -Contract::SEVERITY.fetch(check["status"]) }.each do |check|
          output.puts "  [#{check['status'].upcase}] #{label(check['id'].split('.').last)}: #{check['summary']}"
          check["details"].each { |key, value| output.puts "    #{label(key).ljust(12)} #{detail(value)}" }
          output.puts "    #{'Next'.ljust(12)} #{check['guidance']}" if check["guidance"]
        end
      end
    end

    def label(value)
      value.tr("_", " ").split.map(&:capitalize).join(" ")
    end
    private_class_method :label

    def detail(value)
      value.is_a?(String) ? value : JSON.generate(value)
    end
    private_class_method :detail
  end
end
