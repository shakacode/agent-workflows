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
      child = spawn_guardian(environment, command)
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

    def spawn_guardian(environment, command)
      guardian = fork do
        capability = nil
        pending = []
        SIGNALS.each do |signal|
          Signal.trap(signal) { pending << signal unless capability }
        end
        Process.setpgid(0, 0)
        capability = Process.spawn(environment, *command, unsetenv_others: true)
        pending.each do |signal|
          Process.kill(signal, capability)
        rescue Errno::ESRCH
          nil
        end
        _pid, status = Process.wait2(capability)
        mirror_status(status)
      rescue SystemCallError => e
        warn "operation capability could not be started: #{e.message}"
        exit! 127
      end
      Process.setpgid(guardian, guardian)
      guardian
    rescue Errno::EACCES, Errno::ESRCH
      guardian
    end

    def mirror_status(status)
      exit! status.exitstatus if status.exited?

      signal = status.termsig
      begin
        Signal.trap(signal, "SYSTEM_DEFAULT")
      rescue ArgumentError, Errno::EINVAL
        nil
      end
      Process.kill(signal, Process.pid)
      exit! 128 + signal
    end
  end
end
