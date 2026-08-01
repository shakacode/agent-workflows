# frozen_string_literal: true

require_relative "errors"
require_relative "source_contract"

module AgentWorkflowsOperation
  class SecureGit
    CANONICAL_URL = AgentWorkflowsSourceContract::CANONICAL_URL
    PRIVATE_REF = "refs/agent-workflows/canonical-main"
    GIT_CANDIDATES = AgentWorkflowsSourceContract::GIT_CANDIDATES
    COMMAND_TIMEOUT_SECONDS = 120
    TERMINATION_GRACE_SECONDS = 0.5
    POLL_SECONDS = 0.02
    TIMEOUT_EXIT_STATUS = 124

    attr_reader :executable

    def initialize(timeout: COMMAND_TIMEOUT_SECONDS)
      @executable = GIT_CANDIDATES.find { |path| File.file?(path) && File.executable?(path) }
      raise GitError, "a trusted Git executable was not found in standard system locations" unless @executable

      @timeout = timeout
    end

    def fetch_canonical!(repository, private_home:)
      fetch_url!(repository, CANONICAL_URL, private_home: private_home)
    end

    def import_local_revision!(repository, source, revision, private_home:)
      unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)
        raise GitError, "local provider revision must be a full SHA-1 commit"
      end

      source_root = File.realpath(source)
      source_head = repository_head!(source_root)
      unless source_head == revision
        raise GitError, "local provider HEAD does not match the requested revision"
      end

      run!(
        repository,
        "-c", "protocol.file.allow=always",
        "fetch",
        "--update-shallow",
        "--no-tags",
        "--force",
        "--no-recurse-submodules",
        "--no-write-fetch-head",
        source_root,
        "+#{revision}:#{PRIVATE_REF}",
        private_home: private_home
      )
    rescue SystemCallError => e
      raise GitError, "local provider source is unavailable: #{e.message}"
    end

    def init_bare!(repository, private_home:)
      environment = command_environment(private_home)
      command = [
        executable,
        "-c", "core.hooksPath=/dev/null",
        "-c", "protocol.file.allow=never",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "init",
        "--bare",
        "--quiet",
        "--template=",
        repository
      ]
      _stdout, stderr, status = capture3(environment, command)
      return if status.success?

      detail = stderr.to_s.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise GitError, "secure Git initialization failed: #{detail}"
    rescue SystemCallError => e
      raise GitError, "secure Git initialization unavailable: #{e.message}"
    end

    def resolve_private_revision!(repository, private_home:)
      output = run!(
        repository,
        "rev-parse",
        "--verify",
        "#{PRIVATE_REF}^{commit}",
        private_home: private_home
      )
      revision = output.strip
      raise GitError, "canonical main did not resolve to a full SHA-1 commit" unless revision.match?(/\A[0-9a-f]{40}\z/)

      revision
    end

    def archive!(repository, revision, destination, private_home:)
      require "rubygems/package"
      require "stringio"

      archive = run!(
        repository,
        "archive",
        "--format=tar",
        revision,
        private_home: private_home,
        binary: true
      )
      validate_archive!(archive, destination)
      Gem::Package::TarReader.new(StringIO.new(archive)) do |tar|
        tar.each do |entry|
          extract_archive_entry!(entry, destination)
        end
      end
      validate_snapshot_symlinks!(destination)
    rescue Gem::Package::TarInvalidError => e
      raise GitError, "canonical Git archive is invalid: #{e.message}"
    end

    def ls_tree!(repository, revision, private_home:)
      output = run!(
        repository,
        "ls-tree",
        "-rz",
        "--full-tree",
        "-r",
        revision,
        private_home: private_home,
        binary: true
      )
      output.split("\0").reject(&:empty?).to_h do |record|
        metadata, path = record.split("\t", 2)
        mode, type, object = metadata.split(" ", 3)
        raise GitError, "canonical tree contains a non-blob entry: #{path}" unless type == "blob"

        [path, { "mode" => mode, "object" => object }]
      end
    end

    def repository_head!(repository)
      run!(repository, "rev-parse", "--verify", "HEAD^{commit}", private_home: File.dirname(repository)).strip
    end

    def repository_status!(repository)
      run!(
        repository,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        private_home: File.dirname(repository)
      )
    end

    def run!(repository, *arguments, private_home:, binary: false)
      environment = command_environment(private_home)
      command = [
        executable,
        "-c", "core.hooksPath=/dev/null",
        "-c", "protocol.file.allow=never",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "-c", "fetch.fsckObjects=true",
        "-c", "transfer.fsckObjects=true",
        "-C", repository,
        *arguments
      ]
      stdout, stderr, status = capture3(environment, command, binary: binary)
      return stdout if status.success?

      detail = stderr.to_s.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise GitError, "secure Git command failed: #{detail}"
    rescue SystemCallError => e
      raise GitError, "secure Git command unavailable: #{e.message}"
    end

    private

    def capture3(environment, command, binary: false)
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      timeout_reader, timeout_writer = IO.pipe
      guardian = fork_git_guardian(
        environment,
        command,
        read_streams: [stdout_reader, stderr_reader, timeout_reader],
        stdout: stdout_writer,
        stderr: stderr_writer,
        timeout: timeout_writer
      )
      stdout_writer.close
      stderr_writer.close
      timeout_writer.close
      [stdout_reader, stderr_reader].each(&:binmode) if binary
      readers = [stdout_reader, stderr_reader].map do |stream|
        Thread.new do
          stream.read
        rescue IOError
          ""
        end
      end
      timed_out = timeout_reader.read(1) == "T"
      if timed_out
        Process.detach(guardian)
        guardian = nil
        stop_readers!(readers, [stdout_reader, stderr_reader])
        raise GitError, "secure Git command timed out after #{@timeout} seconds"
      end

      _pid, status = Process.wait2(guardian)
      guardian = nil
      stop_readers!(readers, [stdout_reader, stderr_reader])

      [readers[0].value.to_s, readers[1].value.to_s, status]
    ensure
      [stdout_reader, stdout_writer, stderr_reader, stderr_writer, timeout_reader, timeout_writer].compact.each do |stream|
        stream.close unless stream.closed?
      rescue IOError
        nil
      end
      readers&.each { |thread| thread.join(TERMINATION_GRACE_SECONDS) }
      Process.detach(guardian) if guardian
    end

    def fork_git_guardian(environment, command, read_streams:, stdout:, stderr:, timeout:)
      guardian = fork do
        Process.setpgid(0, 0)
        read_streams.each(&:close)
        git_pid = Process.spawn(
          environment,
          *command,
          unsetenv_others: true,
          pgroup: true,
          in: File::NULL,
          out: stdout,
          err: stderr
        )
        stdout.close
        wait_for_process_group!(git_pid, timeout)
      rescue SystemCallError => e
        stderr.puts("secure Git command unavailable: #{e.message}")
        exit! 127
      ensure
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
        timeout.close unless timeout.closed?
      end
      Process.setpgid(guardian, guardian)
      guardian
    rescue Errno::EACCES, Errno::ESRCH
      guardian
    end

    def wait_for_process_group!(pid, timeout)
      deadline = monotonic_time + @timeout
      status = nil
      loop do
        status ||= reap_nonblock(pid)
        mirror_status(status) if status && !process_group_alive?(pid)
        break if monotonic_time >= deadline

        sleep POLL_SECONDS
      end

      status, group_alive = terminate_process_group!(pid, status)
      begin
        timeout.write("T")
      rescue Errno::EPIPE, IOError
        nil
      end
      timeout.close unless timeout.closed?
      while group_alive
        status ||= reap_nonblock(pid)
        group_alive = process_group_alive?(pid)
        sleep POLL_SECONDS if group_alive
      end
      exit! TIMEOUT_EXIT_STATUS
    end

    def terminate_process_group!(pid, status)
      signal_process_group("TERM", pid)
      deadline = monotonic_time + TERMINATION_GRACE_SECONDS
      loop do
        status ||= reap_nonblock(pid)
        break unless process_group_alive?(pid) && monotonic_time < deadline

        sleep POLL_SECONDS
      end
      signal_process_group("KILL", pid) if process_group_alive?(pid)
      kill_deadline = monotonic_time + TERMINATION_GRACE_SECONDS
      while process_group_alive?(pid) && monotonic_time < kill_deadline
        status ||= reap_nonblock(pid)
        sleep POLL_SECONDS
      end
      status ||= reap_nonblock(pid)
      [status, process_group_alive?(pid)]
    end

    def reap_nonblock(pid)
      waited = Process.waitpid2(pid, Process::WNOHANG)
      waited&.last
    rescue Errno::ECHILD
      nil
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
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

    def signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def stop_readers!(readers, streams)
      deadline = monotonic_time + TERMINATION_GRACE_SECONDS
      readers.each do |reader|
        remaining = deadline - monotonic_time
        reader.join(remaining) if remaining.positive?
      end
      streams.each { |stream| stream.close unless stream.closed? }
      readers.each do |reader|
        next unless reader.alive?

        reader.kill
        reader.join
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def command_environment(private_home)
      {
        "HOME" => private_home,
        "XDG_CONFIG_HOME" => private_home,
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG" => "C",
        "LC_ALL" => "C",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_SYSTEM" => "/dev/null",
        "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_TERMINAL_PROMPT" => "0"
      }
    end

    def fetch_url!(repository, url, private_home:)
      run!(
        repository,
        "fetch",
        "--no-tags",
        "--force",
        "--no-recurse-submodules",
        "--no-write-fetch-head",
        url,
        "+refs/heads/main:#{PRIVATE_REF}",
        private_home: private_home
      )
    end

    def extract_archive_entry!(entry, destination)
      return if entry.header.typeflag == "g" && entry.full_name == "pax_global_header"

      relative = entry.full_name.delete_suffix("/")
      return if relative.empty?

      validate_archive_path!(relative)
      path = File.join(destination, relative)
      if entry.directory?
        ensure_archive_directory!(destination, relative)
      elsif entry.file?
        ensure_archive_parent!(destination, relative)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, entry.header.mode & 0o777) do |file|
          IO.copy_stream(entry, file)
        end
        File.chmod(entry.header.mode & 0o777, path)
      elsif entry.header.typeflag == "2"
        ensure_archive_parent!(destination, relative)
        File.symlink(entry.header.linkname, path)
      else
        raise GitError, "canonical Git archive contains unsupported entry type for #{relative}"
      end
    end

    def validate_archive!(archive, destination)
      entries = {}
      Gem::Package::TarReader.new(StringIO.new(archive)) do |tar|
        tar.each do |entry|
          next if entry.header.typeflag == "g" && entry.full_name == "pax_global_header"

          relative = entry.full_name.delete_suffix("/")
          next if relative.empty?

          validate_archive_path!(relative)
          type = archive_entry_type(entry, relative)
          raise GitError, "canonical Git archive contains a duplicate path: #{relative}" if entries.key?(relative)

          validate_archive_symlink!(entry, destination, relative) if type == :symlink
          entries[relative] = type
        end
      end
      entries.each_key do |relative|
        components = relative.split("/")
        1.upto(components.length - 1) do |length|
          ancestor = components.first(length).join("/")
          next unless entries.key?(ancestor) && entries.fetch(ancestor) != :directory

          raise GitError, "canonical Git archive path traverses a non-directory entry: #{relative}"
        end
      end
    end

    def archive_entry_type(entry, relative)
      return :directory if entry.directory?
      return :file if entry.file?
      return :symlink if entry.header.typeflag == "2"

      raise GitError, "canonical Git archive contains unsupported entry type for #{relative}"
    end

    def validate_archive_symlink!(entry, destination, relative)
      path = File.join(destination, relative)
      resolved = File.expand_path(entry.header.linkname, File.dirname(path))
      return if resolved == destination || resolved.start_with?("#{destination}/")

      raise GitError, "canonical Git archive symlink escapes the snapshot: #{relative}"
    end

    def ensure_archive_parent!(destination, relative)
      parent = File.dirname(relative)
      return if parent == "."

      ensure_archive_directory!(destination, parent)
    end

    def ensure_archive_directory!(destination, relative)
      current = destination
      relative.split("/").each do |component|
        current = File.join(current, component)
        if File.exist?(current) || File.symlink?(current)
          stat = File.lstat(current)
          unless stat.directory? && !stat.symlink?
            raise GitError, "canonical Git archive path traverses a non-directory entry: #{relative}"
          end
        else
          Dir.mkdir(current, 0o700)
        end
      end
    end

    def validate_archive_path!(relative)
      components = relative.split("/")
      return unless relative.start_with?("/") || components.any? { |component| component.empty? || %w[. ..].include?(component) }

      raise GitError, "canonical Git archive contains an unsafe path: #{relative}"
    end

    def validate_snapshot_symlinks!(root)
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next unless File.symlink?(path)

        resolved = File.expand_path(File.readlink(path), File.dirname(path))
        next if resolved == root || resolved.start_with?("#{root}/")

        raise GitError, "canonical Git archive symlink escapes the snapshot: #{path}"
      end
    end
  end
end
