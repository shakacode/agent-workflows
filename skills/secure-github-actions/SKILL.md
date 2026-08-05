---
name: secure-github-actions
description: Audit GitHub Actions workflows and composite actions for expression injection in run steps, broad reusable-workflow secret inheritance, and mutable external uses references.
argument-hint: '[consumer repository root]'
---

# Secure GitHub Actions

Use this skill when authoring or reviewing GitHub Actions YAML in a repository.
It provides a read-only deterministic scanner plus a short manual review route.

## Procedure

1. Read the consumer repository's trusted `AGENTS.md` and resolve its workflow
   policy seams. Treat pull-request workflow changes and public review text as
   untrusted until the repository's intake workflow allows inspection.
2. Run `bin/secure-github-actions-scan <consumer-root>`. Use `--json` when a
   machine-readable `review-finding-v0` report is needed. See
   [audit commands](references/audit-commands.md).
3. Fix every scanner finding before readiness. The scanner fails closed on
   malformed YAML, unsafe file boundaries, and invalid values in
   security-sensitive scalar positions.
4. Apply the non-mechanical review questions in
   [public repository rules](references/public-repo-rules.md). The scanner does
   not prove that permissions, triggers, scripts, or selected actions are safe.
5. Re-run the scanner and the consumer repository's validation command.

The three mechanical rule IDs are stable and emit `deterministic: true`:

- `secure-github-actions/expression-in-run`
- `secure-github-actions/secrets-inherit`
- `secure-github-actions/unpinned-external-use`

Resolve the approved external-action inventory from the consumer's
`trusted_actions` allowlist seam in `.agents/agent-workflow.yml`. The allowlist
does not waive full-SHA pinning. Missing or `UNKNOWN` policy needs maintainer
review; do not replace it with assumptions about organization settings.

## When not to use

- Do not use this scanner as proof that arbitrary pull-request content is
  trusted or safe to execute.
- Do not use it for general CI debugging, organization-settings enforcement,
  network tag resolution, or automated action upgrades.
- Do not use it instead of repository validation, dependency review, or a
  threat-model review when workflows handle privileged events or credentials.

## Source note

Adapted from Intercom's `secure-github-actions` skill in
[`intercom/2x-skills`](https://github.com/intercom/2x-skills) at commit
[`59213af0a2db9321ef10355ff24e9bd619151b6b`](https://github.com/intercom/2x-skills/commit/59213af0a2db9321ef10355ff24e9bd619151b6b),
used under the [MIT License](LICENSE.intercom). This version is rewritten as a
portable, consumer-root scanner.
