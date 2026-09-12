# frozen_string_literal: true

require "shellwords"

module AgentWorkflowSeamDoctor
  module InitCommandShellSafety
    module_function

    def ansi_c_decoded_shell_word(raw)
      rewritten = +""
      found = false
      quote = nil
      index = 0

      while index < raw.length
        character = raw[index]
        if quote
          rewritten << character
          if quote == '"' && character == "\\"
            index += 1
            rewritten << raw[index].to_s
          elsif character == quote
            quote = nil
          end
        elsif character == "\\"
          rewritten << character
          index += 1
          rewritten << raw[index].to_s
        elsif ["'", '"'].include?(character)
          quote = character
          rewritten << character
        elsif character == "$" && raw[index + 1] == "'"
          decoded, finish = decode_ansi_c_segment(raw, index + 2)
          rewritten << Shellwords.escape(decoded)
          found = true
          index = finish
        else
          rewritten << character
        end
        index += 1
      end
      return nil unless found

      words = Shellwords.shellsplit(rewritten)
      raise ArgumentError, "ANSI-C shell tokenization mismatch" unless words.one?

      words.fetch(0)
    end

    def decode_ansi_c_segment(raw, index)
      decoded = +""
      truncated = false
      while index < raw.length
        character = raw[index]
        return [decoded, index] if character == "'"

        unless character == "\\"
          decoded << character unless truncated
          index += 1
          next
        end

        index += 1
        escape = raw[index]
        raise AnsiCDecodeError, "trailing backslash escape" unless escape

        if escape.match?(/[0-7]/)
          digits = raw[index, 3].to_s[/\A[0-7]{1,3}/]
          value = digits.to_i(8)
          truncated = true if (value & 0xff).zero?
          decoded << ansi_c_byte_for_syntax(value) unless truncated
          index += digits.length
        elsif escape == "x"
          digits = raw[index + 1, 2].to_s[/\A[0-9A-Fa-f]{1,2}/]
          raise AnsiCDecodeError, "hex escape requires at least one digit" unless digits

          value = digits.to_i(16)
          truncated = true if (value & 0xff).zero?
          decoded << ansi_c_byte_for_syntax(value) unless truncated
          index += digits.length + 1
        elsif %w[u U].include?(escape)
          limit = escape == "u" ? 4 : 8
          digits = raw[index + 1, limit].to_s[/\A[0-9A-Fa-f]{1,#{limit}}/]
          raise AnsiCDecodeError, "Unicode escape requires at least one digit" unless digits

          value = digits.to_i(16)
          if value > 0x10ffff || value.between?(0xd800, 0xdfff)
            raise AnsiCDecodeError, "Unicode escape is not a scalar value"
          end

          truncated = true if value.zero?
          decoded << value.chr(Encoding::UTF_8) unless truncated
          index += digits.length + 1
        elsif (value = {
          "a" => "\a", "b" => "\b", "e" => "\e", "E" => "\e", "f" => "\f", "n" => "\n",
          "r" => "\r", "t" => "\t", "v" => "\v", '"' => '"', "?" => "?"
        }[escape])
          decoded << value unless truncated
          index += 1
        elsif ["\\", "'"].include?(escape)
          decoded << escape unless truncated
          index += 1
        else
          raise AnsiCDecodeError, "unsupported escape \\#{escape}"
        end
      end
      raise AnsiCDecodeError, "unterminated ANSI-C quote"
    end

    def ansi_c_byte_for_syntax(value)
      byte = value & 0xff
      return "" if byte.zero?
      return byte.chr if byte < 0x80

      # High bytes cannot introduce ASCII shell syntax. A valid UTF-8 sentinel keeps analysis safe
      # while the original ANSI-C command remains byte-for-byte unchanged in the generated wrapper.
      "\ufffd"
    end

    def active_outer_command_substitution?(command)
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
        if quote == '"'
          if character == "\\"
            escaped = true
          elsif character == quote
            quote = nil
          elsif character == "`" || (character == "$" && characters[index + 1] == "(")
            return true
          end
          next
        end

        if character == "\\"
          escaped = true
        elsif character == "'"
          quote = character
        elsif character == '"'
          quote = character
        elsif character == "`" || (character == "$" && characters[index + 1] == "(")
          return true
        end
      end

      false
    end
  end
end
