# Original versus compact changelog pilot

This pilot compares the original `update-changelog` instructions with the
conditional-reference version merged in [PR #789](https://github.com/shakacode/agent-workflows/pull/789).
It belongs to [issue #793](https://github.com/shakacode/agent-workflows/issues/793).
It does not complete the broader route evaluation in
[issue #335](https://github.com/shakacode/agent-workflows/issues/335).

The [protocol](lean-changelog-pilot/protocol.json) defines three synthetic
scenarios, quality criteria, and three repetitions per variant per scenario.
The [runner](lean-changelog-pilot/run.py) uses one Codex route and six prepared
fixtures. Each attempt copies a fresh fixture and creates a fresh container,
controller, external environment and ephemeral model session.

The comparison pins the original at `df63a67cde6408edd38b5829ca6bcc341ac4c719`
and the compact candidate at `37ed91013e485c09db37deeff99bb1a229110bc9`.
The latter is #789's squash merge and the former is its immediate parent.
The helper files are identical. Only the instruction variant changes; the
fixture Git commit IDs consequently differ because instructions are tracked.
The tasks, synthetic PR details, helper implementation and runtime stay fixed.

## Execution boundary

Authentication stays in the existing M5 controller home. A fixed M1 helper owns
fixture copying, Docker, relay lifetime and result collection. M5 connects through
a loopback-only SSH local forward using the existing M1 SSH identity with agent
forwarding disabled. Model tools use the M1 task-local WebSocket relay, a
fixed-environment stdio filter, and the matching Linux Codex exec-server inside
Docker. The container blocks off-container networking and has a read-only root,
no capabilities, no privilege escalation, one disposable fixture mount, and
one read-only public runtime mount. It has no host home, credentials or Docker
socket. One persistent exec-server runs as PID1 for each trial, listening on
container-local `127.0.0.1:8765`. That internal transport is explicitly reachable;
reconnecting Linux websocat clients reuse its session. It is not blanket socket
denial. Per-process settings and the complete effective controller configuration
must be independently reviewed; live MCP tools, resources and templates must be
empty before `turn/start`.

An adapter-only receipt has `trial_release=false`. The existing final executor
receipt must also bind the exact runner, protocol, immutable Ruby image, all seven
runtime files, M5 Codex and SSH configuration, M1 websocat and Docker version,
filter/environment map, exact process-only trust paths, controller config source
content and metadata, and the live M1 fixture freeze. A separate M5 release must
reference the exact final independent receipt hash. Neither worker setup tests nor an adapter PASS
releases model calls. All approval artifacts remain private.
This replaces an unsuccessful native macOS isolation setup: the native process
sandbox allowed scratch reads/writes beyond the fixture. Those deterministic
setup probes are not benchmark attempts or token measurements.

## Reproduction

Use Codex CLI 0.153.4 on M5 macOS arm64, Python 3.11 or later on M5,
Python 3.9 or later on M1, matching Linux arm64 exec-server,
websocat 1.14.1, and the exact Ruby-enabled image recorded with the results.
Use the records’ `adapter_reproduction.reconstruction_dockerfile` on a fresh
Docker host. Its `FROM node@sha256:...` names the Node repository explicitly;
the bare `FROM sha256:...` historical recipe is retained as evidence only.
The reconstruction installs `ruby`, `python3`, and `git`.
Image build can use network; trial containers cannot. No credentials are copied.
The public protocol embeds the exact persistent filter source, controller
settings and seven-file runtime inventory. The records retain the original
build recipe, package versions, immutable Node base reference and historical
adapter source; they also include current download references. They suffice to
reconstruct preparation without private integration scripts. OS package sources
are mutable; a rebuilt image cannot claim the historical local image ID.

For a separately authorized future series, first create a new reviewed protocol
snapshot containing the rebuilt image ID in `runtime_image_id`. Place that
`protocol.json` beside the unchanged `run.py` in the same repository layout on
both hosts; the runner reads this adjacent file and has no protocol-path option.
Its exact-image checks intentionally reject a new image against the historical
protocol. Then use new state directories, prepare new fixtures, freeze both hosts,
and obtain a new exact independent receipt and separate release. Keep this
historical protocol, results and approval evidence intact. These reconstruction
steps do not authorize additional trials.

On M1, check out the same runner and protocol. Download and extract the pinned
Linux Codex tarball under
`$PILOT_ADAPTER/runtime`, place the Linux websocat binary in
`runtime/package/vendor/aarch64-unknown-linux-musl/bin/websocat`, and place the
macOS websocat binary at `$PILOT_ADAPTER/websocat`. Preserve executable modes and
verify all protocol hashes. Write the filter directly from the public source:

```bash
python3 - "$PILOT_ADAPTER" <<'PYTHON'
import json, pathlib, sys
p = pathlib.Path('docs/benchmarks/lean-changelog-pilot/protocol.json')
(pathlib.Path(sys.argv[1]) / 'filter-persistent-exec.py').write_text(
    json.loads(p.read_text())['transport_filter_source'])
PYTHON
python3 docs/benchmarks/lean-changelog-pilot/run.py self-test \
  --state "$PILOT_CHECK_STATE" --adapter "$PILOT_ADAPTER" --image "$PILOT_IMAGE_SHA"
python3 docs/benchmarks/lean-changelog-pilot/run.py prepare \
  --state "$NEW_PILOT_STATE" --adapter "$PILOT_ADAPTER" --image "$PILOT_IMAGE_SHA"
```

`prepare` runs on M1, requires a new empty private state, creates six repositories,
runs the unchanged helper, verifies every expected row including UNKNOWN, and checks
changelog structure without a model. It freezes every live file and directory,
including both Git stores and file permissions. `self-test` forbids process
launches and exercises refusal and dispatch-error handling. Its synthetic
approvals exist only in memory. `gate-check` never launches a controller, even
when accepted; without the independent runner receipt and M5 release it must fail.

On M5, keep a private `m1-executor.json` in the adapter directory with exactly
four fields: `host` equal to the existing SSH alias `m1`, and absolute M1 paths
`runner`, `state`, and `adapter`. The state is the prepared M1 state. No credentials
or remote controller configuration belong in this file. Run `freeze` with a new
empty M5 `--state`, the M5 `--adapter`, and the same immutable `--image`. It creates
18 empty controller directories, reads M1 evidence over SSH, and saves the combined
freeze without starting a controller. `gate-check` and `run` use those M5 paths:

```bash
python3 docs/benchmarks/lean-changelog-pilot/run.py freeze \
  --state "$NEW_M5_STATE" --adapter "$M5_ADAPTER" --image "$PILOT_IMAGE_SHA"
python3 docs/benchmarks/lean-changelog-pilot/run.py gate-check \
  --state "$NEW_M5_STATE" --adapter "$M5_ADAPTER" --image "$PILOT_IMAGE_SHA"
```

The runner's `executor-bind` and `executor-trial` phases are the fixed M1 helper;
its trial input is only an exact binding followed by `finish`, `cancel`, or EOF.

The independent final receipt extends the existing executor receipt with
`runner_review_status: PASS`, `runner_binding` equal to the freshly computed
freeze, a complete `approved_effective_config` captured through `config/read`
for the actual trial cwd, and all `runner_verified` conditions named in the
runner. It retains `trial_release: false`. The separate `m5-trial-release.json`
requires owner `M5`, target `shakacode/agent-workflows:issue:793`,
`trial_release: true`, and `independent_receipt_sha256`. These fields are a
fail-closed local control contract; independent authorship and parent authority
are established through the private coordinator, not cryptographic signatures.
The worker must not manufacture either approval.

Only after independent review and parent release may the same runner's `run`
phase be invoked. It rechecks the gate before each controller launch, verifies
live prepared files immediately before each copy and verifies the copy, rejects
symlinks, and checks full effective configuration and empty live MCP inventories
again before `turn/start`. Every actual controller cwd is declared with its
physical path as a process-only `{trust_level: trusted}` project override before
thread creation. Full effective config must be identical before and after thread
creation. Missing trust refuses before launch; no added trust entry is normalized
away. Installed source hashes and inode, mode, size and timestamp metadata must
remain unchanged after thread creation and controller exit. The runner records
resolved model/provider/effort/service tier.
Missing or null observed thread fields are recorded as `UNKNOWN`; field
availability is recorded from the response. Independent pinned-app-server
evidence exposes `serviceTier=priority`; that exposed field is checked. Every
exposed field is compared to the approved route.
Effective configuration still binds the complete route and service tier.
A run-start marker and per-trial directories prevent silent repetition.
Owner or tunnel loss stops the batch without reconnecting a replacement executor.
EOF, termination, and a bounded M1 owner deadline enter cleanup for the known
owned container and relay. Indeterminate creation remains unverified. Cleanup must be verified; an uncertain cleanup blocks further trials.
Structured dispatch errors, CreateProcess failures, failed patches and
controller transport errors stop the
batch even if a model turn reports completion. An ordinary command with
`status=failed` and a numeric nonzero exit code remains task evidence; status
alone does not establish infrastructure failure.

## Partial released series: four passes, one transport failure

The independently reviewed M5/M1 series started after full repository validation,
parent approval, a separate receipt-bound M5 release and the actual readiness gate.
It stopped automatically on attempt 5 of 18. Four sweep tasks completed and passed
independent blinded grading; attempt 5 failed at the transport boundary and has
UNKNOWN task quality. Thirteen trials never started. No replacement or retry was
launched, and no further release is approved. The runner process returned zero
on this failure stop; its status and per-attempt results, not the process exit
code alone, determine whether the series completed.

| Attempt | Instructions | Sweep repetition | Outcome | Wall seconds | Provider total tokens |
| --- | --- | --- | --- | ---: | ---: |
| 1 | Original | 1 | PASS | 52.259 | 192,756 |
| 2 | Compact | 1 | PASS | 46.587 | 126,341 |
| 3 | Compact | 2 | PASS | 45.384 | 128,105 |
| 4 | Original | 2 | PASS | 46.036 | 205,846 |
| 5 | Original | 3 | Transport failure; quality UNKNOWN | 25.770 | 86,205 |

The four complete reports covered every PR and the unmapped commit, classified
the public feature and internal change, accounted for the full revert, and kept
the unresolved UNKNOWN blocker visible. Their collected tracked diffs were empty.
The checker saw shuffled opaque IDs, the frozen rubric, final responses, diffs
and task command evidence, with instruction reads, order and measurements withheld.
A few abbreviated fixture commit IDs survived full-SHA pseudonymization; the
variant mapping remained private until grading finished. One report used a
different category for the revert; the frozen criterion required its no-entry
result and specific revert reason, which were present. No extra stylistic or
category criterion was added after observing results.

For the two completed sweep tasks per variant, original wall time had median
49.148 seconds (46.036–52.259), and compact had median 45.986 seconds
(45.384–46.587). The ranges overlap. Provider-reported total-token medians were
199,301 and 127,223 respectively. These are descriptive observations from an
incomplete series, not evidence of causal speed improvement or billed savings.
The failed attempt's measurements remain separate from completed-task summaries.
Other authorized work continued on the shared hosts; host and provider load were
not controlled. The performance verdict is **ambiguous**.

Attempt 5 reported `CreateProcess` failure with `exec-server transport disconnected`
at 2026-09-08 01:05:36 UTC. Independent read-only incident review confirmed an
infrastructure dispatch failure, not an ordinary command exit or a demonstrated
fixture/skill defect. Its exact failed command and the underlying disconnect cause
are UNKNOWN. Three untimestamped relay I/O errors do not establish causality.
All five executor cleanups were independently corroborated; frozen code and
installed configuration fingerprints remained unchanged. A later read-only Git
snapshot found attempt 5's fixture clean. That supplemental snapshot does not
replace its missing final answer or original uncollected diff.

The third sweep repetition remains incomplete. Neither the Unreleased editing
scenario nor the explicit prerelease stamping scenario started. Quality parity
for those modes, complete instruction-read behavior, reliable transport through
all 18 trials, and general performance or route recommendations remain unanswered.
Issue #335 remains open. Investigating the observed transport failure and obtaining
fresh verification and release are prerequisites to any further model trials.

Full `bin/validate` passed, including installer and stack suites. Validation used
process-only `BASH_ENV`/`ENV` removal and a private system-Bash shim after inherited
startup settings bypassed test stubs and Homebrew Bash 5.3 stalled a heredoc.
Those earlier environment failures remain recorded; no installed configuration
or repository change was used to make them pass. Lint also passed.

## Published runner repairs after the series

The records preserve the exact released runner under
`split_host_series.execution_runner_source`, with its original hash. The published
`run.py` adds failure-path repairs after execution and is **unmeasured by this
series**. Existing approval applies only to the historical source; it cannot
release trials with this repaired source.

If Docker startup fails before returning a created container ID, the runner now
records creation as UNKNOWN and cleanup as unverified. It deletes only a known
owned ID. This corrects a false cleanup confirmation reproduced by fault injection;
no real leaked container or continued trial was demonstrated. An indeterminate
startup needs task-specific reconciliation before any new release.

After stopping the relay, finish, cancellation and owner failure paths collect each
tracked-state field independently with bounded reads, but only after container
boundary validation succeeded. Partial data and collection errors remain separate
from cleanup. M5 preserves authoritative terminal replies, including startup
errors and verified cleanup, without a redundant cancellation. Cancellation reads
past one delayed ready message within the same deadline. The existing TERM/alarm
handler lets bounded finalization and its durable receipt finish. Historical missing
evidence remains missing; the later run-5 Git snapshot stays supplemental. These
changes improve failure reporting and do not resolve the observed transport cause.
The published runner still returns zero on a failure stop; callers must inspect
its status and result records.

Deterministic self-checks cover the new paths without launching processes or model
calls; independent fault injection also checked unknown ownership, known-ID cleanup,
partial snapshots, EOF/deadline/relay-loss handling and M5 propagation. A future native execution review and separate
release remain required before additional benchmark trials.

## Earlier series: four invalid attempts, fourteen unstarted

Four earlier M1-controller attempts began prematurely: exact Ruby executor
independent PASS was absent at their start. All four are **INVALID comparison
attempts**, including their available usage and durations. Three model turns
completed with infrastructure-blocked responses; the controller interrupted the
fourth after recognizing repeated failure. Fourteen attempts never started.
The executor returned `unknown session id` on subsequent shell operations,
including reads of the skill. No scenario completed successfully.

Their original source, protocol, run order, accounting and output evidence remain
unchanged in the top-level records. The later released series is stored separately
under `split_host_series`. Never pool the two. Earlier completed-turn wall times
of 21.449, 16.506 and 25.194 seconds measure blocked infrastructure attempts, not
successful changelog work. Their quality remains UNKNOWN. The original runner did
not stop automatically; the repaired runner's failure stop was exercised in the
later series. A completed model turn alone is not task success.

## Evidence interpretation

[Records](lean-changelog-pilot/records.json) retain the selected public evidence.
Independent blinded grading covers the four completed released sweep tasks;
failed and unstarted task quality remains UNKNOWN. Report attempted and completed
runs separately, and show per-scenario distributions rather than selecting a best run. Some captured command outputs are null or partial, including compact instruction
reads. Read attempts are observed, but complete delivered instruction bytes remain
UNKNOWN; output hashes and byte counts describe captured text only. Static instruction
bytes are not observed tokens. Token counters do not establish billed cost.
With only two completed sweep repetitions per variant, overlapping distributions
do not demonstrate a speed improvement or justify a general route recommendation.

PR #789's open-to-merge interval is 7,957 seconds. Public evidence contains two
implementation/correction commits and four base merges. CI/review jobs overlap;
their summed durations are not elapsed delivery time or active implementation.
Some validations replayed an unchanged skill snapshot after base changes, but
those bases included policy changes. Redundancy and counterfactual savings are
UNKNOWN. Recommendations here inform the separate workflow-policy owner and
change no security, review or CI gate.

Changelog disposition: `deferred_to_update_changelog`. The three next-edit nits
from #789 remain deferred.
