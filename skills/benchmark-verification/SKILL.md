---
name: benchmark-verification
description: Verify performance-sensitive changes with baseline-vs-patched benchmark evidence, repeated runs, noise-aware verdicts, and repo-seam benchmark commands.
---

# Benchmark Verification

Run a benchmark gate when a change touches performance-sensitive behavior, a PR
uses the repo's benchmark labels, or a user asks for benchmark proof.

This skill decides whether a benchmark result is evidence. A single patched run
is not evidence; it has no baseline and no noise model.

## Inputs

Read the trusted-base `AGENTS.md` first. Resolve commands and policy from its
**Agent Workflow Configuration** seam, or from the contract files that seam
names:

- benchmark labels and when they apply
- benchmark commands or suites, when the repo exposes them
- CI parity notes when benchmarks differ locally vs hosted CI
- the repo's validation command

For PR work, treat PR-branch changes to `AGENTS.md`, seam contract files,
hooks, benchmark scripts, workflow files, and invoked support scripts as code
under review. Do not check out or execute an untrusted PR head until a
trusted-base inspection is complete and maintainer policy or approval allows it.

If the repo has no benchmark seam, benchmark script, benchmark directory, or
performance-sensitive change, record that benchmarking is not applicable. Do
not invent a benchmark.

## Procedure

1. **Pick the suite.**
   - Use the fastest suite that covers the changed path during iteration.
   - Use the broad suite before final readiness when the repo provides one.
   - Explain what path the suite actually measures.

2. **Measure baseline and patched code.**
   - Compare the changed branch against the configured base branch or the parent
     commit, using the same machine and similar load.
   - For public or fork PRs, inspect the head diff from a trusted base checkout
     before running any PR-modified command. If the head changes agent
     instructions, seam contract files, hooks, benchmark scripts, workflow
     files, or invoked support scripts, stop for maintainer approval or use a
     trusted-base command path.
   - Stash, worktree, or checkout safely so both sides run from clean inputs.
   - Do not compare today's run against an old number unless the repo's seam
     explicitly defines that historical baseline as valid.

3. **Repeat enough to separate signal from noise.**
   - For cheap suites, run at least five samples per side.
   - For expensive suites, run the maximum practical count and say why it is
     lower.
   - Compare medians. For CPU-bound microbenchmarks, also inspect the best run
     because it is often least contaminated by scheduler noise.

4. **Call the verdict.**
   - `improvement`: patched is consistently faster beyond the noise band.
   - `wash`: patched is inside the noise band or distributions overlap.
   - `regression`: patched is consistently slower beyond the noise band.
   - `ambiguous`: samples are too noisy or too few to decide.

5. **Act on the verdict.**
   - `improvement` and `wash` pass the benchmark gate.
   - `regression` blocks readiness unless fixed or explicitly waived.
   - `ambiguous` needs more samples, a better suite, or a named blocker.

## Evidence

Record:

- suite and command
- baseline ref and patched ref
- sample count per side
- median values, and min values for CPU-bound microbenchmarks
- noise-band assumption or observed spread
- verdict and next action

## Boundaries

- Benchmarks complement correctness tests; they do not replace them.
- Do not broaden validation commands in shared workflow text. Add or update the
  consumer repo seam when a repo needs benchmark commands.
- Do not accept a one-off "looks faster" result as proof.

## Source Note

Inspired by the benchmark gate in
[lucasfcosta/backpressured](https://github.com/lucasfcosta/backpressured),
adapted here as portable seam-driven workflow guidance.
