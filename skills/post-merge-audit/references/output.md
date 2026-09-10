## Output

Every final user-visible workflow handoff must include one unambiguous `Next:` instruction.
This applies to completed-batch, release/range, and coverage catch-up audits.
When the applicable archive gate passes, use `Next: Archive this task.` When
user input blocks progress, state the smallest action that clears the blocker
and whether to reply here or start a new task. When the current task will
continue without input, state its exact next action.
Keep `Action needed:` separate: name the exact user action or `none`. A durable
issue, report, receipt, or blocker list is evidence, not a next step.

In completed-batch mode only:

Apply [Audit applicability](../../../workflows/pr-batch-integration-closeout.md#audit-applicability) before requiring this audit. The batch coordinator owns a required completed-batch audit and its final handoff; a parent only reconciles the durable audit handoff.

Only the batch coordinator publishes the full `completed-batch-audit v1` wrapper as a durable GitHub comment and emits its human-readable closeout guidance, verified compact receipt reference, the Unblock Block when the status is not clean, and the final `Conversation status` line in chat, after it compares qualifying-checker and advisory-auditor reports and dispositions findings. When the deterministic anchor is a PR, the coordinator separately applies the helper-emitted managed `Completed-batch audit` section inside the canonical description's `Agent details` disclosure, under `### Audit receipts`.

Put `What changed:`, `Action needed:`, and `Next:` before the compact receipt so
the receipt can open the closing lines before the Unblock Block when status is
not clean, and before the final `Conversation status:` line.
Qualifying-checker and advisory-auditor reports return evidence/results for coordinator comparison; they must not publish the durable receipt comment or emit its compact reference or coordinator readiness/status line.
Advisory auditors must not issue the qualifying clean/ready verdict.

Before preflight, persist trusted `coordination_applicability` in a separate
controller/operator-owned `completed-batch-coordination-applicability` v1
artifact and retain its canonical SHA-256 independently from receipt input. It
binds the exact batch and canonical targets to durable HTTPS policy/topology
sources, verification time, and rationale. For `coordination_required`, capture
fresh bounded exact-batch coordination status; for
`coordination_not_applicable`, supply the typed single-controller status proof
without any coordination command. Before publishing `audit_status: complete`,
run `completed-batch-publication-preflight` against the repository's configured
`coordination_backend`, that selected status or proof, the trusted applicability
artifact and independently retained digest, the trusted
target manifest, refreshed terminal target/head snapshots, and one per-target
QA Evidence marker. Compute the canonical digest at classification time with
`completed-batch-publication-preflight digest-applicability-proof --applicability-proof <path>`
and retain it where the publishing actor cannot rewrite it; see
[coordination-backend.md](../../../docs/coordination-backend.md) for that trust
boundary and its limits. The preflight derives the full target set from required
coordination lanes or from the not-applicable proof and fails closed when the
selected evidence is absent, nonterminal, unmerged/unclosed, or `UNKNOWN`; when an exact-head QA
disposition is not `SATISFIED`, explicit valid `NOT_APPLICABLE`, or `WAIVED`
with an authenticated replayable maintainer-waiver comment; or when
the configured coordination seam is unavailable. `unknown`, `in_progress`,
missing, stale-head, and malformed QA evidence block completion.

The issue-to-result-PR projection requires an authenticated same-repository symmetric closing relationship, a closed source issue, a merged result PR, the exact result head, and ordered terminal timestamps; do not union the source issue and result PR as two publication targets, and re-authenticate the projection before ordinary receipt publish or replay. When typed for publication-preflight parsing, accepted lane-target forms are exactly `issue:N`, `pr:N`, or `pull_request:N`; malformed, unknown, or type-ambiguous spellings fail closed. These parsing forms are not distinct agent-coordination claim identities. Legacy bare `N`, `#N`, and positive integer lane targets remain compatible. This projection is only for issue-to-result-PR publication; it does not authorize auxiliary ad-hoc target mappings or multiple coordination lanes for one publication target.

An explicitly URL-less terminal `done` lane that already names mixed issue and pull-request targets reconciles the shared scalar `pr_state` per target only when durable terminal evidence exists, the scalar matches one resolved terminal state, every target state is freshly authenticated, the issue head remains absent, and exact-head QA stays bound to the pull request; this does not derive or union targets from a URL or admit auxiliary lanes.

A normal terminal `done` lane still requires its coordination target state and
terminal evidence. Same-lane worker/model replacement is a nonterminal claim reassignment or supersession operation; it must never emit a terminal lane closeout. Before consuming replacement proof, preserve and verify known `status`, `terminal`, `closed_at`, and `pr_state`; missing or `UNKNOWN` terminal facts fail closed, and a truly terminal lane requires reconciliation or explicit replanning instead of replacement. The first terminal event remains immutable: later authenticated completion may reconcile an `abandoned` lane or a `superseded` issue with typed no-PR evidence, but code-bearing completion after terminal `superseded` is a premature terminal supersession / replacement protocol violation.
The publication snapshot preserves the original coordination terminal and records
the later-target completion mode for accepted reconciliation. Active/nonterminal
lanes, open targets, unauthenticated target facts, and malformed terminal
timestamps remain blocked.

Parse and bind the local receipt to the expected batch ID, choose only from the trusted batch target manifest, verify the deterministic target plus authenticated non-bot actor and write permission, make exactly one comment POST, and read back that exact returned comment ID before emitting the compact reference and managed PR-description section. For a PR anchor, read the latest description after `publish` or `replay`, merge the emitted section inside `### Audit receipts` in the canonical `Agent details` disclosure in one separately retriable update, and read it back; never rerun `publish` to retry description sync.

For `audit_status: complete`, that parse/bind step additionally requires the
eligible publication preflight and exact manifest match. Pass the same refreshed
preflight receipt to `publish` and `replay`
with `--publication-preflight` and explicit `--workflow-config <trusted repo
workflow config>`, plus `--applicability-proof <trusted artifact>` and
`--applicability-proof-sha256 <independently retained digest>`; replay reports a
snapshot mismatch/staleness blocker if applicability, coordination, target/head,
or QA state no longer matches the published binding.

Use `completed-batch-audit-receipt` for both `publish` and `replay`;
`--targets-json` is a JSON array of exact `host`, `repo`, `type`
(`pull_request` or `issue`), and positive `number` objects. The
`completed-batch-publication-preflight-input` v1 fields are `batch_id`,
`coordination_applicability`, `expected_targets`, raw `coordination_status`,
`target_snapshots`, and `qa_evidence`. `target_snapshots` carry `target`,
terminal `state`, full `head_sha`, and `source`; `qa_evidence` carries `target`,
marker text, plus `maintainer_waiver: {"url": "<exact same-target #issuecomment
URL>"}` only for `WAIVED`. The CLI reads
`coordination_backend` only from `--workflow-config`; do not
replace the bounded coordination result with a caller-written lane summary.
Each `qa_evidence` row must carry a coordinator-owned
`user_visible_ui_change` value of exact `yes` or `no`, bound to that row's
canonical target and publication snapshot; `yes` requires strict visual-evidence
v2 replay, `no` preserves historical non-UI v1 replay, and missing, invalid, or
v2-contradictory classification blocks.

The preflight receipt embeds the canonical raw v1 input as `source_input` with
`source_input_digest`; digests prove integrity only and never authenticate
applicability or terminal facts. Before publish or replay accepts a complete
receipt, it authenticates the separate applicability artifact against the
independently retained digest, re-assesses that bound source input, re-fetches
each exact target through authenticated `gh api`, reruns bounded exact-batch
coordination status only for `coordination_required`, and re-authenticates any
waiver. Missing, altered, stale, tampered, contradictory, or mismatched facts
block before any verifier or POST.

Completed-batch receipt `publish` and `replay` require explicit trusted workflow config plus the separate applicability artifact/path and independently retained digest. They load `coordination_backend` only from that YAML seam and bind applicability only from the authenticated artifact, never from an environment or receipt/source-input override. `coordination_required` requires a matching real backend and bounded exact-batch status replay, while a missing or `n/a` backend blocks. Authenticated `coordination_not_applicable` accepts the typed single-controller status proof with any configured backend and invokes no coordination command, including during reassessment. Missing, invalid, tampered, contradictory, or mismatched applicability/config facts block before any verifier or POST.

Configured `public claim-comment fallback` is advisory ownership state only; it
must not invoke private `agent-coord`, and without a separate authenticated
terminal coordination contract it leaves completed-batch publication blocked as
`UNKNOWN`.

For `coordination_not_applicable`, `coordination_status` must be a typed
single-controller proof: a `completed-batch-coordination-not-applicable` v1
object with the exact batch ID and target set, `mode: single_operator`, a known
rationale, a durable HTTPS source, and a valid completion timestamp; missing or
malformed typed evidence blocks. An issue-only no-PR target uses `head_sha: not_applicable` plus
`no_pr_evidence` containing that exact issue URL, exact canonical target, and
known rationale; it must not invent a commit SHA, and forged or malformed no-PR
evidence blocks.

WAIVED input supplies only the exact same-target `#issuecomment-<id>` URL. The
helper must fetch that comment through authenticated `gh api`; HTTP/API failure
or any comment ID, URL, target, exact-head, decision-marker, human author,
trusted association, timestamp, or body mismatch blocks completion. The
authenticated snapshot binds the exact comment ID/URL, body SHA-256,
author/association, timestamps, target, and head. The fetched body must contain
exactly one `qa-maintainer-waiver v1` marker with `target: <exact target URL>`,
`head_sha: <full exact head>`, and `decision: waived`. Receipt publication and
replay independently re-fetch and compare the bound waiver; a self-consistent
preflight digest is not authentication.

Replay parses the compact reference but never opens its URL; fetch the manifest-bound target and exact comment ID through authenticated `gh api`, then revalidate the target, comment, author, trusted association, unchanged timestamps/body, SHA-256, batch ID, wrapper version, and result.

A conversation is archive-ready only when the audit is clean and there are no OUTSTANDING findings, follow-ups, unresolved questions, pending work, or `UNKNOWN` facts. A completed-batch audit has separate well-formed, archive-ready, and blocker-union outputs. A completed-batch audit is release/archive-ready only when `audit_status: complete`, `verdict: clean`, `findings: none`, and `followups_dispositions` is `none` or only fully evidenced terminal records. Ordinary new complete receipts additionally require the helper-managed `publication_snapshot` to match a fresh eligible preflight; the accepted-deferral path below uses exactly one `accepted_deferral_snapshot` instead. Replay only the exact versioned `<!-- completed-batch-audit v1` wrapper through its single final `-->`, with exactly one each of `batch_id`, `audit_status`, `verdict`, `scope_evidence`, `checker_evidence`, `findings`, and `followups_dispositions`; malformed, missing, duplicate, comment-token, newline, nested/case-varied `UNKNOWN`, or cross-field-inconsistent data fails. Ordinary new complete receipts also have exactly one helper-managed `publication_snapshot`; accepted-deferral receipts have exactly one `accepted_deferral_snapshot`, and either kind fails closed when its snapshot is unrefreshed or mismatched. A legacy complete marker without either helper-managed snapshot remains parseable but is never ready; it requires a fresh eligible preflight and a newly bound snapshot before publication or archive readiness.

An old helper-managed `publication_snapshot` missing `coordination_applicability`
or `applicability_proof_digest` stays non-ready even after replay refresh.
Preserve the old comment; establish trusted applicability proof and a fresh
eligible preflight, then use ordinary `publish` with a fresh marker to create a
newly bound receipt and reference after all gates pass. Ordinary snapshot
migration is not the accepted-deferral-only `supersede` operation.

Accepted-deferral lifecycle: use `publish --accepted-deferral <input>` before initial publication or `supersede --reference-file <original-reference> --accepted-deferral <input>` after a non-ready receipt was published; both paths append a helper-managed `accepted_deferral_snapshot`, while `supersede` preserves and re-authenticates the original comment instead of editing or deleting it. This path is eligible only when the exact blocked preflight is canonically reassessed from authenticated inputs, every product target and exact-head QA row is clean, and the sole logical blocker is the named workflow/process-mechanism defect. For the issue-target/implementation-PR resolution defect, the helper accepts only its complete attributable raw-blocker set for one exact issue/lane/source PR; an extra lane, blocker class, substantive blocker, or `UNKNOWN` fact fails closed. The exact tracking issue must already be open, and a current write-authorized non-bot maintainer must accept that exact batch, blocker, owner, predecessor, and preflight digest. Product, correctness, security, release, QA, review, CI, merge, unresolved-user-decision, duplicate-tracker, stale, malformed, and any `UNKNOWN` fact remain non-deferrable and fail closed.

The accepted-deferral input is exactly `completed-batch-accepted-deferral-input` v1 plus one `decision_url`. That URL must name a comment on the deterministic batch anchor whose body is exactly one `completed-batch-accepted-deferral-decision v1` marker binding `batch_id`, the predecessor's exact canonical `blocker_ref`, `blocker_category: workflow-process-mechanism-defect`, `mechanism: publication-preflight-target-resolution`, the exact full-URL `tracking_issue`, the predecessor's exact `owner`, original receipt SHA-256/URL/author/created/updated values (or the canonical pre-publication sentinels), `product_evidence_receipt`, and `decision: accepted-deferral`. The predecessor evidence must be that exact tracking URL; a shorthand `<repository>-<number>` blocker ref is valid only when it maps to the same evidence repository and issue number.
Before publication, bind `original_receipt_sha256` to the exact local blocked marker and use `not-published` for its URL plus `not-applicable` for author and both timestamps. After publication, copy those five bindings from the verified compact predecessor reference; the decision timestamp must be later than the original receipt.

A coordination-backed `batch_id` is an opaque nonempty single-line string and may contain `:` or `;`. Only exact lowercase `non-backend:` and `not-applicable:` prefixes trigger their typed rules; those forms require their rationale and `scope_evidence: targets=<exact refs>; source=<durable ref>`. Each record has `ref`, `owner`, `current status`, `disposition`, and `evidence`; current status is exactly `open`, `unresolved`, `pending`, `UNKNOWN`, or `terminal`; duplicate refs block case-insensitively. `ref` and `owner` are nonempty. Nonterminal evidence is nonempty. Terminal evidence may be exact `UNKNOWN` or empty only as an explicitly non-ready blocker; nested/case-varied `UNKNOWN` is invalid. `UNKNOWN` validation is fail-closed: only literal ASCII exact `UNKNOWN` may use an exact-sentinel path; NFKC-normalize a copy of every scalar and record value before case-insensitive nested-`UNKNOWN` rejection, so compatibility forms cannot count as evidence. Within every record field (`ref`, `owner`, `current status`, `disposition`, and `evidence`), unescaped `;` and `|` are reserved delimiters and are rejected; escaping is not supported. Terminal dispositions are exactly `resolved`, `accepted-waiver`, `accepted-deferral`, or `not-applicable`; nonterminal actions are exactly `investigate`, `fix`, `await-input`, `retry`, `replay`, or `track`. Terminal dispositions are invalid for nonterminal records and nonterminal actions are invalid for terminal records. Every top-level scalar and record value is one physical line; reject embedded CR, LF, CRLF, NUL, control line breaks, and HTML comment tokens. Each completed-batch follow-up ref uses one canonical normalization: Unicode NFKC, collapse Unicode whitespace with `[[:space:]]+`, trim, and reject empty results; preserve the canonical display and derive identity with Unicode full case folding. Use that identity for record duplicates, findings-to-record lookup, and blocker deduplication; `ß` and `SS` collide. External blockers may share the safe canonical display, while record identity stays consistent. Duplicate canonical refs are invalid; every accepted distinct ref remains in the blocker union. After normalization, record and finding refs reject any canonical display that is empty, contains control line breaks, contains `<!--` or `-->`, or is exact/nested `UNKNOWN`. External blockers separately reject empty/control/HTML canonical displays but preserve `UNKNOWN` facts; normalize, dedupe, and render them in the exact Follow-ups union.

Clean/none permits no records or only fully evidenced terminal records. A blocked/follow-ups marker permits `findings: none` with valid open, pending, unresolved, `UNKNOWN`, or imperfect terminal records, but it is non-ready; an `UNKNOWN` current-status record is valid only in that non-clean state or the all-`UNKNOWN` scalar state. A `findings: OUTSTANDING <refs>` value contributes every exact ref to the blocker union even without a record. Every nonterminal record and every record with imperfect terminal evidence contributes its ref and action/block reason; normalize and dedupe without dropping a distinct ref. In the marker, `findings` is `none`, `UNKNOWN`, or `OUTSTANDING <refs>`; every OUTSTANDING ref is visible in the final blocker union even when no action record exists, while operational action refs need not be duplicated in findings. For `OUTSTANDING`, before comma/delimiter fallback, an entire canonical findings payload that exactly matches an accepted record ref is that one ref; otherwise retain comma- or whitespace-separated standalone refs, and consume a whitespace-bearing canonical record ref that matches the remaining findings text before standalone fallback.

A marker has separate well-formed, archive-ready, and blocker-union outputs. Clean/none accepts only no records or fully evidenced terminal records; blocked/follow-ups/OUTSTANDING accepts non-ready records. `UNKNOWN` current status is never ready and cannot appear in a clean/none marker.

Replay the final visible status line from the normalized blocker union: render a nonterminal record as `<ref> (<current status>): <action>`, imperfect terminal evidence as `<ref> (terminal): evidence UNKNOWN` or `evidence missing`, and exact `UNKNOWN` scalars as `<field>: UNKNOWN`. External blockers must be nonempty single-line text without HTML comment tokens; normalize and dedupe them with marker blockers. If marker parsing fails, replay `well=false`, `ready=false`, and the nonempty blocker `completed-batch-audit marker invalid`; normalize and union any sanitized external blockers. Its final status must be exact nonempty `Follow-ups`, never `Ready` or an empty blocker line. Use `Ready` iff archive-ready and the union is empty; otherwise use nonempty `Follow-ups` with that exact union.

Use exactly `Conversation status: Ready for archiving.` only when archive-ready and the blocker union is empty. Otherwise use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.` and emit the [Unblock Block](../../../workflows/pr-processing.md#unblock-block) immediately before it, with one entry per blocker in that same union.

In final chat, this compact receipt line opens the closing lines: it is followed by the [Unblock Block](../../../workflows/pr-processing.md#unblock-block) whenever the status is not clean, and then by the exact `Conversation status` final line; never include the full wrapper:

```text
Completed-batch audit: <clean|follow-ups-remain|UNKNOWN> — [durable v1 receipt](<exact-comment-url>); SHA-256 `<64-lowercase-hex>`; author `<login>`; version `<created_at>/<updated_at>`.
```

Give this local receipt to the helper. It publishes one concise header, one
blank line, and exactly one canonical v1 wrapper; the helper injects the
integrity-bound `publication_snapshot` after `scope_evidence`. Fill every
operator-authored field explicitly and use `none` rather than omitting a field:

```text
Completed-batch audit: replay evidence follows.

<!-- completed-batch-audit v1
batch_id: <opaque coordination batch id (may contain : or ;)|non-backend: identity; rationale: why no backend applies|not-applicable: rationale|UNKNOWN>
audit_status: <complete|blocked|UNKNOWN>
verdict: <clean|follow-ups-remain|UNKNOWN>
scope_evidence: <concise refs|UNKNOWN>
checker_evidence: <identity/route/independence refs|UNKNOWN>
findings: <none|OUTSTANDING concise refs|UNKNOWN>
followups_dispositions: <none|one or more ` | `-separated records with ref, owner, current status, disposition, and evidence; unescaped `;` and `|` are rejected in every record-field value; escaping is not supported; terminal disposition is resolved|accepted-waiver|accepted-deferral|not-applicable; nonterminal action is investigate|fix|await-input|retry|replay|track>
-->
```

For a PR anchor, `publish` and `replay` emit this small managed section after
comment readback; neither mutates the PR description. The coordinator applies it
inside `### Audit receipts` in the canonical `Agent details` disclosure through
a separate freshly-read update, preserves all surrounding text, never duplicates
the markers, and never reruns `publish` to retry description sync:

```markdown
<!-- completed-batch-audit-summary:start -->
#### Completed-batch audit

**Status:** <Clean — no outstanding findings or follow-ups.|Follow-ups remain — see the durable receipt.|Unknown — see the durable receipt.> [Durable receipt](<exact-comment-url>).
<!-- completed-batch-audit-summary:end -->
```

For `non-backend` and `not-applicable`, the structured `scope_evidence` grammar is `targets=<exact refs>; source=<durable ref>`: name the exact verified target set and durable evidence source. `batch_id: UNKNOWN` is allowed only for genuinely unresolved batch identity, never for release/archive readiness.

The replay rule above is fail-closed: malformed, missing, duplicate, `UNKNOWN`, or cross-field-inconsistent marker data blocks; the parent later replays only this durable handoff and never reruns or owns the audit.

Return high-risk findings first, then:

1. Review-gate violations, including PRs merged before requested reviews finished, before actionable review findings were triaged, or with AI review systems incorrectly counted as approval gates.
2. QA coverage findings, including missing, stale, insufficiently scoped, or
   still-`UNKNOWN` required QA evidence.
3. Missing changelog candidates, with a single recommendation to run `/update-changelog` when any are found.
4. Cross-PR interaction risks.
5. A deduped issue plan with parent/child recommendations, fingerprints, and
   issue-creation accounting: parent issue URL if created, child issue URLs,
   skipped duplicates with existing issue URLs, changelog recommendation, and
   any planned issue that could not be created.
6. An audit scope/coverage table with audit mode, base/head range, included PRs,
   excluded range PRs, durable audit coverage marker/ledger status where
   available, and any `UNKNOWN` coverage facts.
7. A worked-issue/QA-lane coverage table with issue number or QA lane id,
   coordination lane/branch, linked PR or no-PR/blocker/QA evidence, final
   state, issue intent-achievement or QA-coverage classification, and `UNKNOWN`
   facts (see the example in `.agents/workflows/post-merge-audit.md`).
8. A PR-by-PR table.
9. A concise evidence trail, not a boilerplate tool list. Include exact
   commands and data sources only when they materially affect audit scope,
   confidence, a finding, or an `UNKNOWN`; include the relevant result, SHA,
   range, status, failure, or timeout beside each entry. For a named batch,
   include bounded `agent-coord status` evidence or the exact reason
   coordination state was `UNKNOWN`. Mention omitted expected sources only when
   the omission changes audit confidence, with the command, permission, or
   artifact needed to resolve it.

Do not create fixes, labels, changelog edits, reverts, or PRs. Do not create
unrelated comments; the release-gate ledger append is allowed when required
before issue creation. Create follow-up issues by default unless the user
explicitly asked for report-only or no issue creation, issue creation is blocked,
or there are no issue-worthy findings.
