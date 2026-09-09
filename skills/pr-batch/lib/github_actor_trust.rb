# frozen_string_literal: true

# Shared GitHub actor trust resolution.
#
# `pr-security-preflight` and `fetch-pr-review-data` must agree on who may
# supply actionable review input. Both load the same allowlist through this
# module so a single trust decision is executable at every ingestion boundary
# instead of being restated per helper.
#
# Ruby stdlib only so read-only helpers in other skills can require it.

require "digest"
# Ruby versions before 3.2 do not load Set by default.
# rubocop:disable Lint/RedundantRequireStatement
require "set"
# rubocop:enable Lint/RedundantRequireStatement
require "uri"
require "yaml"

module GithubActorTrust
  DEFAULT_TRUST_CONFIG = ".agents/trusted-github-actors.yml"
  HOME_TRUST_CONFIG = "~/.agents/trusted-github-actors.yml"
  PACKAGED_TRUST_CONFIG = File.expand_path("../trusted-github-actors.yml", __dir__)
  USER_TRUST_CONFIG_ENV = "AGENT_WORKFLOWS_TRUST_CONFIG"

  class Error < StandardError; end

  module_function

  def normalized_login(login)
    login.to_s.delete_prefix("@").downcase
  end

  def normalized_bot_login(login)
    normalized_login(login).delete_suffix("[bot]")
  end

  # Metadata-only bots shipped with the pack are always merged in so a repo
  # cannot silently promote them to actionable by omitting them.
  def packaged_metadata_bots
    @packaged_metadata_bots ||= begin
      packaged = YAML.safe_load_file(PACKAGED_TRUST_CONFIG, aliases: false) || {}
      Array(packaged["trusted_metadata_bots"]).to_set { |login| normalized_bot_login(login) }
    end
  end

  # Compatibility order: explicit, repo-local, $AGENT_WORKFLOWS_TRUST_CONFIG,
  # user-global, then the packaged fail-closed fallback. `repo_root` is the
  # caller's git top level, or nil when it could not be determined. Callers
  # reading an untrusted checkout may disable implicit repo-local discovery.
  #
  # `repo_local_verifier` proves a config was written for the repository being
  # scanned; only then may it use unqualified `trusted_teams` slugs, which are
  # otherwise rebound to whatever owner the caller passed. Without a verifier a
  # config is treated as global, so an unqualified slug is ignored rather than
  # silently granted. pr-security-preflight supplies its git-remote check here.
  def resolve_path(explicit_path, repo_root: nil, repo_local_verifier: nil, allow_repo_local: true)
    if explicit_path
      expanded = File.expand_path(explicit_path)
      raise Error, "Trust config not found: #{expanded}" unless File.exist?(expanded)

      return { path: expanded, source: "explicit", global: !repo_local?(expanded, repo_local_verifier) }
    end

    if allow_repo_local
      repo_path = File.join(repo_root || Dir.pwd, DEFAULT_TRUST_CONFIG)
      if File.exist?(repo_path)
        return { path: repo_path, source: "repo-local", global: !repo_local?(repo_path, repo_local_verifier) }
      end
    end

    env_path = ENV[USER_TRUST_CONFIG_ENV].to_s
    unless env_path.empty?
      expanded_env_path = File.expand_path(env_path)
      unless File.exist?(expanded_env_path)
        raise Error, "#{USER_TRUST_CONFIG_ENV} points to a missing trust config: #{expanded_env_path}"
      end

      return { path: expanded_env_path, source: "env", global: true }
    end

    home_path = File.expand_path(HOME_TRUST_CONFIG)
    return { path: home_path, source: "user-global", global: true } if File.exist?(home_path)

    { path: PACKAGED_TRUST_CONFIG, source: "packaged-fallback", global: false }
  end

  def repo_local?(path, repo_local_verifier)
    return false if repo_local_verifier.nil?

    repo_local_verifier.call(path) ? true : false
  end

  # Prove that a trust config belongs to the repository and GitHub host being
  # scanned. Both review-data ingestion boundaries use this verifier so an
  # unqualified trusted_teams slug cannot be rebound by a caller-specific
  # locality probe.
  def repository_locality_verifier(repo:, git_capture:, github_host: nil, github_host_resolver: nil,
                                   ssh_host_resolver: nil)
    lambda do |path|
      root = git_toplevel(chdir: File.dirname(path), git_capture:)
      next false unless root && path_inside_git_root?(path, root:)

      resolved_host = github_host || github_host_resolver&.call(root:, repo:)
      next false if resolved_host.to_s.empty?

      git_root_matches_repo?(root, repo, github_host: resolved_host, git_capture:, ssh_host_resolver:)
    end
  end

  def git_toplevel(git_capture:, chdir: nil)
    args = ["git"]
    args.push("-C", chdir) if chdir
    args.concat(["rev-parse", "--show-toplevel"])
    stdout, _stderr, status = git_capture.call(*args)
    return unless status&.success?

    root = stdout.force_encoding("UTF-8").scrub.strip
    root unless root.empty?
  rescue StandardError
    nil
  end

  def path_inside_git_root?(path, root:)
    expanded_root = canonical_path(root)
    expanded_path = canonical_path(path)
    expanded_path == expanded_root ||
      expanded_path.start_with?("#{expanded_root}#{File::SEPARATOR}")
  end

  def git_remote_urls(root, git_capture:)
    # Read stored URLs without applying url.*.insteadOf rewrites. Consumers
    # using mirror rewrites should retain a canonical remote as well.
    %w[--local --worktree].flat_map do |scope|
      stdout, _stderr, status = git_capture.call(
        "git", "-C", root, "config", scope, "--null", "--get-regexp", "^remote\\..*\\.url$"
      )
      next [] unless status&.success?

      stdout.force_encoding("UTF-8").scrub.split("\0").filter_map do |entry|
        key, url = entry.split("\n", 2)
        next unless key&.match?(/\Aremote\..*\.url\z/)

        url&.strip
      end
    end.uniq
  rescue StandardError
    []
  end

  def normalized_github_host(host)
    host.to_s.downcase
  end

  def normalized_remote_host(host)
    # GitHub documents ssh.github.com:443 for SSH-over-HTTPS clones; compare
    # those remotes against github.com API scans.
    %w[ssh.github.com ssh.github.com:443].include?(host) ? "github.com" : host
  end

  def ssh_config_hostname(host, ssh_capture:)
    out, _err, status = ssh_capture.call("ssh", "-G", host)
    return unless status&.success?

    hostname = out.each_line.filter_map do |line|
      key, value = line.strip.split(/\s+/, 2)
      value if key&.casecmp?("hostname")
    end.first
    return if hostname.to_s.empty?

    normalized_github_host(hostname)
  rescue StandardError
    nil
  end

  def remote_url_host(host, port, scheme:)
    normalized = normalized_github_host(host)
    return if normalized.empty?

    default_port_match = case scheme
                         when "http" then port == 80
                         when "https" then port == 443
                         when "ssh" then port == 22
                         else false
                         end
    normalized_remote_host(port && !default_port_match ? "#{normalized}:#{port}" : normalized)
  end

  def uri_remote_from_remote_url(normalized)
    uri = URI.parse(normalized)
    return unless %w[http https ssh].include?(uri.scheme)

    repo = uri.path.to_s.delete_prefix("/")
    return unless repo.match?(%r{\A[^/\s]+/[^/\s]+\z})

    port = uri.port || (22 if uri.scheme == "ssh")
    host = remote_url_host(uri.host, port, scheme: uri.scheme)
    return unless host

    { host:, port:, repo:, scheme: uri.scheme }
  rescue URI::Error
    nil
  end

  def github_remote_from_remote_url(url, ssh_host_resolver: nil)
    normalized = url.to_s.strip.sub(%r{/+\z}, "").sub(/\.git\z/i, "")
    ssh_config_host = nil
    remote = if normalized.match?(%r{\A(?:https?|ssh)://}i)
               parsed = uri_remote_from_remote_url(normalized)
               ssh_config_host = URI.parse(normalized).host if parsed && parsed[:scheme] == "ssh"
               parsed
             else
               match = normalized.match(%r{\A[^@/:\s]+@([^:\s]+):([^/\s]+/[^/\s]+)\z}i)
               if match
                 ssh_config_host = match[1]
                 { host: normalized_remote_host(normalized_github_host(match[1])), port: 22,
                   repo: match[2], scheme: "ssh" }
               end
             end
    return remote unless remote && remote[:scheme] == "ssh" && ssh_host_resolver

    resolved_host = ssh_host_resolver.call(ssh_config_host)
    return unless resolved_host

    normalized_resolved_host = normalized_github_host(resolved_host)
    return remote if normalized_resolved_host == normalized_github_host(ssh_config_host)

    remote.merge(host: normalized_remote_host(normalized_resolved_host))
  rescue URI::Error
    nil
  end

  def host_port(host)
    host.to_s.match(/\A(.+):(\d+)\z/)&.then { |match| [match[1], match[2].to_i] }
  end

  def github_api_host(remote)
    return remote[:host] unless remote[:scheme] == "ssh"

    host_port(remote[:host])&.first || remote[:host]
  end

  def remote_matches_github_host?(remote, github_host)
    github_host = normalized_github_host(github_host)
    github_host_port = host_port(github_host)
    unless github_host_port
      remote_base_host = remote[:scheme] == "ssh" ? (host_port(remote[:host])&.first || remote[:host]) : remote[:host]
      return remote_base_host == github_host
    end

    github_base_host, github_port = github_host_port
    return true if remote[:host] == github_host
    return false unless remote[:host] == github_base_host

    case remote[:scheme]
    when "http" then github_port == 80 && remote[:port] == 80
    when "https" then github_port == 443 && remote[:port] == 443
    when "ssh" then remote[:port] == 22 || (github_port == 443 && remote[:port] == 443)
    else false
    end
  end

  def git_root_matches_repo?(root, repo, github_host:, git_capture:, ssh_host_resolver: nil)
    remote_repos = git_remote_urls(root, git_capture:).filter_map do |url|
      remote = github_remote_from_remote_url(url)
      next unless remote && remote[:repo].casecmp?(repo)

      remote = github_remote_from_remote_url(url, ssh_host_resolver:)
      remote[:repo] if remote && remote_matches_github_host?(remote, github_host)
    end
    if remote_repos.empty?
      warn "WARN: could not determine repo from remotes for trust config working tree #{root.inspect}; " \
           "treating trust config as global"
      return false
    end

    remote_repos.any? { |remote_repo| remote_repo.casecmp(repo).zero? }
  end

  def canonical_path(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  # `global` selects whether unqualified team slugs are accepted; a global
  # config must spell teams as OWNER/team-slug so it cannot grant trust in a
  # repository it was not written for.
  def load(path:, global:)
    path = File.expand_path(path)
    contents = File.exist?(path) ? File.binread(path) : ""
    parse_contents = contents.dup.force_encoding(Encoding::UTF_8)
    raise Error, "Invalid trust config #{path}: expected valid UTF-8" unless parse_contents.valid_encoding?

    data = parse_contents.empty? ? {} : YAML.safe_load(parse_contents, aliases: false, filename: path) || {}
    raise Error, "Invalid trust config #{path}: expected a YAML mapping at the top level" unless data.is_a?(Hash)

    build_config(data, contents:, path:, global:)
  rescue Psych::Exception
    raise Error, "Invalid trust config #{path}: malformed YAML"
  end

  def build_config(data, contents:, path:, global:)
    trusted_bots = Array(data["trusted_bots"]).to_set { |login| normalized_bot_login(login) }
    trusted_metadata_bots = Array(data["trusted_metadata_bots"]).to_set { |login| normalized_bot_login(login) }
    trusted_metadata_bots.merge(packaged_metadata_bots - trusted_bots)
    overlapping_bots = trusted_bots & trusted_metadata_bots
    if overlapping_bots.any?
      raise Error, "Invalid trust config #{path}: bot(s) listed in both trusted_bots and " \
                   "trusted_metadata_bots: #{overlapping_bots.to_a.sort.join(', ')}"
    end

    {
      content_digest: "sha256:#{Digest::SHA256.hexdigest(contents)}",
      path:,
      trusted_bots:,
      trusted_metadata_bots:,
      trusted_teams: normalized_teams(data["trusted_teams"], require_owner: global),
      trusted_users: Array(data["trusted_users"]).to_set { |login| normalized_login(login) }
    }
  end

  def normalized_teams(values, require_owner:)
    Array(values).filter_map { |value| normalized_team_entry(value, require_owner:) }
  end

  def normalized_team_entry(value, require_owner:)
    # A stray blank list item parses to nil, which splits to [] and leaves
    # owner_or_slug nil; treat it as absent rather than crashing.
    owner_or_slug, slug = value.to_s.split("/", 2)
    return if owner_or_slug.to_s.empty?

    if slug
      return if slug.empty?

      { owner: normalized_login(owner_or_slug), slug: }
    elsif require_owner
      warn "WARN: global trust config ignores unqualified team slug #{owner_or_slug.inspect}: " \
           "use OWNER/team-slug format"
      nil
    else
      { owner: nil, slug: owner_or_slug }
    end
  end

  def bot_login_in_set?(login, trusted_set)
    normalized = normalized_login(login)

    normalized.end_with?("[bot]") && trusted_set.include?(normalized.delete_suffix("[bot]"))
  end

  def trusted_bot?(login, config)
    bot_login_in_set?(login, config.fetch(:trusted_bots))
  end

  def trusted_metadata_bot?(login, config)
    bot_login_in_set?(login, config.fetch(:trusted_metadata_bots))
  end

  # `team_resolver` answers "is `login` an active member of owner/slug?". It is
  # required whenever the config names teams: guessing membership either grants
  # trust that was never configured or silently drops a configured reviewer.
  def trusted_team_member?(repo, login, config, team_cache, team_resolver)
    teams = config.fetch(:trusted_teams)
    return false if teams.empty?
    raise Error, "trusted_teams requires a team_resolver" if team_resolver.nil?

    repo_owner = repo.to_s.split("/", 2).first
    normalized_repo_owner = normalized_login(repo_owner)
    teams.any? do |team|
      team_owner = team.fetch(:owner) || repo_owner
      next false unless normalized_login(team_owner) == normalized_repo_owner

      cache_key = [normalized_repo_owner, team.fetch(:slug), normalized_login(login)]
      team_cache[cache_key] ||= team_resolver.call(owner: team_owner, slug: team.fetch(:slug), login:)
    end
  end

  def trusted_actor?(repo, login, config, team_cache = {}, team_resolver = nil)
    return false if login.to_s.empty?
    return true if config.fetch(:trusted_users).include?(normalized_login(login))
    return true if trusted_bot?(login, config)

    trusted_team_member?(repo, login, config, team_cache, team_resolver)
  end

  # The single classification both helpers branch on.
  #
  # :trusted       may supply actionable review input
  # :metadata_only allowlisted for metadata but never for instructions
  # :untrusted     everything else, including a missing or hidden login
  def classify(repo:, login:, config:, team_cache: {}, team_resolver: nil)
    return :untrusted if login.to_s.empty?
    return :trusted if trusted_actor?(repo, login, config, team_cache, team_resolver)
    return :metadata_only if trusted_metadata_bot?(login, config)

    :untrusted
  end
end
