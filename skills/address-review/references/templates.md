# Address-Review Deferred And Summary Templates

Read this reference before preparing deferred-work tracking or posting a PR
summary/status checkpoint from the address-review workflow.
Keep this file host-neutral: host-adapter marker blocks and available-tool
syntax stay in `SKILL.md` or `workflows/address-review.md`, which are covered by
`bin/validate-host-adapter-syntax`.

## Step 9: Deferred-Work Tracking (when requested)

When the user chooses `f+i`, `m`, or explicitly asks for deferred tracking, prepare one deferred-work bundle first. Do not create a GitHub issue until the user chooses that tracking outcome.

Ask the user to choose one outcome:

- Link an existing issue
- Create one bundled follow-up issue
- Post a PR summary comment only
- Drop the bundle as not worth tracking

Only create a GitHub issue after the user chooses "create one bundled follow-up issue".

Resolve the user's tracking-outcome choice before starting the shell block below. **Run Steps 9 and 10 in a single shell call after that choice is known.** They share state — `${TRACKING_OUTCOME}` and `${FOLLOW_UP_URL}` set in Step 9 are consumed by Step 10's summary template, `${issue_body_file}`, `${summary_body_file}`, and the optional `${source_summary_body_file}` share an EXIT trap, and the `_cleanup_addr_review` function is defined once. Agents that execute each Bash tool call in a fresh subshell (the default in Claude Code and similar harnesses) will lose those variables between calls and trigger Step 9's cleanup trap before Step 10 runs. Combine both steps into one heredoc/chained invocation, or capture Step 9's tracking output from stdout and pass it explicitly into Step 10's invocation.

The cleanup trap below is a named `_cleanup_addr_review` function rather than an inline `trap '...' EXIT` so Step 10's standalone path can redefine the same function without divergence. Installing the trap up front (rather than letting Step 10 replace it) closes the race window where an early exit between Step 9 and Step 10 would skip cleanup of summary temp files.

```bash
# Template inputs: replace each <...> placeholder before running this snippet.
# Set CREATE_FOLLOW_UP_ISSUE=1 only when the user chose "create one bundled follow-up issue".
# For the other outcomes, set TRACKING_OUTCOME to the exact chosen result, such as:
#   TRACKING_OUTCOME="existing issue https://github.com/org/repo/issues/123"
#   TRACKING_OUTCOME="PR summary comment only"
#   TRACKING_OUTCOME="dropped"
CREATE_FOLLOW_UP_ISSUE="${CREATE_FOLLOW_UP_ISSUE:-0}"
TRACKING_OUTCOME="${TRACKING_OUTCOME:-}"
# Use single-quoted heredocs so pasted review text is treated as literal content.
DISCUSS_ITEMS="$(cat <<'EOF'
<DISCUSS_ITEMS_BULLETS_OR_EMPTY>
EOF
)"
OPTIONAL_ITEMS="$(cat <<'EOF'
<OPTIONAL_ITEMS_BULLETS_OR_EMPTY>
EOF
)"
SKIPPED_ITEMS="$(cat <<'EOF'
<SKIPPED_ITEMS_BULLETS_OR_EMPTY>
EOF
)"

# For `f+i`, keep this empty. For `m`, include a heading and deferred must-fix bullets.
MUST_FIX_SECTION="$(cat <<'EOF'
<MUST_FIX_SECTION_OR_EMPTY>
EOF
)"

DISCUSS_SECTION=""
if [ -n "${DISCUSS_ITEMS}" ]; then
  DISCUSS_SECTION="### Discuss items
${DISCUSS_ITEMS}
"
fi

OPTIONAL_SECTION=""
if [ -n "${OPTIONAL_ITEMS}" ]; then
  OPTIONAL_SECTION="### Optional items
${OPTIONAL_ITEMS}
"
fi

SKIPPED_SECTION=""
if [ -n "${SKIPPED_ITEMS}" ]; then
  SKIPPED_SECTION="### Skipped items (non-trivial)
${SKIPPED_ITEMS}
"
fi

if [ -z "${MUST_FIX_SECTION}${DISCUSS_SECTION}${OPTIONAL_SECTION}${SKIPPED_SECTION}" ]; then
  echo "No deferred items found; skip deferred tracking."
else
  issue_body_file="$(mktemp)"
  # Cleanup covers issue and primary/source summary temp files; Step 10 redefines it for the standalone path.
  _cleanup_addr_review() {
    [ -n "${issue_body_file:-}" ]   && rm -f "${issue_body_file}"
    [ -n "${summary_body_file:-}" ] && rm -f "${summary_body_file}"
    [ -n "${source_summary_body_file:-}" ] && rm -f "${source_summary_body_file}"
  }
  trap _cleanup_addr_review EXIT
  # Build the issue body with printf only — avoids bash-only ANSI-C quoting
  # (e.g., $'\n\n') which expands to a literal "$\n\n" under POSIX sh (dash).
  {
    printf '## Deferred review feedback from PR #%s\n\n' "${PR_NUMBER}"
    printf 'These items were triaged during review and deferred for follow-up.\n\n'
    printed_first=0
    for section in "${MUST_FIX_SECTION}" "${DISCUSS_SECTION}" "${OPTIONAL_SECTION}" "${SKIPPED_SECTION}"; do
      [ -z "${section}" ] && continue
      if [ "${printed_first}" -eq 1 ]; then
        printf '\n\n'
      fi
      printf '%s' "${section}"
      printed_first=1
    done
    printf '\n\n'
    printf -- '---\n'
    printf 'Original PR: https://github.com/%s/pull/%s\n' "${REPO}" "${PR_NUMBER}"
  } > "${issue_body_file}"

  if [ "${CREATE_FOLLOW_UP_ISSUE}" = "1" ]; then
    # Best-effort: catch broken newline escapes from escaped shell strings
    # before posting an issue body. Fenced code blocks whose indented fences
    # start with three or more backticks or tildes and inline code spans are
    # ignored; build the body with printf/heredocs.
    backtick_fence_count=$(grep -cE '^[[:space:]]*`{3,}' "${issue_body_file}" || true)
    tilde_fence_count=$(grep -cE '^[[:space:]]*~{3,}' "${issue_body_file}" || true)
    if [ $((backtick_fence_count % 2)) -ne 0 ] || [ $((tilde_fence_count % 2)) -ne 0 ]; then
      echo "Refusing to create issue: body has an unclosed fenced code block." >&2
      echo "Inspect and fix ${issue_body_file} before retrying." >&2
      exit 1
    fi
    if matched_newline_escapes=$(
      sed -E '/^[[:space:]]*`{3,}/,/^[[:space:]]*`{3,}/d' "${issue_body_file}" \
        | sed -E '/^[[:space:]]*~{3,}/,/^[[:space:]]*~{3,}/d' \
        | sed 's/``[^`]*``//g' \
        | sed 's/`[^`]*`//g' \
        | grep -nE '\\n'
    ); then
      echo "Refusing to create issue: body contains likely literal \\n escape sequences:" >&2
      printf '%s\n' "${matched_newline_escapes}" >&2
      echo "Inspect and fix ${issue_body_file} before retrying." >&2
      exit 1
    fi
    # FOLLOW_UP_PREFIX has no safe default; resolve it from the repo seam before creating issues.
    FOLLOW_UP_PREFIX="${FOLLOW_UP_PREFIX:?set FOLLOW_UP_PREFIX from .agents/agent-workflow.yml follow_up_prefix}"
    FOLLOW_UP_URL=$(gh issue create --repo "${REPO}" --title "${FOLLOW_UP_PREFIX} Review feedback from PR #${PR_NUMBER}" --body-file "${issue_body_file}")
    TRACKING_OUTCOME="new issue ${FOLLOW_UP_URL}"
  fi

  if [ -z "${TRACKING_OUTCOME}" ]; then
    echo "Refusing to continue: deferred items exist but TRACKING_OUTCOME is not set." >&2
    echo "Set TRACKING_OUTCOME to the chosen existing-issue, PR-summary-only, or dropped outcome before running this snippet." >&2
    exit 1
  fi
fi
```

Rules for follow-up issues:

- Follow-up issues are expensive; default to no new issue.
- Prefer linking an existing issue over creating a new one.
- Create at most one follow-up issue per PR by default. More than one follow-up issue requires explicit user approval.
- Every new follow-up issue title must begin with the repo's follow-up issue prefix (see `follow_up_prefix` in `.agents/agent-workflow.yml`).
- Build multi-line issue bodies with `--body-file`; never pass escaped newline strings through `--body`.
- Only include non-trivial `SKIPPED` items (skip pure duplicates and factually incorrect suggestions)
- For `f+i`, omit the must-fix section because must-fix items were addressed in the current PR
- For `m`, include a must-fix section with heading `### Must-fix items (deferred)` and deferred blockers
- Omit any section heading when its corresponding item list is empty
- Include the original reviewer username and comment link for each item
- Include enough context that someone can act on the issue without re-reading the full PR review
- Do not include pure duplicates, factually incorrect suggestions, style nits, status noise, or weak "could consider" comments
- After the user chooses a tracking outcome, reference that outcome in thread replies: existing issue, new issue URL, PR summary comment, or "not tracking"
- Capture every outcome into `TRACKING_OUTCOME`; for the create-new-issue path, also capture `gh issue create` output into `FOLLOW_UP_URL` and include it in `TRACKING_OUTCOME`
- Return the selected tracking outcome and issue URL if one was created

## Step 10: Post PR Summary Comment

After any chosen action or completed action chain except `a` and inspect-only
bare `o` (`f`, `f+i`, `f+o`, `d`, selected `o`, `r`, `m`, or direct item
selection), post either a marked cutoff-safe summary comment or, when the
cutoff guard below is not satisfied, a non-cutoff status comment.

For `a`, do not post a GitHub PR summary comment automatically; return the local summary to the user with the staged-file list and detailed `DISCUSS` recommendations.

For replacement carryover, build a distinct source checkpoint in addition to
the normal primary checkpoint. A source checkpoint is cutoff-safe only when every source item has a terminal handled, deferred, declined, or other explicitly safe-to-skip outcome; any pending, `ask user`, or user-pending source item requires a non-cutoff status and remains eligible for the next source scan.
Use `SOURCE_CUTOFF_SAFE`, not the primary `CUTOFF_SAFE`, for that decision.
Each source-state row is exactly `item<TAB><source-pr><kind><item-id><thread-id-or-><latest-activity-rfc3339><outcome>` under `<!-- address-review-source-state:v1`; kinds are `issue-comment`, `inline-comment`, or `review-summary`, and outcomes are `handled`, `deferred`, `declined`, `safe-to-skip`, `pending`, or `ask-user`.
Validate the source PR and item ID as positive decimals, the thread ID as a GitHub node ID or `-`, the activity timestamp as RFC3339, the enum fields, stable-identity uniqueness, and snapshot completeness before consuming or posting state.
Missing, duplicate, malformed, identity-mismatched, or incomplete source state suppresses no item and makes source readiness `UNKNOWN` until corrected; a status checkpoint never acts as a global cutoff.
Every new source checkpoint carries forward unchanged valid rows and records every source candidate since `SOURCE_REVIEW_CUTOFF_AT`, including pending rows, so the latest checkpoint is a complete restart snapshot rather than a delta.
Set `SOURCE_STATE_ROWS` from that cumulative verified snapshot and
`SOURCE_STATE_EXPECTED_COUNT` to its exact row count. Zero candidates use an
empty, explicitly set `SOURCE_STATE_ROWS` and count `0`.

A marked summary comment is a cutoff checkpoint. Post one only after every
review item before that checkpoint is safe for future default scans to skip:
addressed, resolved, deferred/tracked, declined with rationale, or explicitly
left pending by user choice in a way recorded on the original thread. If
selected optional handling leaves older optional threads pending/unselected
without that thread-level outcome, post a non-cutoff status comment instead and
tell the next run to use `check all reviews`; do not advance the cutoff.

Rules for the summary comment:

- Always post it as a general PR issue comment, never as a review-thread reply.
- Include the exact marker `<!-- address-review-summary -->` as the first line
  only for cutoff-safe summaries. If older optional items remain
  pending/unselected without a thread-level outcome, use
  `<!-- address-review-status -->` as the first line, call the comment a
  non-cutoff status, and tell the next run to use `check all reviews`.
- Summarize `MUST-FIX` and `DISCUSS` items under a `Mattered` section, including whether each item was addressed, deferred, or left pending by user choice.
- Summarize `OPTIONAL` items under an `Optional` section when any optional item
  has a recorded outcome or is intentionally left pending/unselected by the
  chosen action. Include whether each acted-on item was fixed inline, deferred
  to tracking, deferred/declined under the attention contract, declined, or
  still pending after a selected optional action. For all-pending/no-action
  optional items, use a count-only line such as
  `- N optional items remain pending/unselected from triage; no action taken this run.`
  only in a non-cutoff status comment, or after each pending/unselected optional
  thread has an explicit reply/resolve/defer/decline outcome that makes it safe
  to skip on later default scans. Do not apply this rule to inspect-only bare
  `o`, which posts no checkpoint.
- Summarize `SKIPPED` items under a `Skipped` section with short reasons.
- Mention any deferred-work tracking outcome and follow-up issue URL that was created.
- Mention whether the run used the default cutoff or the explicit `check all reviews` override.
- For marked summaries, end with a note that future full-PR scans should start
  after this comment unless the user says `check all reviews`. For unmarked
  status comments, end with a note that the next run must use
  `check all reviews`.

Suggested marked-summary structure for the cutoff-safe path. As called out in Step 9, run Steps 9 and 10 in the same shell call so `${TRACKING_OUTCOME}`, `${FOLLOW_UP_URL}`, and the EXIT trap persist; otherwise capture the tracking values from Step 9's stdout and pass them in explicitly. `_cleanup_addr_review` is redefined here to cover the standalone-Step-10 path (when Step 9 was skipped and `issue_body_file` is unset). Redefining the same function is harmless if Step 9 already defined it; the `[ -n ... ]` guards keep `rm -f ""` out of the picture on shells that reject empty path arguments. If the cutoff guard is not satisfied, use the status marker instead of the cutoff marker and end with a `check all reviews` note instead of posting a checkpoint.

```bash
summary_body_file="$(mktemp)"
source_summary_body_file=""
# Cleanup mirrors Step 9's definition for the standalone-Step-10 path.
_cleanup_addr_review() {
  [ -n "${issue_body_file:-}" ]   && rm -f "${issue_body_file}"
  [ -n "${summary_body_file:-}" ] && rm -f "${summary_body_file}"
  [ -n "${source_summary_body_file:-}" ] && rm -f "${source_summary_body_file}"
}
trap _cleanup_addr_review EXIT
if [ -n "${SOURCE_PR_NUMBER:-}" ]; then
  source_summary_body_file="$(mktemp)"
fi
# Set SCAN_SCOPE before this block, e.g.:
#   SCAN_SCOPE="since previous summary at ${REVIEW_CUTOFF_AT}"  # cutoff active
#   SCAN_SCOPE="full history via check all reviews"              # CHECK_ALL_REVIEWS set
# Set CUTOFF_SAFE=1 only after verifying the cutoff guard; leave 0 for a non-cutoff status.
CUTOFF_SAFE="${CUTOFF_SAFE:-0}"
# Set OPTIONAL_OUTCOMES to bullets for optional items with recorded outcomes or
# intentionally pending/unselected by the chosen action: fixed, explicitly
# handled, autonomously deferred/declined, declined, deferred to tracking, or
# still pending after a selected optional action. If every optional item remains
# pending/unselected with no action, use a count-only bullet only after those
# threads have explicit outcomes or in the unmarked-status path:
# "- N optional items remain pending/unselected from triage; no action taken this run."
# Leave empty only when there were no optional items in scope.
{
  if [ "${CUTOFF_SAFE:-0}" = "1" ]; then
    printf '<!-- address-review-summary -->\n'
  else
    printf '<!-- address-review-status -->\n'
  fi
  printf '## Address-review summary\n\n'
  printf 'Scan scope: %s\n\n' "${SCAN_SCOPE}"
  printf '### Mattered\n'
  printf '%s\n\n' "<bullets for must-fix/discuss outcomes, or - None.>"
  if [ -n "${OPTIONAL_OUTCOMES:-}" ]; then
    printf '### Optional\n'
    printf '%s\n\n' "${OPTIONAL_OUTCOMES}"
  fi
  printf '### Skipped\n'
  printf '%s\n\n' "<bullets for skipped items, or - None.>"
  if [ -n "${TRACKING_OUTCOME:-}" ]; then
    printf 'Deferred-work tracking: %s\n\n' "${TRACKING_OUTCOME}"
  fi
  if [ "${CUTOFF_SAFE:-0}" = "1" ]; then
    printf 'Next default scan starts after this comment. Say `check all reviews` to rescan the full PR.\n'
  else
    printf 'Non-cutoff status only. The next review pass must use `check all reviews`.\n'
  fi
} > "${summary_body_file}"

if [ -n "${SOURCE_PR_NUMBER:-}" ]; then
  case "${SOURCE_PR_NUMBER}" in
    ''|0|0[0-9]*|*[!0-9]*)
      echo "SOURCE_PR_NUMBER must be a positive decimal; readiness UNKNOWN." >&2
      exit 1
      ;;
  esac
  SOURCE_CUTOFF_SAFE="${SOURCE_CUTOFF_SAFE:-0}"
  case "${SOURCE_CUTOFF_SAFE}" in
    0|1) ;;
    *)
      echo "SOURCE_CUTOFF_SAFE must be 0 or 1; readiness UNKNOWN." >&2
      exit 1
      ;;
  esac
  : "${REPLACEMENT_PR_URL:?set REPLACEMENT_PR_URL for source carryover}"
  : "${SOURCE_OUTCOMES:?set SOURCE_OUTCOMES to explicit source-item outcome bullets}"
  : "${SOURCE_STATE_ROWS?set SOURCE_STATE_ROWS to the cumulative v1 source snapshot}"
  : "${SOURCE_STATE_EXPECTED_COUNT:?set SOURCE_STATE_EXPECTED_COUNT from the verified source candidate set}"
  case "${SOURCE_STATE_EXPECTED_COUNT}" in
    ''|*[!0-9]*|0[0-9]*)
      echo "Source state is incomplete: SOURCE_STATE_EXPECTED_COUNT must be a canonical non-negative integer; readiness UNKNOWN." >&2
      exit 1
      ;;
  esac
  if [ "${SOURCE_STATE_EXPECTED_COUNT}" = "0" ]; then
    if [ -n "${SOURCE_STATE_ROWS}" ]; then
      echo "Source state is incomplete: expected zero rows; readiness UNKNOWN." >&2
      exit 1
    fi
    SOURCE_STATE_ROW_COUNT=0
  else
    if ! SOURCE_STATE_ROW_COUNT="$(printf '%s\n' "${SOURCE_STATE_ROWS}" | awk -F '\t' -v source="${SOURCE_PR_NUMBER}" '
      function valid_kind(v) { return v == "issue-comment" || v == "inline-comment" || v == "review-summary" }
      function valid_outcome(v) { return v == "handled" || v == "deferred" || v == "declined" || v == "safe-to-skip" || v == "pending" || v == "ask-user" }
      /^$/ { next }
      {
        key = $2 SUBSEP $3 SUBSEP $4
        if (NF != 7 || $1 != "item" || $2 != source || !valid_kind($3) ||
            $4 !~ /^[1-9][0-9]*$/ || ($5 != "-" && $5 !~ /^[A-Za-z0-9_=+\/-]+$/) ||
            $6 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?(Z|[+-][0-9][0-9]:[0-9][0-9])$/ ||
            !valid_outcome($7) || seen[key]++) exit 1
        count++
      }
      END { print count + 0 }
    ')"; then
      echo "The source-state rows are malformed or duplicate; readiness UNKNOWN." >&2
      exit 1
    fi
  fi
  if [ "${SOURCE_STATE_ROW_COUNT}" != "${SOURCE_STATE_EXPECTED_COUNT}" ]; then
    echo "Source state is incomplete: expected ${SOURCE_STATE_EXPECTED_COUNT} rows, got ${SOURCE_STATE_ROW_COUNT}; readiness UNKNOWN." >&2
    exit 1
  fi
  SOURCE_STATE_HAS_PENDING=0
  if [ -n "${SOURCE_STATE_ROWS}" ] && printf '%s\n' "${SOURCE_STATE_ROWS}" | awk -F '\t' '$7 == "pending" || $7 == "ask-user" { found = 1 } END { exit(found ? 0 : 1) }'; then
    SOURCE_STATE_HAS_PENDING=1
    SOURCE_CUTOFF_SAFE=0
  fi
  {
    if [ "${SOURCE_CUTOFF_SAFE}" = "1" ]; then
      printf '<!-- address-review-summary -->\n'
    else
      printf '<!-- address-review-status -->\n'
    fi
    printf '## Address-review replacement carryover\n\n'
    printf 'Replacement PR: %s\n\n' "${REPLACEMENT_PR_URL}"
    printf '### Original PR outcomes\n'
    printf '%s\n\n' "${SOURCE_OUTCOMES}"
    if [ "${SOURCE_CUTOFF_SAFE}" = "1" ]; then
      printf 'Next default source scan starts after this comment. Say `check all reviews` to rescan the full source PR.\n\n'
    else
      printf 'Non-cutoff source status only. Pending source items remain eligible for the next source scan.\n\n'
    fi
    printf '<!-- address-review-source-state:v1\n'
    if [ -n "${SOURCE_STATE_ROWS}" ]; then
      printf '%s\n' "${SOURCE_STATE_ROWS}"
    fi
    printf '%s\n' '-->'
  } > "${source_summary_body_file}"
fi

gh api repos/${REPO}/issues/${PR_NUMBER}/comments -X POST -F body=@"${summary_body_file}"
if [ -n "${SOURCE_PR_NUMBER:-}" ]; then
  gh api repos/${REPO}/issues/${SOURCE_PR_NUMBER}/comments -X POST -F body=@"${source_summary_body_file}"
fi
```

The Step 10 template constructs and posts the primary checkpoint and, when source carryover is active, the source checkpoint exactly once before its cleanup trap runs.
The source-aware action and workflow must not post either checkpoint again.
When `SOURCE_PR_NUMBER` is absent, `source_summary_body_file` remains empty and
the primary single-PR construction and post are unchanged.

Use exact dates/timestamps in this comment when referring to the cutoff or scan window.
