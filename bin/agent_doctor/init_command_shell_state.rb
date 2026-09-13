# frozen_string_literal: true

require "shellwords"

module AgentWorkflowSeamDoctor
  module InitCommandShellState
    module_function

    def positional_state_reference?(command)
      active_dollar_expansion?(command) do |characters, index|
        positional_argument_expansion_at?(characters, index) ||
          bash_outer_argument_state_expansion_at?(characters, index)
      end
    end

    def bash_outer_argument_state_expansion_at?(characters, index)
      return true if characters[index + 1, 2] == ["{", "!"]

      %w[BASH_ARGV BASH_ARGC BASH_ARGV0].any? do |name|
        named_parameter_expansion_at?(characters, index, name)
      end
    end

    def named_parameter_expansion_at?(characters, index, name)
      offset = index + 1
      if characters[offset] == "{"
        offset += 1
        offset += 1 if characters[offset] == "#"
      end
      return false unless characters[offset, name.length].join == name

      !characters[offset + name.length]&.match?(/\A[A-Za-z0-9_]\z/)
    end

    def active_dollar_expansion?(command)
      characters = command.chars
      quote = nil
      escaped = false

      characters.each_with_index do |character, index|
        if escaped
          escaped = false
          next
        end

        if quote == "'"
          quote = nil if character == quote
          next
        end

        if character == "\\"
          escaped = true
        elsif quote == '"'
          quote = nil if character == quote
        elsif ["'", '"'].include?(character)
          quote = character
        end

        next unless character == "$"

        return true if yield(characters, index)
      end

      false
    end

    def positional_argument_expansion_at?(characters, index)
      marker = characters[index + 1]
      return true if marker&.match?(/\A[@*#0-9]\z/)
      return false unless marker == "{"

      parameter = characters[index + 2]
      return true if parameter&.match?(/\A[@*0-9]\z/)
      if parameter == "!"
        return characters[index + 3]&.match?(/\A[@*#0-9]\z/)
      end
      return false unless parameter == "#"

      # `${#name}` is the length of a named variable; other `${#...}` forms address
      # the positional-count parameter or the length of a positional parameter.
      !characters[index + 3]&.match?(/\A[A-Za-z_]\z/)
    end
  end
end
