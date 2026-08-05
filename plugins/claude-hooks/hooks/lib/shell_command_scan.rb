# frozen_string_literal: true

# Recognise real command invocations inside a shell command string.
#
# Quoted spans and heredoc bodies are removed before matching so a phrase that
# only appears inside a quoted flag, a message body, or a heredoc is never
# mistaken for a real invocation. That robustness lesson and the overall shape
# of this scan are adapted from the MIT-licensed `intercom/2x-skills` pack
# (`plugins/pr-tools/hooks/strip-quoted-and-heredocs.py` and
# `intercept-gh-pr-create.sh`). Reimplemented in Ruby here; no code is copied
# and there is no runtime dependency on that pack.
#
# Accepted trade-off, same as the reference implementation: stripping quoted
# spans means a quoted subcommand token (`gh pr "merge" 7`) stops matching. A
# missed match is a fail-open outcome for the caller, which is the correct bias
# for deciding whether a gate *applies*; it is not the bias used for deciding
# whether the gated work is safe.
module ShellCommandScan
  # Flags that consume the following token as their value, so that value is not
  # mistaken for a positional subcommand argument.
  VALUE_FLAGS = %w[--repo -R --hostname].freeze

  # Shell operators that end one simple command and begin another.
  SEGMENT_SPLIT = /\|\||&&|;|\||&|\n|\(|\)/

  ASSIGNMENT_PREFIX = /\A[A-Za-z_][A-Za-z0-9_]*=/

  module_function

  # Remove quoted spans and heredoc bodies, replacing each with a space so that
  # neighbouring tokens never fuse into a new token.
  def strip_quoted_and_heredocs(command)
    source = command.to_s
    out = +""
    index = 0
    pending_heredocs = []
    open_heredoc = nil
    in_single = false
    in_double = false

    while index < source.length
      if open_heredoc
        line_end = source.index("\n", index) || source.length
        open_heredoc = pending_heredocs.shift if source[index...line_end].strip == open_heredoc
        out << "\n" if line_end < source.length
        index = line_end + 1
        next
      end

      char = source[index]

      if in_single
        in_single = false if char == "'"
        out << " " if char == "'"
        index += 1
        next
      end

      if in_double
        if char == "\\"
          index += 2
          next
        end
        in_double = false if char == '"'
        out << " " if char == '"'
        index += 1
        next
      end

      case char
      when "\\"
        out << " "
        index += 2
      when "'"
        in_single = true
        out << " "
        index += 1
      when '"'
        in_double = true
        out << " "
        index += 1
      when "<"
        # A `<<<` here-string is a redirection, not a heredoc: keep it whole so
        # the token scan can recognise and skip it.
        if source[index, 3] == "<<<"
          out << "<<<"
          index += 3
          next
        end

        consumed = scan_heredoc_operator(source, index, pending_heredocs)
        if consumed
          out << " "
          index = consumed
        else
          out << char
          index += 1
        end
      when "\n"
        open_heredoc = pending_heredocs.shift unless pending_heredocs.empty?
        out << "\n"
        index += 1
      else
        out << char
        index += 1
      end
    end

    out
  end

  # Detect a `<<`, `<<-`, or `<<~` heredoc operator at `index`. Returns the
  # index just past the delimiter and queues the terminator, or nil when this is
  # not a heredoc (a `<<<` here-string or a plain redirection).
  def scan_heredoc_operator(source, index, pending_heredocs)
    return nil unless source[index, 2] == "<<"
    return nil if source[index + 2] == "<"

    cursor = index + 2
    cursor += 1 if ["-", "~"].include?(source[cursor])
    cursor += 1 while [" ", "\t"].include?(source[cursor])

    quote = source[cursor] if ["'", '"'].include?(source[cursor])
    cursor += 1 if quote
    delimiter = +""
    while cursor < source.length
      char = source[cursor]
      break if quote.nil? && !char.match?(/[A-Za-z0-9_.-]/)
      break if quote && char == quote

      delimiter << char
      cursor += 1
    end
    cursor += 1 if quote && source[cursor] == quote
    return nil if delimiter.empty?

    pending_heredocs << delimiter
    cursor
  end

  # Every invocation of `executable subcommand...` in the command, after
  # stripping. Returns one hash per match with the positional arguments that
  # follow the subcommand path and the `--repo`/`-R` value when present.
  def invocations(command, executable:, subcommands:)
    segments = strip_quoted_and_heredocs(command).split(SEGMENT_SPLIT)

    segments.filter_map do |segment|
      tokens = segment.split(/\s+/).reject(&:empty?)
      tokens = tokens.drop_while { |token| token.match?(ASSIGNMENT_PREFIX) }
      next if tokens.empty?
      next unless File.basename(tokens.first) == executable

      positionals = positional_arguments(tokens.drop(1))
      next unless positionals.first(subcommands.length) == subcommands

      { arguments: positionals.drop(subcommands.length), repo: repo_flag(tokens) }
    end
  end

  # A bare redirection operator, whose target is the next token.
  REDIRECTION_OPERATOR = /\A\d*(?:>>|>|<<<|<)(?:&\d+-?)?\z/

  # A redirection with its target attached, such as `>out.log` or `2>&1`.
  REDIRECTION_WITH_TARGET = /\A\d*(?:>>|>|<<<|<)\S+\z/

  # Tokens that are neither flags, redirections, nor a value consumed by either.
  def positional_arguments(tokens)
    positionals = []
    index = 0
    while index < tokens.length
      token = tokens[index]
      if token.match?(REDIRECTION_OPERATOR)
        index += 2
      elsif token.match?(REDIRECTION_WITH_TARGET)
        index += 1
      elsif token.start_with?("-")
        index += VALUE_FLAGS.include?(token) ? 2 : 1
      else
        positionals << token
        index += 1
      end
    end
    positionals
  end

  def repo_flag(tokens)
    tokens.each_with_index do |token, index|
      return token.split("=", 2).last if token.start_with?("--repo=", "-R=")
      return tokens[index + 1] if ["--repo", "-R"].include?(token) && tokens[index + 1]
    end
    nil
  end
end
