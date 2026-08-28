<!-- markdownlint-disable MD033 -->
<!--
This template follows the Human-First PR Description Contract in
workflows/pr-processing.md: human-visible sections and checklists stay outside
the single `Agent details` disclosure, and every agent artifact goes inside it.
HTML comments in this template are invisible in the rendered PR body; delete
them or leave them, but replace the sections they describe.
-->

## Why

<!--
The problem, user outcome, or maintenance need this addresses. Self-contained:
a reviewer must not have to open an issue to learn why this PR exists. Link
issues as supporting context, and use `Fixes #NNN` / `Closes #NNN` when this
closes one.
-->

## What changed

<!-- One bullet per conceptual change: the human-readable change and its boundary. -->

## How to review and verify

<!--
1. A reviewer-oriented behavior or diff path to inspect.
2. A concise outcome-level verification statement; link durable evidence when useful.
-->

## Test plan

<!--
Every `- [ ]` below is a merge gate. An unchecked box means "not done yet" and
blocks merge; it is never decoration. Resolve each line one of three ways, and
every path ends with the line either checked or no longer a checkbox:

1. Do the work, then check the box and record the command and its real result.
2. Delete the line when it does not apply to this PR. If the record is worth
   keeping, replace it with a plain bullet - no checkbox syntax - saying why it
   does not apply. Striking a checkbox through does not clear it; the line still
   reads as unchecked.
3. Move the work to a follow-up issue, then delete the checkbox or convert it to
   a plain bullet carrying the issue link. Deferring the work does not leave a
   checkbox behind.

Never check a box you did not actually run, and never paste a result you did not
actually see. Add, remove, and rewrite these lines freely - this is a starting
point, not a fixed form.
-->

- [ ] `bin/validate` - result:
- [ ] `.agents/bin/lint` - result:
- [ ] Behavior-level check for this change (command, test, or manual step) - result:
- [ ] `CHANGELOG.md` entry added under `### [Unreleased]`.

<!--
Add a `## Maintainer attention` section here, immediately before the disclosure
below, only for a genuine blocker, question, or high-value risk that needs
maintainer action. Do not add a `None.` placeholder to an otherwise clean PR.
-->

<details>
<summary>Agent details</summary>

### Commands and results

<!-- Exact commands, results, CI URLs, and failures or timeouts. -->

### Decision log

<!--
One entry per non-blocking judgment call, in this shape:

- **Non-blocking:** question or fork in approach
  - **Decision:** what was chosen
  - **Why:** evidence or nearby pattern
  - **Review later:** what a maintainer may want to revisit, or "None"

Re-read this log before merge and confirm each decision still holds after review
changes.
-->

<!--
Add the remaining canonical subsections from the Human-First PR Description
Contract here when they apply, using their exact headings: `### Exact-head and
replay evidence`, the complete `### QA Evidence` block with its markers,
`### Coordination and reviewer telemetry`, `### Merge confidence`, and
`### Audit receipts`. Keep them inside this one disclosure - the contract allows
exactly one collapsed agent-artifact block per PR body.
-->

</details>
