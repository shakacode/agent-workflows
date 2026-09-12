# frozen_string_literal: true

require_relative "init_command_shell_lexical"
require_relative "init_command_shell_safety"
require_relative "init_command_shell_state"

module AgentWorkflowSeamDoctor
  module InitCommandShell
    include InitCommandShellLexical
    include InitCommandShellSafety
    include InitCommandShellState

    PUBLIC_METHODS = %i[
      active_dollar_expansion?
      active_outer_command_substitution?
      ansi_c_byte_for_syntax
      ansi_c_decoded_shell_word
      bash_outer_argument_state_expansion_at?
      decode_ansi_c_segment
      named_parameter_expansion_at?
      positional_argument_expansion_at?
      positional_state_reference?
      shell_c_placeholder_word?
      shell_comment_index
      shell_word_spans
      unquoted_shell_boundary?
    ].freeze
  end
end
