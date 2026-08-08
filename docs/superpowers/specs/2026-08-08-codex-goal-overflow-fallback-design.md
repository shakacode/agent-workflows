# Codex Goal Overflow Fallback Design

## Context

Codex `/goal` input is limited to fewer than 4,000 characters. Claude has no
equivalent goal wrapper. Agent Workflows currently renders every Codex batch
handoff as `Prompt mode: goal` with `/goal`, then splits an otherwise coherent
batch when the goal form would exceed the Codex limit or leave less than 300
characters of headroom.

The prompt-host adapter already accepts `Prompt host: codex` with `Prompt mode:
batch` and no `/goal`. Therefore `/goal` is a Codex delivery envelope, not part
of the batch's objective, scope, dependencies, permissions, safety, QA, review,
or merge-authority semantics.

## Decision

Use a Codex goal only when persistent Goal mode was explicitly requested and
the complete rendered goal is under 4,000 characters with at least 300
characters of headroom. Otherwise render the same complete handoff as a Codex
batch prompt:

```text
Prompt host: codex
Prompt mode: batch
Preferred route: <model-or-class>/<effort>
Route requirement: advisory
Use $pr-batch ...
```

The fallback removes only `/goal` and changes only `Prompt mode: goal` to
`Prompt mode: batch`. It must preserve every other byte after host-mechanic
normalization. The ordinary prompt remains compact and reviewable under the
existing 8,000-character non-goal ceiling. Split only when that ordinary prompt
is itself too large or when ownership, dependencies, collision domains, or
route groups independently require separate batches. Never split solely to
retain `/goal`, and never trim safety or completion semantics to retain it.

## Cross-Host Mode Mapping

Mode mapping preserves the source mode whenever the destination supports it:

| Source | Destination | Result |
| --- | --- | --- |
| Codex `direct` | Claude | Claude `direct` |
| Claude `direct` | Codex | Codex `direct`, no `/goal` |
| Claude `batch` | Codex | Codex `batch`, no `/goal` |
| Codex `batch` | Claude | Claude `batch` |
| Codex `goal` | Claude | Claude `batch`, because Claude has no goal wrapper |

An unmistakable legacy Claude `/pr-batch` prompt converts to Codex batch mode,
not Codex goal mode. An unmistakable legacy Codex `/goal` prompt still converts
to Claude batch mode. Every cross-host result remains inert, requires relaunch,
and is reclassified before execution.

## Generator Behavior

The canonical source template remains portable and declares `Prompt mode:
batch`. Target rendering follows these rules:

1. Claude and generic targets render batch mode without `/goal`.
2. Codex defaults to batch mode without `/goal` unless persistent Goal mode was
   explicitly requested.
3. For an explicit Codex Goal request, render and measure the complete goal
   candidate.
4. Use the goal form only when it is at most 3,700 characters, preserving the
   existing 300-character headroom requirement.
5. Otherwise render the same content as Codex batch mode and report that Goal
   mode fell back because of the verified character count.
6. Apply ordinary size and safe-review splitting only after the fallback.

Plan, pr-batch, triage, continuation, and recovery documentation must use the
same terminology. Generated-prompt contract tests must prove that the fallback
does not change non-envelope semantics.

## Adapter Behavior

The adapter keeps its four classifications. A goal-overflow fallback performed
by a generator produces an ordinary Codex batch prompt, which classifies as
`compatible` on Codex. The adapter does not silently rewrite a same-host
oversized goal after submission; generation must choose the correct envelope
before launch or mutation.

Cross-host conversion changes the destination mode according to the mapping
above. It continues to translate only approved host mechanics and to compare
the normalized semantic payload. Unsupported mechanics, semantic loss, or
ambiguous host state still return `ambiguous` without prompt echo.

## Alternatives Rejected

1. **Always split into multiple Codex goals.** This preserves Goal mode but can
   unnecessarily fragment one ownership and dependency unit and makes replay
   and closeout harder.
2. **Trim safety or completion details until the goal fits.** This weakens the
   self-contained workflow contract and is not acceptable.
3. **Put a short goal in one message and reference an external Batch Plan.**
   This scatters authority across artifacts and makes a missing or stale plan a
   launch-time ambiguity.

## Tests and Acceptance

Implementation uses RED-GREEN-REFACTOR slices for these observable behaviors:

1. Claude batch to Codex conversion produces Codex batch mode without `/goal`,
   preserves the semantic payload, remains inert, and becomes compatible after
   relaunch.
2. Legacy Claude conversion follows the same mapping.
3. Codex goal to Claude conversion remains Claude batch mode.
4. An explicitly requested Codex goal under the headroom threshold retains
   `/goal` and `Prompt mode: goal`.
5. An explicitly requested oversized Codex goal falls back to a byte-equivalent
   Codex batch prompt instead of splitting solely for the wrapper.
6. Default Codex generation uses batch mode unless Goal mode is explicitly
   requested.
7. Prompt-size, fixture, installer, model-routing, goal-contract, and full
   repository validation remain green.

After implementation, the changed head requires a new independent read-only
exact-head checker, fresh hosted CI/review/thread readiness, merge-assurance
recalculation, and a rebuilt PR walkthrough map.

## Scope Limits

This revision does not decide how the native `scw` plugin's qualified skill
namespace is supplied to the adapter. That existing maintainer decision remains
separate and release-blocking. It also does not introduce signing, receipts,
waivers, new merge authority, or host-specific policy outside prompt delivery.
