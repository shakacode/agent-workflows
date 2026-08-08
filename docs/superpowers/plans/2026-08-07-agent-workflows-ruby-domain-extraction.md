# Agent Workflows Ruby Domain Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move remaining shared production Ruby command bodies into reviewable
`AgentWorkflows` domain classes while preserving every public CLI, genuinely
single-skill helper boundary, and safety contract.

**Architecture:** Apply branch-by-abstraction one domain at a time after the gem-foundation plan lands. Each task first characterizes the current executable, adds direct domain tests, moves behavior behind an injected CLI adapter, proves differential compatibility, and only then replaces the legacy file with a thin wrapper.

**Tech Stack:** Ruby 3.2+, Minitest, Open3-based CLI contract harness, injected Git/GitHub/process adapters, existing source-pack fixtures and `bin/validate`.

## Global Constraints

- Requires completion of `docs/superpowers/plans/2026-08-07-agent-workflows-gem-foundation.md`.
- Public package is `agent-workflows`; require path is `agent_workflows`; namespace is `AgentWorkflows`.
- Runtime dependencies remain Ruby standard library only.
- Existing command paths, argv, environment, output channels, JSON/marker schemas, and exit codes remain stable.
- No extraction PR changes security policy, merge authority, mutation authority, timeout semantics, or `UNKNOWN` behavior.
- Every mutating command keeps a non-mutating characterization corpus and separately tested mutation adapter.
- No domain task starts until its current executable passes its focused legacy suite at the task's base commit.
- Tests move with behavior; there is no final mass test rewrite.
- `bin/validate` and independent review pass at each review-sized PR boundary.
- The gem-foundation change to `AGENTS.md` is a prerequisite: shared production
  Ruby belongs in `lib/agent_workflows`, while invoking skill folders retain
  thin launchers and genuinely skill-local helpers.
- Every task that creates or moves a canonical `lib/agent_workflows` or `exe`
  file modifies and stages `agent-workflows.manifest` in the same commit. The
  package build fails for an omitted, duplicate, missing, absolute, or
  parent-traversing entry.
- Before each wrapper cutover, inventory every runtime file read relative to the
  checkout. Package required schemas, templates, datasets, and other resources
  under a canonical data path or inject them explicitly; never leave a gem
  command dependent on a source-checkout-relative path. Prove each new gem
  executable from an isolated installed gem outside the checkout and with the
  checkout temporarily unavailable.
- A skill-relative wrapper cannot cut over until the same PR updates the
  repo-local pinned-copy exporter, bundle manifest, and fixture. A pinned copy
  is one versioned `.agents` application generation containing either a complete
  selected skill entrypoint for hosts that need repo-local discovery or an
  explicitly companion-only helper set for one validated installed/native skill
  route. Both contain `lib/agent_workflows.rb`, `lib/agent_workflows/**`,
  resources, and `agent-workflows-bundle.json`; wrapper-only pins are invalid.

---

## File Structure

### Shared testing support

- `test/support/cli_contract.rb`: invoke a Ruby command with exact env, stdin, cwd, timeout, and captured channels.
- `test/support/fake_command.rb`: create bounded fake `git`, `gh`, or coordination executables.
- `test/support/differential_contract.rb`: compare legacy and extracted results while allowing explicit normalized temporary paths.

### Domain mapping

| Current surface | Canonical folder |
| --- | --- |
| `bin/agent-workflow-seam-doctor` | `lib/agent_workflows/seam` |
| `skills/pr-batch/bin/pr-security-preflight` | `lib/agent_workflows/security` and `lib/agent_workflows/trust` |
| `skills/plan-pr-batch/bin/*` | `lib/agent_workflows/batch` |
| `skills/pr-batch/bin/dispatcher-*`, `stage-*`, `stale-*`, `agent-coord-*` | `lib/agent_workflows/batch` |
| `skills/pr-batch/bin/pr-ci-readiness` | `lib/agent_workflows/readiness` |
| `skills/pr-batch/bin/autonomous-*`, `merge-assurance`, `pr-merge-submit` | `lib/agent_workflows/merge` |
| `skills/post-merge-audit/bin/*` | `lib/agent_workflows/audit` |
| root status, delivery, drift, validators | `lib/agent_workflows/distribution` |
| `bin/push-downstream`, changelog, task-observer, review-data helpers | `lib/agent_workflows/maintainer` or owning skill domain |

Every retained root or skill-relative executable becomes a launcher below 30
lines that calls one `AgentWorkflows::CLI::<Name>.start` method. Root wrappers
load `lib/agent_workflows` from the verified installed root. A fixed trampoline
resolved from `.agents/skills/<skill>/bin` contains the exact relative immutable
generation identity and helper name selected when that trampoline was created.
It invokes only that generation and never follows the mutable status pointer or
falls back to a gem, host-global install, another generation, or source checkout.
The generation wrapper validates its bundle manifest before loading its `lib`.

A skill-relative launcher running from a source checkout, a flat source-pack
install, or a Codex/Claude native-plugin cache derives one candidate package
root from its own real path using a fixed reviewed ancestry. It requires the
matching source/plugin manifest and `agent-workflows.manifest` at that root,
validates the canonical library there, and never searches a companion install,
RubyGems, or another checkout. Native-plugin cache layouts are first-class
launch paths, not aliases for `plugin-companion`.

### Repo-local pinned-copy bundle

- Create `bin/export-agent-workflows-pinned-copy` as the only supported producer
  of repo-local `.agents` pins. It accepts an explicit target, helper allowlist,
  and mutually exclusive delivery mode and refuses a dirty or
  revision-ambiguous source. `full-skill` mode is the supported fallback for a
  host that cannot load installed or native-plugin skills: it versions the
  complete selected skill entrypoint, including `SKILL.md`, `agents/` metadata,
  helper files, and any workflow references required by that entrypoint.
  `helper-companion` mode is allowed only when the consumer records and validates
  one installed or native-plugin skill-delivery route; it exports no
  picker-visible metadata. Both modes stage selected `skills/<skill>/bin`,
  `scripts`, or genuinely skill-local runtime files, canonical library,
  resources, and a generated
  `agent-workflows-bundle.json` beneath
  `.agents/.agent-workflows-generations/<source-revision>-<bundle-digest>/`.
  Compute `bundle-digest` from the canonical JSON containing the package
  version, full source revision, sorted helper allowlist, and a sorted entry for
  every wrapper, library file, and resource with relative path, file mode, and
  SHA-256. Thus two helper sets from the same revision are distinct immutable
  generations. This generated binding is distinct from the gem's source
  allowlist `agent-workflows.manifest`.
- The two modes must never coexist for the same skill and consumer. `full-skill`
  is one complete, version-bound, invocable skill-delivery route and must reject
  an installed/native route that would make the skill auto-invocable twice.
  `helper-companion` remains a checkout-only helper copy and rejects use unless
  its recorded installed/native route is present. Move packaged fallback data
  such as trust defaults under the canonical library resource path before its
  helper wrapper cuts over.
- Validate every staged entry, then atomically rename the staged directory into
  its immutable generation name. In `full-skill` mode, require exporter ownership
  of the complete stable `.agents/skills/<skill>` path and atomically replace
  that path with one relative symlink to the immutable generation's complete
  skill subtree; reject repo-owned files or a host that cannot discover and
  resolve that symlink to the generation root. In `helper-companion` mode, do not
  replace whole skill directories because they may coexist with repo-owned local
  skills and unrelated pinned helpers. Instead, create one fixed, minimal
  trampoline per selected helper path. Each trampoline binds its helper directly
  to one complete immutable generation. On first migration, build and select the
  complete generation before atomically renaming each staged symlink or
  trampoline over its legacy path. Each invocation therefore opens either the
  complete old path or the complete new path; there is no missing-path or
  half-written interval. Subsequent updates atomically replace each affected
  generation-bound stable path and then update the single
  `.agents/agent-workflows-current` symlink used only for status and exporter
  bookkeeping; runtime launch never follows that pointer. Refuse unmanaged
  collisions, serialize exporters with a no-follow lock, and retain every
  superseded generation until an explicit garbage-collection operation proves
  consumer quiescence. Normal export never deletes a generation.
- Treat the requested helper allowlist as the complete desired managed set and
  read the prior exporter receipt before building an update. For additions or
  removals, first build a transition generation containing the sorted union of
  the prior and desired helper sets, then atomically write a separate
  transaction journal before the first pointer or trampoline mutation. The
  journal records the prior and desired sets, prior, union, and compact
  generation identities and digests, source revision, delivery mode, canonical
  stable-path template digest, and a phase from `prepared`, `union_selected`,
  `paths_reconciled`,
  `compact_selected`, or `committed`. Build the complete union generation,
  atomically replace or add generation-bound trampolines, and atomically unlink
  trampolines no longer in the desired set, advancing the journal after each
  durable phase. Only after every stable path matches the desired set may the
  exporter build/select a compact desired-only generation for new trampolines
  and status. It retains both prior and union generations. A process that opened
  an old trampoline before replacement or unlink reads that already-open file,
  which names a still-present immutable generation; a new invocation opens only
  the new trampoline. Refuse an update when the prior receipt or managed-helper
  set cannot be reconciled exactly.
- Every helper trampoline uses one fixed canonical template parameterized only
  by its validated relative generation identity and helper name; every
  full-skill symlink uses one canonical relative-target rule. The exporter
  verifies each stable path, mode, rendered inputs or link target, and SHA-256
  before and after reconciliation. An exporter-owned
  stable receipt outside the generation records the completed managed-helper
  set, delivery mode, and canonical stable-path digest for the next update/status
  check; replace
  it atomically only at the journal's `committed` phase. On startup under the
  exporter lock, an extant journal is validated against immutable manifests,
  the current pointer, stable paths, and the prior receipt. Resume each phase
  idempotently when its recorded inputs still match; otherwise roll back to the
  recorded complete prior generation and helper set without deleting ambiguous
  paths. If neither resume nor rollback is provably safe, fail with the exact
  journal and path discrepancy for human disposition. Remove the journal only
  after the new stable receipt and desired paths read back successfully. Runtime
  wrappers do not reread either mutable file. A trampoline validates the
  generation identity and helper name embedded in its own already-open bytes,
  then executes its named wrapper in that immutable generation. The selected
  generation wrapper requires that helper
  name in its own immutable manifest and verifies its own entry plus all runtime
  entries required by its CLI against source revision, helper-set digest, mode,
  and SHA-256 before loading Ruby. It does not reread or require a match with the
  live current pointer: an invocation bound to the old complete generation
  before an atomic update is allowed to finish while new invocations select the
  new one. Package version alone is never accepted as a generation binding.
- Before migration, inventory every tracked path under each consumer's pinned
  shared-helper directories and compare it with its recorded source revision.
  Refuse any directory containing repo-specific skills, deliberate overrides,
  or unclassified edits; those require an explicit consumer-owned disposition.
  Classify each consumer as `full-skill` or `helper-companion` and prove that its
  selected mode leaves exactly one invocable skill route. Migrate one canary
  consumer first, then update every supported pinned consumer
  through its own reviewed PR. The first skill-wrapper cutover cannot merge
  until the canary passes and every remaining consumer either has the complete
  generation bundle or explicitly retains the pre-cutover helper body.
- Add `test/pinned_copy/export_test.bash` and fixture consumers containing no
  gem, host-global library, or source checkout. Before the first skill wrapper
  cutover, prove exported helpers run from the fixture, a partial or
  version-mismatched library fails with exit `64`, and same-version stale or
  mixed-generation wrapper/library bytes fail their digest or generation check.
  Prove an old wrapper-only pin fails with upgrade guidance and unrelated
  `.agents` files survive. Prove `full-skill` fixtures remain discoverable and
  resolve the loaded skill base to one immutable generation carrying matching
  skill-policy/helper revisions, `helper-companion` fixtures contain no
  picker-visible metadata, and mode collisions fail closed. An
  invocation during every initial trampoline replacement and status-pointer
  fault must see only an old or new complete implementation; an invocation
  paused after opening a trampoline must finish against its bound immutable
  generation, two helper allowlists at one source revision coexist without
  overwrite, and concurrent invocations must survive both helper addition and
  removal, including a process paused after opening a soon-to-be-unlinked
  trampoline. Fault injection before and after every journal, pointer,
  trampoline, receipt, and compaction write proves the next exporter invocation
  idempotently resumes or restores a complete prior set. Prove normal exports
  never delete superseded generations; test explicit garbage collection only
  behind a recorded quiescence assertion and fail closed when quiescence cannot
  be established. An irreconcilable
  fixture must fail closed without changing any additional stable path.
- Update the installation/adoption documentation and every supported pinned-copy
  updater to invoke this exporter. `bin/push-downstream` remains a seam
  synchronizer and must not silently acquire shared-skill copying behavior.
- Add the exporter, its tests, and pinned-layout documentation in the first
  domain PR that cuts over a skill-relative helper. No later domain task may
  defer this prerequisite.

### Task 1: Build the reusable characterization harness

**Files:**

- Create: `test/support/cli_contract.rb`
- Create: `test/support/fake_command.rb`
- Create: `test/support/differential_contract.rb`
- Create: `test/gem/support/cli_contract_test.rb`
- Create: `test/gem/support/differential_contract_test.rb`
- Modify: `Rakefile`

**Interfaces:**

- Consumes: Ruby standard library `open3`, `tempfile`, `tmpdir`, and `timeout`.
- Produces:

```ruby
CliContract.run(command:, argv: [], env: {}, stdin: "", chdir:, timeout: 10)
# => CliContract::Run(stdout:, stderr:, exit_status:, timed_out:)

DifferentialContract.assert_same(test_case, legacy:, extracted:, normalize:)
```

- [ ] **Step 1: Write harness tests**

```ruby
run = CliContract.run(
  command: RbConfig.ruby,
  argv: ["-e", "STDOUT.write('out'); STDERR.write('err'); exit 3"],
  chdir: Dir.pwd
)
assert_equal "out", run.stdout
assert_equal "err", run.stderr
assert_equal 3, run.exit_status
refute run.timed_out
```

Add a timeout case whose child traps `TERM`; assert the harness terminates the process group, reports `timed_out`, and leaves no sentinel child alive. Add a differential mismatch case that reports stdout, stderr, and exit-status differences together.

- [ ] **Step 2: Run tests and verify missing constants**

Run: `ruby -Itest test/gem/support/cli_contract_test.rb && ruby -Itest test/gem/support/differential_contract_test.rb`

Expected: failure because the support classes do not exist.

- [ ] **Step 3: Implement bounded execution**

Use `Process.spawn(..., pgroup: true)`, nonblocking pipe reads, a monotonic deadline, `TERM` followed by bounded `KILL`, and `Process.waitpid2`. The run result never raises merely because the child exits nonzero. It raises `ArgumentError` only for invalid harness input.

- [ ] **Step 4: Implement fake commands and differential assertions**

`FakeCommand.write(dir:, name:, body:)` writes an executable file with a fixed Ruby shebang from `RbConfig.ruby`. `DifferentialContract` runs both commands with separately cloned fixture roots and compares normalized strings plus exit status.

- [ ] **Step 5: Run support tests and lint**

Run:

```bash
ruby -Itest test/gem/support/cli_contract_test.rb
ruby -Itest test/gem/support/differential_contract_test.rb
rubocop "_$(tr -d '[:space:]' < .rubocop-version)_" test/support test/gem/support
```

Expected: PASS.

- [ ] **Step 6: Commit the harness**

```bash
git add Rakefile test/support test/gem/support
git commit -m "test: add Ruby CLI characterization harness"
```

### Task 2: Extract the seam doctor in three review slices

**Files:**

- Create: `lib/agent_workflows/seam/shell_command.rb`
- Create: `lib/agent_workflows/seam/javascript_command.rb`
- Create: `lib/agent_workflows/seam/initializer.rb`
- Create: `lib/agent_workflows/seam/validator.rb`
- Create: `lib/agent_workflows/seam/policy.rb`
- Create: `lib/agent_workflows/seam/renderer.rb`
- Create: `lib/agent_workflows/cli/seam_doctor.rb`
- Create: `test/gem/seam/*_test.rb`
- Modify: `bin/agent-workflow-seam-doctor`
- Modify: `bin/agent-workflow-seam-doctor-test.rb`
- Modify: `exe/agent-workflow-seam-doctor`
- Modify: `agent-workflows.manifest`
- Modify: `agent-workflows.gemspec`

**Interfaces:**

```ruby
AgentWorkflows::Seam::ShellCommand.new(source).forwarding_plan
AgentWorkflows::Seam::Initializer.new(filesystem:, detector:).call(request)
AgentWorkflows::Seam::Validator.new(filesystem:, git:).call(root:, shared_roots:)
AgentWorkflows::CLI::SeamDoctor.start(argv, env:, input:, output:, error:) # => Integer
```

- [ ] **Step 1: Freeze shell and package-manager parsing**

Move the current command-forwarding assertions into direct tests for `ShellCommand` and `JavascriptCommand`. Include ANSI-C quoting, command substitutions, positional parameters, `env -S`, `exec`, shell `-c`, npm separator insertion, pnpm/yarn behavior, required option values, and hostile/ambiguous compound commands.

- [ ] **Step 2: Implement parsers without filesystem mutation**

Move only pure parsing methods from the legacy module. Return immutable plans containing original source, token spans, command family, and wrapper run line. Preserve the legacy error strings in typed `Seam::CommandError` instances.

- [ ] **Step 3: Freeze initializer and validator filesystem effects**

Characterize exact created bytes, file modes, preservation of unmanaged files, pointer-section reconciliation, YAML mapping validation, shared-root checks, text output, JSON output, and idempotent second runs. Use disposable fixture copies.

- [ ] **Step 4: Implement initializer, validator, policy, and renderer**

`Initializer` owns writes and accepts a filesystem collaborator. `Validator` returns an array of typed findings and performs no writes. `Renderer.text(findings)` and `Renderer.json(findings)` preserve current output. `Policy` owns `.agents/agent-workflow.yml` and trust mapping validation.

- [ ] **Step 5: Add the CLI and differential corpus**

Run legacy and extracted commands over every non-mutating validation fixture and `--init` over independent identical fixture copies. Normalize only temporary absolute roots. Assert exact channels and exit statuses.

- [ ] **Step 6: Replace the legacy body and run the full seam suite**

The old path becomes a thin launcher. Run:

```bash
ruby bin/agent-workflow-seam-doctor-test.rb
ruby -Ilib test/gem/seam/shell_command_test.rb
ruby -Ilib test/gem/seam/initializer_test.rb
ruby -Ilib test/gem/seam/validator_test.rb
bin/agent-workflow-seam-doctor --root test/fixtures/consumer-repo --shared .
bin/validate
```

Expected: all established assertions and full validation pass.

- [ ] **Step 7: Commit as three PR-sized commits**

Commit pure parsing, initializer/writes, and validator/CLI cutover separately with messages `refactor: extract seam command parsing`, `refactor: extract seam initialization`, and `refactor: extract seam validation`.

### Task 3: Extract GitHub trust and security preflight

**Files:**

- Create: `lib/agent_workflows/github/client.rb`
- Create: `lib/agent_workflows/github/paginator.rb`
- Create: `lib/agent_workflows/git/probe_environment.rb`
- Create: `lib/agent_workflows/trust/configuration.rb`
- Create: `lib/agent_workflows/trust/resolver.rb`
- Create: `lib/agent_workflows/security/content_scanner.rb`
- Create: `lib/agent_workflows/security/participant_scanner.rb`
- Create: `lib/agent_workflows/security/preflight.rb`
- Create: `lib/agent_workflows/cli/security_preflight.rb`
- Create: `test/gem/{github,git,trust,security}/*_test.rb`
- Create: `bin/export-agent-workflows-pinned-copy`
- Create: `test/pinned_copy/export_test.bash`
- Create: `test/fixtures/pinned-copy-consumer/.agents/*`
- Modify: `skills/pr-batch/bin/pr-security-preflight`
- Modify: `skills/pr-batch/bin/pr-security-preflight-test.rb`
- Modify: `agent-workflows.manifest`
- Modify: pinned-copy installation and adoption documentation.
- Delete after cutover: `skills/pr-batch/lib/git_probe_env.rb`

**Interfaces:**

```ruby
AgentWorkflows::GitHub::Client#json(*args, timeout:) # => Hash or Array
AgentWorkflows::GitHub::Paginator#connection(query:, variables:, path:) # => Array
AgentWorkflows::Trust::Resolver#trusted_actor?(login, repository:)
AgentWorkflows::Security::Preflight#call(repository:, targets:, acknowledged_risks:) # => Result
```

- [ ] **Step 1: Characterize transport and coverage failures**

Extract existing fake-`gh` cases for nonzero exit, timeout, malformed JSON, page cap, missing `pageInfo`, partial GraphQL errors, unknown actor, team lookup failure, and rate limits into direct client/paginator tests. Preserve exact error categories used by the CLI.

- [ ] **Step 2: Implement transport adapters**

`AgentWorkflows::GitHub::Client` receives the canonical
`AgentWorkflows::Process::Runner` from the foundation plan and a command path.
It never shells out through a string. `Paginator` owns cursor progression and
explicit coverage failure; it does not know trust policy. No GitHub- or
doctor-specific runner may duplicate this boundary.

- [ ] **Step 3: Characterize and implement trust resolution**

Cover and preserve exact trust configuration precedence: explicit flag,
repo-local config, `AGENT_WORKFLOWS_TRUST_CONFIG`, home config, then packaged
fallback. Test a populated and empty file at every tier, missing environment
paths, GitHub host/repository binding, bot normalization, team membership,
collaborator permission, untrusted interactions, malformed config, and
canonical-path safety. `Trust::Resolver` receives client and configuration
objects and caches only within one preflight call.

- [ ] **Step 4: Characterize and implement scanners**

Move suspicious added-line location, issue/review/comment text, reaction, source-actor, participant, high-risk-file, and warning-deduplication cases into scanner tests. Scanners receive already fetched records and return typed findings; they never call GitHub directly.

- [ ] **Step 5: Compose preflight and replace the wrapper**

`Security::Preflight` coordinates fetch, trust, and scanners and returns a
result. The CLI owns option parsing, finding order, formatting, and established
exit status. Before replacing this first skill-relative wrapper, implement the
pinned-copy exporter and all atomicity, collision, partial-library,
version-mismatch, source-absent, and rollback cases from the pinned-copy bundle
contract. Run the entire existing 3,000-plus-line test suite plus direct tests
and a differential non-mutating corpus in source, installed-source-pack,
installed-gem, exported repo-local-pin, Codex native-plugin-cache, and Claude
native-plugin-cache layouts. Each native fixture contains a host-shaped cache
and enabled-plugin receipt but no companion install, gem, global library, or
source checkout. Tests relocate the cache, invoke through the host-visible skill
path, and prove root discovery, manifest provenance, packaged fallback data,
missing-library failure, and same-version mixed-byte rejection.

- [ ] **Step 6: Run security closeout gates**

Run:

```bash
ruby skills/pr-batch/bin/pr-security-preflight-test.rb
ruby -Ilib test/gem/github/client_test.rb
ruby -Ilib test/gem/github/paginator_test.rb
ruby -Ilib test/gem/trust/resolver_test.rb
ruby -Ilib test/gem/security/preflight_test.rb
bash test/pinned_copy/export_test.bash
bin/validate
```

Then perform independent adversarial review focused on trust-source precedence, partial API coverage, path binding, timeout cleanup, and fail-closed results.

- [ ] **Step 7: Commit transport, trust, scanners, and CLI cutover separately**

Use four review-sized commits. Delete `git_probe_env.rb` only in the final cutover commit after `rg` proves no caller remains.

### Task 4: Extract batch planning, routing, dependency, and readiness domains

**Files:**

- Create: `lib/agent_workflows/batch/{plan,route,assignment,dependency_graph,stale_assignment_sweep,coordination}.rb`
- Create: `lib/agent_workflows/readiness/{check_run,decision,evaluator}.rb`
- Create: corresponding `lib/agent_workflows/cli/*.rb`
- Create: `test/gem/batch/*_test.rb`, `test/gem/readiness/*_test.rb`
- Modify: `agent-workflows.manifest`
- Modify wrappers and legacy tests for `batch-plan-preflight`, `dispatcher-capability-preflight`, `stage-dependency-gate`, `stale-assignment-sweep`, `agent-coord-bounded`, and `pr-ci-readiness`.

**Interfaces:**

```ruby
AgentWorkflows::Batch::Route.select(requested:, candidates:, authority:, history:) # => Route::Decision
AgentWorkflows::Batch::DependencyGraph.evaluate(lanes:, edges:, observations:) # => Result
AgentWorkflows::Batch::StaleAssignmentSweep.plan(items:, now:, policy:) # => Array<Action>
AgentWorkflows::Readiness::Evaluator.call(pull_request:, check_runs:, reviews:, policy:) # => Readiness::Decision
```

- [ ] **Step 1: Extract immutable route and dependency decisions**

Move current canonicalization, replay, replacement fencing, operator-decision, critical-path, and identity validation assertions into direct tests. Build `Data` value objects only after input hashes pass explicit shape validation; malformed and nested `UNKNOWN` cases remain rejected.

- [ ] **Step 2: Extract coordination process bounds**

Move `agent-coord-bounded` process-group logic behind
`AgentWorkflows::Process::Runner`. Preserve captured output order, signal
escalation, timeout exit status, and descendant cleanup tests; extend the
shared runner only through its own direct tests if this command exposes a
missing general capability.

- [ ] **Step 3: Separate stale-sweep planning from mutation**

`StaleAssignmentSweep.plan` is pure and returns `Action` values. A GitHub mutation adapter re-reads live state immediately before each authorized comment or assignment change. Existing warn, grace, release, bot, exemption, multiple-human, terminal-item, and per-item failure cases remain exact.

- [ ] **Step 4: Extract readiness interpretation**

Create typed check-run and review observations. Preserve missing required-check fallback policy, exact-head binding, duplicate/context handling, pending/failed/skipped interpretation, review-thread states, and JSON/text rendering.

- [ ] **Step 5: Cut over one command at a time**

For each command, run its full legacy test, direct domain tests, differential corpus, and `bin/validate` before replacing the next body. Do not combine route selection and readiness in one review diff.

- [ ] **Step 6: Commit each independently reviewable domain**

Use separate commits for route/assignment, dependency graph, coordination bounds, stale sweep, and readiness.

### Task 5: Extract merge policy, assurance, and submission

**Files:**

- Move: `skills/pr-batch/lib/autonomous_merge_*.rb` into `lib/agent_workflows/merge/`.
- Move: `bin/agent_doctor/autonomous_merge_policy*.rb` into `lib/agent_workflows/merge/`.
- Create: `lib/agent_workflows/merge/{policy,evidence,eligibility,calibration,assurance,submission,trusted_snapshot}.rb`
- Create: `lib/agent_workflows/cli/{autonomous_merge_calibrate,autonomous_merge_eligibility,merge_assurance,pr_merge_submit}.rb`
- Create: `test/gem/merge/*_test.rb`
- Modify: `agent-workflows.manifest`
- Modify current merge wrappers and focused tests.
- Modify runtime-trust fixture paths and provenance tests.

**Interfaces:**

```ruby
AgentWorkflows::Merge::Eligibility.call(policy:, evidence:, runtime_trust:) # => Decision
AgentWorkflows::Merge::Assurance.call(context:, receipts:, now:) # => Result
AgentWorkflows::Merge::Submission.call(request:, assurance:, policy:) # => Result
AgentWorkflows::Merge::TrustedSnapshot.materialize(repository:, base_sha:, executable:) { |snapshot| ... }
```

- [ ] **Step 1: Move autonomous policy and evidence with no behavior change**

Convert namespaces and require paths, preserve calibration dataset and digest
behavior, and run every autonomous-merge test before deleting the skill-local
library files and the three deferred `bin/agent_doctor` policy files. Update the
runtime-trust manifest, workflow documentation, seam doctor, and installed-copy
fixtures in the same cutover; no compatibility lookup searches both locations.

- [ ] **Step 2: Extract assurance parsing and semantic validation**

Split receipt parsing, target binding, timestamps, evidence digests, authority, walkthrough, operation validation, semantic tracker authentication, and result rendering. Direct tests cover every existing invalid shape and timeout.

- [ ] **Step 3: Extract trusted snapshot materialization**

Create one object owning trusted-base file lookup, shebang parsing, closed environment, private Git root, fixed argv, process execution, cleanup, and cleanup-`UNKNOWN`. Its tests preserve path traversal, mode, object/ref, token redaction, symlink, interpreter, replacement, and cleanup cases.

- [ ] **Step 4: Extract submission state machine**

Keep queue submission and guarded direct submission separate strategies. Both re-fetch exact GitHub state after action. Ambiguous action outcomes remain `UNKNOWN`; a successful child exit never alone proves a merge.

- [ ] **Step 5: Bind runtime provenance to the gem tree**

Replace old path lists with a versioned manifest of canonical library files, wrappers, and calibration fixtures. Tests prove modified, missing, extra-unexpected, and wrong-version bytes fail closed.

- [ ] **Step 6: Run merge closeout gates**

Run all autonomous, assurance, and submission suites, full validation, then independent adversarial review focused on authority separation, exact-head/base binding, environment closure, trusted snapshot isolation, post-mutation verification, and cleanup.

- [ ] **Step 7: Commit policy, assurance, snapshot, and submission separately**

Delete old skill-local libraries only after `rg` and packaging tests prove all installed layouts use canonical files.

### Task 6: Extract completed-batch audit and replay

**Files:**

- Create: `lib/agent_workflows/audit/{marker,follow_up,publication_snapshot,publication_preflight,replay,check_timing,renderer}.rb`
- Create: CLI adapters for every `skills/post-merge-audit/bin/*` Ruby command.
- Create: `test/gem/audit/*_test.rb`
- Modify: `agent-workflows.manifest`
- Modify post-merge wrappers, tests, fixtures, and package manifest.

**Interfaces:**

```ruby
AgentWorkflows::Audit::Marker.parse(text) # => Marker or InvalidMarker
AgentWorkflows::Audit::PublicationPreflight.call(input:, policy:, observations:, now:) # => Result
AgentWorkflows::Audit::Replay.call(marker:, live_state:, external_blockers:) # => ReplayResult
```

- [ ] **Step 1: Extract marker grammar as pure values**

Move canonical Unicode normalization, delimiter validation, exact/nested `UNKNOWN`, status/action compatibility, duplicate ref identity, finding-to-record lookup, publication snapshot, and blocker union assertions into direct parser/value tests.

- [ ] **Step 2: Extract publication preflight**

Separate input parsing, target-manifest binding, coordination interpretation, terminal target/head validation, QA evidence/waiver authentication, freshness, and receipt generation. Each collaborator returns typed findings; the orchestrator determines eligibility.

- [ ] **Step 3: Extract replay and rendering**

Replay accepts parsed marker plus refreshed observations. Renderer alone produces managed sections, compact references, JSON, and final human status. Preserve exact marker and final-status text asserted by current tests.

- [ ] **Step 4: Extract bounded GitHub publication**

Keep authentication, one comment POST, exact returned-ID readback, and separately retriable PR-description update in a mutation adapter. Tests retain ambiguous POST, missing readback, wrong actor, wrong repository, description retry, and no-second-comment cases.

- [ ] **Step 5: Cut over commands and run full audit gates**

Run every post-merge-audit Ruby and Bash test, direct tests, fixture replays, full validation, and adversarial review focused on normalization, freshness, target set equality, mutation ambiguity, and blocker union completeness.

- [ ] **Step 6: Commit parser, preflight, publication, and replay separately**

Each commit leaves all command paths operational.

### Task 7: Extract distribution, validation, and maintainer commands

**Files:**

- Create: `lib/agent_workflows/distribution/{delivery_state,status,trust_audit,drift,manifest_validator,review_finding_validator,solution_validator}.rb`
- Modify: `lib/agent_workflows/distribution/install_ownership.rb` from the
  foundation as the surrounding distribution abstractions arrive; assert the
  foundation already removed every legacy doctor-ownership caller.
- Create: `lib/agent_workflows/maintainer/{downstream_registry,downstream_sync,changelog,review_data,task_observer}.rb`
- Create corresponding CLI adapters and direct tests.
- Modify: `agent-workflows.manifest`
- Modify root and skill-relative wrappers and legacy tests.

**Interfaces:**

```ruby
Distribution::Status.call(install:, source:, fetch:) # => Result
Distribution::Drift.call(source:, installed:, manifest:) # => Result
Maintainer::DownstreamSync.plan(registry:, selection:, policy:) # => Plan
Maintainer::DownstreamSync.apply(plan:, git:, github:) # => Result
```

- [ ] **Step 1: Extract read-only distribution state**

Move delivery-mode, native/flat detection, install metadata, source revision,
status, trust-audit planning, and drift comparison into injected objects.
Fail if any `bin/agent_doctor/install_ownership.rb` body or caller survived the
foundation cutover; keep ownership behavior under
`AgentWorkflows::Distribution::InstallOwnership` while composing it with the
new metadata objects. Preserve encoding scrubbing, no-follow path checks,
tree-digest/marker compatibility, and no-network defaults.

- [ ] **Step 2: Extract validators**

Move Codex plugin manifest, OpenAI metadata, host-adapter syntax, solution docs, and review-finding schema logic into domain validators returning findings. CLI adapters retain current output and exit codes.

- [ ] **Step 3: Split downstream planning from publication**

Extract registry/preset loading, contract resolution, scaffold reconciliation, policy byte patching, branch isolation, PR state, and publication into separate objects. Dry-run plans contain every intended file and action. Apply revalidates base, branch, and selected policy keys before each mutation.

- [ ] **Step 4: Extract smaller maintainer helpers**

Move changelog merged-PR collection, review data collection, autoreview target state, task observer, and prompt-size validation into their owning namespaces with direct tests and thin wrappers.

- [ ] **Step 5: Run focused and aggregate validation after each wrapper cutover**

For `push-downstream`, retain dry-run as the default and run its full 2,000-plus-line test plus registry dry-run. For every validator, run its existing test and current live repository validation input.

- [ ] **Step 6: Commit read-only distribution, validators, downstream sync, and small helpers separately**

Do not combine fleet mutation code with unrelated validators.

### Task 8: Remove remaining legacy bodies and ratchet quality

**Files:**

- Delete: migrated shared production bodies remaining under root `bin/*` and
  skill paths after replacing them with launchers or canonical library files.
  Retain genuinely single-skill Ruby helpers under their invoking skill.
- Modify: `.rubocop.yml`, `agent-workflows.gemspec`, `Rakefile`, `bin/validate`, docs, and changelog.
- Modify/split: legacy test files whose subject is now a canonical class.
- Create: `test/packaging/require_boundary_test.rb`.
- Create: `config/ruby-production-boundaries.yml` with reviewed retained
  single-skill helpers and repository-only entrypoints.

**Interfaces:**

- Consumes: all extracted domains.
- Produces: one production implementation tree and enforced reviewability limits.

- [ ] **Step 1: Inventory every tracked Ruby production file**

Run the same tracked-file classifier used in the design evidence. Every
production Ruby file outside canonical `lib` and `exe` must be classified as a
launcher below 30 lines, a genuinely single-skill helper owned by its invoking
skill, or a repository-only validation entrypoint. Require a short ownership
rationale and direct tests for each retained skill-local helper; move any helper
used by multiple skills or repo-wide commands into the gem.

- [ ] **Step 2: Prove there are no obsolete implementation requires**

Run:

```bash
rg -n 'require_relative.*bin/agent_doctor' --glob '*.rb' --glob 'bin/*' --glob 'skills/*/bin/*'
rg -n 'require_relative.*(?:\.\./)+lib/' --glob '*.rb' --glob 'bin/*' --glob 'skills/*/bin/*'
ruby test/packaging/require_boundary_test.rb
```

The boundary test enumerates tracked production Ruby files and Ruby-shebang
launchers, parses every literal `require_relative` with `Ripper`, resolves the
target with Ruby's optional `.rb` rule, and fails on a missing target or a
resolved target under `bin/agent_doctor`. A target under `skills/*/lib` is
accepted only when the boundary manifest classifies it as genuinely local to
that same invoking skill and no tracked caller outside that skill resolves it.
It also fails closed on dynamic `require_relative` arguments until explicitly
classified. Expected: searches and resolver report no obsolete or cross-skill
production dependency.

- [ ] **Step 3: Enable gem metrics without blanket exclusions**

Remove temporary migration exclusions. Run RuboCop and split real responsibility violations. Use local documented exceptions only where a parser table or immutable schema definition is clearer intact.

- [ ] **Step 4: Split test files by behavior**

For each test file over 800 lines, split by parser/policy/transport/rendering/CLI behavior when setup and assertions are independent. Keep shared builders under `test/support`; do not hide assertions in helper methods.

- [ ] **Step 5: Run the complete matrix and package smoke**

Run `bin/validate` on Ruby 3.2 and 3.4, build/install the gem, run every gem executable, run flat/plugin copy and symlink installer suites, and run `git diff --check`.

- [ ] **Step 6: Perform final architecture and adversarial reviews**

Use `plan-review` against the approved design for scope completion, `autoreview` on the branch diff, and adversarial review on security/merge/audit changes. Resolve findings and rerun exact touched and aggregate gates.

- [ ] **Step 7: Commit legacy removal and quality ratchet**

```bash
git add -A
git commit -m "refactor: complete agent workflows Ruby domain extraction"
```

## Plan Completion Gate

- All shared production Ruby behavior lives under `AgentWorkflows`; each
  retained skill-local helper has one invoking-skill owner, direct tests, and no
  cross-skill caller.
- Root and skill-relative Ruby commands are thin launchers.
- Every old focused test and new direct-domain test passes.
- Security, merge, and audit independent reviews report no unresolved blocking finding.
- Package content contains every runtime file and no repository-only tests.
- Full Ruby 3.2/3.4 validation, installer modes, standalone Codex/Claude native
  plugin caches, package smoke, and `git diff --check` pass.
- No package publication occurs under this plan.
