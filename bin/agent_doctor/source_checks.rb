# frozen_string_literal: true

require_relative "contract"

module AgentDoctor
  class SourceChecks
    def initialize(runner:, environment: ENV)
      @runner = runner
      @environment = environment
    end

    def checkout(name, path)
      unless File.directory?(path)
        return Contract.check("#{name}.source", "failed", "source checkout missing", details: { "path" => path },
                                                                                     guidance: "Run `agent-stack sync` to create the checkout.")
      end

      origins, origin_error = git_config_values(path, "remote.origin.url")
      if origin_error
        return Contract.check("#{name}.source", "failed", "source checkout is not a readable Git worktree",
                              details: { "path" => path }, guidance: "Repair or replace the checkout, then rerun doctor.")
      end
      unless origins.one?
        return Contract.check("#{name}.source", "failed", "source checkout has ambiguous origin configuration",
                              details: { "path" => path, "origin_count" => origins.length },
                              guidance: "Configure exactly one local remote.origin.url, then rerun doctor.")
      end
      origin = origins.first
      unless origin_allowed?(name, origin)
        return Contract.check("#{name}.source", "failed", "origin does not match the configured repository",
                              details: { "path" => path, "origin" => origin },
                              guidance: "Correct the origin or the matching AGENT_STACK_*_URL override.")
      end
      filters, filter_error = git_config_names(path, '^filter\..*\.(clean|smudge|process)$')
      if filter_error
        return Contract.check("#{name}.source", "failed", "source checkout is not a readable Git worktree",
                              details: { "path" => path }, guidance: "Repair or replace the checkout, then rerun doctor.")
      end
      unless filters.empty?
        return Contract.check("#{name}.source", "failed", "source checkout has executable filter configuration",
                              details: { "path" => path, "filter_count" => filters.length },
                              guidance: "Remove local filter clean, smudge, and process commands, then rerun doctor.")
      end

      revision, revision_error = git_value(path, "rev-parse", "--short", "HEAD")
      branch, branch_error = git_value(path, "branch", "--show-current")
      dirty, dirty_error = dirty_worktree?(path)
      if revision_error || branch_error || dirty_error
        return Contract.check("#{name}.source", "failed", "source checkout is not a readable Git worktree",
                              details: { "path" => path }, guidance: "Repair or replace the checkout, then rerun doctor.")
      end

      status = branch == "main" && !dirty ? "healthy" : "degraded"
      summary = status == "healthy" ? "source checkout ready" : "source checkout differs from sync-ready main"
      guidance = "Commit or stash local changes and return the checkout to `main` before syncing." if status == "degraded"
      Contract.check("#{name}.source", status, summary,
                     details: { "path" => path, "branch" => branch.empty? ? "detached" : branch,
                                "revision" => revision, "dirty" => dirty }, guidance: guidance)
    end

    def compatibility(name, compat_root, source_path)
      path = File.join(compat_root, name)
      unless File.symlink?(path)
        summary = File.exist?(path) ? "compatibility path is not a symlink" : "compatibility link missing"
        return Contract.check("#{name}.compatibility", "degraded", summary, details: { "path" => path },
                                                                            guidance: "Run `agent-stack sync` to restore compatibility links.")
      end
      target = File.expand_path(File.readlink(path), File.dirname(path))
      unless File.exist?(path)
        return Contract.check("#{name}.compatibility", "degraded", "compatibility link is dangling",
                              details: { "path" => path, "target" => target },
                              guidance: "Run `agent-stack sync --replace-compat` to replace the dangling link.")
      end
      return Contract.check("#{name}.compatibility", "healthy", "compatibility link ready", details: { "path" => path }) if File.realpath(path) == File.realpath(source_path)

      Contract.check("#{name}.compatibility", "degraded", "compatibility link targets another checkout",
                     details: { "path" => path, "target" => File.realpath(path) },
                     guidance: "Run `agent-stack sync --replace-compat` after reviewing the existing path.")
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
      Contract.check("#{name}.compatibility", "degraded", "compatibility link cannot be resolved",
                     details: { "path" => path }, guidance: "Repair or replace the compatibility link, then rerun doctor.")
    end

    private

    def git_config_names(path, pattern)
      result = @runner.capture(
        ["git", "--no-optional-locks", "-C", path, "config", "--local", "--includes", "--null", "--name-only",
         "--get-regexp", pattern], timeout: 3
      )
      return [nil, result[:failure]] if result[:failure]
      return [[], nil] if result[:exit].to_i == 1
      return [nil, "git exited #{result[:exit]}"] unless result[:exit].to_i.zero?

      values = result[:stdout].split("\0", -1)
      values.pop if values.last == ""
      [values, nil]
    end

    def dirty_worktree?(path)
      dirty = false
      [
        ["diff-index", "--no-ext-diff", "--cached", "--quiet", "HEAD", "--"],
        ["diff-files", "--no-ext-diff", "--quiet", "--"]
      ].each do |arguments|
        result = safe_git(path, *arguments)
        return [nil, result[:failure]] if result[:failure]

        case result[:exit].to_i
        when 0 then next
        when 1 then dirty = true
        else return [nil, "git exited #{result[:exit]}"]
        end
      end

      untracked = safe_git(path, "ls-files", "--others", "--exclude-standard", "--")
      return [nil, untracked[:failure]] if untracked[:failure]
      return [nil, "git exited #{untracked[:exit]}"] unless untracked[:exit].to_i.zero?

      [dirty || !untracked[:stdout].empty?, nil]
    end

    def safe_git(path, *arguments)
      @runner.capture(
        ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
         "-C", path, *arguments], timeout: 3,
                                  environment: { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL,
                                                 "GIT_CONFIG_NOSYSTEM" => "1" }
      )
    end

    def git_config_values(path, key)
      result = @runner.capture(
        ["git", "--no-optional-locks", "-C", path, "config", "--local", "--null", "--get-all", key], timeout: 3
      )
      return [nil, result[:failure]] if result[:failure]
      return [[], nil] if result[:exit].to_i == 1
      return [nil, "git exited #{result[:exit]}"] unless result[:exit].to_i.zero?

      values = result[:stdout].split("\0", -1)
      values.pop if values.last == ""
      [values, nil]
    end

    def git_value(path, *arguments)
      result = @runner.capture(["git", "--no-optional-locks", "-C", path, *arguments], timeout: 3)
      return [nil, result[:failure]] if result[:failure]
      return [nil, "git exited #{result[:exit]}"] unless result[:exit].to_i.zero?

      [result[:stdout].strip, nil]
    end

    def origin_allowed?(name, origin)
      key = "AGENT_STACK_#{name.tr('-', '_').upcase}_URL"
      configured = @environment[key].to_s
      return origin == configured unless configured.empty?

      [
        "https://github.com/shakacode/#{name}",
        "https://github.com/shakacode/#{name}.git",
        "git@github.com:shakacode/#{name}.git"
      ].include?(origin)
    end
  end
end
