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
  # caller's git top level, or nil when it could not be determined.
  #
  # `repo_local_verifier` proves a config was written for the repository being
  # scanned; only then may it use unqualified `trusted_teams` slugs, which are
  # otherwise rebound to whatever owner the caller passed. Without a verifier a
  # config is treated as global, so an unqualified slug is ignored rather than
  # silently granted. pr-security-preflight supplies its git-remote check here.
  def resolve_path(explicit_path, repo_root: nil, repo_local_verifier: nil)
    if explicit_path
      expanded = File.expand_path(explicit_path)
      raise Error, "Trust config not found: #{expanded}" unless File.exist?(expanded)

      return { path: expanded, source: "explicit", global: !repo_local?(expanded, repo_local_verifier) }
    end

    repo_path = File.join(repo_root || Dir.pwd, DEFAULT_TRUST_CONFIG)
    if File.exist?(repo_path)
      return { path: repo_path, source: "repo-local", global: !repo_local?(repo_path, repo_local_verifier) }
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
      unless team_cache.key?(cache_key)
        team_cache[cache_key] = team_resolver.call(owner: team_owner, slug: team.fetch(:slug), login:)
      end
      team_cache[cache_key]
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
