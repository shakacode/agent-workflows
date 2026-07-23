# frozen_string_literal: true

require "open3"

require_relative "errors"

module AgentWorkflowsOperation
  class SecureGit
    CANONICAL_URL = "https://github.com/shakacode/agent-workflows.git"
    PRIVATE_REF = "refs/agent-workflows/canonical-main"
    GIT_CANDIDATES = %w[/usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git].freeze

    attr_reader :executable

    def initialize
      @executable = GIT_CANDIDATES.find { |path| File.file?(path) && File.executable?(path) }
      raise GitError, "a trusted Git executable was not found in standard system locations" unless @executable
    end

    def fetch_canonical!(repository, private_home:)
      fetch_url!(repository, CANONICAL_URL, private_home: private_home)
    end

    def init_bare!(repository, private_home:)
      environment = command_environment(private_home)
      command = [
        executable,
        "-c", "core.hooksPath=/dev/null",
        "-c", "protocol.file.allow=never",
        "init",
        "--bare",
        "--quiet",
        "--template=",
        repository
      ]
      _stdout, stderr, status = Open3.capture3(environment, *command, unsetenv_others: true)
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
        "-c", "fetch.fsckObjects=true",
        "-c", "transfer.fsckObjects=true",
        "-C", repository,
        *arguments
      ]
      stdout, stderr, status = Open3.capture3(environment, *command, unsetenv_others: true, binmode: binary)
      return stdout if status.success?

      detail = stderr.to_s.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise GitError, "secure Git command failed: #{detail}"
    rescue SystemCallError => e
      raise GitError, "secure Git command unavailable: #{e.message}"
    end

    private

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
        FileUtils.mkdir_p(path, mode: 0o700)
      elsif entry.file?
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, entry.header.mode & 0o777) do |file|
          IO.copy_stream(entry, file)
        end
        File.chmod(entry.header.mode & 0o777, path)
      elsif entry.header.typeflag == "2"
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.symlink(entry.header.linkname, path)
      else
        raise GitError, "canonical Git archive contains unsupported entry type for #{relative}"
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
