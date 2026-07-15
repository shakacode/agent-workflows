# Changelog

All notable changes to this portable workflow pack are documented here.

<!-- Version headers intentionally use `###` and categories use `####` to match skills/update-changelog/SKILL.md. -->

### [Unreleased]

#### Added

- **Add an agent-workflow consumer seam with portable configuration and command wrappers.** [PR 140](https://github.com/shakacode/agent-workflows/pull/140) by [justin808](https://github.com/justin808).
- **Add a portable dispatcher-capability preflight that records bound, attested route/dispatcher selection or one durable decision request without launching workers or mutating coordination.**
- **Add portable autoreview risk/coverage receipts and independent validation evidence for consequential review findings.**
- **Add durable `flat` and `plugin-companion` delivery modes so native `scw` users can retain installer-managed workflows, docs, helpers, metadata, status, and upgrades without a duplicate flat skill tree.**
- **Add Codex catalog plus Claude Code native-plugin and marketplace metadata for installing the complete semantic skill tree under `scw`, with isolated plugin-root and no-shadow validation.**
- **Add `agent-workflow-seam-doctor --init` for conservative, fail-closed consumer seam scaffolding and immediate contract validation.**
- **Add an MIT license for the workflow pack and install the license notice with copied or symlinked agent homes.**
- **Add portable plan-review, type-design-review, manual-testing, benchmark-verification, and pr-monitoring skills adapted from `lucasfcosta/backpressured` workflow ideas.**
- **Add durable workflow solution docs, review finding schema, readiness vocabulary, autoreview target-state fixtures, and the optional `task-observer` skill.**
- **Add the `$pause` skill to print restart-safe pause, resume, and new-chat handoff prompts for ordinary and `$pr-batch` work.** [PR 68](https://github.com/shakacode/agent-workflows/pull/68) by [justin808](https://github.com/justin808).
- **Add `agent-workflows-trust-audit` to check recent merged PRs against `pr-security-preflight` and draft candidate repo-local trust entries for maintainer review.**
- **Add `trusted_metadata_bots` so workflow/status bot comments can be audited as metadata without becoming actionable trusted instructions.**
- **Add `pr-security-preflight --strict-trust` so exact-target batches can report actor-trust findings by default while still supporting fail-closed launches.**
- **Add replayable closeout evidence helpers for QA Evidence, priority finding dispositions, selected-check post-merge timing, and explicitly requested hosted-CI readiness gates.**
- **Document the trust/preflight operating model, including global vs repo-local trust, audit flow, acknowledgement policy, and security tradeoffs.**
- **Document bounded inline Claude Code review as a fallback when hosted Claude review checks are stale or fail for capacity/quota reasons, and tighten the human-merge Review Completion Gate so stale older-head checks require a current-head review, maintainer waiver, or qualifying fallback before merge.**
- **Add a portable model-routing playbook covering coordinator/worker separation, staged escalation, replacement handoffs, verification depth, human gates, and routing metrics.**

#### Changed

- **Adopt the recommended Codex GPT-5.6 routing profile: Sol/xhigh multi-lane coordination, adversarial QA, and high-risk escalation; Terra/high only for positively classified simple workers; and Sol/high for uncertainty and routine deterministic QA.**
- **Default autonomously clearable blocked Goal-mode batches to one deduplicated 15-minute current-thread monitor when supported, with manual-resume fallback and no polling for user-input blockers.**
- **Clarify the portable planning-chat lifecycle: batch coordinators own completed-batch audits, prompt-only chats may archive after durable worker handoff, and parents reconcile only durable audit handoffs before release or archive.**
- **Clarify same-chat launch selection, complete triage response ordering, and completed-batch audit handoffs so only outstanding work blocks archival while fully evidenced terminal dispositions remain durable.**
- **Harden model-routed batches with fail-closed launch assurance, Sol-controlled conservative GPT-5.6 coordination and checking, bounded Terra execution envelopes, and auditable worker assignment evidence.**
- **Change the public Codex native-plugin identifier from `agent-workflows` to `scw`; existing native-plugin users must remove the old entry and reinstall `scw`, while the repository, marketplace, helper, installer, status, and upgrade identities remain `agent-workflows`.**
- **Make `$pr-batch` the sole workflow for one or more targets, with a default single-target worker subagent, staged cost-aware model routing, and explicit merge authority before launch.**
- **Require parent batch coordinators to run a completed-batch audit after every target reaches final state, then end the conversation with either an archive-ready confirmation or every remaining follow-up and blocker.**
- **Route `$plan-pr-batch` readiness, manual-testing, and merge-sequencing requests through the target repository's readiness and review-gate policy, using inline `AGENTS.md` Agent Workflow Configuration values when `.agents/agent-workflow.yml` is absent.** [PR 47](https://github.com/shakacode/agent-workflows/pull/47) by [justin808](https://github.com/justin808).
- **Harden `address-review` with mutual-exclusion claims, advisory public fallback rules, and non-fast-forward push re-fetch and re-triage stops, while moving detailed actions and templates into progressive-disclosure references.** [PR 70](https://github.com/shakacode/agent-workflows/pull/70) by [justin808](https://github.com/justin808).
- **Keep the `$pr-batch` coordinator on its independently selected model/effort pair while routine workers start on modest cost-aware routes, correct once on the initial tier, and request evidence-gated stronger-model plan review or replacement only when escalation criteria are met. Stop superseded workers with durable handoffs, claim fencing, and no old/new overlap; provide a dedicated recovery prompt for in-flight batches.**
- **Port consumer-repo preflight hardening: fail closed when `AGENT_WORKFLOWS_TRUST_CONFIG` points to a missing file, treat explicit `--trust-config` paths outside the consuming repo's git root as user-global (warning on ignored unqualified team slugs), scan trusted metadata-bot comments for suspicious-text warnings, keep blocking-pattern warnings visible on resolved trusted-bot review threads, and require full source-actor timeline coverage before treating a PR source as trusted for diff-warning downgrades.**
- **Port consumer-repo `agent-coord-bounded` hardening: preserve captured stdout/stderr on interrupt and timeout exits, and wait for the whole process group to exit during termination.**
- **Default post-merge audits to the obvious just-run batch before asking for batch confirmation.**
- **Clarify completed-batch post-merge audit scope, release/range audits, and coverage catch-up for explicit un-audited PR or commit ranges.**
- **Start pasteable batch prompts with a short title that includes a repository-derived project abbreviation, optional A/B/C split marker, and `MM-DD HH:MM` from the local shell `date` command.**
- **Default post-merge audits to creating follow-up issues from the deduped issue plan unless the user requests report-only/no issue creation.**

#### Fixed

- **Reject stale priority replay evidence so only final-head closeout evidence qualifies.** [PR 118](https://github.com/shakacode/agent-workflows/pull/118) by [justin808](https://github.com/justin808).
- **Hardened seam-init argument forwarding across nested shells, env split strings, exec prefixes, and npm options, preserving caller arguments or failing closed for unsafe command shapes.** [PR 119](https://github.com/shakacode/agent-workflows/pull/119) by [justin808](https://github.com/justin808).
- **Fail closed on native-plus-flat Agent Workflows collisions and preserve modified, ambiguous, mismatched, or unowned skill paths during migration and rollback.**
- **Require replayable final-head QA evidence before readiness or merge so commits made after QA invalidate stale closeout evidence.**
- **Fix post-merge audit default-batch handling so unavailable coordination verification asks before deep audit, and tighten batch-title guard coverage.**
- **Harden `pr-security-preflight` trust resolution and warning scans for explicit global configs, missing environment configs, metadata-only bots, bounded git probes, host-qualified repo-local trust checks, and truncated timeline coverage.**
- **Fix downstream PR-batch bootstrap guidance and sync support so consumer repos can seed repo-local base-branch and trust config without widening the packaged fallback.**
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
