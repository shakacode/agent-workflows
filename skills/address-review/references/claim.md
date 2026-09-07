## Mutual Exclusion Gate

Before Step 5, establish the applicable ownership gate for every PR that may be
mutated. Without replacement carryover this is only `PRIMARY_PR_NUMBER`; with
replacement carryover it is both `PRIMARY_PR_NUMBER` and `SOURCE_PR_NUMBER`.
Replacement carryover must acquire and preserve ownership for both
`PRIMARY_PR_NUMBER` and `SOURCE_PR_NUMBER` before any branch or non-claim GitHub mutation;
a conflict, refusal, timeout, or `UNKNOWN` on either target blocks mutations on
both.
Read-only fetches in Steps 3-4 may run before this gate. Follow the repo's
`coordination_backend` seam and the vocabulary in
`docs/coordination-backend.md`: use the selected private backend when available,
use public claim comments only when the seam allows them, and treat `n/a` as a
single-operator workflow. Do not create todos, present an unattended
`autopilot` action, commit, push, post replies, resolve threads, or post a
summary checkpoint until the required ownership gate passes. If Steps 3-4
fetched review data before the ownership claim, rerun the Step 4 fetch after the
claim succeeds and use the post-claim data for Step 5. Public fallback claims
are GitHub comments, so do not post them merely to triage, run `autopilot`, or
execute local-only action `a`; for public-fallback repos, Step 5 may proceed
after the read-only conflict inspection below, but any GitHub-mutating action
must post or refresh the fallback claim after the user selects that action and
before the first branch update, push, reply, thread resolution, follow-up issue,
or summary/status comment. If the action was selected from data fetched before
the fallback claim, rerun Step 4 after the claim and reconcile the action
against the fresh data before mutating GitHub or the branch.

- If the repo's `coordination_backend` seam selects an available coordination
  backend, acquire the target PR claim with the bounded helper from the resolved
  `pr-batch` skill directory. Use stable `AGENT_ID` and `BATCH_ID` values from
  the current run when available, and use the normal PR branch name when a branch is known. If
  `AGENT_ID` is not already set, initialize a stable fallback from the current
  thread/session when possible; set `AGENT_ID` explicitly when running multiple
  concurrent sessions against the same PR:

  ```bash
  if [ -z "${PR_BATCH_SKILL_DIR:-}" ]; then
    if [ -n "${ADDRESS_REVIEW_SKILL_DIR:-}" ] && [ -d "$(dirname -- "${ADDRESS_REVIEW_SKILL_DIR}")/pr-batch" ]; then
      PR_BATCH_SKILL_DIR="$(dirname -- "${ADDRESS_REVIEW_SKILL_DIR}")/pr-batch"
    elif [ -d ".agents/skills/pr-batch" ]; then
      PR_BATCH_SKILL_DIR=".agents/skills/pr-batch"
    else
      echo "Refusing to continue: set PR_BATCH_SKILL_DIR or install/pin the pr-batch skill." >&2
      exit 1
    fi
  fi
  machine_id="${MACHINE_ID:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf machine)}"
  AGENT_ID="${AGENT_ID:-address-review-${CODEX_THREAD_ID:-${CLAUDE_SESSION_ID:-${USER:-agent}-${machine_id}-pr-${PR_NUMBER}}}}"
  coord_read_degraded=0
  CLAIM_TARGETS="${PRIMARY_PR_NUMBER}"
  if [ -n "${SOURCE_PR_NUMBER}" ]; then
    CLAIM_TARGETS="${CLAIM_TARGETS} ${SOURCE_PR_NUMBER}"
  fi
  "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 doctor --json || coord_read_degraded=1
  for CLAIM_TARGET in ${CLAIM_TARGETS}; do
    "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 status --repo "${REPO}" --target "${CLAIM_TARGET}" --json || coord_read_degraded=1
  done
  if [ "${coord_read_degraded}" -ne 0 ] && [ "${ADDRESS_REVIEW_CLAIM_ONLY_CONFIRMED:-}" != "1" ]; then
    echo "Refusing to claim: coordination doctor/status is degraded; set ADDRESS_REVIEW_CLAIM_ONLY_CONFIRMED=1 only after confirming an exact independent assignment with no dependency refs." >&2
    exit 1
  fi
  ACQUIRED_CLAIM_TARGETS=""
  for CLAIM_TARGET in ${CLAIM_TARGETS}; do
    set -- --agent-id "${AGENT_ID}" --repo "${REPO}" --target "${CLAIM_TARGET}"
    [ -n "${BATCH_ID:-}" ] && set -- "$@" --batch-id "${BATCH_ID}"
    if [ "${CLAIM_TARGET}" = "${PRIMARY_PR_NUMBER}" ] && [ -n "${BRANCH_NAME:-}" ]; then
      set -- "$@" --branch "${BRANCH_NAME}"
    fi
    if "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 claim "$@" --json; then
      ACQUIRED_CLAIM_TARGETS="${ACQUIRED_CLAIM_TARGETS} ${CLAIM_TARGET}"
    else
      claim_status=$?
      for ACQUIRED_CLAIM_TARGET in ${ACQUIRED_CLAIM_TARGETS}; do
        set -- --agent-id "${AGENT_ID}" --repo "${REPO}" --target "${ACQUIRED_CLAIM_TARGET}"
        [ -n "${BATCH_ID:-}" ] && set -- "$@" --batch-id "${BATCH_ID}"
        if ! "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 release "$@" --terminal abandoned --json; then
          echo "Warning: could not confirm rollback of claim for PR #${ACQUIRED_CLAIM_TARGET}; coordination state is UNKNOWN." >&2
        fi
      done
      exit "${claim_status}"
    fi
  done
  ```

- If a later private claim fails, terminal-release every target acquired by that
  claim loop before returning the original failure status. A rollback that
  cannot be confirmed leaves that target's coordination state `UNKNOWN`; report
  it explicitly and do not mutate either PR.
- A refused private claim for either mutation target is a hard stop. If the claim returns
  `CLAIM_REFUSED` / exit code 3, report the holder, heartbeat liveness, and
  target PR; do not continue with triage, branch changes, pushes, replies,
  resolutions, summaries, or public fallback.
- If bounded doctor/status is degraded but this is an exact independent
  address-review assignment with no dependency refs, a coordinator may try the
  bounded claim directly by setting `ADDRESS_REVIEW_CLAIM_ONLY_CONFIRMED=1` for
  that command only. If that direct claim succeeds, proceed with
  `private_state: claim-only`, immediately rerun the Step 4 fetch when any
  earlier review data was fetched before the claim, heartbeat at phase
  transitions, and record the degraded read evidence in the handoff. If the
  claim times out, stop with `private_state: UNKNOWN (claim outcome)` and
  reconcile backend state before fallback or mutation.
- After any successful private claim, refresh every acquired target's heartbeat at phase
  transitions: triage complete, action selected, before and after long-running
  local fix or validation blocks, before push/reply/resolve/summary work,
  blocked/resumed states, and final stable stop. Do not let a live address-review
  run exceed the backend heartbeat TTL without a refresh.
- After a successful private claim on an issue/PR, mirror it to the seam's claim
  label (`agent_claimed_label`, default `agent-claimed`) and remove it on release
  only for this lane's own claim (holder/generation check, so a replacement claim
  that reapplied the label is not cleared), the same as the batch claim step —
  mirror only when the backend provides claim-label expiry reconciliation, and
  skip entirely when `coordination_backend: n/a`.
- Use a structured public `codex-claim` comment only when the repo's
  `coordination_backend` seam explicitly selects public claim-comment fallback,
  or when the private claim cannot be started or definitively fails with a
  non-timeout setup/auth error before any mutation and the
  `coordination_backend` seam allows that fallback. Public claim comments are
  advisory and must not override a private claim refusal, timeout, or a repo
  seam that opts out of coordination.
- Before posting a fallback claim, inspect recent PR comments for an unexpired
  `codex-claim` block on the same PR. Only a marker backed by authenticated and
  authorized ownership evidence is conflicting. A marker proven malformed or
  unauthorized remains advisory; an unavailable or incomplete verification
  remains `UNKNOWN` and blocks the affected action. For a verified conflict, stop
  GitHub-mutating actions and report the comment URL; local-only action `a` may
  still proceed, but it must report that publishing/reply actions remain blocked
  by the verified active claim. Apply the concrete author-and-marker verification
  in the public [backend guide](../../../docs/coordination-backend.md#public-claim-comment-fallback);
  a marker body alone is never ownership proof.
  In replacement carryover, run that conflict inspection independently on both
  `PRIMARY_PR_NUMBER` and `SOURCE_PR_NUMBER`, then post or refresh one separate
  claim comment on each PR before any non-claim mutation; a conflict or failed claim
  update on either PR blocks mutations on both. Otherwise post a PR issue
  comment using this marker shape only when a
  GitHub-mutating action is selected:

  ```markdown
  <!-- codex-claim v1
  batch: <BATCH_ID>
  machine: <MACHINE_ID>
  thread: <codex-thread-id>
  branch: <BRANCH_NAME>
  status: in_progress
  expires_at: <ISO8601_UTC>
  -->
  ```

  Use a stable session or thread identity; if none is available, use
  `thread: unavailable`, which cannot self-renew. Refresh only a comment with
  the matching stable identity; restart with an unavailable identity requires
  explicit reassignment. Set a short bounded advisory lease, usually 2-4 hours.
- At a stable stop, update every acquired private heartbeat or advisory claim
  state before reporting. For private coordination, send terminal heartbeats and
  release the claims on normal completion; preserve them for blocked or handoff
  states when the repo workflow requires preservation. For public fallback,
  edit the claim comments to a terminal status with an expired `expires_at`; a final
  address-review summary/status comment may link the terminal claim, but it must
  not be the only cleanup step.
