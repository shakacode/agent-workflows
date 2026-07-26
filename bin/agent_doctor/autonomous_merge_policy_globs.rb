# frozen_string_literal: true

module AutonomousMergePolicy
  module_function

  def parse_glob_list(value, prefix)
    return [[], []] if value.nil?
    return [[], ["#{prefix} must be a list"]] unless value.is_a?(Array)

    errors = []
    patterns = value.filter_map.with_index do |pattern, index|
      pattern_errors = glob_errors(pattern, "#{prefix}[#{index}]")
      errors.concat(pattern_errors)
      pattern if pattern_errors.empty?
    end
    [patterns, errors]
  end

  def parse_safe_path_groups(value)
    return [{}, []] if value.nil?
    return [{}, ["autonomous_merge.safe_path_groups must be a mapping"]] unless value.is_a?(Hash)

    errors = []
    groups = {}
    value.each do |name, group|
      prefix = "autonomous_merge.safe_path_groups.#{name}"
      unless %w[documentation tests].include?(name)
        errors << "autonomous_merge.safe_path_groups contains unknown group #{name.inspect}"
        next
      end
      unless group.is_a?(Hash)
        errors << "#{prefix} must be a mapping"
        next
      end

      errors.concat(unknown_key_errors(group, SAFE_PATH_GROUP_KEYS, prefix))
      includes, include_errors = parse_glob_list(group["include"], "#{prefix}.include")
      excludes, exclude_errors = parse_glob_list(group["exclude"], "#{prefix}.exclude")
      errors.concat(include_errors)
      errors.concat(exclude_errors)
      errors << "#{prefix}.include must contain at least one pattern" if includes.empty?
      groups[name] = { "include" => includes, "exclude" => excludes }
    end
    [groups, errors]
  end

  def glob_errors(pattern, prefix)
    return ["#{prefix} invalid glob: expected a nonempty string"] unless nonempty_string?(pattern)
    return ["#{prefix} invalid glob: paths must be repository-relative"] if pattern.start_with?("/")

    unsupported_syntax = pattern.match?(/[\\{}]/) || pattern.start_with?("!")
    return ["#{prefix} invalid glob: backslashes, braces, and negation are unsupported"] if unsupported_syntax
    return ["#{prefix} invalid glob: .. path components are unsupported"] if pattern.split("/").include?("..")

    pattern.split("/", -1).each do |component|
      if component.include?("**") && component != "**"
        return ["#{prefix} invalid glob: ** must occupy a complete path component"]
      end

      begin
        component_regex(component) unless component == "**"
      rescue InvalidGlob => e
        return ["#{prefix} invalid glob: #{e.message}"]
      end
    end

    []
  end

  def match?(pattern, path)
    return false unless path.is_a?(String) && !path.empty?
    return false if path.start_with?("/") || path.split("/").include?("..")

    pattern_components = pattern.split("/", -1)
    path_components = path.split("/", -1)
    memo = {}
    matcher = lambda do |pattern_index, path_index|
      key = [pattern_index, path_index]
      return memo[key] if memo.key?(key)

      memo[key] = if pattern_index == pattern_components.length
                    path_index == path_components.length
                  elsif pattern_components.fetch(pattern_index) == "**"
                    matcher.call(pattern_index + 1, path_index) ||
                      (path_index < path_components.length && matcher.call(pattern_index, path_index + 1))
                  elsif path_index < path_components.length
                    component_regex(pattern_components.fetch(pattern_index)).match?(
                      path_components.fetch(path_index)
                    ) && matcher.call(pattern_index + 1, path_index + 1)
                  else
                    false
                  end
    end
    matcher.call(0, 0)
  rescue InvalidGlob
    false
  end

  def component_regex(component)
    source = +""
    index = 0
    while index < component.length
      character = component[index]
      case character
      when "*"
        source << "[^/]*"
      when "?"
        source << "[^/]"
      when "["
        closing_index = component.index("]", index + 1)
        raise InvalidGlob, "malformed bracket class" unless closing_index

        content = component[(index + 1)...closing_index]
        raise InvalidGlob, "empty bracket class" if content.empty?
        raise InvalidGlob, "malformed bracket class" if content.include?("[")

        negated = content.start_with?("!", "^")
        content = content[1..] if negated
        raise InvalidGlob, "empty bracket class" if content.empty?

        source << bracket_class_regex(content, negated:)
        index = closing_index
      when "]"
        raise InvalidGlob, "malformed bracket class"
      else
        source << Regexp.escape(character)
      end
      index += 1
    end
    Regexp.new("\\A#{source}\\z")
  rescue RegexpError
    raise InvalidGlob, "malformed bracket class"
  end

  def bracket_class_regex(content, negated:)
    characters = content.chars
    source = +""
    index = 0
    while index < characters.length
      if index + 2 < characters.length && characters[index + 1] == "-" &&
         characters[index] != "-" && characters[index + 2] != "-"
        first = characters[index]
        last = characters[index + 2]
        raise InvalidGlob, "descending bracket range" if first.ord > last.ord

        source << "#{Regexp.escape(first)}-#{Regexp.escape(last)}"
        index += 3
      else
        source << Regexp.escape(characters[index])
        index += 1
      end
    end
    "[#{negated ? '^' : ''}#{source}]"
  end
end
