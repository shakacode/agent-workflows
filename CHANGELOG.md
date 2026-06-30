# Changelog

All notable changes to this portable workflow pack are documented here.

<!-- Version headers intentionally use `###` and categories use `####` to match skills/update-changelog/SKILL.md. -->

### [Unreleased]

#### Added

- **Add `agent-workflows-trust-audit` to check recent merged PRs against `pr-security-preflight` and draft candidate repo-local trust entries for maintainer review.**
- **Add `trusted_metadata_bots` so workflow/status bot comments can be audited as metadata without becoming actionable trusted instructions.**
- **Add `pr-security-preflight --strict-trust` so exact-target batches can report actor-trust findings by default while still supporting fail-closed launches.**
- **Document the trust/preflight operating model, including global vs repo-local trust, audit flow, acknowledgement policy, and security tradeoffs.**
- **Document bounded inline Claude Code review as a fallback when hosted Claude review checks are stale or fail for capacity/quota reasons, and tighten the human-merge Review Completion Gate so stale older-head checks require a current-head review, maintainer waiver, or qualifying fallback before merge.**

#### Fixed

- **Add explicit exact-target `pr-security-preflight` risk acknowledgement so maintainer waivers can unblock a batch without broadening shared trust defaults.**
- **Fix `upgrade-agent-workflows` with no `--consumer-root` arguments under shells that treat empty arrays as unset.**
- **Fix `pr-security-preflight` trust config inheritance so repo-local, user-global, environment, and fail-closed packaged allowlists resolve predictably.** [PR 20](https://github.com/shakacode/agent-workflows/pull/20) by [justin808](https://github.com/justin808).

### [0.1.0] - 2026-06-24

#### Added

- **Add the Validate GitHub Actions workflow to run `bin/validate` on pull requests and pushes to `main`.** [PR 4](https://github.com/shakacode/agent-workflows/pull/4) by [justin808](https://github.com/justin808).

#### Changed

- **Port generic `pr-security-preflight` review-thread resolution and untrusted-interaction decomposition from a consumer repo while keeping repo-specific hosted-CI metadata recognition out of the portable pack.** [PR 5](https://github.com/shakacode/agent-workflows/pull/5) by [justin808](https://github.com/justin808).

#### Fixed

- **Fix `agent-workflow-seam-doctor` under `LANG=C` / `LC_ALL=C` by reading `AGENTS.md` as UTF-8 and scrubbing invalid bytes before seam validation.** [PR 1](https://github.com/shakacode/agent-workflows/pull/1) by [justin808](https://github.com/justin808).
- **Harden `agent-workflows-status` and `pr-security-preflight` under non-UTF-8 locales by forcing UTF-8 at metadata, version, git-output, and GitHub JSON boundaries.** [PR 3](https://github.com/shakacode/agent-workflows/pull/3) by [justin808](https://github.com/justin808).

[unreleased]: https://github.com/shakacode/agent-workflows/compare/v0.1.0...main
[0.1.0]: https://github.com/shakacode/agent-workflows/releases/tag/v0.1.0
