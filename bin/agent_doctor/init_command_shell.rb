# frozen_string_literal: true

require_relative "init_command_shell_lexical"
require_relative "init_command_shell_safety"
require_relative "init_command_shell_state"

module AgentWorkflowSeamDoctor
  module InitCommandShell
    include InitCommandShellLexical
    include InitCommandShellSafety
    include InitCommandShellState
  end
end
