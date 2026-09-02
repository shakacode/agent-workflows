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
- owner/task, lane, worktree, command class, unique launch token, shell-free
  root command argv, and durable log path; and
- the short pre-launch reservation TTL.

When this optional component is enabled, the consumer `AGENTS.md` policy
pointer resolves its stable inputs from `.agents/agent-workflow.yml`. Use the
mapping selected under `heavy_root_admission.hosts` by the stable host key,
with child keys `host_id`, `state_dir`, `ceiling`, `scan_command_argv`,
`scan_timeout_seconds`, and `reservation_ttl_seconds`. Encode
`scan_command_argv` as JSON only when passing it to `--scan-command-json`.
Do not invent these values from a task, issue, PR, or coordinator-local prompt.

The `--ceiling`, scan command, load and memory thresholds, and elevated-versus-
healthy host classification remain policy inputs. The helper deliberately has
no M5, M1, RAM-size, or fleet-wide default. Changing those inputs does not
change the atomic admission mechanism.

All coordinators that share one host and state directory must resolve the same
configured `--ceiling`. The helper does not persist or arbitrate caller policy;
a different configured value is a configuration error. A live scan may still
lower the effective ceiling for one attempt.

Each scanner row is a verified live root and declares `verified: true`, owner,
lane, worktree, command class, and a PID or PGID. Missing, malformed,
unverified, failed, or timed-out scan evidence blocks admission; it never means
zero roots. The timeout covers the scanner process group and output-pipe drain;
on expiry the helper terminates that group, closes inherited pipes, and denies
the reservation. A scanner may return nonnegative `ceiling` and human-readable
`retry_when` fields; the effective ceiling is the lower of that live result and
`--ceiling`, so a live policy observation can reduce but never silently expand
the configured maximum.

## Launch And Release

1. On the host that will execute the root, run `bin/heavy-root-admission
   launch` with `--state-dir`, `--host`, `--owner`, `--lane`, `--worktree`,
   `--command-class`, `--launch-token`, `--ceiling`,
   `--scan-command-json`, `--command-json`, and `--log`. Both command values are
   JSON argv arrays resolved from trusted consumer seams; the helper never runs
   them through a shell. It holds the host-local lock while it scans, counts
   verified live roots plus active reservations, and performs the bounded
   launch transaction. That lock includes the scan duration, so release may
   wait up to `--scan-timeout`; keep the timeout at the smallest reliable value.
2. While still holding the lock, the helper persists a short-lived pre-launch
   reservation, creates a child in its own process group, and keeps that child
   blocked on a private permit pipe. The child does not change directory, open
   the log, or execute the root command yet. The helper captures the real
   PID/PGID and process start identity, persists the bound reservation, and only
   then permits the child to open the log and `exec` the argv. A failure before
   the bound write closes the pipe and reaps the gated group; it never leaves an
   untracked root or repository/log writer. The durable pre-launch record then
   expires normally so another coordinator can recover it with a fresh token.
3. Only an intact receipt with decision `launched` (exit 0) confirms that the
   helper executed the transaction. An intact `capacity-full` decision (exit 3)
   names owning tasks/lanes and says when to retry. Do not poll raw PIDs, invoke
   the command separately, or treat any pre-launch reservation as external
   launch permission. The old public `reserve` and `bind` commands are invalid.
4. Preserve the helper-owned process and descendants to natural terminal.
   Verify the exact terminal outcome and complete no-writer cleanup, including
   descendants, loggers, open repository writers, and Git locks. Only then run
   `bin/heavy-root-admission release` with `--terminal-outcome` and
   `--no-writer-cleanup`. Release refuses a live PID or PGID.

A crashed helper's gated child sees the permit pipe close and exits without
opening the log or executing the root. A reservation still in `reserved` state
expires after the bounded TTL. A reservation already persisted as `bound` must
instead follow the same-token reconciliation and cleanup path below. The next
claimant recovers an expired pre-launch reservation while holding the same lock,
but must use a new launch token and repeat the whole-host scan. Launch tokens are single-use
for the life of the state directory: hashed tombstones reject a token even after
its detailed record is pruned. Released and expired detail records are retained for
at most one hour and the newest 128 records per host, whichever bound is reached
first. Active records are never pruned. An expired record never authorizes
killing or ignoring an unverified live root. A bound record remains occupied
until terminal/no-writer cleanup evidence is supplied and it is released. If
the original claimant disappears after binding, a replacement coordinator may
read the stored lane, launch token, PID/PGID, and start identity, perform a
fresh verified whole-host scan, confirm natural terminal and zero descendants,
loggers, writers, and Git locks, then run the same `release` command. Release
does not require the original claimant identity. It still fails closed for an
ambiguous live process group; it does not auto-expire a bound root. PID reuse
with a different recorded start identity is not treated as the original root.

## Remote M1 Pattern

Run the entire launch/release sequence on M1 itself. A lock or state file
on M5 cannot coordinate another process that independently admits work on M1.
Use the repository's configured non-interactive login-shell transport; with an
operator-configured alias the shape is:

```text
ssh <m1-alias> 'zsh -lc '\''<resolved-pr-batch-dir>/bin/heavy-root-admission launch <M1 policy and root-command inputs>'\'''
```

This shows the transport shape, not a string-interpolation template. Resolve
the command from trusted seam values and shell-escape every dynamic argument
separately before assembling the remote command; never interpolate task, PR,
title, or branch text directly.

The helper launches the remote root non-interactively, records its PID/PGID,
and redirects it to the durable remote `--log`. After natural terminal and
remote no-writer cleanup, invoke `release` through the same login-shell form on
M1. Record the remote host, task/lane, worktree, command, launch token,
PID/PGID, log, terminal outcome, and cleanup receipt. Never admit on M5 for work
that will execute on M1.

## Status And Recovery

Treat an intact exit 0 receipt with decision `launched` as confirmation that the
helper launched and durably bound the root. An intact exit 3 receipt with reason
`capacity-full` is a normal denial; show its owner/task rows and exact retry
condition. Exit 64 is invalid CLI input rejected before the launch transaction
and launches nothing.

A missing receipt or any nonzero `launch` outcome is `UNKNOWN` once valid
launch inputs entered the transaction. Do not retry the command or mint a fresh
token. First reconcile the same launch token against the host-local state. A
bound record means the root may be live and must be monitored through terminal,
no-writer cleanup, and release. A reserved record must reach bounded expiry and
recovery. Only when no active reservation remains for the token and a fresh
corrected whole-host scan proves no matching root may a coordinator use a fresh
token. Preserve the state
directory for replay across coordinator restarts. The mechanism is optional: a
single-operator or serial workflow may omit it, but must not claim atomic
multi-coordinator admission without using the host-local contract.
