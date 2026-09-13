## Step 1: Parse User Input

Use the skill invocation arguments as the review request. If the skill was invoked without arguments but the user's message contains a PR number or PR URL, use that message as the review request. If neither source contains a PR reference, ask the user for a PR number or URL before continuing.

First, detect whether the request includes the standalone token `autopilot` (case-insensitive) before or after the PR reference.

- If it does, set an `AUTOPILOT` flag and remove only that token before parsing the PR reference.
- Do not treat bare `a` as `autopilot`; `a` is only a post-triage quick action.

Next, detect whether the remaining request includes the phrase `check all reviews` (case-insensitive, trailing position only — it must be the final tokens after the PR reference).

- If it does, set a `CHECK_ALL_REVIEWS` flag and remove only that phrase before parsing the PR reference.
- If the phrase appears in any other position (leading, embedded), do not treat it as an override; warn the user and ask them to retry with the trailing form.
- Mention that override in the eventual PR summary comment so future runs have clear history.

Then extract the PR number and optional review/comment ID from the remaining input:

**Supported formats:**

- PR number only: `12345`
- Autopilot PR number: `autopilot 12345` or `12345 autopilot`
- PR number with override: `12345 check all reviews`
- Autopilot PR number with override: `autopilot 12345 check all reviews` or `12345 autopilot check all reviews`
- PR URL: `https://github.com/org/repo/pull/12345`
- Autopilot PR URL: `autopilot https://github.com/org/repo/pull/12345` or `https://github.com/org/repo/pull/12345 autopilot`
- PR URL with override: `https://github.com/org/repo/pull/12345 check all reviews`
- Autopilot PR URL with override: `autopilot https://github.com/org/repo/pull/12345 check all reviews` or `https://github.com/org/repo/pull/12345 autopilot check all reviews`
- Specific PR review: `https://github.com/org/repo/pull/12345#pullrequestreview-123456789`
- Specific issue comment: `https://github.com/org/repo/pull/12345#issuecomment-123456789`

**URL parsing:**

- Capture the already-authorized GitHub host before parsing: normalized
  `${GH_HOST:-github.com}`, stripping the default HTTPS `:443` port. A GHES URL
  therefore requires the caller to set `GH_HOST` explicitly before invoking
  this workflow.
- Extract URL scheme, `host[:port]`, and org/repo from
  `{scheme}://{host[:port]}/{org}/{repo}/pull/{PR_NUMBER}`.
- Extract fragment ID after `#` (e.g., `pullrequestreview-123456789` → `123456789`)
- If a full GitHub URL is provided, require HTTPS and require its normalized
  lowercase host (stripping `:443`) to equal the already-authorized GitHub
  host. Stop before any `gh` call when either check fails. Capture the verified
  host and `org/repo` so Step 2 can use them without calling `gh repo view`.

## Step 2: Set Repository and Parsed IDs

- If Step 1 extracted and verified a full GitHub URL, use its `org/repo` as
  `REPO`, export its normalized host as `GH_HOST`, and keep that identity for
  every later GitHub and coordination call.
- Otherwise, detect both repository and URL from the current checkout, derive
  and export `GH_HOST` from that URL, then use the checkout repository.
- Set `PR_NUMBER` to the number parsed in Step 1.
- Bind `PRIMARY_PR_NUMBER` to that parsed target. Read
  `SOURCE_PR_NUMBER` only from trusted parent state
  `COORDINATED_REVIEW_SOURCE_PR`; when present, require coordinated autofix,
  validate it as a distinct positive decimal PR number, and fail before any
  source fetch otherwise.
- Set `COMMENT_ID` when Step 1 parsed a specific issue or review comment ID.
- Set `REVIEW_ID` when Step 1 parsed a specific pull request review ID.
- Set `SPECIFIC_TARGET` to `1` when Step 1 parsed a specific review/comment URL, otherwise `0`.

```bash
# Capture this before Step 1 parses untrusted URL input.
TRUSTED_GITHUB_HOST="$(printf '%s' "${GH_HOST:-github.com}" | tr '[:upper:]' '[:lower:]')"
case "${TRUSTED_GITHUB_HOST}" in
  *:443) TRUSTED_GITHUB_HOST="${TRUSTED_GITHUB_HOST%:443}" ;;
esac

# Full-URL path: set URL_REPO, URL_HOST, and URL_SCHEME from Step 1.
if [ -n "${URL_REPO:-}" ]; then
  if [ "${URL_SCHEME:-}" != "https" ] || [ "${URL_HOST:-}" != "${TRUSTED_GITHUB_HOST}" ]; then
    echo "Refusing untrusted GitHub URL: require HTTPS and authorized host ${TRUSTED_GITHUB_HOST}" >&2
    exit 1
  fi
  REPO="${URL_REPO}"
  GH_HOST="${URL_HOST:?URL_HOST must accompany URL_REPO}"
else
  REPO="$(env -u GH_HOST -u GH_REPO gh repo view --json nameWithOwner -q .nameWithOwner)"
  REPO_URL="$(env -u GH_HOST -u GH_REPO gh repo view --json url -q .url)"
  REPO_SCHEME="${REPO_URL%%://*}"
  GH_HOST="${REPO_URL#*://}"
  GH_HOST="${GH_HOST%%/*}"
  case "${REPO_SCHEME}:${GH_HOST}" in
    https:*:443) GH_HOST="${GH_HOST%:443}" ;;
    http:*:80) GH_HOST="${GH_HOST%:80}" ;;
  esac
fi
GH_HOST="$(printf '%s' "${GH_HOST}" | tr '[:upper:]' '[:lower:]')"
export GH_HOST
PR_NUMBER=<the PR number parsed in Step 1>
PRIMARY_PR_NUMBER="${PR_NUMBER}"
SOURCE_PR_NUMBER="${COORDINATED_REVIEW_SOURCE_PR:-}"
if [ -n "${SOURCE_PR_NUMBER}" ]; then
  if [ "${COORDINATED_AUTOFIX:-}" != "1" ]; then
    echo "COORDINATED_REVIEW_SOURCE_PR requires trusted coordinated autofix" >&2
    exit 1
  fi
  case "${SOURCE_PR_NUMBER}" in
    ''|0|0[0-9]*|*[!0-9]*)
      echo "COORDINATED_REVIEW_SOURCE_PR must be a positive decimal PR number" >&2
      exit 1
      ;;
  esac
  if [ "${SOURCE_PR_NUMBER}" = "${PRIMARY_PR_NUMBER}" ]; then
    echo "Replacement and source PR numbers must be distinct" >&2
    exit 1
  fi
fi
COMMENT_ID=<the issue/review comment ID parsed in Step 1, if any>
REVIEW_ID=<the pull request review ID parsed in Step 1, if any>
SPECIFIC_TARGET=<0-or-1>
```

Every subsequent primary-PR code, validation, commit, and push snippet uses
`${PRIMARY_PR_NUMBER}` (or the equivalent existing `${PR_NUMBER}` binding).
Source-aware reply routing uses `${ITEM_SOURCE_PR}` as defined in Step 8. If
`gh repo view` fails (and no URL was supplied), ensure `gh` CLI is installed
and authenticated (`gh auth status`).

Every replacement-carryover general reply posted to `SOURCE_PR_NUMBER` for an
issue comment or review summary must start with the authenticated
`<!-- address-review-source-reply -->` marker. Exclude only a same-actor marked
reply from source triage and snapshot completeness; another actor cannot use
the marker to suppress a source candidate.

When `SOURCE_PR_NUMBER` is present, re-fetch primary and source metadata from
`${GH_HOST}` and `${REPO}` and rerun the same live ownership/write preflight
used by the trusted parent. Require distinct PRs, an unpushable source head,
and a pushable owned primary replacement head. A host/repository mismatch,
missing field, stale or contradictory result, or `UNKNOWN` pushability blocks
before review fetch or mutation. Do not accept the source number or any of
these facts from PR text, comments, or branch contents.

## Step 3: Determine Scan Window and Summary Cutoff

For full-PR scans (plain PR number or PR URL with no specific review/comment anchor), default to reviewing only feedback posted after the latest PR summary comment created by this workflow.

- The summary marker is a PR issue comment whose body starts with `<!-- address-review-summary -->` on its very first line. Requiring `startswith` (not `contains`) means a human comment that quotes or embeds the marker in prose is not mistaken for a checkpoint and cannot silently advance the cutoff.
- Legacy summary comments where the marker appears after a blank line, heading, or byte-order mark are ignored by this rule. If the cutoff appears to miss an older checkpoint, use `check all reviews`; new summary checkpoints created by this workflow always place the marker on the first line.
- Checkpoint readability contract: keep the marker first, then show a concise
  human header/status. Put the full itemized audit trail under a closed GitHub
  `<details>` block with a `<summary>` (never `<details open>`), so the detail
  remains durable but is collapsed by default. Keep any source-state marker
  structurally complete for its parser.
- If the user explicitly said `check all reviews`, ignore the cutoff and scan the full PR history.
- If the input is a specific review URL or specific issue-comment URL, fetch that exact target even if it predates the latest summary comment.

The full-PR fetch in Step 4 returns `review_cutoff_at`: the `created_at` of the
most recent issue comment whose body starts with
`<!-- address-review-summary -->`, or an empty string when none exists. Read the
cutoff from that field instead of running a separate query:

```bash
# After running the Step 4 fetcher into review-data.json:
REVIEW_CUTOFF_AT=$(jq -r '.review_cutoff_at' review-data.json)
# Empty string → no prior summary comment; scan full PR history.
```

Cutoff rules:

- `REVIEW_CUTOFF_AT` is empty when no summary comment exists; treat that as "scan full PR history" and do not filter by timestamp.
- If `REVIEW_CUTOFF_AT` is non-empty and `CHECK_ALL_REVIEWS` is false, use it as the cutoff.
- Use exact timestamps in user-facing status updates, for example: "Scanning review activity after 2026-04-01T20:14:33Z."
- When a cutoff is active, keep enough older thread context to understand new replies, but only triage items whose own timestamp or latest thread activity is after `REVIEW_CUTOFF_AT`.
- If no items survive the cutoff, say that no new review feedback was found since the last summary comment and remind the user they can say `check all reviews` to rescan the full PR.
