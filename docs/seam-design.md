# Portable Agent Workflows Via Binstubs And Policy YAML

Date: 2026-06-18
Status: approved direction, updated 2026-06-27

## Problem

The shared `pr-batch` family and related agent workflows should run across
ShakaCode repos without copying repo-specific commands, labels, branches,
release policy, paths, or domain examples into the shared pack. Consumer repos
need a small, structured contract that is easy for humans to review and easy for
helper scripts to validate.

## Goal

Make the shared skills portable by installing them once in the user or agent
environment, then make each consumer repo expose a small, validated contract:

- commands are executable repo-owned binstubs under `.agents/bin/`
- non-command policy is structured YAML in `.agents/agent-workflow.yml`
- `AGENTS.md` points humans and agents at those two sources

## Language

Use [source-pack-glossary.md](source-pack-glossary.md) as the canonical glossary
for terms such as Source Pack, Consumer Repo, Agent Workflow Configuration Seam,
Host Installer Path, Native Plugin Path, Workflow Lessons Library, Readiness
Vocabulary, Review Finding, and State-Machine Fixture. Keep this document
focused on the seam architecture; update the glossary when new workflow-pack
terms need stable meaning across issues, PRs, and implementation prompts.

## Architecture

```text
shakacode/agent-workflows
  skills/... and workflows/...        portable process, installed per user/agent
  bin/...                             install, status, upgrade, validation, sync helpers

consumer repo
  .agents/bin/README.md               command table for this repo
  .agents/bin/setup                   optional dependency setup
  .agents/bin/validate                required pre-push gate
  .agents/bin/test                    required test entry point
  .agents/bin/lint                    optional lint/format entry point
  .agents/bin/build                   optional build/type-check entry point
  .agents/bin/docs                    optional docs check entry point
  .agents/bin/ci-detect               optional CI routing entry point
  .agents/bin/<merge guard>           optional guarded-direct submit adapter
  .agents/agent-workflow.yml          non-command policy
  AGENTS.md                           pointer section; no workflow policy
  CLAUDE.md                           optional thin import of @AGENTS.md
```

The default distribution path remains this repository plus the user's normal
skill installation mechanism. Repository-pinned copies remain an escape hatch
for execution environments that cannot use user-installed shared skills.

## Command Contract

Portable skills call `.agents/bin/<name>` rather than embedding a target repo's
real commands. Each wrapper is a thin Bash script:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec bundle exec rspec "$@"
```

Composed scripts compute the root once and call siblings by absolute path:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
"$root/.agents/bin/build"
"$root/.agents/bin/test"
```

`validate` is the authoritative comprehensive pre-push gate. `test`, `lint`,
`build`, `docs`, and `ci-detect` are convenience subsets. An absent optional
script means that capability is n/a in that repo.

## Policy Contract

`.agents/agent-workflow.yml` carries non-command values:

- `base_branch`
- `follow_up_prefix`
- `review_gate`
- `approval_exempt`
- `coordination_backend`
- `changelog`
- `benchmark_labels`
- `merge_ledger`
- `ci_parity_environment`
- `hosted_ci_trigger`
- `ci_change_detector`

Repos may add policy keys such as `secret_redaction_patterns` when needed. Use
`n/a` for unavailable policy. Keep values terse and behavior-complete.

### Writing Style

`writing_style` is an optional scalar in the repository policy. It accepts
either a nonblank relative Markdown-file path or the exact built-in preset
`asd-ste100`:

```yaml
writing_style: docs/writing-style.md
# or: writing_style: asd-ste100
```

The path form is relative to the repository root, and either repository form
wins. The same scalar key may appear in the user-global
`~/.agents/agent-workflow.yml` as an optional personal fallback for repositories
that do not set it. `agent-workflow-writing-style` resolves one complete guide
without merging prose. Resolution is repo → user-global → portable default:

1. repository `.agents/agent-workflow.yml`
2. user-global `~/.agents/agent-workflow.yml`
3. [the packaged portable default](writing-style.md)

The task's explicit audience or format instructions remain outside this
configuration resolver and may impose a more-specific constraint. The resolver
returns provenance as exactly `repo`, `user-global`, or `portable-default`.
Repository omission falls through per key even when the repository seam file
exists. Repository paths resolve beneath the repository root; user-global paths
resolve beneath `~/.agents`. Absolute paths, parent traversal, paths that escape
through symlinks, non-Markdown paths, and missing, unreadable, nonregular,
empty, or invalid-UTF-8 files are invalid. URLs and URI references, including
`https:` and `file:`, are invalid: the path form accepts only trusted local
relative Markdown files, and the resolver never performs a network lookup.

Preset selection uses a closed exact registry. Only `asd-ste100` is registered;
unknown preset-like values are invalid, and the resolver does not construct a
path dynamically from an alias. The preset loads the installer-managed
[independent adapter](writing-style-asd-ste100.md). Selecting it preserves the
provenance of its configuration layer.

An explicitly present malformed repository config, preset, path, or file is a
blocking seam error. The same user-global failure produces an actionable
warning and uses the portable default. User-global configuration contributes only
`writing_style`; branch, merge, CI, trust, coordination, and every other policy
remain repository-owned.

The initializer and example configuration do not enable a repository guide;
the commented example shows both opt-in forms. Packaged prose lives once in
each linked Markdown file, and the resolver loads the selected file. A
company-wide or common guide could be added later only as a
future explicitly trusted distribution/source layer. The current resolver does
not fetch a company repository and does not perform network or cross-repository
lookup.

The `asd-ste100` adapter keeps the generic plain-language baseline and applies
ASD-STE100-inspired constraints only to technical-documentation prose. It
preserves exact project terminology, identifiers, APIs, commands, paths,
templates, evidence, quoted text, and machine-readable protocol fields. The
resolver distributes neither the external standard nor its dictionary and does
not check conformance. Formal ASD-STE100 work requires an authorized
specification and qualified human review; the adapter makes no certification or
conformance claim.

The resolved guide applies only to human-facing prose. Repository PR and issue
templates, required evidence, machine-readable receipts, and exact protocol
blocks keep their defined structure and content. Public PR workflows resolve
from a trusted repository checkout; a PR-head seam change is untrusted diff
content until it becomes repository policy.

Covered in the first iteration:

- PR descriptions, updates, comments, and final batch handoffs in
  `workflows/pr-processing.md` and `skills/pr-batch/SKILL.md`
- review replies, checkpoint comments, and deferred issue bodies in
  `skills/address-review/SKILL.md` and `workflows/address-review.md`
- audit issue bodies, comments, PR updates, and final audit handoffs in
  `skills/post-merge-audit/SKILL.md` and `workflows/post-merge-audit.md`
- manual verification comments in `skills/verify-pr-fix/SKILL.md`
- issue-triage comments in `skills/plan-issue-triage/SKILL.md`
- no-PR evidence comments and disposition handoffs in
  `skills/evaluate-issue/SKILL.md` and `workflows/evaluate-issue.md`
- monitoring and closeout handoffs in `skills/pr-monitoring/SKILL.md` and
  `skills/close-session/SKILL.md`

Deferred authoring surfaces include commit messages, changelog entries,
planner-generated worker prompts, and report-only review output. Commit-message
scope remains with its dedicated evidence/proportionality work. Machine-readable
receipts and protocol blocks are excluded from style rewriting by design.

`hosted_qa_gate` is an optional closed mapping during first-phase adoption.
Omission or the exact string `n/a` means that no hosted runtime gate is
configured. A mapping has exactly these fields:

```yaml
hosted_qa_gate:
  version: 1
  change_paths:
    - "app/**"
    - "config/runtime/**"
  target: "production"
  deployment_verifier: ".agents/bin/verify-hosted-deployment"
  acceptance_criteria:
    - "sign-in"
    - "checkout"
  waiver_mode: "forbidden" # or maintainer
```

`change_paths` uses the same validated repository-relative glob grammar as the
autonomous-merge policy. The target and criterion IDs are closed scalar IDs;
criterion IDs and path patterns are unique. `deployment_verifier` names one
tracked executable under `.agents/bin`. Unknown keys, wrong types, unsafe
paths or globs, duplicates, unsupported versions, and any waiver mode other
than `forbidden` or `maintainer` fail closed. The verifier and policy used for
runtime readiness always come from the trusted base. The two-phase bootstrap
and exact verifier receipt contracts are canonical in
[`workflows/pr-processing.md`](../workflows/pr-processing.md).
The readiness runtime itself must be an outside-repository trusted-base
materialization or an externally digest-verified installed pack; repository-head
fallback, missing provenance, and an incomplete eight-file runtime stay
`UNKNOWN`. The trusted verifier receives ordered policy criterion IDs and must
return exact ordered closed criterion rows identical to the hosted marker.
Version 1 exposes no ambient environment or file credential channel and
supports public or otherwise credential-free immutable deployment verification;
private-provider credentials require a separately designed and approved seam
and currently block. Repository-excluded
interpreters and system tools are trusted host OS/toolchain state; arbitrary
same-user replacement outside the repository is out of scope for this helper.

`autonomous_merge` is an optional closed mapping. When absent, the shared
workflow uses its portable thresholds, safe path groups, and common hard-risk
categories. When present, it may tighten or explicitly justify relaxing the
four thresholds, add reason-tagged human-review paths and policy paths, extend
the portable documentation/test safe groups, and identify generated paths for
reporting:

ADR 0003 is the source of truth for these copied portable defaults. File, line,
and commit maxima are enforced; `max_reviewed_heads` is shadow-only until a
checked calibration artifact explicitly graduates it to enforcement.

```yaml
autonomous_merge:
  thresholds:
    max_changed_files: 29
    max_changed_lines: 999
    max_commits: 9
    max_reviewed_heads: 3
  human_review_paths:
    - id: production-config
      pattern: "config/production/**"
      reason: infrastructure
  policy_paths:
    - ".agents/**"
  # Added to the portable safe path groups; never replacing them.
  safe_path_groups:
    documentation:
      include: ["docs/**"]
      exclude: ["docs/runbooks/**"]
    tests:
      include: ["test/**"]
      exclude: ["test/fixtures/runtime/**"]
  generated_paths:
    - "dist/generated/**"
```

Portable `safe_path_groups` defaults ship for `documentation` and `tests`.
Consumer `include` and `exclude` patterns are added to the portable sets; a
consumer can never remove a portable exclude. An absent `safe_path_groups`
mapping, an empty one, and one that declares a single group all keep the full
portable defaults for every group the repository did not declare. A declared
group may carry only `exclude` and no `include`: it then inherits the portable
include list unchanged and only tightens that group. ADR 0003 is
the source of truth for the exact portable include and exclude sets. Every
portable group excludes the built-in autonomous-merge policy surface -
`AGENTS.md`/`CLAUDE.md`, `**/SKILL.md`, `workflows/**`, `.agents/**`,
`docs/adr/**`, and the autonomous-merge helpers - so a repository cannot widen
its includes into a positive safe classification for a policy path.

Thresholds are inclusive maxima: the next value triggers human review. A value
above a portable default also requires
`threshold_relaxation.rationale`. Duplicate/unknown keys, wrong scalar types,
invalid enums or globs, and malformed mappings fail closed. Safe and generated
classifications never subtract common hard, repository path, size, churn,
rollback, or maintainer-concern gates. The evaluator always reads this mapping
from the trusted base, so a PR cannot weaken its own policy.

Glob patterns are repository-root-relative. A complete `**` path component
crosses zero or more components; `*`, `?`, and valid bracket classes remain
within one component. Absolute paths, `..`, negation, backslashes, braces,
empty or malformed bracket classes, and `**` embedded in another component
fail closed. A semantic assessment must explicitly set
`safe_classification_complete: true` and a valid `safe_class`; missing,
contradictory, or ambiguous safe classification yields `UNKNOWN`. Explicit
complete `safe_class: none` remains valid.

`repo_prefix` is optional. When present, it overrides the deterministic
repository-name abbreviation used as `<PROJECT>` in batch titles and, in
lowercase form, in thread handles. Its value must contain 1-6 uppercase ASCII
letters or digits. An invalid configured value is a seam-doctor error; an
absent key remains valid and uses the portable repository-name fallback. Omit
`repo_prefix` when it is unset; unlike neighboring policy keys, this optional
key does not accept the `n/a` sentinel.

Repos that use `untrusted-contributor-intake` add one explicit trusted-base
authority mapping. The seam doctor requires all three values when the mapping
is present, and the skill fails closed when the mapping is absent or invalid:

```yaml
untrusted_contributor_intake:
  trusted_github_host: "github.com"
  trusted_github_scheme: "https"
  trusted_github_repo: "OWNER/REPO"
```

### Merge submission

`merge_submission` is an optional closed mapping. Its portable default is
`direct` when the mapping is absent or explicitly selects `direct`. A
queue-enabled repository must explicitly select `merge_queue_only` or
`merge_queue_or_guarded_direct`; both modes use canonical enqueue while queue
control is active. Live queue control under direct mode fails before mutation
with a configuration error. Repositories that also need a repository-owned
direct guard may select the latter mode, whose executable is one fixed
repository-root-relative file under `.agents/bin`:

```yaml
merge_submission:
  mode: merge_queue_or_guarded_direct
  guarded_direct:
    executable: ".agents/bin/merge-pr-after-checks"
    method: squash
    non_atomic_base:
      acknowledged: true
      rationale: "The repository guard revalidates local policy immediately before direct squash."
```

The executable value is a path, never a command string: arguments, shell
fragments, interpolation, and paths outside `.agents/bin` are invalid. The
guard must exist as an executable regular file in the trusted-base tree and in
the invoking checkout with identical bytes. At runtime, `pr-merge-submit` does
not reopen that configured live path: it materializes the validated trusted-base
bytes as a private executable and invokes them from an isolated private Git
root whose detached `HEAD`, index, and working files all bind the receipt-base
commit and tree. This contract isolates HEAD/index/worktree state; it does not
promise object/ref confidentiality, and the materialized repository preserves
the source `origin`. PR identity exists only in revalidated live GitHub metadata and
the fixed argv; `git show HEAD` inside the guard cannot expose PR-tree bytes.
Repository-relative delegation therefore resolves trusted-base dependencies.
Every guard must have a supported explicit shebang; shebang-less files,
including native magic prefixes, fail closed before spawn. The helper parses
the trusted shebang and invokes an
identity-recorded absolute interpreter outside the consumer repository
directly; `/usr/bin/env PROGRAM` is resolved through a fixed trusted path rather
than the caller's `PATH`. The identity check and later absolute-path spawn have
a known filesystem TOCTOU window. The guard
receives a closed environment containing the explicit GitHub host/repository,
OS-account home and identity, fixed path, and supported GitHub token variables,
so variables such as `BASH_ENV`, `RUBYOPT`, and loader injection settings are
not inherited. The private executable and Git root are removed afterward;
cleanup failure after launch is an `UNKNOWN` outcome. Runtime `$0` and `__dir__`
identify the private copy, so guard adapters must resolve repository files from
the private working directory or passed argv. Internal validation and
materialization Git receives no GitHub tokens, SSH agent, or caller
credential/config controls. Preserved `origin` is metadata for the trusted
consumer guard; only that authorized guard receives supported GitHub token
variables. The helper supplies this fixed
argv contract, in order:

```text
--repo OWNER/REPO --host HOST --pr NUMBER
--expected-head SHA --expected-base BRANCH --expected-base-sha SHA
--method METHOD --merge-assurance-receipt ABSOLUTE_PATH
[--subject SUBJECT] [--body BODY]
```

The guard owns any additional direct-merge policy. Its exit status and output
do not prove a merge: the portable helper re-fetches GitHub and succeeds only
when the authorized head is an exact terminal merge on the expected base. This
exception explicitly acknowledges that GitHub direct merge has no atomic
expected-base OID; it does not make direct merge equivalent to the merge queue.
Queue-enabled PRs use canonical enqueue only in a queue-capable mode and never
invoke the guard; direct mode instead reports the required seam opt-in before
mutation. On a queue-disabled base, only explicit `merge_queue_only` is a
deterministic configuration error (exit 1), not an `UNKNOWN` mutation outcome.
An absent seam uses the portable direct path.

## AGENTS Pointer

Each consumer `AGENTS.md` owns a section named
`## Agent Workflow Configuration`, but the section is only a pointer:

```markdown
## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
```

Consumer repos should keep broader human guidance in `AGENTS.md`, but command
resolution and workflow policy come from the binstubs and YAML.

## Seam Initialization

`agent-workflow-seam-doctor --init` creates the smallest complete consumer seam
and immediately validates it through the same public interface. Initialization
preserves valid repo-owned wrappers and existing policy, trust, and unrelated
`AGENTS.md` content. It writes an empty repo-local trust configuration so a new
seam starts fail-closed.

The initializer conservatively detects executable root `bin/validate` and
`bin/test`, or exact JavaScript `validate` and `test` scripts when one recognized
lockfile identifies npm, pnpm, or Yarn. Unknown, partial, and ambiguous command
surfaces get marked fail-closed wrappers and a precise `FAIL` result. Callers can
instead pass both `--validate-command` and `--test-command`; multiline, empty,
and NUL-containing command values are rejected before any write. Simple commands
forward arguments automatically; npm gets its required `--` separator, while
pnpm and Yarn receive arguments directly. Compound shell expressions are kept
verbatim and must include `"$@"` themselves when forwarding is wanted. `env -S`
and `env --split-string` commands are likewise caller-controlled because their
split payload owns argument placement. Missing
policy or trust keys are appended to existing block mappings so comments and
formatting remain intact. Initialization also adds an explicit
`merge_submission.mode: direct` default. It fails closed before
writing when a safe append is not possible.

The init marker is the ownership boundary for generated wrappers. Explicit
commands replace both marked wrappers on a later run, while an unmarked valid
wrapper is repo-owned and preserved; explicit replacement of that repo-owned
wrapper fails closed. Put hand-written behavior behind a managed wrapper or
remove the marker deliberately before taking direct ownership.

## Seam Doctor

`agent-workflow-seam-doctor` validates the contract:

- `AGENTS.md` has the pointer section
- `.agents/bin/README.md` exists
- core scripts `validate` and `test` exist, are executable, pass `bash -n`, and
  include the repo-root `cd` preamble
- `.agents/agent-workflow.yml` parses and has all required policy keys with
  resolved values
- an optional `autonomous_merge` mapping conforms to the shared closed schema;
  malformed policy is reported instead of silently falling back
- an optional `merge_submission` mapping uses the closed direct, queue-only, or
  guarded-direct schema, and any configured guard is a present executable
  regular file under `.agents/bin`
- an optional `.agents/trusted-github-actors.yml` parses as a mapping and has no
  normalized bot login in both actionable and metadata-only roles; regular
  checks and `--init` preserve preflight compatibility with legacy scalar
  values, while newly generated role values use lists
- repo-local and supplied shared skill/workflow Markdown do not contain
  unresolved executable placeholders such as `<follow-up prefix>`

The doctor intentionally does not execute the wrappers. Before consumer PRs,
also verify that wrapped commands/tasks exist in the target repo. It does reject
the initializer's marked fail-closed wrappers until real commands replace them.

## Repository-Pinned Copies

Some repos may need a pinned copy of shared workflow files because their
execution environment cannot depend on user-installed skills or because shared
workflow updates must be reviewed inside that repo. Treat that as an explicit
deployment choice. The default architecture remains installed shared skills plus
a validated repo-owned seam.

## Validation

- `bin/validate`
- `ruby bin/agent-workflow-seam-doctor-test.rb`
- `ruby bin/push-downstream-test.rb`
- `bin/agent-workflow-seam-doctor --root <consumer-repo> --shared <this-repo>`
- Markdown review for edited docs
