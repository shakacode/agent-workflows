# frozen_string_literal: true

require "open3"
require "json"
require "yaml"

module AgentDoctor
  module LinterAdvice
    RUBOCOP_CONFIGS = [".rubocop.yml"].freeze
    RUBOCOP_LIMITS = {
      "Metrics/AbcSize" => 17,
      "Metrics/BlockLength" => 25,
      "Metrics/ClassLength" => 100,
      "Metrics/CyclomaticComplexity" => 7,
      "Metrics/MethodLength" => 10,
      "Metrics/ModuleLength" => 100,
      "Metrics/ParameterLists" => 5,
      "Metrics/PerceivedComplexity" => 8
    }.freeze
    ESLINT_CONFIG_PATTERN = /\A(?:eslint\.config\.(?:js|mjs|cjs|ts|mts|cts)|\.eslintrc(?:\.(?:js|cjs|json|ya?ml))?)\z/
    ESLINT_LIMITS = {
      "complexity" => 10,
      "max-lines" => 300,
      "max-lines-per-function" => 50,
      "max-params" => 4,
      "max-depth" => 4,
      "max-statements" => 20
    }.freeze
    SOURCE_REPO_URL = "https://github.com/shakacode/agent-workflows/issues/309"

    module_function

    def call(root)
      policy = lint_policy(root)
      advice = RUBOCOP_CONFIGS.filter_map do |relative_path|
        path = File.join(root, relative_path)
        rubocop(root, relative_path, path, policy) if File.file?(path)
      end
      eslint_config_paths(root).each do |relative_path|
        advice << eslint(relative_path, File.join(root, relative_path), policy)
      end
      return advice unless advice.empty?

      [{ "message" => "No recognized RuboCop or ESLint config found." }]
    end

    def rubocop(root, relative_path, path, policy)
      config = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false) || {}
      config = {} unless config.is_a?(Hash)
      department_disabled = config.dig("Metrics", "Enabled") == false ||
                            config.dig("AllCops", "DisabledByDefault") == true
      enforced = []
      recommendations = []

      RUBOCOP_LIMITS.each do |rule, default|
        setting = config[rule]
        enabled = setting.is_a?(Hash) && setting["Enabled"] != false &&
                  (!department_disabled || setting["Enabled"] == true)
        if enabled
          enforced << { "rule" => rule, "value" => setting.fetch("Max", default) }
          next
        end
        next if suppressed?(policy, "rubocop", rule)

        threshold = threshold(policy, "rubocop", rule, default)
        state = setting.is_a?(Hash) || department_disabled ? "disabled" : "missing"
        recommendations << {
          "rule" => rule,
          "state" => state,
          "suggestion" => "#{rule}:\n  Enabled: true\n  Max: #{threshold}"
        }
      end

      result = {
        "linter" => "RuboCop",
        "config" => relative_path,
        "enforced" => enforced,
        "recommendations" => recommendations
      }
      result["note"] = "Re-enabling this repository's RuboCop metrics is tracked in #{SOURCE_REPO_URL}." if
        agent_workflows_repo?(root)
      result
    rescue EncodingError, Psych::Exception, SystemCallError => e
      {
        "linter" => "RuboCop",
        "config" => relative_path,
        "enforced" => [],
        "recommendations" => [],
        "note" => "Could not inspect linter settings: #{e.message}"
      }
    end

    def agent_workflows_repo?(root)
      out, status = Open3.capture2("git", "-C", root, "remote", "get-url", "origin", err: File::NULL)
      status.success? && out.match?(%r{(?:github\.com[:/])shakacode/agent-workflows(?:\.git)?\s*\z})
    end

    def eslint_config_paths(root)
      Dir.children(root).grep(ESLINT_CONFIG_PATTERN).sort
    rescue SystemCallError
      []
    end

    def eslint(relative_path, path, policy)
      source = File.read(path, encoding: "UTF-8")
      settings = if relative_path.end_with?(".json", ".yaml", ".yml") || relative_path == ".eslintrc"
                   eslint_structured_settings(source)
                 else
                   eslint_source_settings(source)
                 end
      enforced = []
      recommendations = []

      ESLINT_LIMITS.each do |rule, default|
        state, value = settings.fetch(rule, [:missing, nil])
        if state == :enforced
          enforced << { "rule" => rule, "value" => value }
        else
          next if suppressed?(policy, "eslint", rule)

          threshold = threshold(policy, "eslint", rule, default)
          recommendations << {
            "rule" => rule,
            "state" => state.to_s,
            "suggestion" => %("#{rule}": ["error", #{threshold}])
          }
        end
      end

      {
        "linter" => "ESLint",
        "config" => relative_path,
        "enforced" => enforced,
        "recommendations" => recommendations
      }
    rescue EncodingError, Psych::Exception, SystemCallError => e
      {
        "linter" => "ESLint",
        "config" => relative_path,
        "enforced" => [],
        "recommendations" => [],
        "note" => "Could not inspect linter settings: #{e.message}"
      }
    end

    def eslint_structured_settings(source)
      config = if source.lstrip.start_with?("{")
                 JSON.parse(source)
               else
                 YAML.safe_load(source, aliases: false)
               end
      rules = eslint_rule_maps(config)
      ESLINT_LIMITS.to_h do |rule, _default|
        values = rules.filter_map { |mapping| mapping[rule] if mapping.key?(rule) }
        [rule, eslint_setting(values.last)]
      end
    rescue JSON::ParserError
      eslint_source_settings(source)
    end

    def eslint_rule_maps(value)
      case value
      when Hash
        own = value["rules"].is_a?(Hash) ? [value["rules"]] : []
        own + value.values.flat_map { |child| eslint_rule_maps(child) }
      when Array
        value.flat_map { |child| eslint_rule_maps(child) }
      else
        []
      end
    end

    def eslint_source_settings(source)
      ESLINT_LIMITS.to_h do |rule, _default|
        expression = eslint_rule_expression(source, rule)
        [rule, expression ? eslint_source_setting(expression) : [:missing, nil]]
      end
    end

    def eslint_rule_expression(source, rule)
      quoted = /["']#{Regexp.escape(rule)}["']/
      bare = /(?<![A-Za-z0-9_-])#{Regexp.escape(rule)}(?![A-Za-z0-9_-])/
      match = source.match(/(?:#{quoted}|#{bare})\s*:\s*/)
      match && source[match.end(0)..]
    end

    def eslint_source_setting(expression)
      return [:disabled, nil] if expression.match?(/\A(?:["']off["']|0)(?:\W|\z)/)

      match = expression.match(/\A\[\s*(?<severity>["'](?:error|warn|off)["']|[012])\s*,\s*(?:(?<value>\d+)|\{(?<options>[^}]*)\})/m)
      return [:missing, nil] unless match
      return [:disabled, nil] if match[:severity].match?(/(?:off|0)/)

      value = match[:value] || match[:options]&.match(/["']?max["']?\s*:\s*(\d+)/)&.captures&.first
      value ? [:enforced, value.to_i] : [:missing, nil]
    end

    def eslint_setting(value)
      severity, options = value.is_a?(Array) ? value : [value, nil]
      return [:disabled, nil] if [0, "off"].include?(severity)

      threshold = options.is_a?(Hash) ? (options["max"] || options[:max]) : options
      threshold.is_a?(Numeric) ? [:enforced, threshold] : [:missing, nil]
    end

    def lint_policy(root)
      path = File.join(root, ".agents/agent-workflow.yml")
      config = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false)
      policy = config.is_a?(Hash) ? config["lint_advice"] : nil
      policy.is_a?(Hash) ? policy : {}
    rescue EncodingError, Psych::Exception, SystemCallError
      {}
    end

    def threshold(policy, linter, rule, default)
      configured = policy.dig("thresholds", linter, rule)
      configured.is_a?(Numeric) && configured.positive? ? configured : default
    rescue TypeError
      default
    end

    def suppressed?(policy, linter, rule)
      suppressions = policy["suppress"]
      suppressions.is_a?(Array) && suppressions.include?("#{linter}.#{rule}")
    end
  end
end
