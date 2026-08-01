# frozen_string_literal: true

require "tempfile"
require "tmpdir"

module AgentWorkflowsSourceContract
  REPOSITORY = "shakacode/agent-workflows"
  REF = "refs/heads/main"
  REMOTE_REF = "refs/remotes/origin/main"
  FETCH_REFSPEC = "+#{REF}:#{REMOTE_REF}".freeze
  CANONICAL_URL = "https://github.com/#{REPOSITORY}.git".freeze
  ACCEPTED_URLS = [
    CANONICAL_URL,
    "https://github.com/#{REPOSITORY}",
    "git@github.com:#{REPOSITORY}.git",
    "ssh://git@github.com/#{REPOSITORY}.git"
  ].freeze
  GIT_CANDIDATES = %w[/usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git].freeze
  COMMAND_TIMEOUT_SECONDS = 120
  TERMINATION_GRACE_SECONDS = 0.5
  POLL_SECONDS = 0.02

  module_function

  def git_executable
    GIT_CANDIDATES.find { |path| File.file?(path) && File.executable?(path) } ||
      raise("a trusted Git executable was not found in standard system locations")
  end

  def environment(home)
    {
      "HOME" => home,
      "XDG_CONFIG_HOME" => home,
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

  def git(source, *arguments, timeout: COMMAND_TIMEOUT_SECONDS)
    command = [
      git_executable,
      "-c", "core.hooksPath=/dev/null",
      "-c", "protocol.file.allow=never",
      "-C", source,
      *arguments
    ]
    stdout, stderr, status = capture_git(
      environment(File.dirname(File.realpath(source))),
      command,
      timeout:
    )
    return stdout.strip if status.success?

    detail = stderr.to_s.strip
    detail = "exit #{status.exitstatus}" if detail.empty?
    raise "secure Git command failed: #{detail}"
  end

  def capture_git(environment, command, timeout:)
    stdout = Tempfile.new("agent-workflows-git-stdout")
    stderr = Tempfile.new("agent-workflows-git-stderr")
    [stdout, stderr].each(&:binmode)
    pid = Process.spawn(
      environment,
      *command,
      unsetenv_others: true,
      pgroup: true,
      in: File::NULL,
      out: stdout,
      err: stderr
    )
    status = wait_for_git(pid, timeout)
    unless status
      status = terminate_git_process_group(pid)
      begin
        Process.detach(pid) unless status
      rescue Errno::ECHILD
        nil
      end
      raise "secure Git command timed out after #{timeout} seconds"
    end

    stdout.rewind
    stderr.rewind
    [stdout.read, stderr.read, status]
  ensure
    stdout&.close!
    stderr&.close!
  end

  def wait_for_git(pid, timeout)
    deadline = monotonic_time + timeout
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited.last if waited
      return nil if monotonic_time >= deadline

      sleep POLL_SECONDS
    end
  rescue Errno::ECHILD
    nil
  end

  def terminate_git_process_group(pid)
    signal_git_process_group("TERM", pid)
    status = nil
    deadline = monotonic_time + TERMINATION_GRACE_SECONDS
    while git_process_group_alive?(pid) && monotonic_time < deadline
      status ||= reap_git(pid)
      sleep POLL_SECONDS
    end
    return status unless git_process_group_alive?(pid)

    signal_git_process_group("KILL", pid)
    deadline = monotonic_time + TERMINATION_GRACE_SECONDS
    while git_process_group_alive?(pid) && monotonic_time < deadline
      status ||= reap_git(pid)
      sleep POLL_SECONDS
    end
    status ||= reap_git(pid)
    status
  end

  def reap_git(pid)
    Process.waitpid2(pid, Process::WNOHANG)&.last
  rescue Errno::ECHILD
    nil
  end

  def git_process_group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  end

  def signal_git_process_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def validate_root!(source)
    root = File.realpath(source)
    raise "declared Git source is not a working tree" unless git(root, "rev-parse", "--is-inside-work-tree") == "true"

    top = File.realpath(git(root, "rev-parse", "--show-toplevel"))
    raise "declared Git source resolves to another worktree root: #{top}" unless top == root

    root
  rescue SystemCallError => e
    raise "declared Git source is unavailable: #{e.message}"
  end

  def validate_origin!(source)
    urls = git(source, "config", "--get-all", "remote.origin.url").lines.map(&:strip).reject(&:empty?)
    raise "managed source requires exactly one canonical origin URL" unless urls.length == 1
    raise "managed source origin is not #{REPOSITORY}" unless ACCEPTED_URLS.include?(urls.first)

    true
  end

  def cached_revision!(source)
    revision = git(source, "rev-parse", "--verify", "#{REMOTE_REF}^{commit}")
    raise "cached canonical main is not a full commit SHA" unless revision.match?(/\A[0-9a-f]{40}\z/)

    revision
  end

  def version_at_revision!(source, revision)
    raise "canonical revision is not a full commit SHA" unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)

    git(source, "cat-file", "blob", "#{revision}:VERSION")
  end

  def fetch!(source)
    revision = nil
    Dir.mktmpdir("agent-workflows-canonical-fetch") do |staging|
      File.chmod(0o700, staging)
      git(staging, "init", "--quiet", "--bare", "--template=")
      git(
        staging,
        "fetch", "--quiet", "--no-tags", "--prune", "--force",
        "--no-recurse-submodules", "--no-write-fetch-head",
        CANONICAL_URL, "+#{REF}:#{REF}"
      )
      revision = git(staging, "rev-parse", "--verify", "#{REF}^{commit}")
      raise "canonical main is not a full commit SHA" unless revision.match?(/\A[0-9a-f]{40}\z/)

      bundle = File.join(staging, "canonical-main.bundle")
      git(staging, "bundle", "create", bundle, REF)
      git(source, "bundle", "unbundle", bundle)
      git(source, "update-ref", REMOTE_REF, revision)
    end
    raise "canonical fetch did not resolve main" unless revision

    cached = cached_revision!(source)
    raise "cached canonical main differs from the isolated fetch" unless cached == revision

    revision
  end

  def validate_managed_install!(source, fetch: true)
    root = validate_root!(source)
    validate_origin!(root)
    fetch!(root) if fetch
    branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD")
    raise "managed install requires the clean main branch" unless branch == "main"
    raise "managed install requires a clean source checkout" unless git(root, "status", "--porcelain=v1", "--untracked-files=all").empty?

    head = git(root, "rev-parse", "--verify", "HEAD^{commit}")
    remote = cached_revision!(root)
    raise "managed install requires main to equal cached canonical origin/main" unless head == remote

    head
  end

  def validate_managed_metadata!(metadata)
    return if metadata["provider_repository"] == REPOSITORY && metadata["provider_ref"] == REF

    raise "managed install metadata must record #{REPOSITORY} at #{REF}"
  end

  def fast_forward_main!(source, fetch: true)
    root = validate_root!(source)
    validate_origin!(root)
    branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD")
    raise "managed upgrade requires the clean main branch" unless branch == "main"
    raise "managed upgrade requires a clean source checkout" unless git(root, "status", "--porcelain=v1", "--untracked-files=all").empty?

    remote = fetch ? fetch!(root) : cached_revision!(root)
    head = git(root, "rev-parse", "--verify", "HEAD^{commit}")
    if fetch
      git(root, "merge", "--ff-only", "--quiet", remote) unless head == remote
    elsif head != remote
      raise "managed --no-fetch upgrade requires main to equal cached canonical origin/main"
    end
    git(root, "rev-parse", "--verify", "HEAD^{commit}")
  end
end
