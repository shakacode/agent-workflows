# Changelog

All notable changes to this portable workflow pack are documented here.

### [Unreleased]

- Add repository formatter guardrails with RuboCop and EditorConfig.

### [2026-06-24] - 2026-06-24

#### Added

- Added the Validate GitHub Actions workflow to run `bin/validate` on pull
  requests and pushes to `main` (#4).

#### Changed

- Ported the generic `pr-security-preflight` review-thread resolution and
  untrusted-interaction decomposition from a consumer repo while keeping
  repo-specific hosted-CI metadata recognition out of the portable pack (#5).

#### Fixed

- Fixed `agent-workflow-seam-doctor` under `LANG=C` / `LC_ALL=C` by reading
  `AGENTS.md` as UTF-8 and scrubbing invalid bytes before seam validation (#1).
- Hardened `agent-workflows-status` and `pr-security-preflight` under
  non-UTF-8 locales by forcing UTF-8 at metadata, version, git-output, and
  GitHub JSON boundaries, with regression tests wired into `bin/validate` (#3).
