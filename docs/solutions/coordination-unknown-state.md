---
title: Preserve UNKNOWN coordination state
date: "2026-07-02"
category: coordination
component: pr-processing
problem_type: degraded-private-state
symptoms:
  - Bounded coordination doctor or status reads time out.
  - A worker has a successful direct claim but no reliable private status view.
  - A handoff is tempted to describe the lane as clean because no conflict was observed.
root_cause: Coordination reads are observational and can degrade independently from the compare-and-swap claim operation.
resolution: Report degraded reads as UNKNOWN, or claim-only when an exact independent lane has a successful direct private claim, and avoid upgrading missing coordination evidence into clean state.
related_files:
  - workflows/pr-processing.md
  - skills/pr-batch/SKILL.md
related_issues:
  - https://github.com/shakacode/agent-workflows/issues/37
---

Private coordination state has two distinct surfaces: reads and claims. Reads
such as bounded `doctor` or `status` calls are preflight evidence. A timeout,
setup error, or auth failure means that read is degraded and must stay
`UNKNOWN` in the handoff.

The claim operation is different because it is the race gate. For an exact
independent lane with no dependency refs, a successful direct private claim can
support `private_state: claim-only` even when earlier reads were degraded. That
does not prove the broader backend status is clean. It only proves the lane has
the recorded claim result it reports.

When in doubt, keep the missing read explicit. Future coordinators can reconcile
an `UNKNOWN` or claim-only state, but they cannot recover evidence that a worker
silently rounded up to clean.
