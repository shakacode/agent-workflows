# Commit Message And Receipt Placement Workflow

This is the canonical policy for two related problems: commit and squash
messages that grow disproportionate to the change they describe, and audit
receipts (decision logs, QA evidence, review dispositions) that get copied
into permanent Git history instead of living in the PR where they belong.
There is no companion skill for this workflow; it is referenced directly by
`skills/verify/SKILL.md`'s Commit Message Contract step and by any other
authoring or closeout step that drafts a commit message or PR body.

Rich receipts are valuable. The problem is not the amount of evidence
produced during review — it is where that evidence ends up. A commit message
is read by `git log` and `git blame`, often months later and without a PR
open; a PR description is read once, near the time of the change, alongside
the full review transcript. Evidence that only makes sense with that
transcript belongs in the PR, not in history that outlives it.

## Ownership Map

Use this to decide where a given piece of content belongs. When in doubt,
prefer the PR description over the commit body — it is easier to add detail
to a PR after the fact than to rewrite a merged commit.

| Content | Owner / location |
| --- | --- |
| Why this commit exists, what it changes, issue linkage | Commit subject + body (see the Concise Commit/Squash Contract below) |
| Non-blocking implementation decisions and rationale | PR description, `## Codex Decision Log` (see `workflows/pr-processing.md`) |
| QA evidence, coverage/testing proof, release-blocking status | PR description `### QA Evidence` block plus the hidden `qa-evidence v2` marker (see `workflows/pr-processing.md`) |
| Coverage-of-change receipts (`COVERAGE ...`) from `verify` | PR description, alongside or inside the QA Evidence block (see `skills/verify/SKILL.md`) |
| Reviewer transcripts, back-and-forth, priority-finding dispositions | PR comments, or the hidden `priority-finding-dispositions v1` marker (see `workflows/pr-processing.md`) |
| Batch/lane coordination state, claims, heartbeats | The coordination backend or batch handoff comment, never the commit body (see `workflows/pr-processing.md`'s Batch Handoff Format) |
| User-facing release notes | The repo's changelog file (`changelog` key in `.agents/agent-workflow.yml`), per `skills/update-changelog/SKILL.md` — not the commit body |
| Required provenance (issue-closing keywords, co-author trailers) | Commit trailers — see Preserve Required Provenance below |

A decision belongs in the commit body only when a maintainer reading the
committed code in isolation, without the PR open, would otherwise misread
*why* it is written that way — for example, an intentionally unusual
algorithm choice made to avoid a specific known failure mode. That is the
exception, not the default; most rationale, evidence, and process detail
stays in the PR.

## Concise Commit/Squash Contract

Apply this shape to both individual commits and the final squash/merge
message, unless the repo's own merge-commit policy (if any) overrides it:

```text
<subject: imperative, plain text, no trailing period>

Summary: <1-3 sentences — what changed, in plain terms>
Why: <1-3 sentences — the motivating problem, bug, or issue>
Fixes #NNN | Closes #NNN   (when the change resolves a tracked issue)
```

- **Subject** is the only mandatory line. It must stand alone in a `git log
  --oneline` scan.
- **Summary** is required whenever the subject alone would leave a future
  reader guessing what actually changed (multi-file diffs, behavior changes,
  anything non-mechanical).
- **Why** is required whenever the motivation is not obvious from the subject
  and Summary together — most bug fixes and feature work need it; a pure
  rename or formatting pass usually does not.
- **Issue linkage** uses the repo's normal issue-closing keywords when the
  change resolves a tracked issue. Do not invent a different linkage format.
- Do not add empty section headers. A `Why:` line with no content is worse
  than no `Why:` line — omit the label entirely when there is nothing to add
  beyond the subject and Summary.

This is a shape, not a template to fill mechanically. A one-line Summary
that fully explains a small fix is complete; do not pad it to look more
thorough.

## Concise Mode For Small Diffs

Use concise mode when the diff is small, single-behavior, and low-risk:
mechanical fixes, narrow bug fixes with one clear cause, dependency bumps,
formatting-only changes, and other changes with nothing to say beyond what
the subject and a one-line Summary already cover. There is deliberately no
line-count or file-count threshold here — see Non-Goals below for why.
Judge proportionality from the same signals already used elsewhere in this
pack to size a change, for example the diff's file/line footprint relative
to the repo's own low-risk-change signal (such as
`autonomous_merge.thresholds` in `.agents/agent-workflow.yml`, where a repo
defines one) combined with whether the change touches security, data
migration, public API, or release-critical surfaces.

In concise mode:

- Omit `Why:` when the subject plus Summary already make the motivation
  obvious.
- Omit the whole commit body beyond the subject when even a one-line
  Summary would only restate the subject.
- Never reproduce the PR's Decision Log, QA Evidence block, or reviewer
  transcript in the commit body — those already live in the PR (see the
  Ownership Map above). A concise commit may reference them by pointer
  (`see PR description`) but must not duplicate their content.

Use the full contract — Summary, Why, and issue linkage all present — for
anything that does not qualify as small: multi-behavior changes, security or
compatibility implications, anything with a PR-body Decision Log entry that
a future commit-log reader would need, and anything the repo's own
higher-risk-change signals flag (release-affecting paths, workflow/CI
changes, or other surfaces the repo marks as needing more scrutiny).

## Detecting And Collapsing Duplicated Sections

Before committing, and again before PR closeout, compare the drafted commit
message body against the current PR description:

1. Read both texts.
2. For each section that appears in both (a Decision Log entry, a QA
   summary, a rationale paragraph), keep the copy in its owned location per
   the Ownership Map above and remove or reduce the other copy to a pointer.
3. When the commit body is the one being trimmed, replace the duplicated
   section with either nothing (if it is not essential to reading the code)
   or a one-line pointer such as `See PR description Decision Log for
   rationale.`
4. Never trim a copy that is inside a hidden replay marker (`qa-evidence
   v2`, `priority-finding-dispositions v1`, or similar) — those are
   structured receipts for machine replay, not prose to summarize, and they
   never belong in a commit message in the first place.

This is a `checklist+replay` mechanism in the sense used by
`workflows/pr-processing.md`'s Process Gap Disposition: a human/agent
judgment check performed at authoring and closeout time, not a standalone
line-count linter. `skills/verify/SKILL.md`'s Commit Message Contract step is
the wired enforcement point — it requires this comparison and its
`COMMIT-CONTRACT <concise|full>: <reason>` receipt before a commit is
finalized.

## Preserve Required Provenance

Concise mode and duplicate-collapsing must never remove:

- Issue-closing keywords and issue numbers (`Fixes #NNN`, `Closes #NNN`) when
  the change resolves a tracked issue.
- Co-author and other provenance trailers the repo or its tooling requires.
- Release-note content: when the repo's `changelog` policy
  (`.agents/agent-workflow.yml`) requires a changelog entry for
  user-visible changes, that entry lives in the changelog file itself (see
  `skills/update-changelog/SKILL.md`), not folded into or replaced by a
  short commit message. A concise commit message and a full changelog entry
  are not in tension — they answer different questions for different
  readers.

## Non-Goals

- **No brittle universal line-count limit.** Proportionality is judged from
  the change's actual size, risk, and evidence needs, not a fixed number of
  lines. A security-sensitive or multi-behavior change earns a longer
  message; a one-line rename does not need to be padded to hit a minimum.
- **Do not remove auditability or provenance.** This workflow moves evidence
  to its correct owned location; it never deletes evidence outright. When in
  doubt about whether something is essential provenance, keep it.
- **Do not rewrite existing Git history.** This workflow governs new commits
  and PR descriptions going forward. It is not a mandate to squash, amend, or
  rewrite already-merged commit messages.
- **Do not force large or security-sensitive changes into a minimal
  two-line message.** Concise mode is opt-in based on the diff's actual
  proportionality, never a target every commit must hit.

## Deferred: Fixtures

A fixture demonstrating a small diff with rich QA evidence, and showing that
evidence remains replayable without being copied into the commit body, is
intentionally out of scope for this workflow file (fixtures live under
`test/fixtures/**`, owned by a different lane than this workflow file). See
[issue #324](https://github.com/shakacode/agent-workflows/issues/324) for the
follow-up.
