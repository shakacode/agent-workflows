# frozen_string_literal: true

require "shellwords"
require "tempfile"
require "tmpdir"
require "pathname"

module PrBatchGitProbeEnv
  GIT_TIMEOUT_SECONDS = Integer(ENV.fetch("PR_BATCH_GIT_PROBE_TIMEOUT_SECONDS", "10"))
  TimeoutError = Class.new(StandardError)
  OutputLimitError = Class.new(StandardError)
  IsolationError = Class.new(StandardError)

  # Keep this fallback in sync with `git rev-parse --local-env-vars` for the
  # oldest supported Git; it is used only when the dynamic query fails.
  LOCAL_ENV_VARS_FALLBACK = %w[
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR
    GIT_CONFIG
    GIT_CONFIG_COUNT
    GIT_CONFIG_PARAMETERS
    GIT_DIR
    GIT_GRAFT_FILE
    GIT_IMPLICIT_WORK_TREE
    GIT_INDEX_FILE
    GIT_NAMESPACE
    GIT_NO_REPLACE_OBJECTS
    GIT_OBJECT_DIRECTORY
    GIT_PREFIX
    GIT_REPLACE_REF_BASE
    GIT_SHALLOW_FILE
    GIT_WORK_TREE
  ].freeze

  # These explicit overrides are not reported by `git rev-parse --local-env-vars`,
  # but they can redirect config/attribute sources or change pathspec semantics.
  EXTRA_ENV_VARS = %w[
    GIT_ATTR_NOSYSTEM
    GIT_ATTR_SOURCE
    GIT_CEILING_DIRECTORIES
    GIT_CONFIG_GLOBAL
    GIT_CONFIG_NOSYSTEM
    GIT_CONFIG_SYSTEM
    GIT_DEFAULT_HASH
    GIT_DIFF_OPTS
    GIT_GLOB_PATHSPECS
    GIT_ICASE_PATHSPECS
    GIT_LITERAL_PATHSPECS
    GIT_NOGLOB_PATHSPECS
    GIT_TEMPLATE_DIR
  ].freeze

  module_function

  def local_env_vars
    @local_env_vars ||= begin
      stdout, _stderr, status = capture3({}, "git", "rev-parse", "--local-env-vars")
      names = status.success? ? stdout.force_encoding("UTF-8").scrub.lines.map(&:strip).reject(&:empty?) : []
      names.empty? ? LOCAL_ENV_VARS_FALLBACK : names
    rescue StandardError
      LOCAL_ENV_VARS_FALLBACK
    end
  end

  def capture3(
    env,
    *command,
    stdin_data: nil,
    timeout_seconds: GIT_TIMEOUT_SECONDS,
    chdir: nil,
    stdout_limit_bytes: nil
  )
    if stdout_limit_bytes
      return capture3_with_stdout_limit(
        env,
        *command,
        stdin_data: stdin_data,
        timeout_seconds: timeout_seconds,
        chdir: chdir,
        stdout_limit_bytes: stdout_limit_bytes
      )
    end

    Tempfile.create("git-probe-stdin") do |stdin|
      Tempfile.create("git-probe-stdout") do |stdout|
        Tempfile.create("git-probe-stderr") do |stderr|
          [stdin, stdout, stderr].each(&:binmode)
          stdin.write(stdin_data) if stdin_data
          stdin.rewind
          spawn_options = { in: stdin, out: stdout, err: stderr, pgroup: true }
          spawn_options[:chdir] = chdir if chdir
          pid = Process.spawn(env, *command, **spawn_options)
          status = wait_for_process(pid, timeout_seconds)
          unless status
            terminate_process_group(pid)
            status = :terminated
            raise TimeoutError, "Git probe timed out after #{timeout_seconds} seconds"
          end

          stdout.rewind
          stderr.rewind
          return [stdout.read, stderr.read, status]
        ensure
          terminate_process_group(pid) if pid && !status
        end
      end
    end
  end

  def capture3_with_stdout_limit(
    env,
    *command,
    stdout_limit_bytes:,
    stdin_data: nil,
    timeout_seconds: GIT_TIMEOUT_SECONDS,
    chdir: nil
  )
    limit = Integer(stdout_limit_bytes, exception: false)
    raise ArgumentError, "stdout limit must be a nonnegative integer" unless limit && !limit.negative?

    pid = nil
    status = nil
    stdout_reader = nil
    stdout_writer = nil
    Tempfile.create("git-probe-stdin") do |stdin|
      Tempfile.create("git-probe-stderr") do |stderr|
        stdout_reader, stdout_writer = IO.pipe
        [stdin, stderr, stdout_reader, stdout_writer].each(&:binmode)
        stdin.write(stdin_data) if stdin_data
        stdin.rewind
        spawn_options = { in: stdin, out: stdout_writer, err: stderr, pgroup: true }
        spawn_options[:chdir] = chdir if chdir
        pid = Process.spawn(env, *command, **spawn_options)
        stdout_writer.close
        stdout_bytes = +"".b
        stdout_eof = false
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          unless remaining.positive?
            terminate_process_group(pid)
            status = :terminated
            raise TimeoutError, "Git probe timed out after #{timeout_seconds} seconds"
          end

          if !stdout_eof && IO.select([stdout_reader], nil, nil, [0.01, remaining].min)
            read_length = [64 * 1024, (limit + 1) - stdout_bytes.bytesize].min
            chunk = stdout_reader.read_nonblock(read_length, exception: false)
            case chunk
            when String
              stdout_bytes << chunk
              if stdout_bytes.bytesize > limit
                terminate_process_group(pid)
                status = :terminated
                raise OutputLimitError, "Git probe stdout exceeded #{limit} bytes"
              end
            when nil
              stdout_eof = true
            end
          end

          unless status
            waited = Process.waitpid2(pid, Process::WNOHANG)
            status = waited[1] if waited
          end
          break if status && stdout_eof

          sleep [0.01, remaining].min if stdout_eof && !status
        end

        stderr.rewind
        [stdout_bytes, stderr.read, status]
      ensure
        stdout_reader&.close unless stdout_reader&.closed?
        stdout_writer&.close unless stdout_writer&.closed?
        terminate_process_group(pid) if pid && !status
      end
    end
  end

  def wait_for_process(pid, timeout_seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited[1] if waited

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return nil unless remaining.positive?

      sleep [0.01, remaining].min
    end
  rescue Errno::ECHILD
    nil
  end

  def terminate_process_group(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  ensure
    begin
      Process.waitpid2(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def probe_env(source_env = ENV)
    (local_env_vars + EXTRA_ENV_VARS).uniq.to_h { |name| [name, nil] }.tap do |env|
      source_env.each_key do |name|
        env[name] = nil if name.match?(/\AGIT_CONFIG_(KEY|VALUE)_\d+\z/)
      end
      env["GIT_NO_REPLACE_OBJECTS"] = "1"
      env["GIT_GRAFT_FILE"] = File::NULL
      env["GIT_CONFIG_PARAMETERS"] = "'advice.graftFileDeprecated'='false'"
      preserve_safe_directory_config(env, source_env)
    end
  end

  def with_committed_attributes(repository_root)
    common_dir, common_dir_stderr, common_dir_status = capture3(
      probe_env,
      "git", "rev-parse", "--git-common-dir", chdir: repository_root
    )
    unless common_dir_status.success? && common_dir_stderr.empty?
      raise IsolationError, "Git common directory is unavailable"
    end

    common_dir_path = common_dir.strip
    common_dir_path = File.expand_path(common_dir_path, repository_root) unless Pathname.new(common_dir_path).absolute?
    object_directory = File.realpath(File.join(common_dir_path, "objects"))
    object_format, object_format_stderr, object_format_status = capture3(
      probe_env,
      "git", "rev-parse", "--show-object-format", chdir: repository_root
    )
    unless object_format_status.success? && object_format_stderr.empty? && object_format.strip == "sha1"
      raise IsolationError, "Git SHA-1 object format is required"
    end

    Dir.mktmpdir("pr-batch-committed-attributes") do |isolation_root|
      git_directory = File.join(isolation_root, "repository.git")
      template_directory = File.join(isolation_root, "empty-template")
      Dir.mkdir(template_directory, 0o700)
      init_env = probe_env.merge(
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => File::NULL,
        "GIT_DEFAULT_HASH" => nil,
        "GIT_TEMPLATE_DIR" => nil
      )
      init_arguments = [
        "git", "init", "--bare", "--quiet", "--object-format=sha1", "--template=#{template_directory}"
      ]
      init_arguments << git_directory
      _stdout, stderr, status = capture3(init_env, *init_arguments)
      raise IsolationError, "Isolated Git directory initialization failed" unless status.success? && stderr.empty?

      env = probe_env.merge(
        "GIT_DIR" => git_directory,
        "GIT_OBJECT_DIRECTORY" => object_directory,
        "GIT_INDEX_FILE" => File.join(git_directory, "canonical-diff.index"),
        "GIT_WORK_TREE" => nil,
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => File::NULL
      )
      config_count = Integer(env.fetch("GIT_CONFIG_COUNT", "0"), exception: false) || 0
      env["GIT_CONFIG_COUNT"] = (config_count + 1).to_s
      env["GIT_CONFIG_KEY_#{config_count}"] = "core.attributesFile"
      env["GIT_CONFIG_VALUE_#{config_count}"] = File::NULL
      yield env, git_directory
    end
  rescue SystemCallError, ArgumentError, TypeError => e
    raise IsolationError, e.message
  end

  def preserve_safe_directory_config(env, source_env)
    entries = command_scope_safe_directory_entries(source_env)
    return if entries.empty?

    env["GIT_CONFIG_COUNT"] = entries.size.to_s
    entries.each_with_index do |value, index|
      env["GIT_CONFIG_KEY_#{index}"] = "safe.directory"
      env["GIT_CONFIG_VALUE_#{index}"] = value
    end
  end

  def command_scope_safe_directory_entries(source_env)
    safe_directory_entries_from_count(source_env) + safe_directory_entries_from_parameters(source_env)
  end

  def safe_directory_entries_from_count(source_env)
    count = Integer(source_env.fetch("GIT_CONFIG_COUNT", nil), exception: false)
    return [] unless count&.positive?

    (0...count).filter_map do |index|
      key = source_env["GIT_CONFIG_KEY_#{index}"]
      next unless key&.casecmp?("safe.directory")

      source_env.fetch("GIT_CONFIG_VALUE_#{index}", "")
    end
  end

  def safe_directory_entries_from_parameters(source_env)
    parameters = source_env["GIT_CONFIG_PARAMETERS"].to_s
    return [] if parameters.empty?

    Shellwords.split(parameters).filter_map do |parameter|
      key, value = parameter.split("=", 2)
      next unless key&.casecmp?("safe.directory")

      value || ""
    end
  rescue ArgumentError
    []
  end
end
