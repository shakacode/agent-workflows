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
    ESLINT_RUNTIME_DEFAULTS = {
      "complexity" => 20,
      "max-lines" => 300,
      "max-lines-per-function" => 50,
      "max-params" => 3,
      "max-depth" => 4,
      "max-statements" => 10
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
    rescue StandardError
      [{ "message" => "Linter settings advice is unavailable; seam validation is unaffected." }]
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
        configured_value = setting.is_a?(Hash) ? setting.fetch("Max", default) : nil
        if enabled && finite_nonnegative_number?(configured_value)
          enforced << { "rule" => rule, "value" => configured_value }
          next
        end
        next if suppressed?(policy, "rubocop", rule)

        threshold = threshold(policy, "rubocop", rule, default)
        state = if enabled
                  "invalid"
                elsif setting.is_a?(Hash) || department_disabled
                  "disabled"
                else
                  "missing"
                end
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
    rescue ArgumentError, EncodingError, Psych::Exception, SystemCallError, TypeError => e
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
        occurrences = settings.fetch(rule, [])
        occurrences = [[:missing, nil, nil]] if occurrences.empty?
        occurrences.each do |state, value, scope|
          if state == :enforced
            item = { "rule" => rule, "value" => value }
            item["scope"] = scope if scope
            enforced << item
            next
          end
          next if suppressed?(policy, "eslint", rule)

          threshold = threshold(policy, "eslint", rule, default)
          item = {
            "rule" => rule,
            "state" => state.to_s,
            "suggestion" => %("#{rule}": ["error", #{threshold}])
          }
          item["scope"] = scope if scope
          recommendations << item
        end
      end

      {
        "linter" => "ESLint",
        "config" => relative_path,
        "enforced" => enforced,
        "recommendations" => recommendations
      }
    rescue ArgumentError, EncodingError, Psych::Exception, SystemCallError, TypeError => e
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
        occurrences = rules.filter_map do |mapping, scope|
          next unless mapping.key?(rule)

          [*eslint_setting(mapping[rule], rule), scope]
        end
        [rule, effective_eslint_occurrences(occurrences)]
      end
    rescue JSON::ParserError
      eslint_source_settings(source)
    end

    def eslint_rule_maps(value, inherited_scope = nil)
      case value
      when Hash
        scope = eslint_scope(value) || inherited_scope
        own = value["rules"].is_a?(Hash) ? [[value["rules"], scope]] : []
        overrides = value["overrides"].is_a?(Array) ? value["overrides"] : []
        own + overrides.flat_map { |child| eslint_rule_maps(child, scope) }
      when Array
        value.flat_map { |child| eslint_rule_maps(child, inherited_scope) }
      else
        []
      end
    end

    def eslint_scope(config)
      files = config["files"]
      files.nil? ? nil : JSON.generate(files)
    end

    def eslint_source_settings(source)
      rule_bodies = javascript_rule_bodies(source)
      ESLINT_LIMITS.to_h do |rule, _default|
        occurrences = rule_bodies.filter_map do |entry|
          expression = eslint_rule_expression(entry.fetch(:body), rule)
          [*eslint_source_setting(expression, rule), entry[:scope]] if expression
        end
        [rule, effective_eslint_occurrences(occurrences)]
      end
    end

    def javascript_rule_bodies(source)
      source = strip_javascript_comments(source)
      source = exported_javascript_expression(source)
      return [] unless source

      javascript_config_bodies(source).filter_map do |entry|
        config_body = entry.fetch(:body)
        expression = eslint_rule_expression(config_body, "rules")
        next unless expression

        opening_index = expression.index("{")
        next unless opening_index && expression[...opening_index].strip.empty?

        rules_body, = javascript_object_body(expression, opening_index)
        next unless rules_body

        { body: rules_body, scope: entry[:scope] }
      end
    end

    def javascript_config_bodies(source, inherited_scope = nil)
      javascript_object_bodies(source).flat_map do |config_body|
        scope = javascript_scope(config_body) || inherited_scope
        entries = [{ body: config_body, scope: scope }]
        overrides = eslint_rule_expression(config_body, "overrides")
        opening_index = overrides&.index(/\S/)
        next entries unless opening_index && overrides[opening_index] == "["

        ending_index = javascript_array_end(overrides, opening_index)
        next entries unless ending_index

        nested = overrides[(opening_index + 1)...ending_index]
        entries + javascript_config_bodies(nested, scope)
      end
    end

    def exported_javascript_expression(source)
      start = javascript_export_start(source)
      return unless start

      javascript_expression(source, start)
    end

    def javascript_export_start(source)
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = nil
      index = 0
      while index < source.length
        character = source[index]
        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
        elsif ["\"", "'", "`"].include?(character)
          quote = character
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
        else
          export = source[index..].match(/\Aexport\s+default\b/)
          return index + export[0].length if export

          commonjs = source[index..].match(/\Amodule\.exports\s*=/)
          return index + commonjs[0].length if commonjs
        end
        previous = character unless character.match?(/\s/) || quote || regex
        index += 1
      end
      nil
    end

    def javascript_expression(source, start)
      depth = { "{" => 0, "[" => 0, "(" => 0 }
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = "="
      index = start
      while index < source.length
        character = source[index]
        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
        elsif ["\"", "'", "`"].include?(character)
          quote = character
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
        else
          return source[start...index] if character == ";" && top_level?(depth)

          depth[character] += 1 if depth.key?(character)
          closing = { "}" => "{", "]" => "[", ")" => "(" }[character]
          depth[closing] -= 1 if closing && depth[closing].positive?
        end
        previous = character unless character.match?(/\s/) || quote || regex
        index += 1
      end
      source[start..]
    end

    def javascript_object_bodies(source)
      bodies = []
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = nil
      depth = 0
      source.each_char.with_index do |character, index|
        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
          next
        end
        if ["\"", "'", "`"].include?(character)
          quote = character
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
        elsif character == "{"
          if depth.zero?
            body, = javascript_object_body(source, index)
            bodies << body if body
          end
          depth += 1
        elsif character == "}"
          depth -= 1 if depth.positive?
        end
        previous = character unless character.match?(/\s/) || quote || regex
      end
      bodies
    end

    def javascript_scope(config_body)
      expression = eslint_rule_expression(config_body, "files")
      opening_index = expression&.index(/\S/)
      return unless opening_index && expression[opening_index] == "["

      ending_index = javascript_array_end(expression, opening_index)
      ending_index && expression[opening_index..ending_index].gsub(/\s+/, " ")
    end

    def javascript_array_end(source, opening_index)
      depth = 0
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = nil
      source.each_char.with_index do |character, index|
        next if index < opening_index

        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
          next
        end

        if ["\"", "'", "`"].include?(character)
          quote = character
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
        elsif character == "["
          depth += 1
        elsif character == "]"
          depth -= 1
          return index if depth.zero?
        end
        previous = character unless character.match?(/\s/) || quote || regex
      end
      nil
    end

    def strip_javascript_comments(source)
      output = +""
      quote = nil
      regex = false
      character_class = false
      escaped = false
      comment = nil
      previous = nil
      index = 0
      while index < source.length
        character = source[index]
        following = source[index + 1]
        if comment == :line
          if character == "\n"
            comment = nil
            output << character
          end
        elsif comment == :block
          output << "\n" if character == "\n"
          if character == "*" && following == "/"
            comment = nil
            index += 1
          end
        elsif quote || regex
          output << character
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
        elsif ["\"", "'", "`"].include?(character)
          quote = character
          output << character
        elsif character == "/" && following == "/"
          comment = :line
          index += 1
        elsif character == "/" && following == "*"
          comment = :block
          index += 1
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
          output << character
        else
          output << character
        end
        previous = character unless character.match?(/\s/) || comment || quote || regex
        index += 1
      end
      output
    end

    def javascript_object_body(source, opening_index)
      depth = 0
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = nil
      source.each_char.with_index do |character, index|
        next if index < opening_index

        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
          next
        end

        if ["\"", "'", "`"].include?(character)
          quote = character
        elsif character == "/" && javascript_regex_start?(previous)
          regex = true
        elsif character == "{"
          depth += 1
        elsif character == "}"
          depth -= 1
          return [source[(opening_index + 1)...index], index] if depth.zero?
        end
        previous = character unless character.match?(/\s/) || quote || regex
      end
      [nil, nil]
    end

    def eslint_rule_expression(source, rule)
      depth = { "{" => 0, "[" => 0, "(" => 0 }
      quote = nil
      regex = false
      character_class = false
      escaped = false
      previous = nil
      index = 0
      while index < source.length
        character = source[index]
        if quote || regex
          quote, regex, character_class, escaped = javascript_literal_state(
            character, quote, regex, character_class, escaped
          )
          index += 1
          next
        end

        if ["\"", "'", "`"].include?(character)
          property, after = quoted_property(source, index, character)
          return property_expression(source, after) if top_level?(depth) && property == rule

          quote = character unless after
          index = after || index + 1
          next
        end
        if character == "/" && javascript_regex_start?(previous)
          regex = true
          index += 1
          next
        end
        depth[character] += 1 if depth.key?(character)
        closing = { "}" => "{", "]" => "[", ")" => "(" }[character]
        depth[closing] -= 1 if closing && depth[closing].positive?
        if top_level?(depth) && character.match?(/[A-Za-z_$]/)
          property = source[index..].match(/\A[A-Za-z_$][A-Za-z0-9_$]*/).to_s
          after = index + property.length
          return property_expression(source, after) if property == rule

          index = after
          next
        end
        previous = character unless character.match?(/\s/)
        index += 1
      end
      nil
    end

    def quoted_property(source, index, quote)
      escaped = false
      cursor = index + 1
      while cursor < source.length
        character = source[cursor]
        if escaped
          escaped = false
        elsif character == "\\"
          escaped = true
        elsif character == quote
          return [source[(index + 1)...cursor], cursor + 1]
        end
        cursor += 1
      end
      [nil, nil]
    end

    def property_expression(source, after)
      match = source.match(/\G\s*:\s*/, after)
      match && source[match.end(0)..]
    end

    def top_level?(depth)
      depth.values.all?(&:zero?)
    end

    def javascript_literal_state(character, quote, regex, character_class, escaped)
      if escaped
        escaped = false
      elsif character == "\\"
        escaped = true
      elsif quote && character == quote
        quote = nil
      elsif regex && character == "["
        character_class = true
      elsif regex && character == "]"
        character_class = false
      elsif regex && character == "/" && !character_class
        regex = false
      end
      [quote, regex, character_class, escaped]
    end

    def javascript_regex_start?(previous)
      previous.nil? || "([{=,:;!?&|+-*%^~<>".include?(previous)
    end

    def effective_eslint_occurrences(occurrences)
      occurrences.each_with_object({}) { |occurrence, effective| effective[occurrence[2]] = occurrence }.values
    end

    def eslint_source_setting(expression, rule)
      return [:disabled, nil] if expression.match?(/\A(?:["']off["']|0)(?:\W|\z)/)
      return [:enforced, ESLINT_RUNTIME_DEFAULTS.fetch(rule)] if
        expression.match?(/\A(?:["'](?:error|warn)["']|[12])(?:\W|\z)/)

      match = expression.match(
        /\A\[\s*(?<severity>["'](?:error|warn|off)["']|[012])\s*(?:,\s*(?:(?<value>\d+)|\{(?<options>[^}]*)\}))?\s*\]/m
      )
      return [:missing, nil] unless match
      return [:disabled, nil] if match[:severity].match?(/(?:off|0)/)

      value = match[:value] || match[:options]&.match(/["']?(?:max|maximum)["']?\s*:\s*(\d+)/)&.captures&.first
      value ? [:enforced, value.to_i] : [:enforced, ESLINT_RUNTIME_DEFAULTS.fetch(rule)]
    end

    def eslint_setting(value, rule)
      severity, options = value.is_a?(Array) ? value : [value, nil]
      return [:disabled, nil] if [false, 0, "off"].include?(severity)
      return [:missing, nil] unless [1, 2, "warn", "error"].include?(severity)
      return [:enforced, ESLINT_RUNTIME_DEFAULTS.fetch(rule)] if options.nil?

      if options.is_a?(Hash)
        keys = ["max", :max, "maximum", :maximum]
        configured_key = keys.find { |key| options.key?(key) }
        return [:enforced, ESLINT_RUNTIME_DEFAULTS.fetch(rule)] unless configured_key

        threshold = options[configured_key]
      else
        threshold = options
      end
      valid_eslint_limit?(threshold) ? [:enforced, threshold] : [:invalid, nil]
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
      configured.is_a?(Integer) && configured.positive? ? configured : default
    rescue TypeError
      default
    end

    def valid_eslint_limit?(value)
      value.is_a?(Integer) && value >= 0
    end

    def finite_nonnegative_number?(value)
      value.is_a?(Numeric) && value >= 0 && (!value.respond_to?(:finite?) || value.finite?)
    end

    def suppressed?(policy, linter, rule)
      suppressions = policy["suppress"]
      suppressions.is_a?(Array) && suppressions.include?("#{linter}.#{rule}")
    end
  end
end
