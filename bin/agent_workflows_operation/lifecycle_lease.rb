# frozen_string_literal: true

require "securerandom"

require_relative "errors"
require_relative "secure_paths"

module AgentWorkflowsOperation
  class LifecycleLease
    TIMEOUT_SECONDS = 10
    POLL_SECONDS = 0.05
    LOCK_NAME = "lifecycle.lock"

    attr_reader :root, :target

    def initialize(target:, root:, timeout: TIMEOUT_SECONDS)
      @target = File.expand_path(target)
      @root = root
      @timeout = timeout
    end

    def with_shared(&block)
      with_lock(File::LOCK_SH, &block)
    end

    def with_exclusive(&block)
      with_lock(File::LOCK_EX, &block)
    end

    def lock_path
      File.join(root, LOCK_NAME)
    end

    private

    def with_lock(mode)
      file = open_lock_file!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      until file.flock(mode | File::LOCK_NB)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise LifecycleBusyError, "LIFECYCLE_BUSY: timed out acquiring the provider lifecycle lease"
        end

        sleep POLL_SECONDS
      end
      file.close_on_exec = true
      yield file
    ensure
      file&.flock(File::LOCK_UN)
      file&.close
    end

    def open_lock_file!
      SecurePaths.verify_private_directory!(root)
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      file = File.open(lock_path, flags, 0o600)
      path_stat = SecurePaths.verify_private_file!(lock_path, mode: 0o600)
      descriptor_stat = file.stat
      unless [path_stat.dev, path_stat.ino, path_stat.uid, path_stat.ftype] ==
             [descriptor_stat.dev, descriptor_stat.ino, descriptor_stat.uid, descriptor_stat.ftype]
        raise LifecycleError, "LIFECYCLE_STATE_UNSAFE: lifecycle lock identity changed"
      end

      file
    rescue PathError, SystemCallError => e
      file&.close
      raise LifecycleError, "LIFECYCLE_STATE_UNSAFE: #{e.message}"
    end
  end
end
