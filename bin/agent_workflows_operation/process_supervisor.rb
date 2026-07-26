# frozen_string_literal: true

module AgentWorkflowsOperation
  module ProcessSupervisor
    SIGNALS = %w[HUP INT TERM].freeze

    module_function

    def wait!(environment:, command:)
      child = nil
      pending = []
      prior_traps = SIGNALS.to_h do |signal|
        [signal, Signal.trap(signal) { child ? forward_signal(signal, child) : pending << signal }]
      end
      child = Process.spawn(environment, *command, pgroup: true)
      pending.each { |signal| forward_signal(signal, child) }
      _pid, status = Process.wait2(child)
      status
    ensure
      prior_traps&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    def forward_signal(signal, process_group)
      Process.kill(signal, -process_group)
    rescue Errno::ESRCH
      nil
    end
  end
end
