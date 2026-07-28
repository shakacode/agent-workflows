# frozen_string_literal: true

require "open3"

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

  def git(source, *arguments)
    stdout, stderr, status = Open3.capture3(
      environment(File.dirname(File.realpath(source))),
      git_executable,
      "-c", "core.hooksPath=/dev/null",
      "-c", "protocol.file.allow=never",
      "-C", source,
      *arguments,
      unsetenv_others: true
    )
    return stdout.strip if status.success?

    detail = stderr.to_s.strip
    detail = "exit #{status.exitstatus}" if detail.empty?
    raise "secure Git command failed: #{detail}"
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

  def fetch!(source)
    git(
      source,
      "fetch", "--quiet", "--no-tags", "--prune", "--force",
      "--no-recurse-submodules", "--no-write-fetch-head",
      CANONICAL_URL, FETCH_REFSPEC
    )
    cached_revision!(source)
  end

  def validate_managed_install!(source)
    root = validate_root!(source)
    validate_origin!(root)
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
