# frozen_string_literal: true

require "time"
require_relative "configuration"
require_relative "contract"
require_relative "source_checks"
module AgentDoctor
  class Orchestrator
    COMPONENTS = %w[agent-workflows agent-coordination agent-coordination-dashboard].freeze

    def initialize(options, runner:, sanitizer:, environment: ENV, now: -> { Time.now.utc })
      @options = options
      @runner = runner
      @sanitizer = sanitizer
      @environment = environment
      @now = now
    end

    def call
      paths = expanded_paths
      sources = COMPONENTS.to_h { |name| [name, File.join(paths[:source_root], name)] }
      checker = SourceChecks.new(runner: @runner, environment: @environment)
      source_results = sources.to_h { |name, source| [name, checker.checkout(name, source)] }
      components = contracts(paths, sources, source_results).map do |contract|
        component = contract.fetch("component")
        append_source_checks(contract, checker, paths[:compat_root], sources.fetch(component),
                             source_results.fetch(component))
      end
      {
        "schema_version" => 1,
        "status" => components.map { |item| item.fetch("status") }.max_by { |status| Contract::SEVERITY.fetch(status) },
        "deep" => @options[:deep],
        "checked_at" => @now.call.iso8601,
        "components" => components.map { |item| @sanitizer.component(item) }
      }
    end

    private

    def expanded_paths
      host, target = Configuration.host_and_target(@options[:host], @options[:target], environment: @environment)
      {
        source_root: File.expand_path(@options[:source_root]),
        compat_root: File.expand_path(@options[:compat_root]),
        runtime_root: File.expand_path(@options[:runtime_root]),
        install_dir: File.expand_path(@options[:install_dir]),
        host: host, target: target, dashboard_uri: Configuration.dashboard_uri(@options[:dashboard_url])
      }
    end

    def contracts(paths, sources, source_results)
      [workflow_contract(paths, sources, source_results.fetch("agent-workflows")),
       coordination_contract(paths, sources, source_results.fetch("agent-coordination")),
       dashboard_contract(paths, sources, source_results.fetch("agent-coordination-dashboard"))]
    end

    def workflow_contract(paths, sources, source_check)
      command = [File.join(paths[:target], "bin", "agent-workflows-doctor"), "--stack-json", "--host", paths[:host],
                 "--target", paths[:target], "--source", sources.fetch("agent-workflows")]
      command << "--deep" if @options[:deep]
      delegates = [command.first, File.join(paths[:target], "bin", "agent-workflows-status")]
      delegates << File.join(paths[:target], "bin", "agent-workflow-seam-doctor") if @options[:deep]
      if delegates.any? { |executable| source_delegate_blocked?(source_check, executable, sources.fetch("agent-workflows")) }
        return source_trust_failure("agent-workflows")
      end
      return Contract.unavailable("agent-workflows", "component doctor executable is missing") unless File.executable?(command.first)

      Contract.delegate("agent-workflows", command, runner: @runner)
    end

    def coordination_contract(paths, sources, source_check)
      command = [File.join(paths[:install_dir], "agent-coord"), "doctor", "--stack-json"]
      command << "--deep" if @options[:deep]
      selector = Configuration.coordination_selector(paths[:runtime_root], environment: @environment)
      if source_delegate_blocked?(source_check, command.first, sources.fetch("agent-coordination"))
        return source_trust_failure("agent-coordination")
      end
      return Contract.unavailable("agent-coordination", "component doctor executable is missing") unless File.executable?(command.first)
      return Contract.unavailable("agent-coordination", "no explicit or existing coordination backend found") unless selector

      Contract.delegate("agent-coordination", command + selector, runner: @runner)
    end

    def dashboard_contract(paths, sources, source_check)
      source = sources.fetch("agent-coordination-dashboard")
      script = File.join(source, "bin", "agent-coordination-dashboard.js")
      if source_check.fetch("status") == "failed" || source_delegate_blocked?(source_check, script, source)
        return source_trust_failure("agent-coordination-dashboard", status: "degraded")
      end

      node = @environment.fetch("NODE_BIN", "node")
      command = [node, script, "doctor", "--stack-json"]
      command << "--deep" if @options[:deep]
      command += ["--url", paths[:dashboard_uri].to_s]
      unless File.file?(script)
        return Contract.unavailable("agent-coordination-dashboard", "component doctor executable is missing", status: "degraded")
      end
      unless Configuration.command_available?(node, environment: @environment)
        return Contract.unavailable("agent-coordination-dashboard", "Node.js is unavailable for the dashboard doctor", status: "degraded")
      end

      Contract.delegate("agent-coordination-dashboard", command, runner: @runner, unavailable_status: "degraded")
    end

    def append_source_checks(contract, checker, compat_root, source, source_check)
      component = contract.fetch("component")
      generic = [component_source_check(component, source_check), checker.compatibility(component, compat_root, source)]
      Contract.component(component, generic + contract.fetch("checks"))
    end

    def component_source_check(component, source_check)
      return source_check unless component == "agent-coordination-dashboard" && source_check.fetch("status") == "failed"

      source_check.merge("status" => "degraded")
    end

    def source_delegate_blocked?(source_check, executable, source)
      source_check.fetch("status") != "healthy" && source_resident?(executable, source)
    end

    def source_resident?(executable, source)
      resolved_source = File.realpath(source)
      candidate = File.expand_path(executable)
      visited = {}
      return true if source_contains_inode?(candidate, resolved_source)

      loop do
        return true if within_source?(candidate, resolved_source)

        resolved_parent = File.realpath(File.dirname(candidate))
        return true if within_source?(resolved_parent, resolved_source)
        return within_source?(File.realpath(candidate), resolved_source) unless File.symlink?(candidate)
        return false if visited[candidate]

        visited[candidate] = true
        candidate = File.expand_path(File.readlink(candidate), resolved_parent)
      end
    rescue SystemCallError
      false
    end

    def source_contains_inode?(candidate, source, entry_limit: 50_000)
      candidate_stat = begin
        File.stat(candidate)
      rescue Errno::ENOENT, Errno::ENOTDIR
        return false
      end
      source_stat = File.stat(source)
      return false if candidate_stat.nlink <= 1 || candidate_stat.dev != source_stat.dev

      directories = [source]
      entries_scanned = 0
      until directories.empty?
        directory = directories.pop
        Dir.each_child(directory) do |entry|
          return true if (entries_scanned += 1) > entry_limit

          path = File.join(directory, entry)
          entry_stat = File.lstat(path)
          return true if entry_stat.dev == candidate_stat.dev && entry_stat.ino == candidate_stat.ino

          directories << path if entry_stat.directory? && entry_stat.dev == candidate_stat.dev
        end
      end
      false
    rescue SystemCallError
      true
    end

    def within_source?(path, source)
      path == source || path.start_with?("#{source}/")
    end

    def source_trust_failure(component, status: "failed")
      Contract.unavailable(component, "source checkout is not trusted for delegate execution; component doctor was not executed",
                           status: status, guidance: "Repair or replace the source checkout, then rerun doctor.")
    end
  end
end
