---
name: structural-review
description: Use when a diff is correct but may still be making the codebase worse — file growth, scattered conditionals, thin abstractions, layer violations, or feature-flag branching debt.
argument-hint: '[diff, PR, branch, or merged range]'
---

# Structural Review

Every other review axis in this pack asks "is this **wrong**?" This one asks
"is this making the codebase **worse**?"

A change can be correct, secure, well-typed, and green while pushing a file past
any sane size, scattering a flag across six call sites, or adding a fifth
special case to a busy method. That is the only thing this review looks for.

The organising idea is **structural judo**: hunt for restructurings that
preserve behavior while making whole branches, helpers, modes, or layers
disappear. "This could be a bit cleaner" is not a finding. "These three
conditionals stop existing if the caller passes a resolved value" is.

## Non-Coverage

This axis is deliberately single-purpose. It does **not** cover:

| Not covered here | Owned by |
| --- | --- |
| Correctness bugs, regressions, security gaps | `autoreview` |
| Skeptical pre/post-merge risk and merge-gate discipline | `adversarial-pr-review` |
| Type surfaces and representable invalid states | `type-design-review` |
| Performance measurement and regression proof | `benchmark-verification` |
| Test presence, quality, and coverage | the repo's test policy and `verify` |
| Formatting, naming, import order, style | linters and formatters |
| Whether the change works at all | `verify`, `run-ci`, `replicate-ci` |

Do not spend a finding on anything in the right-hand column. If the diff is
structurally fine, say so and stop; do not pad the report with observations
another axis already owns.

### Resolving The Two Real Overlaps

Two standards touch a neighboring skill. Resolve them this way rather than
firing both skills on the same diff:

- **Standard 5 (type and boundary cleanliness) vs `type-design-review`.**
  `type-design-review` owns the question "what invalid state does this type
  permit?" — it is the deeper axis and it wins whenever the diff adds or
  changes data models, signatures, domain types, parsing boundaries, casts, or
  state machines. Structural review keeps only the *structural consequence* of
  loose boundaries: a signature so untyped that call sites must each re-derive
  or re-check the same facts, producing duplicated defensive code. State that
  duplication as the finding. If the sharper statement is "this type permits an
  invalid state", hand it to `type-design-review` and do not restate it here.
- **Standard 8 (sequential orchestration and non-atomic updates) vs
  `benchmark-verification`.** `benchmark-verification` owns any claim about
  measured speed; it requires baseline-vs-patched evidence and this skill has
  none. Structural review may only flag orchestration *shape*: independent work
  written as a forced sequence, or a multi-step state update with no atomic
  boundary and a visible partial-failure window. Never assert a change is slow.
  If the concern is really "is this slower?", route it to
  `benchmark-verification` and record that routing instead of a finding.

## Precedence

Repo-local convention overrides the generic baseline below, always. Read the
repo's `AGENTS.md` and the policy it names in `.agents/agent-workflow.yml`
first. If the repo documents a different file-size norm, a layering rule, or an
accepted pattern that a standard here would flag, the repo wins and the
standard is silent. Say which convention you applied.

## Step 1 — Pin The Fixed Point Before Reading Any Code

Structural review compares a *state* against a *baseline*, so an unpinned or
empty diff produces a confidently wrong review. Resolve the base branch from
the `base_branch` key in `.agents/agent-workflow.yml` (or from PR metadata when
a PR is open), then pin the exact merge-base three-dot diff:

```bash
base=$(ruby -ryaml -e 'p=(YAML.safe_load(File.read(".agents/agent-workflow.yml"), aliases: false) || {}); puts(p.fetch("base_branch", "main"))')
git rev-parse --verify "origin/$base"
git merge-base "origin/$base" HEAD
git diff --stat "origin/$base...HEAD"
git diff --name-only "origin/$base...HEAD"
```

Resolve `base` before the first command; an unset `base` silently becomes
`origin/`, which is exactly the unpinned review this step exists to prevent.
Keep it exported for the later steps, or re-resolve it the same way.

Stop and report if the ref does not resolve or the diff is empty. Do not
substitute a two-dot diff, a working-tree diff, or "recent commits" — fail here
rather than producing a review of the wrong change set. Record the base SHA and
head SHA; every finding is anchored to them.

For a merged range (the `post-merge-audit` entry point), pin `BASE..HEAD`
explicitly the same way and record both SHAs.

## Step 2 — Read Whole Files, Not Hunks

Structure is invisible in a hunk. For every file with more than about 10
changed lines, read the whole file, not the diff fragment. File size, the
number of conditional sites, layer placement, and near-duplicate helpers are
all properties of the file, and a hunk hides every one of them.

Get the post-change totals, because Standard 1 is evaluated on the resulting
file, not on the lines added:

```bash
# Reuse the `base` resolved in Step 1, or re-resolve it in a fresh shell.
git diff --numstat "origin/$base...HEAD"
wc -l path/to/changed_file
```

Skip what tooling already enforces. If the repo runs a linter, formatter, or
type checker, those failures are CI's job and never a finding here.

## Step 3 — Apply The Standards

Full catalog with symptoms and worked restructurings:
`references/code-smells.md`. Load it when a candidate finding needs the
detailed test; the summary below is the working checklist.

0. **Be ambitious about structural simplification.** Prefer the restructuring
   that deletes complexity over the one that rearranges it. Ask what would have
   to be true for this branch, mode, helper, or layer to not exist.
1. **File size.** Do not push a file past roughly 1000 lines without strong
   justification, evaluated on the post-change total. The finding is the growth
   plus a named split, not the number alone.
2. **No random spaghetti growth.** A new ad-hoc conditional dropped into an
   unrelated flow is a design problem, not a nit. Flag the *placement*, not the
   condition.
3. **Clean the design, do not just accept working code.** "It passes" is not
   the bar when the change leaves a structure the next author must work around.
4. **Prefer direct and boring over magical.** Flag thin abstractions,
   pass-through wrappers, indirection with one caller, and configuration that
   exists to avoid writing the direct call.
5. **Type and boundary cleanliness** — structural consequence only; see the
   overlap rule above.
6. **Keep logic in the canonical layer.** Business rules leaking into
   controllers, views, serializers, migrations, or scripts is a finding even
   when the code is correct there.
7. **Feature flags must not become permanent branching debt.** Flag a new flag
   with three or more conditional sites, no named cleanup path, or nested flag
   conditions.
8. **Orchestration shape** — sequencing and atomicity only; see the overlap
   rule above.

A finding must name: the standard, the location, the structural cost that
already exists in the post-change code, and a concrete restructuring. A finding
without a restructuring is an opinion; drop it.

## Step 4 — Severity

Structural findings are almost never merge blockers. Default them to `P2` /
`should_fix`, or `P3` / `deferred` when the work is real but clearly a
follow-up. Reserve `P1` for a file-size or layer violation the author cannot
justify — that is, one where the growth or misplacement was avoidable, was
pointed out, and has no stated reason. `P0` is not a structural severity; if a
structural observation is genuinely release-blocking, it is a correctness or
security finding and belongs to another axis.

Human-facing labels map to the shared severities in
`docs/review-finding-schema.md` as:

- `BLOCKER` → `P1` / `must_fix` (rare here; requires the unjustified-violation
  test above)
- `MAJOR` → `P2` / `should_fix`
- `SUGGESTION` → `P3` / `deferred`

## Step 5 — Verdict And Output

Close with exactly one verdict:

- `APPROVE` — no structural finding, or only `P3` follow-ups.
- `REFINE` — the design is right; specific `P2` cleanups are named.
- `RETHINK` — the change's structure is the problem, and the named
  restructuring is large enough that the author should reconsider the approach
  before more work lands on it.

Report:

- base SHA, head SHA, and how the fixed point was pinned
- files read in full vs. read as diff, and why
- repo-local conventions applied that overrode a generic standard
- findings, each with standard, location, structural cost, restructuring, and
  severity
- overlaps routed to `type-design-review` or `benchmark-verification`
- the verdict

### Machine-Readable Findings

When structured output is requested, emit findings using
`docs/review-finding-schema.md` with `source: structural-review` on each
finding.

Do **not** emit a `review_receipt` from this skill. The receipt `source` field
is a closed allowlist in `bin/validate-review-findings`, and
`structural-review` is not in it; emitting one would fail repo validation.
Findings-only output is the supported mode here. Report scope, coverage, and
limitations in the prose report instead.

## Entry Points

- **Batch default: `post-merge-audit`.** Structural drift accumulated across a
  concurrent-agent batch is exactly what no other axis reviews. Run this over
  the audited range and file findings into the audit's issue plan.
- **On demand pre-merge**, when a PR grows a file substantially, adds a flag,
  or moves logic between layers.

This is not a closeout gate and must not be wired in as one. `autoreview`'s
scope discipline — small fixes at the right boundary, no refactors — stays
exactly as it is; this skill exists precisely so that discipline does not have
to be loosened.

## Source Note

Adapted from the `thermo-nuclear-code-review` skill in
[intercom/2x-skills](https://github.com/intercom/2x-skills) (MIT), reworked
here as a portable seam-driven axis with this pack's severity vocabulary and
review-boundary rules.
