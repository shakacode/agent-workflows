---
name: fix-flaky-tests
description: Use when a test fails intermittently in CI — classify the intermittency, work from the real CI error, fix the root cause systemically, and verify with a green CI build rather than local runs.
argument-hint: '[failing test, run URL, or flake report]'
---

# Fix Flaky Tests

A flaky test fails intermittently on unchanged code. That single property
invalidates the two habits an agent falls into by default: reasoning about the
cause from the source alone, and proving a fix by running it locally.

Handed "this spec is flaky", the two most common responses are both wrong. Do
not reason from the code without the CI error. Do not propose a skip.

## Hard Gate

These three rules are not negotiable and have no reduced-confidence mode.

1. **No fix without the real CI error.** You need the actual exception and
   backtrace from the failing CI run, or the same text pasted verbatim by the
   user. Not the test source. Not a plausible reconstruction. Not "this looks
   like a race". If the logs have expired and nobody can produce the error,
   report that and stop — an unverifiable guess is worse than an open issue,
   because it closes the investigation while leaving the flake in place.
2. **No local-pass verification.** Verification comes from a green CI build.
   A fix that passes 40 local runs but fails in CI is not a fix. Local runs are
   *investigation*, never proof.
3. **No skip.** Never propose `xit`, `skip`, `pending`, `t.Skip`, `.skip`,
   `@Ignore`, or an exclusion filter as the fix. Quarantining a test is a
   maintainer's risk decision about coverage, not a remedy an agent applies —
   and it converts a visible flake into invisible lost coverage. If quarantine
   is genuinely the right call, say so, say what it costs, and let a maintainer
   make it.

One more rule that prevents the most common misdiagnosis: **never assume
infrastructure flakiness without build-wide evidence.** "CI was just flaky" is
a claim about the whole build. A single failing example is the *opposite* of
that evidence — it usually means one uniquely fragile test. Infra evidence
looks like many unrelated tests failing in the same build, a runner or service
that failed to start, or the same failure across concurrent unrelated builds.

## Step 1 — Fast Exits Before Any Log Fetch

Run these first. They use git and repository/issue metadata only, so they still
resolve when CI logs have expired, and each one can end the task in a minute:

1. **Already fixed, not closed.** Check whether the test or its subject changed
   after the failing run. Compare the failing commit against the current head.
2. **Existing open PR.** Search open PRs touching the test file or its subject.
   Do not open a second fix for the same flake.
3. **Broken, not flaky.** Confirm intermittency before investigating it as a
   flake. A test that fails on every recent run is simply broken, and this
   workflow is the wrong tool — that is a normal bug fix.
4. **Historical recurrence.** Search closed issues and PRs for the same test
   file. Three or more prior fixes on one file means the per-occurrence fix has
   already failed repeatedly; the finding is the systemic cause, and a fourth
   local patch is the wrong output.
5. **Prior skip or quarantine.** If a bot or an earlier PR already skipped,
   quarantined, or retry-wrapped this test, the task is to restore it and fix
   the cause. Record what was suppressed and when — a suppressed test that has
   been failing silently may be protecting a real product bug.

## Step 2 — Progressive Discovery

Load only what the repository actually is:

- **Test framework** — detect from the repo's manifests and test layout.
- **CI provider** — detect from the CI configuration present in the repo.
- **Repository seam** — resolve validation, test, and lint commands from
  `.agents/bin/` per `.agents/bin/README.md`, and non-command policy from
  `.agents/agent-workflow.yml`. A missing script means that capability is not
  available here; do not invent a substitute command.

### Getting The Real CI Error

GitHub Actions is the shipped default path:

```bash
gh run view <run-id> --log-failed
gh run view <run-id> --json headSha,conclusion,createdAt,workflowName
```

For any other provider, resolve the log-fetch and replay commands from the
repository seam described above rather than assuming a provider CLI exists.
Buildkite, CircleCI, and everything else stay seam-resolved by design: this
skill must not hardcode a provider the consumer repo does not use.

Record with the error: the exact run id, head SHA, job name, attempt/retry
number, failing step, and timestamp. If any of those cannot be verified, write
`UNKNOWN` rather than guessing. A backtrace without its head SHA cannot be
matched to the code you are reading.

## Step 3 — Classify The Intermittency

Full catalog with symptoms and evidence tests: `references/flake-patterns.md`.
The families are order dependence and shared state, time and clock, concurrency
and async, randomness and unstable ordering, external resources, load
sensitivity, and fixture or data collisions.

Classify from the CI error, then look for the mechanism in the code. Working in
that direction is what keeps the investigation honest — starting from the code
produces a plausible story that the error may not support.

### Reproduction Is Not Verification

Keep these strictly separate:

- **Reproduction** observes state during investigation. It is capped at **two
  attempts per hypothesis**. If two attempts do not reproduce it, the hypothesis
  is not disproved — reproduction is simply not the tool for it. Move to
  evidence from the CI error, the code path, and the failure history.
- **Verification** answers "did the fix work", and only a green CI build
  answers it.

Failing to reproduce locally is expected and is not evidence that the flake is
fixed, absent, or environmental.

## Step 4 — Fix The Cause, Not The Occurrence

The fix must name the mechanism from Step 3 and remove it. When the same file
has three or more recurrences, fix the shared cause — the leaking helper, the
unfrozen clock, the shared fixture — rather than the one test that surfaced it.

These are not fixes, and proposing one is a failure of this workflow:

- raising a timeout without evidence that the timeout value is the cause
- inserting a sleep
- wrapping the test in a retry
- reordering or isolating the test so the ordering dependence stops showing
- skipping, quarantining, or excluding it

Each one suppresses the signal and leaves the defect. Several also hide a real
product race that the test was correctly detecting.

## Step 5 — Verify With CI

Push the fix and cite a green CI build for the changed test on the fix's head
SHA. Include the run URL, head SHA, and conclusion. If the test's failure rate
was the evidence, say how many post-fix runs support the claim — a single green
run on a flake that fails one time in twenty is weak evidence, and saying so is
part of the job.

## Outcomes

Close with exactly one of:

- `FIXED` — mechanism named, systemic fix merged, green CI build cited on the
  fix head SHA.
- `ROOT_CAUSE_NOT_IDENTIFIED` — an explicit statement of what was checked, what
  the CI error did and did not show, which hypotheses were tested and rejected,
  and what evidence would settle it. This is an acceptable, honest outcome.

There is no third outcome. A skip, a local-run-only pass claim, and a
speculative fix are all failures of this workflow, not results.

## Boundary With Replicate CI

Both skills start from "CI is red and my machine is green", and they fork on
one question: **is the failure deterministic?**

- **Deterministic** — the hosted check fails every time on this commit while
  local passes every time. That is a parity gap between environments: runner
  image, toolchain version, locale, timezone, filesystem, or service topology.
  Use `replicate-ci`. Its premise is that reproducing the failure in a
  CI-matched environment explains it, and for a deterministic gap that premise
  holds.
- **Intermittent** — the same commit passes and fails across runs. Use this
  skill. `replicate-ci`'s premise does not hold here: a parity run that passes
  proves nothing about a test that fails one run in twenty, and treating a
  green parity run as exoneration is exactly the wrong conclusion.

If the classification itself is unclear, establish determinism first by
inspecting the run history for that commit. Do not run both workflows in
parallel on the same failure.

## Findings

When structured output is requested, emit findings using
`docs/review-finding-schema.md` with `source: fix-flaky-tests` on each finding,
so a flake investigation can feed `pr-batch` and `post-merge-audit` like any
other review source.

Do **not** emit a `review_receipt` from this skill. The receipt `source` field
is a closed allowlist in `bin/validate-review-findings`, and `fix-flaky-tests`
is not in it; emitting one would fail repo validation. Findings-only output is
the supported mode here.

## Report Format

```markdown
## Flake Investigation
- Test:
- Fast exit taken (if any):
- CI error (run id, head SHA, job, attempt, step):
- Intermittency class:
- Mechanism:
- Recurrence history:
- Reproduction attempts and result:
- Fix (systemic or single-test, and why):
- CI verification (run URL, head SHA, conclusion):
- Outcome: FIXED | ROOT_CAUSE_NOT_IDENTIFIED
- UNKNOWN facts:
```

## Self-Check

- The real CI error was obtained, with its run id and head SHA, or the task
  stopped at the Hard Gate.
- Local runs were used only for investigation; the pass claim cites CI.
- No skip, sleep, retry wrapper, or unjustified timeout increase was proposed.
- Infrastructure flakiness was claimed only with build-wide evidence.
- Recurrence history was checked, and a repeated flake got a systemic fix.
- Repo-specific commands and policy came from the seam, not from this text.

## Source Note

Adapted from the `fix-flaky-tests` skill in
[intercom/2x-skills](https://github.com/intercom/2x-skills) (MIT). The hard
gate, fast exits, and reproduction/verification split are preserved; the
provider-specific log-fetch tier is replaced by this pack's repository seam.
