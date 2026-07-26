# frozen_string_literal: true

module AgentWorkflowsEntryLease
  class Error < StandardError; end

  TIMEOUT_SECONDS = 10
  POLL_SECONDS = 0.05
  STATE_DIRECTORY = ".agent-workflows-operation-state"
  LOCK_NAME = "lifecycle.lock"

  class Held
    def initialize(file:, mode:)
      @file = file
      @mode = mode
    end

    def with_shared
      yield @file
    end

    def with_exclusive
      unless @mode == :exclusive
        raise Error, "LIFECYCLE_REENTRY_REJECTED: shared entry lease cannot satisfy an exclusive operation"
      end

      yield @file
    end
  end

  module_function

  def with(target:, mode:)
    target = File.expand_path(target)
    root = File.join(target, STATE_DIRECTORY)
    verify_owned_directory!(target)
    verify_private_directory!(root)
    path = File.join(root, LOCK_NAME)
    flags = File::RDWR
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    file = File.open(path, flags)
    verify_lock_identity!(path, file)
    acquire!(file, mode)
    file.close_on_exec = false
    yield Held.new(file:, mode:)
  rescue SystemCallError => e
    raise Error, "LIFECYCLE_STATE_UNSAFE: #{e.message}"
  ensure
    file&.flock(File::LOCK_UN)
    file&.close
  end

  def verify_private_directory!(path)
    stat = File.lstat(path)
    return if stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

    raise Error, "LIFECYCLE_STATE_UNSAFE: expected private owned directory: #{path}"
  end

  def verify_owned_directory!(path)
    stat = File.lstat(path)
    return if stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?

    raise Error, "LIFECYCLE_STATE_UNSAFE: expected owned non-writable directory: #{path}"
  end

  def verify_lock_identity!(path, file)
    path_stat = File.lstat(path)
    descriptor_stat = file.stat
    expected = [path_stat.dev, path_stat.ino, path_stat.uid, path_stat.ftype, path_stat.mode & 0o777]
    actual = [
      descriptor_stat.dev,
      descriptor_stat.ino,
      descriptor_stat.uid,
      descriptor_stat.ftype,
      descriptor_stat.mode & 0o777
    ]
    return if expected == actual && expected.last == 0o600 && !path_stat.symlink?

    raise Error, "LIFECYCLE_STATE_UNSAFE: lifecycle lock identity changed"
  end

  def acquire!(file, mode)
    operation = mode == :exclusive ? File::LOCK_EX : File::LOCK_SH
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS
    until file.flock(operation | File::LOCK_NB)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Error, "LIFECYCLE_BUSY: timed out acquiring the provider lifecycle lease"
      end

      sleep POLL_SECONDS
    end
  end
end
