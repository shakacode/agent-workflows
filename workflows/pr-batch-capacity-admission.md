# PR-Batch Heavy-Root Capacity Admission

This optional component makes one host's decision to scan capacity and reserve
one heavyweight execution slot atomic. It is not a global queue or scheduler,
does not serialize the heavyweight work itself, and never kills a root to make
space.

Use it when independent coordinators may start full validators, broad test
suites, review roots, or QA roots on the same host. Ordinary implementation,
focused checks that are known to be lightweight, and GitHub reads do not consume
these slots.

## Inputs

Resolve the sibling `bin/heavy-root-admission` helper from the same trusted
PR-batch skill pack. The operator or consumer policy supplies, per host:

- a host-local state directory shared by coordinators on that host;
- the stable host identifier and current heavyweight-root ceiling (host IDs are
  case-normalized so aliases such as `M1` and `m1` share one lock domain);
- a bounded whole-host scanner command that returns JSON with a `roots` array
  and may lower the current ceiling from live load/memory policy;
- owner/task, lane, worktree, command class, and a unique launch token; and
- the short pre-launch reservation TTL.

The `--ceiling`, scan command, load and memory thresholds, and elevated-versus-
healthy host classification remain policy inputs. The helper deliberately has
no M5, M1, RAM-size, or fleet-wide default. Changing those inputs does not
change the atomic admission mechanism.

Each scanner row is a verified live root and declares `verified: true`, owner,
lane, worktree, command class, and a PID or PGID. Missing, malformed,
unverified, failed, or timed-out scan evidence blocks admission; it never means
zero roots. A scanner may return nonnegative `ceiling` and human-readable
`retry_when` fields; the effective ceiling is the lower of that live result and
`--ceiling`, so a live policy observation can reduce but never silently expand
the configured maximum.

## Reserve, Launch, Bind, Release

1. On the host that will execute the root, run `bin/heavy-root-admission
   reserve` with `--state-dir`, `--host`, `--owner`, `--lane`, `--worktree`,
   `--command-class`, `--launch-token`, `--ceiling`, and
   `--scan-command-json`. The helper holds a host-local file lock only while it
   runs the bounded scan, recovers expired pre-launch records, counts live roots
   plus active reservations, and persists its decision.
2. Launch only when the decision is `reserved` (exit 0). A `capacity-full`
   decision (exit 3) names the owning tasks/lanes and says to retry after a live
   root or reservation reaches terminal/no-writer cleanup and releases. Do not
   poll raw PIDs or launch anyway.
3. Start the root in a traceable process group, retain its durable log, then
   immediately run `bin/heavy-root-admission bind` with the same state
   directory, host, and launch token plus the real `--pid` and `--pgid`. Binding
   verifies the local process and process group. A bound reservation does not
   expire automatically.
4. Preserve the process and descendants to natural terminal. Verify the exact
   terminal outcome and complete no-writer cleanup, including descendants,
   loggers, open repository writers, and Git locks. Only then run
   `bin/heavy-root-admission release` with `--terminal-outcome` and
   `--no-writer-cleanup`. Release refuses a live PID or PGID.

A crashed claimant's unbound reservation expires after the bounded TTL. The
next claimant recovers it while holding the same lock, but must use a new launch
token and repeat the whole-host scan. An expired record never authorizes killing
or ignoring an unverified live root. A bound record remains occupied until its
owner supplies terminal/no-writer cleanup evidence and releases it.

## Remote M1 Pattern

Run the entire reserve/bind/release sequence on M1 itself. A lock or state file
on M5 cannot coordinate another process that independently admits work on M1.
Use the repository's configured non-interactive login-shell transport; with an
operator-configured alias the shape is:

```text
ssh <m1-alias> 'zsh -lc '\''<resolved-pr-batch-dir>/bin/heavy-root-admission reserve <M1 policy inputs>'\'''
```

Launch the remote root non-interactively with a durable remote log and captured
PID/PGID, then invoke `bind` through the same login-shell form on M1. After its
natural terminal and remote no-writer cleanup, invoke `release` there as well.
Record the remote host, task/lane, worktree, command, launch token, PID/PGID,
log, terminal outcome, and cleanup receipt. Never reserve on M5 for work that
will execute on M1.

## Status And Recovery

Treat exit 0 as the only launch permission. Exit 3 is a normal capacity denial;
show its owner/task rows and exact retry condition. Exit 1 or 64 is an unknown
or invalid admission attempt and launches nothing. Preserve the state directory
for replay across coordinator restarts. The mechanism is optional: a
single-operator or serial workflow may omit it, but must not claim atomic
multi-coordinator admission without using the host-local contract.
