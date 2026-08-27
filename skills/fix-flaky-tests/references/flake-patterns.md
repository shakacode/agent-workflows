# Flake Patterns

Classification catalog for `fix-flaky-tests`. Load this after the real CI error
is in hand — classifying from the test source alone produces a plausible story
the error may not support.

Each family lists: the symptom in the CI error, the evidence that distinguishes
it from its neighbours, the real fix, and the false fix to refuse.

---

## Order Dependence And Shared State

**Symptom.** Passes alone, fails in a suite; fails only in some shard or seed
order; the error names state the test never set. Errors often reference a
record, key, mock, or configuration value belonging to another test.

**Evidence.** Compare the failing run's test order or seed with a passing run.
Re-run the suite with the failing seed. Look for module-level or class-level
mutable state, global registries, cached singletons, stubbed constants, or
environment variables set without teardown.

**Real fix.** Remove the shared mutable state or restore it in teardown. Prefer
removing the sharing over adding another cleanup hook — a cleanup hook is one
more thing to forget in the next test.

**False fix.** Reordering tests, pinning a seed, or isolating the test into its
own process so the dependence stops surfacing. The leak still exists and will
surface elsewhere.

---

## Time And Clock

**Symptom.** Fails around midnight, month end, year end, or a DST boundary;
off-by-one-day or off-by-one-hour assertions; fails only in CI's timezone;
duration assertions that fail when the machine is slow.

**Evidence.** Compare the failure timestamp with the boundary it sits near.
Check whether the test computes an expected value with a *second* call to the
clock — two clock reads can straddle a tick.

**Real fix.** Freeze or inject the clock. Compute expected values from a single
captured instant. Make timezone explicit rather than ambient. For durations,
assert on ordering or on injected time, not on wall-clock elapsed.

**False fix.** Widening a tolerance until the failure stops appearing.

---

## Concurrency And Async

**Symptom.** Intermittent nil, missing record, "not found", or partially
updated state; failures that get worse under CI parallelism; the error changes
between runs.

**Evidence.** Look for un-awaited work, background threads or jobs, callbacks
completing after assertions, connection-pool sharing between threads, or a
transaction that another thread cannot see. Failure rate rising with
parallelism is strong evidence.

**Real fix.** Await the actual completion signal, or make the test observe a
deterministic state transition. If a product race exists, fix the product — an
intermittent test failure is frequently a correct detection of a real race, and
this is the single most valuable outcome of a flake investigation.

**False fix.** A sleep. A retry wrapper. Both convert a real race into a
latency-dependent one.

---

## Randomness And Unstable Ordering

**Symptom.** Fails for particular generated values; collisions in generated
names, emails, or identifiers; assertions on collection order that hold most of
the time.

**Evidence.** Check whether the failing value was randomly generated. Look for
assertions on the order of a set, hash, or unordered query result.

**Real fix.** Seed deterministically and log the seed, guarantee uniqueness
explicitly instead of hoping for it, and assert on sorted or set-compared
output when order is not part of the contract. If order *is* part of the
contract, make the query specify it.

**False fix.** Re-running until the value is friendly.

---

## External Resources

**Symptom.** Connection refused, timeout, DNS failure, port already in use,
container or service not ready, disk full.

**Evidence.** Determine whether the resource is genuinely required or
accidentally reached. Check whether the failure appears across concurrent
unrelated builds — that would be true infrastructure evidence.

**Real fix.** Stub the external dependency, or wait on a real readiness signal
rather than a fixed delay. Allocate ports dynamically instead of hardcoding.

**False fix.** Declaring "infra flake" from a single failing example. That is
the opposite of build-wide evidence and usually means one uniquely fragile
test.

---

## Load Sensitivity And Resource Exhaustion

**Symptom.** Timeouts that trip only on loaded or shared runners; failures that
correlate with runner size or parallel job count; memory pressure; slow
subprocess startup.

**Evidence.** Compare failure rate against runner load, job concurrency, or
machine class. Check whether the timeout is tight relative to the work.
Cold-start and subprocess-spawn races belong here.

**Real fix.** Remove the timing dependence — wait on completion signals rather
than durations, and reduce per-test resource cost. Raise a timeout only with
direct evidence that the operation legitimately needs longer, and say what that
evidence was.

**False fix.** Raising a timeout because it made the failure stop. That is a
guess, and it hides genuine slowdowns permanently.

---

## Fixture And Data Collisions

**Symptom.** Unique-constraint violations, duplicate keys, records from a prior
test still present, sequence or counter assumptions.

**Evidence.** Check whether fixtures are shared across tests, whether cleanup
is transactional, and whether IDs or sequences are assumed to start at a known
value.

**Real fix.** Make setup independent per test and cleanup reliable. Do not
assert on generated ID values.

**False fix.** Adding a "clean everything" hook that masks the coupling while
slowing the suite.

---

## Systemic Recurrence

Not a mechanism — a signal about the fix's altitude.

**Symptom.** The same file or directory has three or more prior flake fixes.

**Evidence.** Search closed issues and PRs for the test file.

**Real fix.** The shared cause: the leaking helper, the ambient clock, the
shared fixture factory, the parallelism assumption. When per-occurrence fixes
have failed three times, a fourth is the wrong output regardless of how
plausible it looks.

**False fix.** One more single-test patch.
