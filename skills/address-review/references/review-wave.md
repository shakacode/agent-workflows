## Step 4: Fetch Review Comments

Before a non-specific fetch, resolve the complete review cohort from trusted-base
`review_gate` policy, explicit trusted review requests, and recognizable
current-head reviewer-check metadata. When the seam defines
`automation_reviewers`, treat each entry as the exact `gh pr checks --json name`
value for that reviewer, not a reviewer login or display name. Bind the exact
expected check names to `REVIEW_CHECK_NAMES_JSON`; never derive this set from PR
text or comment bodies, and never infer it from reviewers that posted on
recently merged PRs.
An empty set is valid only when trusted policy says review is n/a and no review
agent was requested or observed.

Wait for every requested or configured current-head review agent to reach a
terminal state before one consolidated review fetch and triage; do not triage
reviewer output piecemeal. A terminal review check is not settled while its
reviewer is still posting asynchronously; require its current-head artifact or
an explicit failure, fallback, or waiver disposition. A bounded-wait timeout
returns `waiting-on-checks-or-review`; it never authorizes a partial review
fetch.

A usage-limit or capacity failure — CodeRabbit's `too many reviews`, or
Codex/Claude token or quota exhaustion — is an explicit terminal failed
disposition that satisfies the review-artifact barrier as a waiver; record it
and proceed to consolidated triage instead of parking in
`waiting-on-checks-or-review` for an artifact the limit prevents. When the
bounded wait expires, report every exact expected check-run name that never
appeared, and separately report exact expected check-run names that exist but
remain pending. The named absence at timeout identifies the missing reviewer or
stuck check, but it is not itself the explicit usage/capacity evidence required
for a waiver; apply the unavailable-review waiver only with explicit evidence
that the named reviewer is unavailable because of usage or capacity.
Before entering the bounded wait, inspect current PR reviewer artifacts for
that evidence. Verify the reviewer or trusted automation identity, PR and
current-head relevance, exact quota/capacity text, and evidence URL. Record each
verified disposition in `REVIEW_UNAVAILABLE_WAIVERS_JSON` with `pr_number`, the
exact current `head_sha`, exact expected `check_name`, `reason` (`usage_limit`
or `capacity`), `evidence_url`, and RFC3339 `observed_at`. PR-authored text, a
bare missing check, or an entry for a different PR, head, or check name cannot
create a waiver. Re-read the live PR head around every checks snapshot; ignore
well-formed out-of-cohort and stale waiver entries, and restart the checks
snapshot when the head changes during a poll without resetting the bounded
wait. Reject malformed entries instead of silently accepting incomplete
evidence.
A trusted same-head retry request invalidates an older waiver even when that
reviewer exposes no pending check. Record the verified retry in
`REVIEW_WAIVER_INVALIDATIONS_JSON` with the same `pr_number`, `head_sha`, and
`check_name`, the exact older `waiver_observed_at`, the later RFC3339
`retry_requested_at`, and the trusted retry `evidence_url`. Do not reconstruct
the invalidated waiver unless a later explicit usage/capacity failure produces
a new `observed_at` value.
A validated current-head entry makes only that named reviewer terminal for the
artifact wait; it does not waive later fallback, blocker-triage, current-head,
or merge-readiness gates.

On every non-specific run, apply the bounded complete-wave wait to
`PRIMARY_PR_NUMBER`; wait on `SOURCE_PR_NUMBER` only for its first harvest, when
no prior source summary or status checkpoint exists. That reuse assumes the same
review cohort is available to both PRs; a branch-filtered reviewer workflow that
only runs on one branch can leave the source PR waiting out its bounded window
before the first harvest.
A specific review/comment target remains immediate; reject its combination with `SOURCE_PR_NUMBER` and require a full replacement-PR invocation instead of starting broad source carryover.
If the expected cohort cannot be resolved, or `gh pr checks` is unavailable or
returns an error, return `waiting-on-checks-or-review` with `UNKNOWN` evidence
instead of fetching partial feedback.

```bash
# Block while any exact expected review check is missing, queued, or running.
# Pass --repo so cross-repo PR URLs target the parsed REPO, not the current checkout.
# `MAX_WAIT` caps each PR wait; timeout returns a resumable nonterminal state.
if [ "${SPECIFIC_TARGET}" = "1" ] && [ -n "${SOURCE_PR_NUMBER}" ]; then
  echo "Replacement carryover requires a full replacement-PR target" >&2
  exit 1
fi
if [ "${SPECIFIC_TARGET}" != "1" ]; then
  SOURCE_HAS_CHECKPOINT=0
  if [ -n "${SOURCE_PR_NUMBER}" ]; then
    if SOURCE_CHECKPOINT_JSON="$(gh api --paginate --slurp "repos/${REPO}/issues/${SOURCE_PR_NUMBER}/comments" 2>/dev/null)"; then
      SOURCE_REVIEW_ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
      SOURCE_CHECKPOINT_COUNT="$(printf '%s' "${SOURCE_CHECKPOINT_JSON}" | jq --arg actor "${SOURCE_REVIEW_ACTOR}" --arg source "${SOURCE_PR_NUMBER}" '
        def valid_kind: . == "issue-comment" or . == "inline-comment" or . == "review-summary";
        def valid_outcome: . == "handled" or . == "deferred" or . == "declined" or . == "safe-to-skip" or . == "pending" or . == "ask-user";
        def terminal_outcome: . == "handled" or . == "deferred" or . == "declined" or . == "safe-to-skip";
        def terminal_row: split("\t") | .[6] | terminal_outcome;
        def valid_row:
          split("\t") as $fields |
          ($fields | length) == 7 and
          $fields[0] == "item" and $fields[1] == $source and
          ($fields[2] | valid_kind) and
          ($fields[3] | test("^[1-9][0-9]*$")) and
          ($fields[4] == "-" or ($fields[4] | test("^[A-Za-z0-9_=+/-]+$"))) and
          ($fields[5] | test("^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\\.[0-9]+)?(Z|[+-][0-9][0-9]:[0-9][0-9])$")) and
          ($fields[6] | valid_outcome);
        def valid_body:
          . as $body |
          (($body | startswith("<!-- address-review-summary -->")) or
           ($body | startswith("<!-- address-review-status -->"))) and
          ([ $body | scan("(?m)^<!-- address-review-source-state:v1$") ] | length) == 1 and
          (($body | capture("(?m)^<!-- address-review-source-state:v1\\n(?<rows>(?:item\\t[^\\r\\n]*\\n)*)-->$")?) as $state |
            $state != null and
            (($state.rows | split("\n") | map(select(length > 0))) as $rows |
              all($rows[]; valid_row) and
              (($body | startswith("<!-- address-review-status -->")) or
               (($body | startswith("<!-- address-review-summary -->")) and all($rows[]; terminal_row))) and
              (($rows | map(split("\t") | .[1:4] | join("\t")) | unique | length) == ($rows | length))));
        [.[][] |
          select(((.user.login // "") | ascii_downcase) == ($actor | ascii_downcase)) |
          select((.body // "") | valid_body)] | length
      ' 2>/dev/null || echo 0)"
      case "${SOURCE_CHECKPOINT_COUNT}" in
        ''|*[!0-9]*) SOURCE_CHECKPOINT_COUNT=0 ;;
      esac
      if [ -n "${SOURCE_REVIEW_ACTOR}" ] && [ "${SOURCE_CHECKPOINT_COUNT}" -gt 0 ]; then
        SOURCE_HAS_CHECKPOINT=1
      elif [ -z "${SOURCE_REVIEW_ACTOR}" ]; then
        echo "Warning: could not resolve the expected review actor for source checkpoints; treating PR #${SOURCE_PR_NUMBER} as first harvest." >&2
      fi
    else
      echo "Warning: could not probe source checkpoints for PR #${SOURCE_PR_NUMBER}; treating it as first harvest for the review wait." >&2
    fi
  fi
  REVIEW_WAIT_PRS="${PRIMARY_PR_NUMBER}"
  if [ -n "${SOURCE_PR_NUMBER}" ] && [ "${SOURCE_HAS_CHECKPOINT}" != "1" ]; then
    REVIEW_WAIT_PRS="${REVIEW_WAIT_PRS} ${SOURCE_PR_NUMBER}"
  fi
  # `REVIEW_CHECK_NAMES_JSON` must already contain exact `gh pr checks --json name`
  # values, not reviewer logins or display names.
  if ! printf '%s' "${REVIEW_CHECK_NAMES_JSON:-}" |
    jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' >/dev/null; then
    echo "waiting-on-checks-or-review: configured review cohort is UNKNOWN" >&2
    exit 2
  fi
  # Populate this only after inspecting trusted reviewer/automation artifacts.
  # Keep the default empty: absence alone never creates a waiver.
  REVIEW_UNAVAILABLE_WAIVERS_JSON="${REVIEW_UNAVAILABLE_WAIVERS_JSON:-[]}"
  REVIEW_WAIVER_INVALIDATIONS_JSON="${REVIEW_WAIVER_INVALIDATIONS_JSON:-[]}"
  if ! printf '%s' "${REVIEW_UNAVAILABLE_WAIVERS_JSON}" |
    jq -e --arg host "${GH_HOST}" --arg repo "${REPO}" '
      type == "array" and
      all(.[];
        . as $waiver |
        ($waiver | type == "object") and
        ($waiver.pr_number | type == "number" and . > 0 and floor == .) and
        ($waiver.head_sha | type == "string" and test("^[0-9a-f]{40}$")) and
        ($waiver.check_name | type == "string" and length > 0) and
        ($waiver.reason == "usage_limit" or $waiver.reason == "capacity") and
        ($waiver.evidence_url | type == "string" and startswith("https://\($host)/\($repo)/pull/\($waiver.pr_number)#")) and
        ($waiver.observed_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")))
    ' >/dev/null; then
    echo "waiting-on-checks-or-review: unavailable-review waiver evidence is malformed" >&2
    exit 2
  fi
  if ! printf '%s' "${REVIEW_WAIVER_INVALIDATIONS_JSON}" |
    jq -e --arg host "${GH_HOST}" --arg repo "${REPO}" '
      def rfc3339_epoch:
        capture("^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})(?:\\.(?<fraction>[0-9]+))?(?<zone>Z|(?<sign>[+-])(?<offset_hour>[0-9]{2}):(?<offset_minute>[0-9]{2}))$") as $timestamp |
        ([$timestamp.year, $timestamp.month, $timestamp.day, $timestamp.hour, $timestamp.minute, $timestamp.second, 0, 0] |
          map(tonumber) |
          .[1] -= 1 |
          mktime) +
        (if ($timestamp.fraction // "") == "" then 0 else ("0." + $timestamp.fraction | tonumber) end) -
        (if $timestamp.zone == "Z" then 0
         else ((($timestamp.offset_hour | tonumber) * 60 + ($timestamp.offset_minute | tonumber)) * 60) *
           (if $timestamp.sign == "+" then 1 else -1 end)
         end);
      type == "array" and
      all(.[];
        . as $invalidation |
        ($invalidation | type == "object") and
        ($invalidation.pr_number | type == "number" and . > 0 and floor == .) and
        ($invalidation.head_sha | type == "string" and test("^[0-9a-f]{40}$")) and
        ($invalidation.check_name | type == "string" and length > 0) and
        ($invalidation.waiver_observed_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")) and
        ($invalidation.retry_requested_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")) and
        (try (($invalidation.retry_requested_at | rfc3339_epoch) >
          ($invalidation.waiver_observed_at | rfc3339_epoch)) catch false) and
        ($invalidation.evidence_url | type == "string" and startswith("https://\($host)/\($repo)/pull/\($invalidation.pr_number)#")))
    ' >/dev/null; then
    echo "waiting-on-checks-or-review: review-waiver invalidation evidence is malformed" >&2
    exit 2
  fi
  for REVIEW_WAIT_PR in ${REVIEW_WAIT_PRS}; do
    MAX_WAIT=180
    WAITED=0
    REVIEW_REPORTED_WAIVER_HEAD_SHA=""
    while :; do
      if ! REVIEW_WAIT_HEAD_SHA="$(gh pr view "${REVIEW_WAIT_PR}" --repo "${REPO}" --json headRefOid --jq .headRefOid 2>/dev/null)" ||
        ! printf '%s' "${REVIEW_WAIT_HEAD_SHA}" | grep -Eq '^[0-9a-f]{40}$'; then
        if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
          echo "waiting-on-checks-or-review: current head remained UNKNOWN for PR #${REVIEW_WAIT_PR} during the ${MAX_WAIT}s bounded wait" >&2
          exit 2
        fi
        echo "Current head is temporarily UNKNOWN for PR #${REVIEW_WAIT_PR}; retrying after bounded backoff." >&2
        sleep 15
        WAITED=$((WAITED + 15))
        continue
      fi
      REVIEW_WAIVED_CHECK_NAMES_JSON="$(printf '%s' "${REVIEW_UNAVAILABLE_WAIVERS_JSON}" |
        jq -c --argjson pr "${REVIEW_WAIT_PR}" --arg head "${REVIEW_WAIT_HEAD_SHA}" --argjson expected "${REVIEW_CHECK_NAMES_JSON}" --argjson invalidations "${REVIEW_WAIVER_INVALIDATIONS_JSON}" '
          [.[] |
            . as $waiver |
            select(.pr_number == $pr and .head_sha == $head) |
            select(any($invalidations[];
              .pr_number == $waiver.pr_number and .head_sha == $waiver.head_sha and
              .check_name == $waiver.check_name and .waiver_observed_at == $waiver.observed_at) | not) |
            .check_name as $name |
            select($expected | index($name) != null) |
            $name
          ] | unique')"
      if REVIEW_CHECKS_JSON="$(gh pr checks "${REVIEW_WAIT_PR}" --repo "${REPO}" --json name,bucket 2>/dev/null)"; then
        REVIEW_CHECKS_STATUS=0
      else
        REVIEW_CHECKS_STATUS=$?
      fi
      case "${REVIEW_CHECKS_STATUS}" in
        0|1|8) ;;
        *)
          echo "waiting-on-checks-or-review: review-check state is UNKNOWN for PR #${REVIEW_WAIT_PR}" >&2
          exit 2
          ;;
      esac
      if ! printf '%s' "${REVIEW_CHECKS_JSON}" | jq -e 'type == "array"' >/dev/null; then
        echo "waiting-on-checks-or-review: malformed review-check state for PR #${REVIEW_WAIT_PR}" >&2
        exit 2
      fi
      if ! REVIEW_WAIT_HEAD_SHA_AFTER="$(gh pr view "${REVIEW_WAIT_PR}" --repo "${REPO}" --json headRefOid --jq .headRefOid 2>/dev/null)" ||
        ! printf '%s' "${REVIEW_WAIT_HEAD_SHA_AFTER}" | grep -Eq '^[0-9a-f]{40}$'; then
        if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
          echo "waiting-on-checks-or-review: current head remained UNKNOWN after checks snapshots for PR #${REVIEW_WAIT_PR} during the ${MAX_WAIT}s bounded wait" >&2
          exit 2
        fi
        echo "Current head is temporarily UNKNOWN after the checks snapshot for PR #${REVIEW_WAIT_PR}; retrying after bounded backoff." >&2
        sleep 15
        WAITED=$((WAITED + 15))
        continue
      fi
      if [ "${REVIEW_WAIT_HEAD_SHA_AFTER}" != "${REVIEW_WAIT_HEAD_SHA}" ]; then
        if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
          echo "waiting-on-checks-or-review: review head for PR #${REVIEW_WAIT_PR} kept changing during the ${MAX_WAIT}s bounded wait" >&2
          exit 2
        fi
        echo "Review head changed during checks snapshot for PR #${REVIEW_WAIT_PR}; retrying after bounded backoff."
        REVIEW_REPORTED_WAIVER_HEAD_SHA=""
        sleep 15
        WAITED=$((WAITED + 15))
        continue
      fi
      if [ "$(printf '%s' "${REVIEW_WAIVED_CHECK_NAMES_JSON}" | jq 'length')" -gt 0 ] &&
        [ "${REVIEW_REPORTED_WAIVER_HEAD_SHA}" != "${REVIEW_WAIT_HEAD_SHA}" ]; then
        REVIEW_WAIVER_EVIDENCE="$(printf '%s' "${REVIEW_UNAVAILABLE_WAIVERS_JSON}" |
          jq -r --argjson pr "${REVIEW_WAIT_PR}" --arg head "${REVIEW_WAIT_HEAD_SHA}" --argjson expected "${REVIEW_CHECK_NAMES_JSON}" --argjson invalidations "${REVIEW_WAIVER_INVALIDATIONS_JSON}" '
            [.[] |
              . as $waiver |
              select(.pr_number == $pr and .head_sha == $head) |
              select(any($invalidations[];
                .pr_number == $waiver.pr_number and .head_sha == $waiver.head_sha and
                .check_name == $waiver.check_name and .waiver_observed_at == $waiver.observed_at) | not) |
              .check_name as $name |
              select($expected | index($name) != null) |
              "\($name)=\(.evidence_url)"
            ] | join(", ")')"
        echo "Review-artifact usage/capacity waiver for PR #${REVIEW_WAIT_PR} at ${REVIEW_WAIT_HEAD_SHA}: ${REVIEW_WAIVER_EVIDENCE}"
        REVIEW_REPORTED_WAIVER_HEAD_SHA="${REVIEW_WAIT_HEAD_SHA}"
      fi
      # Compare exact check-run names from `gh pr checks --json name`.
      REVIEW_WAVE_STATUS_JSON="$(printf '%s' "${REVIEW_CHECKS_JSON}" |
        jq -c --argjson expected "${REVIEW_CHECK_NAMES_JSON}" --argjson waived "${REVIEW_WAIVED_CHECK_NAMES_JSON}" '
          [ $expected[] as $name |
            ([.[] | select(.name == $name)]) as $checks |
            select(($waived | index($name)) == null or any($checks[]; .bucket == "pending")) |
            {
              name: $name,
              missing: (($checks | length) == 0),
              pending: (($checks | length) > 0 and any($checks[]; .bucket == "pending"))
            }
          ] as $states |
          {
            pending_count: ([$states[] | select(.missing or .pending)] | length),
            missing_names: ([$states[] | select(.missing) | .name] | join(", ")),
            pending_names: ([$states[] | select(.missing == false and .pending) | .name] | join(", "))
          }')"
      REVIEW_WAVE_PENDING="$(printf '%s' "${REVIEW_WAVE_STATUS_JSON}" | jq -r '.pending_count')"
      if [ "${REVIEW_WAVE_PENDING}" -eq 0 ]; then
        break
      fi
      if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        REVIEW_WAVE_MISSING_CHECK_NAMES="$(printf '%s' "${REVIEW_WAVE_STATUS_JSON}" | jq -r '.missing_names')"
        REVIEW_WAVE_PENDING_CHECK_NAMES="$(printf '%s' "${REVIEW_WAVE_STATUS_JSON}" | jq -r '.pending_names')"
        REVIEW_WAVE_MISSING_CHECK_NAMES="${REVIEW_WAVE_MISSING_CHECK_NAMES:-none}"
        REVIEW_WAVE_PENDING_CHECK_NAMES="${REVIEW_WAVE_PENDING_CHECK_NAMES:-none}"
        echo "waiting-on-checks-or-review: review wave for PR #${REVIEW_WAIT_PR} did not settle after ${MAX_WAIT}s; missing expected check-run names: ${REVIEW_WAVE_MISSING_CHECK_NAMES}; pending expected check-run names: ${REVIEW_WAVE_PENDING_CHECK_NAMES}" >&2
        exit 2
      fi
      echo "Waiting for complete review wave on PR #${REVIEW_WAIT_PR}... (${WAITED}s elapsed)"
      sleep 15
      WAITED=$((WAITED + 15))
    done
  done
fi
```

After the checks become terminal, take one final current-head reviewer-artifact
snapshot before triage. If a reviewer is known to post asynchronously and its
artifact or explicit no-findings/failure disposition is not yet observable,
return `waiting-on-checks-or-review`; do not fetch and triage the partial wave.
