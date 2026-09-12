# frozen_string_literal: true

require "shellwords"

module AgentWorkflowSeamDoctor
  module InitCommandShellLexical
    module_function

    def shell_comment_index(command)
      quote = nil
      escaped = false
      token_start = true

      command.each_char.with_index do |character, index|
        if escaped
          escaped = false
          token_start = false
          next
        end
        if quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
          token_start = false
          next
        end

        case character
        when "\\"
          escaped = true
        when "'", '"'
          quote = character
          token_start = false
        when "#"
          return index if token_start

          token_start = false
        else
          token_start = character.match?(/\s/)
        end
      end
      nil
    end

    def unquoted_shell_boundary?(raw)
      quote = nil
      escaped = false

      raw.each_char do |character|
        if escaped
          escaped = false
        elsif quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
        elsif character == "\\"
          escaped = true
        elsif ["'", '"'].include?(character)
          quote = character
        elsif character.match?(/[|&;()<>]/)
          return true
        end
      end

      false
    end

    def shell_c_placeholder_word?(raw)
      return false if raw.empty? || raw.match?(/\A[#|&;()<>]/)
      return false if raw.match?(/\A(?:[0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})[<>]/)

      quote = nil
      escaped = false
      raw.each_char do |character|
        if escaped
          escaped = false
        elsif quote == "'"
          quote = nil if character == quote
        elsif character == "\\"
          escaped = true
        elsif quote == '"'
          return false if ["$", "`"].include?(character)

          quote = nil if character == quote
        elsif ["'", '"'].include?(character)
          quote = character
        elsif ["$", "`", "*", "?", "[", "]", "{", "}", "(", ")", "|", "&", ";", "<", ">"].include?(character)
          return false
        end
      end

      true
    end

    def shell_word_spans(command)
      values = Shellwords.shellsplit(command)
      spans = []
      token_start = nil
      quote = nil
      escaped = false

      command.each_char.with_index do |character, index|
        if escaped
          escaped = false
          next
        end

        if quote
          if quote == '"' && character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          end
          next
        end

        if character.match?(/\s/)
          if token_start
            spans << { start: token_start, finish: index }
            token_start = nil
          end
        else
          token_start ||= index
          case character
          when "\\"
            escaped = true
          when "'", '"'
            quote = character
          end
        end
      end
      spans << { start: token_start, finish: command.length } if token_start
      raise ArgumentError, "shell tokenization mismatch" unless values.length == spans.length

      values.zip(spans).map do |value, span|
        span.merge(value:, raw: command[span.fetch(:start)...span.fetch(:finish)])
      end
    end
  end
end
