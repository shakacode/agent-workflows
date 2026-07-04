# ADR 0001: Identical Skill Text Across Hosts

Date: 2026-07-02
Status: accepted

## Context

`agent-workflows` installs the same shared skills, workflows, and helper scripts
into different agent hosts. Codex Desktop and Claude Code Desktop differ in
instruction files, invocation syntax, UI metadata, permission models, helper
availability, and persistent memory locations.

Those differences create pressure to rewrite skill text at install time, for
example by replacing Codex `$skill` references with Claude Code `/skill`
references. That would make each host's installed pack easier to read in one
place, but it would split the source of truth.

## Decision

Installed skill and workflow Markdown remains byte-identical across supported
hosts. The installer must not rewrite shared Markdown per host.

Host differences live in:

- the Host Adapter Contract under `docs/host-adapter/`;
- optional metadata ignored by hosts that do not understand it, such as
  `skills/*/agents/openai.yaml` or plugin manifests;
- host runtime configuration, including sandbox, approval, permission, and
  connector availability;
- consumer repository seams such as `AGENTS.md`, `.agents/bin/`, and
  `.agents/agent-workflow.yml`.

Shared skill text should use host-neutral verbs and marked host branches when a
literal host invocation is unavoidable.

## Consequences

Benefits:

- `agent-workflows-status` can compare installed revisions without accounting
  for host-specific generated text.
- `bin/push-downstream` and downstream diffs stay debuggable because the same
  source text is installed everywhere.
- Reviewers can reason about one shared skill body instead of checking Codex and
  Claude variants for semantic drift.
- Follow-on host work can reference a single adapter contract instead of
  repeating platform explanations in each skill.

Trade-offs:

- Some shared docs must say "Codex: `$name`; Claude Code: `/name`" instead of
  showing only the local host's syntax.
- Agents must availability-check host-specific tools such as `codex review`,
  Claude Code slash commands, `/simplify`, native plugin metadata, and
  task-observer memory paths before using them.
- Host-specific UI polish belongs in metadata or adapter docs, not in rewritten
  skill Markdown.

## Rejected Option: Install-Time Text Rewriting

Install-time substitution such as `$pr-batch` to `/pr-batch` is rejected.

It would make `agent-workflows-status` revision comparison ambiguous, obscure
which text was reviewed in the source pack, complicate downstream sync and diff
review, and create host-specific drift that would be hard to debug. The
temptation to add one more substitution would recur with every new host-only
feature, so the boundary is explicit: agents adapt at runtime; the installer
does not rewrite shared Markdown.
