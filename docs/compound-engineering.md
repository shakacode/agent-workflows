# Using Compound Engineering With Agent Workflows

Use this guide when you want a Compound Engineering (CE) capability without
giving up Agent Workflows ownership of the delivery lane. The architectural
boundary is recorded in
[ADR 0002](adr/0002-compose-compound-engineering-inside-agent-workflows.md):
Agent Workflows orchestrates delivery; CE is an optional inner method.

The examples were checked against CE 3.19.0 on 2026-07-10. CE evolves quickly,
so confirm the installed skill names and modes in the current host before use.

## Responsibilities

| Concern | Agent Workflows | Compound Engineering |
| --- | --- | --- |
| Ownership | Target, claim, worktree, dependencies, and handoff | Work delegated by the owning lane |
| Repository policy | `AGENTS.md` and the `.agents/` seam | Reads project conventions as input |
| Planning | `spec`, `plan-review`, and `$plan-pr-batch` | Optional ideation, research, or draft plan |
| Verification | Repo-owned tests, manual proof, and CI parity | Skill-local checks are supporting evidence |
| Review | Finding verification, disposition, and clean closeout | Optional specialized lenses and synthesis |
| Shipping | Commit policy, push, PR, CI, review follow-up, readiness | Not used inside the lane |
| Knowledge | Portable workflow lessons and curated runbooks | Consumer-specific technical and domain learning |

The practical rule is simple: CE may produce research, edits, findings, or a
knowledge artifact. Agent Workflows decides whether that output is in scope,
proves it against the repository contract, and owns what happens next.

## Which CE Capability To Use

### External Decision: `ce-pov`

Use `ce-pov` when a fixed external input needs a project-specific verdict, for
example whether to adopt a library, respond to a CVE, or change a workflow
pattern. Run it before `spec` or implementation.

A useful result must cite both a verified project fact and current external
evidence. Keep the project tree read-only and make durable capture opt-in. Use
Agent Workflows `evaluate-issue` instead when the question is whether a GitHub
issue or proposed fix is worth doing.

See CE's
[PoV evidence contract](https://github.com/EveryInc/compound-engineering-plugin/blob/3519336ecdf204e418a325d961a834abd8507d89/skills/ce-pov/SKILL.md#L17-L54).

### Planning And Implementation: `ce-plan` And `ce-work`

CE may research or draft a plan, but run Agent Workflows `plan-review` before
implementation. If CE implements inside an existing lane, use
[`ce-work mode:return-to-caller <plan-path>`](https://github.com/EveryInc/compound-engineering-plugin/blob/3519336ecdf204e418a325d961a834abd8507d89/skills/ce-work/SKILL.md#L351-L391).
Inspect its edits or local commits, then continue with the repository's normal
proof and closeout gates.

Do not run CE `lfg` or `ce-commit-push-pr` inside the lane. Those workflows
take over the shipping tail.

### Additional Review: `ce-code-review mode:agent`

Keep Agent Workflows `autoreview` as the default primary review. Consider CE
only after that review is clean and the diff is broad, high-risk, or genuinely
benefits from independent specialist lenses.

Use `ce-code-review mode:agent` so CE reports findings without editing or
committing. Verify every finding against the real code and normalize accepted
items into the existing
[Review Finding Schema](review-finding-schema.md). Do not use reviewer
agreement as proof.

Agent Workflows may adopt proven review disciplines such as risk-lens
selection, coverage receipts, provenance, and independent validation for
consequential findings. That work belongs in `autoreview`; it does not make CE
a required reviewer.

### Simplification: Choose One Engine

The canonical Agent Workflows gate currently names Claude Code `/simplify`.
CE `ce-simplify-code` is an experimental alternative, not an additional
required pass. Both mutate the working tree, so never run both sequentially on
the same live lane.

For a controlled comparison, start each engine from the same commit in separate
worktrees. For a live lane, choose exactly one engine, inspect every edit, run
repo-owned verification, and rerun `autoreview` until clean.

Skip simplification for tiny, documentation-only, or generated-only diffs. Do
not make the canonical gate engine-selectable until a controlled comparison
shows that CE adds enough value to justify the extra integration surface.

### Durable Learning: `ce-compound`

Use `ce-compound` only after a non-trivial learning is solved, verified, and
worth finding again. Start interactively, keep session-history import off, and
inspect every proposed file.

Run the first pilot in a consumer repository with a named destination and
schema. Do not run it unattended in this source pack: Agent Workflows uses flat
`docs/solutions/*.md` files with its own frontmatter, while CE uses categorized
paths and a different schema. Nested CE output can bypass the source pack's
current flat-only validator.

## CE's Specialist Agents

The public agent list in the original
[Compound Engineering article](https://every.to/chain-of-thought/compound-engineering-how-every-codes-with-agents)
is not the current product surface. At the pinned CE revision, CE exposes
[29 public skills and no standalone agents](https://github.com/EveryInc/compound-engineering-plugin/blob/3519336ecdf204e418a325d961a834abd8507d89/README.md#L107-L124).

Specialist behavior lives behind owning skills such as `ce-code-review`,
`ce-plan`, `ce-pov`, and `ce-compound`. Those skills select internal prompts,
dispatch generic subagents, and synthesize their results. Use the public owning
skill rather than invoking internal prompt assets directly.

This specialization is useful when independent evidence or judgment can run in
parallel. It adds little value to tiny diffs, mechanical work, or cheap and
reversible decisions.

## Delivery Sequence

1. Optionally run `ce-pov` before requirements or planning.
2. Create the requirements and implementation-ready plan. If CE drafts the
   plan, run Agent Workflows `plan-review` before execution.
3. Start Agent Workflows `$pr-batch` for the exact target. Single-target mode
   is the canonical one-lane path.
4. Implement normally, or delegate a bounded step through
   `ce-work mode:return-to-caller <plan-path>`.
5. Run the focused repository proof and get `autoreview` clean.
6. For a qualifying diff, run either report-only CE review or one selected
   simplifier. Do not transfer lane ownership.
7. Inspect accepted changes, rerun repository verification, and get the final
   review clean.
8. Let Agent Workflows commit or approve local commits, push, open or update the
   PR, monitor CI and feedback, and report readiness.
9. Optionally run `ce-compound` after the result is stable and the consumer
   knowledge convention is explicit.

## Disposable Pilot Setup

Keep CE experiments out of the normal agent profile. Start with Agent Workflows
and CE checkouts at recorded revisions:

```bash
export AGENT_WORKFLOWS_SOURCE="/absolute/path/to/agent-workflows"
export CE_SOURCE="/absolute/path/to/compound-engineering-plugin"
```

For Claude Code, install Agent Workflows into a dedicated configuration
directory and load the checked-out CE plugin directly:

```bash
export CLAUDE_CONFIG_DIR="$HOME/.claude/profiles/ce-pilot"
"$AGENT_WORKFLOWS_SOURCE/bin/install-agent-workflows" \
  --host claude --target "$CLAUDE_CONFIG_DIR"
claude --plugin-dir "$CE_SOURCE"
```

[`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars) replaces Claude
Code's default `~/.claude` configuration directory for that session.

For Codex, install both packs into one dedicated profile, then launch Codex
with that same `CODEX_HOME`:

```bash
export CODEX_HOME="$HOME/.codex/profiles/ce-pilot"
"$AGENT_WORKFLOWS_SOURCE/bin/install-agent-workflows" --host codex
codex plugin marketplace add "$CE_SOURCE"
codex plugin add compound-engineering@compound-engineering-plugin
codex
```

Restart the host if required, run CE `ce-setup` in the pilot repository, and
confirm the public skills appear before allowing project-tree writes. Use the
exact invocation shown by the host; flat and plugin-qualified names differ.

## Pilot Evidence

For each experiment, record:

- repository, base/head SHA, worktree, host, and exact CE version;
- selected skill and mode;
- project-tree mutations and whether they stayed in scope;
- elapsed time, agent usage, and unavailable or degraded roles;
- unique verified signal, false positives, and duplicated findings;
- repository verification and final review outcome;
- a promote, revise, reject, or gather-more-evidence verdict.

Track each experiment in the repository where its decision or learning belongs.
Open a `ce-compound` experiment only after naming the consumer repository and
one stable learning to test.
