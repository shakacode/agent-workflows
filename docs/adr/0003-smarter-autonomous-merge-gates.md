# ADR 0003: Smarter Autonomous Merge Gates

Date: 2026-07-23
Status: accepted

Scope: Portable PR merge-readiness policy, repository seams, and supporting
evaluation evidence for `merge_authority: auto_merge_when_gates_pass`

## Problem

`auto_merge_when_gates_pass` currently treats clean CI, completed reviews,
resolved threads, mergeability, and release policy as sufficient evidence for
autonomous merge. Those checks can establish that the implementation is
internally consistent without establishing that the chosen design is simple,
operationally reversible, or appropriate.

[shakacode/hichee#9831](https://github.com/shakacode/hichee/pull/9831)
demonstrates the gap. The PR reached a clean implementation state after many
review rounds, but it still warranted a maintainer decision about whether a
permanent listing-redirect abstraction was a justified solution. At the time of
inspection it had:

- 57 changed files;
- 2,511 changed lines;
- 12 commits;
- 44 submitted reviews;
- many distinct reviewed head revisions;
- four database migrations; and
- permanent, cross-cutting behavior on listing and watch-list paths.

Automatically merging that PR because implementation gates were clean would
have been unsafe. A green review state cannot resolve a fundamental question
about performance, complexity, data architecture, or whether a simpler design
should replace the proposed mechanism.

## Goals

1. Make `auto_merge_when_gates_pass` necessary but not sufficient for
   autonomous merge.
2. Add an explicit autonomous-merge eligibility gate after ordinary
   correctness and readiness gates.
3. Require fresh human judgment for irreversible, operationally sensitive,
   architecturally broad, very large, or repeatedly churned changes.
4. Preserve efficient autonomous merging for bounded low-risk work.
5. Keep common policy portable while allowing consumer repositories to declare
   critical files, safe path groups, and stricter thresholds.
6. Produce an auditable result tied to the exact current head SHA.
7. Fail closed when required evidence, configuration, or semantic
   classification is incomplete.

## Non-Goals

- Replacing CI, code review, adversarial review, merge ledgers, or release
  policy.
- Treating a risk score as a substitute for a human decision.
- Automatically proving that an arbitrary production change is reversible.
- Allowing repository seams to disable common hard-risk categories.
- Treating positive AI reviews as human approval.
- Making raw review-comment volume a merge gate.
- Performing an exhaustive organization-wide historical calibration in the
  first implementation.

## Considered Approaches

### Allowlist-only autonomous merge

Only documentation, tests, and similarly narrow path groups would merge
autonomously.

This is simple and safe, but it discards useful automation for small,
well-tested implementation fixes that have no durable or sensitive effects.

### Weighted risk score

Files, lines, paths, commits, review rounds, migrations, and other signals would
contribute points toward a human-review threshold.

This is flexible, but it creates false precision. A score can obscure why a PR
is unsafe, invite tuning that offsets one serious signal with several weak
signals, and make review outcomes difficult to audit.

### Hybrid eligibility gate

Use:

- common hard triggers that always require human judgment;
- objective size and churn thresholds;
- repository-owned critical-path additions;
- narrowly defined safe path groups; and
- a current-head human risk decision when a trigger fires.

This is the selected approach. It is explicit, auditable, portable, and easier
to reason about than a risk score.

## Calibrating The Defaults

A bounded historical study sampled 397 recent merged PRs across:

- `shakacode/react_on_rails`;
- `shakacode/react_on_rails_rsc`;
- `shakacode/shakastack-com`;
- `shakacode/shakapacker`;
- `shakacode/react_on_rails_pro`; and
- `shakacode/react-on-rails-demos`.

The study capped high-volume repositories at their 100 most recent merged PRs.
It also inspected representative PR file lists and review histories and sampled
the ShakaStack-linked `control-plane-flow`, `cypress-playwright-on-rails`, and
`shakaperf` repositories before the GitHub API rate window was exhausted.

| Repository | Sample | Median files / lines / commits | Triggered by 30 files, 1,000 lines, or 10 commits |
| --- | ---: | ---: | ---: |
| `react_on_rails` | 100 | 4 / 233 / 3 | 20% |
| `react_on_rails_rsc` | 98 | 4 / 175 / 2 | 23% |
| `shakastack-com` | 24 | 5 / 147 / 2 | 4% |
| `shakapacker` | 100 | 4 / 66 / 2 | 15% |
| `react_on_rails_pro` | 21 | 2 / 38 / 2 | 19% |
| `react-on-rails-demos` | 54 | 3 / 156 / 2 | 22% |

The proposed size and final-commit defaults flagged 75 of 397 PRs, or about
19%. The outliers were generally releases, broad runtime changes, agent/release
policy, generated demo additions, dependency work, or long-running changes.
That rate covers only files, lines, and final commit count; the full-policy
trigger rate is unknown because reviewed-head history was not available for the
complete sample. The four-reviewed-head default is therefore a conservative,
provisional safety threshold that must be measured in shadow mode before
autonomous enforcement.

The study also showed that final commit count is insufficient:

- [shakapacker#1206](https://github.com/shakacode/shakapacker/pull/1206)
  ended with one commit but had 11 distinct reviewed head SHAs and 63 submitted
  reviews.
- [react_on_rails#4701](https://github.com/shakacode/react_on_rails/pull/4701)
  had 44 files, 4,925 lines, 16 commits, and 14 reviewed heads.
- [react_on_rails#4669](https://github.com/shakacode/react_on_rails/pull/4669)
  changed only three files but had 16,489 lines, 16 commits, and 15 reviewed
  heads in release automation.

Therefore distinct reviewed head SHAs are the primary review-churn measure.
Final commit count remains a useful secondary signal. Raw review and comment
counts are reported as context but are not primary gates because bot behavior
varies widely.

Small sensitive changes also prove that numeric thresholds are not sufficient.
For example,
[cypress-playwright-on-rails#237](https://github.com/shakacode/cypress-playwright-on-rails/pull/237)
changed one file and 93 lines but altered workflow permissions. Repository path
policy and common semantic categories must catch such changes.

## Merge Decision Model

The merge decision becomes:

1. Resolve trusted merge authority.
2. Pass existing validation, CI, review, thread, mergeability, ledger, QA, and
   release-policy gates.
3. Evaluate autonomous-merge eligibility for the exact current head SHA.
4. Merge autonomously only when the result is
   `autonomous-merge-eligible`.
5. When the result is `human-approval-required`, stop in
   `ready-human-review-required`.
6. When the result is `UNKNOWN`, stop in
   `autonomous-merge-evidence-unknown`.
7. Only `human-approval-required` can be resolved by a qualifying human
   decision. `UNKNOWN` remains blocking for automation and cannot be converted
   into an eligible or approved result.
8. A qualifying human decision changes the exact-head result to
   `human-approved-for-current-head`; automation may then perform the mechanical
   merge if every other gate remains clean.
9. Any head change invalidates the decision and restarts evaluation.

This separates judgment from mechanics. `auto_merge_when_gates_pass` authorizes
the agent to perform a merge; it does not authorize the agent to answer a
material design or operational-risk question on the maintainer's behalf.

## Common Human-Approval Triggers

The following categories require explicit human approval before merge
automation may proceed.

### Persistent data and storage

- Schema or storage migrations
- Backfills and durable data rewrites
- Cleanup jobs that delete, merge, or permanently reassign data
- New persistent formats that an old application version cannot safely read
- Storage lifecycle or retention changes

Additive or technically reversible migrations still require human approval.
Operational rollback is broader than whether a down migration exists.

### Infrastructure and delivery

- Infrastructure-as-code and production topology
- Deployment, promotion, release, or publishing behavior
- CI workflow permissions or trust boundaries
- Secrets, credentials, identity, or production configuration
- Runtime, compiler, framework, or dependency upgrades

### Irreversible or externally visible effects

- Payments, billing, emails, webhooks, or third-party mutations
- Security, authorization, authentication, or privacy behavior
- Destructive operations
- Public API, wire-format, persisted-format, or compatibility changes
- Changes for which code-only rollback, mixed-version operation, or forward
  recovery cannot be established

### Architectural and product judgment

- A maintainer raises an unresolved question about design, simplicity,
  performance, complexity, product behavior, or rollout
- A change introduces a broad abstraction or cross-cuts multiple runtime
  subsystems
- A repository seam identifies a critical runtime or hot path

A concern is cleared only by an explicit resolution or the qualifying risk
decision described below. Silence, a positive bot review, or thread closure
without a recorded decision does not clear it.

### Size and churn

The portable defaults require human approval at any of these inclusive
boundaries:

- 30 changed files;
- 1,000 added plus deleted lines;
- 10 commits in the current PR history; or
- 4 distinct head SHAs referenced by submitted reviews, subject to the
  shadow-mode rule below.

All changed files and lines count by default, including lockfiles and generated
artifacts. Generated-file classification is useful reporting context, not an
automatic size discount.

All submitted reviews count toward distinct reviewed heads, including reviews
from configured automation reviewers. This signal measures repeated
post-review head replacement and CI/review churn, not reviewer trust or human
approval. Four such heads deliberately route even an otherwise small PR to a
human check; the follow-up calibration must report how often ordinary
automation re-review cadence causes that trigger and recommend whether the
portable threshold should change. This reviewed-head threshold is shadow-mode
only until that calibration is complete. In shadow mode,
`reviewed-heads-limit` is emitted in `shadow_triggered_gates`, not
`triggered_gates`; it does not change the verdict or block autonomous merge.
After calibration explicitly graduates the threshold to enforcement, the same
signal moves to `triggered_gates` and produces `human-approval-required`.

The counter uses the complete paginated GitHub review-object history. It
includes `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, and `DISMISSED` reviews
with a nonnull `commit_id`; dismissal does not erase that a head was reviewed.
It excludes `PENDING` drafts, review-thread comments that are not submitted
review objects, and duplicate `commit_id` values. Before graduation, incomplete
pagination or a submitted review with missing head evidence sets
`shadow_evidence_unknown` and does not change the verdict. After graduation,
the same evidence failure makes the eligibility verdict `UNKNOWN`.

When reliable history is available, the evaluator may also report cumulative
post-review churn and head-replacement events. Those are advisory until a
consumer repository explicitly configures a deterministic threshold. Missing
optional churn history does not create `UNKNOWN`; missing evidence for a
configured required metric does.

## Presumptively Safe Lanes

The portable policy recognizes three possible low-risk classes:

- documentation-only;
- test-only additions or strengthening; and
- formatting, spelling, or non-executable comment-only changes.

Classification is conjunctive:

1. Every changed path belongs to one safe group.
2. No path belongs to that group's exclusions.
3. Semantic inspection confirms the change preserves the safe class.
4. No common hard trigger, repository critical path, maintainer concern, size
   trigger, or churn trigger applies.
5. All ordinary correctness and readiness gates pass.

Test-only classification fails when a change deletes or skips tests, weakens
assertions, accepts new snapshots without independent justification, changes
runtime fixtures or configuration, or modifies CI behavior.

Documentation-only classification fails for autonomous-merge policy artifacts
(including ADRs, workflow and skill sources, generated contracts, repository
agent instructions, and seam configuration), security policy, operator
runbooks, release instructions, executable documentation, or other
repository-declared sensitive documents.

Safe lanes make a positive autonomous classification easier; they do not
override another gate.

## Repository Seam

Consumer repositories may add an optional structured
`autonomous_merge` mapping to `.agents/agent-workflow.yml`:

```yaml
autonomous_merge:
  thresholds:
    # Inclusive maxima: the next value triggers human review.
    max_changed_files: 29
    max_changed_lines: 999
    max_commits: 9
    max_reviewed_heads: 3

  human_review_paths:
    - id: "<repo-owned-kebab-case-id>"
      pattern: "<repo-owned glob>"
      reason: "<migration|infrastructure|release|security|hot-path|policy|other>"
      detail: "<required nonempty explanation when reason is other>"

  policy_paths:
    - "<repo-owned autonomous-merge-policy glob>"

  safe_path_groups:
    documentation:
      include:
        - "<repo-owned glob>"
      exclude:
        - "<repo-owned sensitive glob>"
    tests:
      include:
        - "<repo-owned glob>"
      exclude:
        - "<repo-owned runtime-fixture or configuration glob>"

  generated_paths:
    - "<repo-owned reporting-only glob>"
```

The shared workflow owns the schema and semantic rules. Consumers own only
their repository-specific values.

When any `max_*` value is more permissive than its portable default, the same
trusted-base `autonomous_merge` mapping must also contain:

```yaml
autonomous_merge:
  threshold_relaxation:
    rationale: "<nonempty rationale covering all relaxed thresholds>"
```

Whenever `threshold_relaxation` is present, `rationale` must be a nonempty
string. The mapping is required when any threshold is relaxed and may be
omitted otherwise. A required-but-missing mapping, missing key, non-string
value, or blank value makes the configuration malformed and the eligibility
result `UNKNOWN`. This rule includes `max_reviewed_heads` while it is
shadow-only: changing it alters calibration output, and the rationale must
already be durable if that threshold later graduates to enforcement.

The mapping is a closed, versioned schema:

- `autonomous_merge` accepts only `thresholds`, `threshold_relaxation`,
  `human_review_paths`, `policy_paths`, `safe_path_groups`, and
  `generated_paths`;
- `threshold_relaxation` accepts only the `rationale` key;
- `thresholds` accepts only the four documented `max_*` keys; each value must
  be a YAML integer greater than or equal to zero, with booleans and numeric
  strings rejected;
- an omitted threshold key inherits its portable default, while a supplied
  value replaces that metric's portable maximum; lower values tighten policy
  and higher values require `threshold_relaxation.rationale`;
- duplicate YAML keys, unknown keys, type mismatches, invalid enums, blank
  identifiers or patterns, and invalid glob syntax make the configuration
  malformed; duplicate keys must be detected from parser events or the YAML
  syntax tree before ordinary mapping construction because last-key-wins
  loaders are not acceptable;
- each `human_review_paths` entry requires a unique kebab-case `id`, a
  nonempty `pattern`, and one documented `reason`, and accepts only optional
  `detail`, which must be a nonempty string when `reason` is `other` and must
  be omitted otherwise;
- `policy_paths` and `generated_paths` are lists of nonempty glob strings; and
- each safe path group accepts only `include` and `exclude`, both lists of
  nonempty glob strings, and must define at least one include pattern.

Globs are repository-root-relative and match normalized `/`-separated paths.
The portable grammar supports literals, `*` and `?` within a path component,
`**` across components, and bracket character classes. Absolute paths, `..`,
negation, backslashes, brace expansion, and malformed or unterminated classes
are invalid.

There is no precedence ambiguity: common hard triggers always apply; the
effective per-metric threshold is the supplied trusted-base value or its
portable default; `human_review_paths` and `policy_paths` only add triggers;
and safe or generated classification never subtracts one.

Portable built-in policy sources are the trusted-base seam, repository agent
instructions governing merge, the canonical PR-processing workflow, its
`pr-batch`/`pr-monitoring`/`plan-pr-batch`/`triage` parity sources and
generated contracts, and this ADR when present. Consumer `policy_paths` add
repo-specific policy documents and helpers; they cannot remove a built-in
source.

### Seam rules

- Missing `autonomous_merge` configuration uses portable defaults.
- Malformed configuration is `UNKNOWN` and blocks autonomous merge.
- Common hard categories cannot be disabled.
- Consumer repositories may tighten thresholds without additional ceremony.
- Relaxing a portable threshold requires a nonempty trusted-base rationale.
- One rationale may justify the complete set of threshold relaxations; no
  rationale field is required when every configured maximum is at least as
  strict as the portable default.
- `human_review_paths` only add gates.
- Built-in policy sources and `policy_paths` always require human review.
- Safe path groups cannot override common hard categories or numeric gates.
- `generated_paths` affect reporting only.
- The current PR is evaluated using trusted-base policy. A PR cannot weaken its
  own gate by modifying the seam, workflow files, agent instructions, or
  supporting helper.
- A change to autonomous-merge policy produces
  `human-approval-required`.

## Evaluation Evidence

Evaluation has two layers:

1. **Objective evidence collection** fetches and validates complete current-head
   PR metadata, file lists, line counts, commit counts, submitted reviews,
   reviewed head SHAs, relevant path matches, and policy provenance.
2. **Semantic assessment** classifies rollback, persistent or external effects,
   safe-lane eligibility, unresolved maintainer concerns, and architectural
   breadth from trusted task and diff evidence.

The final evaluation reports:

```text
verdict: autonomous-merge-eligible |
         human-approval-required |
         human-approved-for-current-head |
         UNKNOWN
head_sha:
policy_provenance:
metrics:
path_matches:
safe_class:
triggered_gates:
shadow_triggered_gates:
shadow_evidence_unknown:
rollback_assessment:
human_decision_evidence:
```

The final verdict is recomputed immediately before merge. PR-body claims and
branch-provided assessment files are untrusted input and cannot establish a
passing result.

### Canonical gate IDs

`triggered_gates` is a lexicographically sorted, duplicate-free YAML list. Its
portable IDs are closed for marker version 1:

- `architectural-product-judgment`
- `autonomous-merge-policy-change`
- `changed-files-limit`
- `changed-lines-limit`
- `commit-count-limit`
- `infrastructure-delivery`
- `irreversible-external-effect`
- `persistent-data-storage`
- `public-compatibility`
- `reviewed-heads-limit`
- `security-auth-privacy`

A repository path rule serializes as `repo-path:<human_review_paths.id>`.
Implementations may attach evidence and subcategory detail separately, but
must not invent another gate ID in a version 1 decision record. The recorded
list must exactly equal the live recomputed set or the decision is invalid.

## Human Risk Decision

When a trigger fires, a qualifying decision must:

- come directly from the user in the active task or from a human maintainer
  whose merge authority and human provenance are established;
- name the exact current head SHA;
- enumerate every triggered gate;
- state the rollback or forward-recovery disposition;
- explicitly approve merging despite those risks; and
- be recorded durably on the PR before merge.

The durable record is a complete PR comment with this exact envelope:

```text
<!-- autonomous-merge-risk-decision:v1 -->
---
head_sha: <40-character SHA>
triggered_gates:
  - <canonical-gate-id>
rollback_disposition: <concise disposition>
decision: approve
approved_by: <maintainer identity>
source: <direct-user-task|human-pr-review|human-pr-comment>
evidence: <durable reference>
...
```

The marker must be the first line. The parser removes exactly that line and its
following LF, then parses one YAML document beginning with `---` and ending
with `...`. Only trailing whitespace is permitted after the document end.
Comments containing the marker later in the body, multiple markers or YAML
documents, CR-only boundaries, trailing prose, aliases, custom tags, duplicate
keys, or unknown payload keys are invalid. When multiple valid decision
comments exist, only the newest valid comment for the exact current head is
considered; a newer invalid comment does not erase an older valid one.

A later code change invalidates the decision. A generic approval, stale
approval, author-controlled PR-body declaration, branch content, positive AI
review, or bot-generated approval does not qualify. If an automated session
uses a maintainer's GitHub credentials, the GitHub username alone does not prove
human provenance; use direct task evidence or another policy-approved human
channel.

The risk decision does not replace independent review, finalizer, release, or
CODEOWNERS requirements. It may be supplied by the author when that author is
the human maintainer making the direct judgment, but it cannot be supplied by
the authoring agent on that maintainer's behalf. This is a human-attention
gate, not an implicit two-person rule: repositories that require a second
human for security, destructive, infrastructure, or other categories enforce
that through their existing independent-review, CODEOWNERS, or release-policy
gate, which this decision cannot waive.

## Fail-Closed Behavior

Autonomous merge returns `UNKNOWN` when any required fact cannot be established,
including:

- incomplete or unavailable file pagination;
- incomplete submitted-review pagination;
- inability to bind evidence to the current head;
- missing required churn evidence;
- malformed seam configuration;
- invalid path patterns;
- ambiguous safe-lane classification;
- unknown rollback safety;
- uncertain maintainer-decision provenance;
- disagreement between live metadata and a recorded decision; or
- inability to retrieve and use trusted-base policy when the PR changes a
  policy source.

A PR that changes an available policy source deterministically produces
`human-approval-required` under the seam rules above; it becomes `UNKNOWN` only
when the trusted-base policy needed to evaluate that change cannot be
established.

`UNKNOWN` does not assert that the PR is unsafe. It asserts that automation is
not authorized to make or mechanically execute the merge decision, even when a
risk-approval marker exists. The `autonomous-merge-evidence-unknown` state
carries the exact head SHA, missing or contradictory evidence, policy
provenance, and the evidence-repair action; it is not a request for risk
approval. A human may still review and merge manually under normal repository
policy.

## Workflow Integration

The canonical policy belongs in `workflows/pr-processing.md`. Mirrored or
consumer-facing skills must reference or reproduce the same outcome without
weakening it:

- `skills/pr-batch/SKILL.md`;
- `skills/pr-monitoring/SKILL.md`;
- `skills/plan-pr-batch/SKILL.md`;
- `skills/triage/SKILL.md` and the `$pr-batch` prompt it emits; and
- generated goal/completion contracts that currently equate
  `auto_merge_when_gates_pass` with merge-on-no-real-blocker.

The completion contract changes from "merge unless a real blocker prevents it"
to "merge only when correctness gates and autonomous-merge eligibility pass, or
when a qualifying current-head human risk decision resolves the eligibility
gate."

The new terminal/intermediate states are:

```text
ready-human-review-required
autonomous-merge-evidence-unknown
```

`ready-human-review-required` carries the current head SHA, every trigger,
rollback status, and the exact decision needed.
`autonomous-merge-evidence-unknown` carries the current head SHA, evidence
failure, policy provenance, and repair action. Neither state may collapse into
`ready-gates-clean` or a generic `blocked-user-input`.

## Consequences

Benefits:

- consequential or difficult-to-reverse changes cannot merge solely because
  implementation checks are green;
- every autonomous-merge decision is explainable from named triggers and
  exact-head evidence; and
- bounded low-risk work retains a path to autonomous merge.

Trade-offs:

- legitimate iterative PRs may require a human check after repeated automated
  review rounds;
- consumer repositories must maintain sensitive-path seams when common
  semantic classification is insufficient; and
- fail-closed evidence collection adds latency and can reduce autonomous merge
  throughput until missing evidence is repaired.

## Verification

Implementation must include:

### Policy and helper tests

- every inclusive threshold boundary and the value immediately below it;
- distinct reviewed-head counting, including force-pushed one-commit PRs;
- included/excluded GitHub review states, dismissed reviews, null head
  evidence, deduplication, and complete pagination;
- pre-calibration shadow reporting versus post-calibration enforced verdicts;
- complete pagination and incomplete-pagination failure;
- common hard-trigger classification;
- reason-tagged repository path matching;
- malformed patterns and malformed seam configuration;
- unknown and duplicate seam keys, wrong scalar types, negative maxima,
  omitted threshold defaults, and precedence;
- duplicate-key-aware parsing and `reason: other` detail validation;
- stricter consumer thresholds;
- relaxed thresholds with and without rationale;
- generated-path reporting without size exclusion;
- safe-group inclusion and exclusion;
- test weakening and runtime-fixture counterexamples;
- trusted-base policy provenance;
- a PR attempting to weaken its own policy;
- exact-head human decisions;
- canonical gate-ID ordering and exact-set comparison;
- exact decision-marker envelope parsing and newest-valid-record selection;
- stale and malformed decisions;
- approval markers presented while the verdict is `UNKNOWN`;
- policy-only PRs, including ADR, workflow, skill, contract, instruction, and
  seam changes;
- direct-user versus unproven bot provenance; and
- `UNKNOWN` propagation.

### Workflow parity tests

Existing contract tests must prevent canonical workflow, `pr-batch`,
`pr-monitoring`, `plan-pr-batch`, `triage` and its emitted batch prompt,
planning prompts, and goal completion text from disagreeing about eligibility
or terminal states.

### Regression fixtures

A synthetic fixture modeled on hichee PR #9831 must trigger independently for:

- changed files;
- changed lines;
- commits;
- reviewed heads;
- migrations;
- cross-cutting runtime paths;
- rollback uncertainty; and
- an unresolved maintainer architecture concern.

The fixture must produce `human-approval-required` even when every ordinary CI
and review gate is clean.

### Repository validation

Run:

```bash
bin/validate
```

Run focused helper and contract tests directly while developing, then run the
complete repository validation before publication.

## Rollout

1. Add the canonical policy, evaluation contract, state taxonomy, seam
   documentation, and tests.
2. Add or extend the read-only helper that collects objective current-head
   evidence.
3. Run the complete policy in shadow mode and measure trigger rates, including
   automated-reviewer contributions to distinct reviewed heads.
4. Revisit the provisional four-reviewed-head threshold from that evidence
   before enabling autonomous enforcement.
5. Use portable defaults when a consumer has no `autonomous_merge` seam.
6. Seed the optional seam in presets and installation documentation without
   overwriting repo-owned policy.
7. Update downstream consumers through the existing source-pack adoption flow.
8. Validate each consumer with `agent-workflow-seam-doctor`.

After shadow-mode calibration and any resulting threshold adjustment, the
safety rule takes effect when the updated workflow pack is installed. A
consumer does not receive a permissive grace period merely because it has not
yet customized the optional seam.

## Follow-Up Historical Calibration

Build a reusable, rate-limit-aware historical calibration command that:

- accepts repositories and a time or PR-count window;
- caches or checkpoints GitHub responses;
- reports size, commit, reviewed-head, and path-category distributions;
- identifies PRs that would change classification under proposed thresholds;
- samples both triggered PRs and near misses for semantic inspection; and
- emits no merge decisions.

Run it across the broader ShakaStack-linked repository set after the initial
policy lands. Historical calibration may refine repository seams and stricter
or explicitly justified relaxed thresholds, but it must not weaken common hard
categories.

The initial 397-PR table is a narrative snapshot rather than a committed,
reproducible artifact. Shadow mode must not graduate to enforcement until the
follow-up command reproduces or supersedes that evidence, publishes the
reviewed-head distribution, and records the resulting threshold decision.

## Acceptance Criteria

The design is implemented when:

1. `auto_merge_when_gates_pass` no longer permits autonomous merge based only on
   ordinary readiness gates.
2. Hichee PR #9831's synthetic regression fixture requires a human decision.
3. Data/storage migrations and infrastructure changes always require human
   approval.
4. The post-shadow calibrated size and churn defaults are enforced.
5. Review churn uses distinct reviewed head SHAs, not raw comment volume.
6. Consumer repositories can add reason-tagged critical paths and bounded safe
   path groups.
7. Safe lanes cannot bypass hard, size, churn, or maintainer-concern gates.
8. Human decisions are explicit, durable, current-head-bound, and invalidated
   by later code changes.
9. Missing or ambiguous evidence fails closed as `UNKNOWN`.
10. Workflow and skill contracts agree on `ready-human-review-required` and
    `autonomous-merge-evidence-unknown`.
11. `bin/validate` passes.
