# Agent Workflows Ruby Domain Extraction Implementation Plan

> **Execution note:** Work task-by-task. Host-provided plan-execution or
> subagent capabilities are optional accelerators, not repository dependencies;
> when unavailable, follow the checked steps directly.

**Goal:** Move remaining shared production Ruby command bodies into reviewable
`AgentWorkflows` domain classes while preserving every public CLI, genuinely
single-skill helper boundary, and safety contract.

**Architecture:** Apply branch-by-abstraction one domain at a time after the gem-foundation plan lands. Each task first characterizes the current executable, adds direct domain tests, moves behavior behind an injected CLI adapter, proves differential compatibility, and only then replaces the legacy file with a thin wrapper.

**Tech Stack:** Ruby 3.3+, Minitest, Open3-based CLI contract harness, injected Git/GitHub/process adapters, existing source-pack fixtures and `bin/validate`.

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
- Before every commit, expand the task's final changed-file inventory to literal
  file and deletion paths and compare it with `git diff --cached --name-only`.
  Directory pathspecs, globs, and `git add -A` are never valid staging shortcuts.
- The gem-foundation change to `AGENTS.md` is a prerequisite: shared production
  Ruby belongs in `lib/agent_workflows`, while invoking skill folders retain
  thin launchers and genuinely skill-local helpers.
- Every task that creates or moves a canonical `lib/agent_workflows` or `exe`
  file modifies and stages both `agent-workflows.gem-manifest` and
  `agent-workflows.runtime-manifest` in the same commit. The gem manifest drives
  only `spec.files`; the runtime manifest drives only source-pack completeness
  and may additionally contain source-pack wrappers/resources. Each consumer
  fails for an omitted, duplicate, missing, absolute, or parent-traversing entry.
- No extraction task begins until Task 1 creates and reviews
  `config/ruby-production-boundaries.yml`. Later references to the reviewed
  production-boundary manifest consume that committed classification; Task 8
  completes and ratchets it rather than creating it for the first time.
- Every task that adds a canonical class or CLI modifies
  `lib/agent_workflows.rb` in the same change, registers each public entrypoint
  explicitly, and updates `test/packaging/public_entrypoints_test.rb`. That test
  builds and installs the gem into an isolated home, disables the source
  checkout, and resolves every registered constant after only
  `require "agent_workflows"`. Ad hoc direct requires in executables are not a
  substitute for the package entrypoint.
- Every extracted root or skill-relative launcher performs the foundation's
  stdlib-free Ruby-version check before requiring package code. The shared
  `ruby32-source-pack-guard` corpus invokes every extracted launcher from
  source-pack and Codex/Claude native-plugin layouts under Ruby 3.2 and requires
  the single documented diagnostic, no backtrace, and exit `78` (`EX_CONFIG`).
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
| `bin/agent_doctor/autonomous_merge_policy*.rb` | `lib/agent_workflows/policy`; move atomically with every caller/provenance rewrite in Task 2 |
| `skills/pr-batch/bin/pr-security-preflight` | `lib/agent_workflows/security` and `lib/agent_workflows/trust` |
| `skills/plan-pr-batch/bin/batch-plan-preflight` | `lib/agent_workflows/batch` |
| `skills/plan-pr-batch/bin/pr-file-touch-map` | Retained single-skill helper owned by `plan-pr-batch` |
| `skills/pr-batch/bin/dispatcher-*`, `stage-*`, `stale-*`, `agent-coord-*` | `lib/agent_workflows/batch` |
| `skills/pr-batch/bin/pr-ci-readiness` | `lib/agent_workflows/readiness` |
| `skills/pr-batch/bin/autonomous-*`, `merge-assurance`, `pr-merge-submit` | `lib/agent_workflows/merge` |
| `skills/post-merge-audit/bin/*` | `lib/agent_workflows/audit` |
| root status, delivery, drift, validators | `lib/agent_workflows/distribution` |
| `bin/push-downstream`, changelog, task-observer, review-data helpers | `lib/agent_workflows/maintainer` or owning skill domain |

Every retained root or skill-relative executable whose implementation moves into
the gem becomes a launcher below 30 lines that calls one
`AgentWorkflows::CLI::<Name>.start` method. The reviewed production-boundary
manifest explicitly exempts genuinely single-skill helpers such as
`skills/plan-pr-batch/bin/pr-file-touch-map`; they retain their direct tested
implementation until a second real consumer justifies extraction. Root wrappers
load `lib/agent_workflows` from the verified installed root. A fixed trampoline
resolved from `.agents/skills/<skill>/bin` contains the exact relative immutable
generation identity and helper name selected when that trampoline was created.
It invokes only that generation and never follows the mutable status pointer or
falls back to a gem, host-global install, another generation, or source checkout.
Its pinned trusted bootstrap validates the bundle manifest and required runtime
tree before loading the generation wrapper or its `lib`.

A skill-relative launcher running from a source checkout, a flat source-pack
install, or a Codex/Claude native-plugin cache derives one candidate package
root from its own real path using a fixed reviewed ancestry. It requires the
  matching source/plugin manifest and `agent-workflows.runtime-manifest` at that root,
validates the canonical library there, and never searches a companion install,
RubyGems, or another checkout. Native-plugin cache layouts are first-class
launch paths, not aliases for `plugin-companion`.

### Repo-local pinned-copy bundle

This exporter is the second consumer of the foundation plan's
`AgentWorkflows::Distribution::RuntimeBootstrap` and
`AgentWorkflows::Distribution::GenerationTransaction`. Reuse the stdlib-only
bootstrap for trusted pre-generation lock, direct generation/helper validation,
lease, and child-execution behavior. Reuse the transaction for immutable
staging, receipt/digest verification, atomic promotion and stable-path
replacement, durable journals, recovery, and retention. The exporter supplies
its richer union/compact phase graph and helper-specific stable-path callbacks;
it must not implement another bootstrap, lease format, generation store, pointer
writer, journal parser, or rollback engine. Add shared contract tests that run
the same fault corpus through both the source-pack installer and the pinned-copy
exporter, plus exporter-only tests for helper-set transitions.

- Create `AgentWorkflows::Distribution::PinnedCopyExporter` as the canonical
  application and `AgentWorkflows::CLI::ExportPinnedCopy` as its injectable
  option/rendering adapter. Create `bin/export-agent-workflows-pinned-copy` as a
  sub-30-line launcher and the only supported entrypoint for producing
  repo-local `.agents` pins. The CLI accepts an explicit target, helper
  allowlist, and mutually exclusive delivery mode; the application refuses a dirty or
  revision-ambiguous source. Before loading canonical Ruby, acquiring its lock,
  creating staging state, or changing the target, its stdlib-only pre-floor
  guard rejects Ruby older than 3.3 with the source pack's single diagnostic and
  exit `78` (`EX_CONFIG`). Extend the foundation's required Ruby 3.2 source-pack guard job with
  exporter no-mutation filesystem snapshots before this entrypoint is supported.
  `full-skill` mode is the supported fallback for a
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
  allowlist `agent-workflows.gem-manifest`.
- The two modes must never coexist for the same skill and consumer. `full-skill`
  is one complete, version-bound, invocable skill-delivery route and must reject
  an installed/native route that would make the skill auto-invocable twice.
  `helper-companion` remains a checkout-only helper copy and rejects use unless
  its recorded installed/native route is present. Move packaged fallback data
  such as trust defaults under the canonical library resource path before its
  helper wrapper cuts over.
- Validate every staged entry, then atomically rename the staged directory into
  its immutable generation name. In `full-skill` mode, require exporter ownership
  of the complete stable `.agents/skills/<skill>` path. For a fresh path or an
  already exporter-owned symlink layout, atomically install or replace one
  relative symlink to the immutable generation's complete skill subtree; reject
  repo-owned files or a host that cannot discover and resolve that symlink to the
  generation root. A portable POSIX filesystem cannot atomically replace a
  non-empty legacy directory with a symlink. Treat that conversion as an
  explicit one-time offline migration, never as an online atomic update: require
  a reviewed maintenance grant naming the consumer, skill, and every source,
  flat-copy, Codex, Claude, native-plugin, or other host/supervisor capable of
  resolving the exact legacy path. The grant binds the complete supervisor
  inventory and each exact `LegacyConsumerFence` adapter path and SHA-256;
  unknown or unfenced supervisors block migration. Each injected adapter must
  acquire its supervisor-level stop-and-inhibit fence, prevent new host
  invocations, enumerate that supervisor's active invocations, and return a
  canonical receipt binding consumer root, skill, supervisor identity, fence
  token digest, `active_invocation_count: 0`, observation time, and expiry. The
  exporter verifies every granted adapter, acquires every listed fence while
  holding its no-follow lock, independently requires zero current generation
  leases, and keeps all locks until the new path and receipts verify. A consumer
  whose complete resolver inventory is unknown, or whose supervisors cannot all
  inhibit starts and prove zero active invocations, is not migratable in place;
  leave it on the legacy layout or use a fresh consumer root. Journal and
  fsync the exact legacy directory descriptor, adjacent backup path, staged
  symlink, desired generation, and phases `prepared`, `legacy_backed_up`,
  `symlink_selected`, `verified`, `committed`. Immediately before the destructive
  legacy-directory rename, re-read canonical UTC and require every quiescence
  receipt to remain strictly before expiry. If any receipt is equal to or past
  expiry, refresh every zero-active receipt while all fences remain held. An
  adapter that cannot refresh under its held fence must cause the exporter to
  release the complete fence set without mutation, then reacquire every fence
  in canonical supervisor-identity order and obtain fresh receipts for all;
  never recursively acquire a held adapter or release/reacquire only a subset.
  Rename the legacy directory to the
  backup, install the staged symlink, and verify before releasing quiescence;
  startup recovery must reacquire the no-follow lock and every inventoried
  adapter fence, require fresh zero-active receipts from all supervisors, and
  prove that the named consumer remains stopped under the offline grant before restoring the
  directory or finishing the symlink selection. If fresh quiescence cannot be
  proved, fail closed without another mutation and require renewed maintenance
  fencing; never reuse a pre-crash proof. Consumers may resume only after
  recovery verifies a complete selected path and releases the adapter fence.
  Retain the backup until the
  committed receipt verifies. The no-missing-path guarantee applies to online
  updates; this explicitly quiesced migration instead guarantees that no
  invocation can observe its bounded exchange interval. In `helper-companion`
  mode, do not replace whole skill directories because they may coexist with
  repo-owned local skills and unrelated pinned helpers. Instead, create one fixed, minimal
  trampoline per selected helper path. Each sub-30-line trampoline binds its
  helper directly to one complete immutable generation and pins one immutable
  stdlib-only bootstrap path and digest under
  `.agents/.agent-workflows-bootstraps/`. Its minimal loader uses the foundation
  plan's no-follow descriptor, ownership/mode, and already-open-byte digest
  checks before evaluating that bootstrap; no selected-generation code runs
  first. Install and fsync the immutable bootstrap before any trampoline may name
  it, and never delete an older bootstrap during normal export. On first
  migration, build and select the complete generation and install its bootstrap
  before atomically renaming each staged symlink or trampoline over an absent,
  symlink, or regular-file legacy path. Each online invocation therefore opens
  either the complete old path or the complete new path; there is no missing-path
  or half-written interval. A non-empty full-skill legacy directory follows only
  the quiesced offline migration above and never enters this rename-over path.
  Subsequent updates atomically replace each affected
  generation-bound stable path and then update the single
  `.agents/agent-workflows-current` symlink used only for status and exporter
  bookkeeping; runtime launch never follows that pointer. Refuse unmanaged
  collisions, serialize exporters with a no-follow lock, and retain every
  superseded generation until an explicit garbage-collection operation proves
  consumer quiescence. Normal export never deletes a generation.
- The union/compact helper graph below applies only to `helper-companion` mode.
  A `full-skill` update stages one complete desired generation, journals
  `prepared`, atomically replaces the single exporter-owned relative skill
  symlink, fsyncs its parent, writes the bound receipt/status pointer, and then
  journals `full_skill_selected` and `committed`. It retains the prior
  generation. Recovery verifies the symlink and receipt as one old-or-new state
  and either restores the prior symlink or finishes the desired receipt; it
  never creates, replaces, or unlinks per-helper trampolines in this mode.
- In `helper-companion` mode, treat the requested helper allowlist as the complete desired managed set and
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
  by its validated relative generation identity, helper name, and immutable
  bootstrap relative path and digest; every
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
  wrappers do not reread either mutable file. A trampoline validates and loads
  its pinned bootstrap from already-open bytes, then passes the generation
  identity and helper name embedded in its own already-open bytes. The trusted
  bootstrap acquires the retention lock, validates the named immutable manifest
  and required runtime tree, publishes the generation lease, and only then
  executes the named wrapper. It does not reread or require a match with the live
  current pointer: an invocation bound to the old complete generation before an
  atomic update is allowed to finish while new invocations select the new one.
  Package version alone is never accepted as a generation binding.
- Before migration, inventory every directory entry under each consumer's pinned
  shared-helper directories, including tracked, untracked, ignored, and
  no-follow symlink entries, and compare tracked paths with the recorded source
  revision. Refuse any directory containing repo-specific skills, deliberate
  overrides, locally generated files, or other non-tracked entries without
  explicit exporter ownership or a consumer-owned disposition; no replacement
  begins while any entry is unclassified. A classified non-empty `full-skill`
  directory still requires the named maintenance grant and proved quiescence
  above; classification alone never authorizes its offline replacement.
  Classify each consumer as `full-skill` or `helper-companion` and prove that its
  selected mode leaves exactly one invocable skill route. Migrate one canary
  consumer first, then update every supported pinned consumer through its own
  reviewed PR. Keep the supported pinned consumer set as an explicit reviewed
  manifest in this plan; use its first entry as the canary and update only the
  consumers named there. The first skill-wrapper cutover cannot merge until the
  canary passes and every remaining consumer either has the complete generation
  bundle or explicitly retains the pre-cutover helper body.
- Add `test/pinned_copy/export_test.bash` and fixture consumers containing no
  gem, host-global library, or source checkout. Before the first skill wrapper
  cutover, prove exported helpers run from the fixture, a partial or
  version-mismatched library fails with exit `78`, and same-version stale or
  mixed-generation wrapper/library bytes fail their digest or generation check.
  Prove an old wrapper-only pin fails with upgrade guidance and unrelated
  `.agents` files survive. Prove `full-skill` fixtures remain discoverable and
  resolve the loaded skill base to one immutable generation carrying matching
  skill-policy/helper revisions, `helper-companion` fixtures contain no
  picker-visible metadata, and mode collisions fail closed. An invocation during
  every helper-companion trampoline replacement, online full-skill symlink
  update, and status-pointer fault must see only an old or new complete
  implementation; an invocation paused after opening a trampoline must finish
  against its bound immutable generation, two helper allowlists at one source
  revision coexist without overwrite, and concurrent invocations must survive
  both helper addition and removal, including a process paused after opening a
  soon-to-be-unlinked trampoline. A non-empty legacy `full-skill` fixture must
  refuse migration before mutation without the exact maintenance grant,
  complete resolver inventory, digest-bound `LegacyConsumerFence` for every
  supervisor, all held stop-and-inhibit fences, all fresh zero-active canonical
  receipts, and an empty generation-lease scan. A second active supervisor and
  a receipt that expires after journaling but before the destructive rename must
  each fail closed before mutation; the latter must refresh all receipts under
  held fences or release and deterministically reacquire the complete set rather
  than recursively acquiring a held adapter or refreshing only the expired
  member. With all present,
  fault injection at every
  `prepared`, `legacy_backed_up`, `symlink_selected`, `verified`, and `committed`
  boundary must prove startup recovery restores the legacy directory or finishes
  the symlink selection before quiescence is released. A restart fixture where
  the original proof is stale and a consumer has resumed must prove recovery
  refuses every mutation until the lock is reacquired and fresh quiescence is
  established. No consumer invocation is permitted during that offline interval,
  and its adjacent backup remains until the committed receipt verifies. Fresh
  and already exporter-owned symlink `full-skill` fixtures remain atomic online.
  Fault injection before and after every other journal, pointer, trampoline,
  receipt, and compaction write proves the next exporter invocation idempotently
  resumes or restores a complete prior set. Prove normal exports never delete
  superseded generations; test explicit garbage collection only behind a
  a no-follow lock plus empty, freshly enumerated lease set and fail closed when
  any valid lease exists or lease coverage is incomplete. An irreconcilable fixture must fail closed without changing any
  additional stable path.
- Update the installation/adoption documentation and every supported pinned-copy
  updater to invoke this exporter. `bin/push-downstream` remains a seam
  synchronizer and must not silently acquire shared-skill copying behavior.
- Add the exporter, its tests, and pinned-layout documentation in the first
  domain PR that cuts over a skill-relative helper. No later domain task may
  defer this prerequisite.

### Task 1: Freeze production boundaries and build the reusable characterization harness

**Files:**

- Create: `test/support/cli_contract.rb`
- Create: `test/support/fake_command.rb`
- Create: `test/support/differential_contract.rb`
- Create: `test/gem/support/cli_contract_test.rb`
- Create: `test/gem/support/differential_contract_test.rb`
- Create: `config/ruby-production-boundaries.yml` with the initial reviewed
  retained single-skill helpers and repository-only entrypoints.
- Modify: `Rakefile`

**Interfaces:**

- Consumes: Ruby standard library `open3`, `tempfile`, `tmpdir`, and `timeout`.
- Produces:

```ruby
CliContract.run(command:, argv: [], env: {}, stdin: "", chdir:, timeout: 10)
# => CliContract::Run(stdout:, stderr:, exit_status:, timed_out:)

DifferentialContract.assert_same(test_case, legacy:, extracted:, normalize:)
```

- [ ] **Step 1: Commit the initial production-boundary classification**

Inventory every tracked production Ruby file outside `lib` and `exe`. Record
each retained file as a thin launcher, genuinely single-skill helper, or
repository-only entrypoint, with its owner, rationale, and direct test. Reject a
helper with a second caller or a repo-wide responsibility. Review and commit
`config/ruby-production-boundaries.yml` before beginning Task 2; all later
domain tasks update this same manifest in the commit that changes a boundary.

- [ ] **Step 2: Write harness tests**

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

- [ ] **Step 3: Run tests and verify missing constants**

Run: `ruby -Itest test/gem/support/cli_contract_test.rb && ruby -Itest test/gem/support/differential_contract_test.rb`

Expected: failure because the support classes do not exist.

- [ ] **Step 4: Implement bounded execution**

Use `Process.spawn(..., pgroup: true)`, nonblocking pipe reads, a monotonic deadline, `TERM` followed by bounded `KILL`, and `Process.waitpid2`. The run result never raises merely because the child exits nonzero. It raises `ArgumentError` only for invalid harness input.

- [ ] **Step 5: Implement fake commands and differential assertions**

`FakeCommand.write(dir:, name:, body:)` writes an executable file with a fixed Ruby shebang from `RbConfig.ruby`. `DifferentialContract` runs both commands with separately cloned fixture roots and compares normalized strings plus exit status.

- [ ] **Step 6: Run support tests and lint**

Run:

```bash
ruby -Itest test/gem/support/cli_contract_test.rb
ruby -Itest test/gem/support/differential_contract_test.rb
rubocop "_$(tr -d '[:space:]' < .rubocop-version)_" test/support test/gem/support
```

The underscore-wrapped first argument is RubyGems' executable-version selector,
not a RuboCop path. First run the same command with only `--version` and require
its output to equal `.rubocop-version`; then run the lint command above.
Expected: PASS.

- [ ] **Step 7: Commit the harness**

```bash
git add -- Rakefile config/ruby-production-boundaries.yml \
  test/support/cli_contract.rb \
  test/support/fake_command.rb test/support/differential_contract.rb \
  test/gem/support/cli_contract_test.rb \
  test/gem/support/differential_contract_test.rb
git commit -m "test: add Ruby CLI characterization harness"
```

### Task 2: Extract the seam doctor in four atomic review slices

**Files:**

- Create: `lib/agent_workflows/seam/shell_command.rb`
- Create: `lib/agent_workflows/seam/javascript_command.rb`
- Create: `lib/agent_workflows/seam/initializer.rb`
- Create: `lib/agent_workflows/seam/validator.rb`
- Create: `lib/agent_workflows/seam/policy.rb`
- Create: `lib/agent_workflows/seam/renderer.rb`
- Move: `bin/agent_doctor/autonomous_merge_policy.rb` to
  `lib/agent_workflows/policy/autonomous_merge_policy.rb`.
- Move: `bin/agent_doctor/autonomous_merge_policy_globs.rb` to
  `lib/agent_workflows/policy/autonomous_merge_policy_globs.rb`.
- Move: `bin/agent_doctor/autonomous_merge_policy_yaml.rb` to
  `lib/agent_workflows/policy/autonomous_merge_policy_yaml.rb`.
- Create: `lib/agent_workflows/cli/seam_doctor.rb`
- Create: `test/gem/seam/*_test.rb`
- Create: `test/gem/policy/autonomous_merge_policy_test.rb`
- Create: `test/packaging/installed_seam_doctor_test.rb`
- Modify: `test/packaging/public_entrypoints_test.rb`
- Modify: `bin/agent-workflow-seam-doctor`
- Modify: `bin/agent-workflow-seam-doctor-test.rb`
- Modify: `skills/pr-batch/lib/autonomous_merge_decision.rb`
- Modify: `skills/pr-batch/lib/autonomous_merge_runtime_trust.rb`
- Modify: `skills/pr-batch/bin/autonomous-merge-eligibility`
- Modify: `skills/pr-batch/bin/autonomous-merge-contract-test.rb`
- Modify: `skills/pr-batch/bin/autonomous-merge-eligibility-test.rb`
- Modify: `skills/pr-batch/bin/merge-assurance-test.rb`
- Modify: `skills/pr-batch/bin/pr-merge-submit-test.rb`
- Modify: `skills/pr-batch/fixtures/autonomous-merge-policy-sources.json`
- Modify: `workflows/pr-processing.md`
- Modify: `bin/install-agent-workflows-test.bash` for source-pack policy loading.
- Create: `exe/agent-workflow-seam-doctor`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify: `agent-workflows.gemspec`
- Modify: `config/ruby-production-boundaries.yml`

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

Move the complete pure `bin/agent_doctor/autonomous_merge_policy*.rb` parser
trio into `AgentWorkflows::Policy` in this task, because seam validation already
depends on its closed-schema `autonomous_merge` checks. `Seam::Policy` delegates
to that packaged parser; it must not reach back into `bin/agent_doctor`, weaken
the schema, or defer this dependency until the later merge-submission task.
Characterize its YAML, glob, and policy errors directly and include all three
canonical files in both manifests and the installed-gem isolation corpus.
Atomically update every current merge caller, trusted-base tree path,
installed-pack digest role, source-pack/pinned-copy manifest, and fixture to the
canonical package paths. Delete the legacy trio only after `rg` proves both seam
and merge callers use the package and the legacy-vs-canonical policy corpus is
byte-for-byte equivalent in decisions, errors, and glob matches. No
compatibility lookup may search both old and new policy locations.

The listed merge-eligibility, assurance, and submission files are mechanical
caller/provenance rewrites required to make this one policy-domain move atomic;
they do not move or redesign those merge domains. Their staged diff is limited
to require paths, manifest/provenance identities, fixtures, and assertions that
prove the same decisions and errors. Any merge-domain implementation change is
deferred to Task 5 and requires its own review slice.

Perform that package-policy cutover as the first substep of Step 4. Immediately
after the packaged parser, existing callers, provenance paths, manifests,
fixtures, isolation coverage, and legacy deletions pass their focused tests,
create the first commit in this step. Do this before creating
`Seam::Policy`, rewriting the seam launchers, or modifying their shared package
entrypoint for the seam cutover. The later seam work may then build only on the
committed canonical policy API and cannot leave an intermediate commit whose
launcher references an unstaged seam implementation.

- [ ] **Step 5: Add both installed and source-pack CLIs and the differential corpus**

Run legacy and extracted commands over every non-mutating validation fixture and `--init` over independent identical fixture copies. Normalize only temporary absolute roots. Assert exact channels and exit statuses.

Create `exe/agent-workflow-seam-doctor` as the RubyGems launcher for
`AgentWorkflows::CLI::SeamDoctor.start`; this executable does not exist in the
foundation plan and must be added here, not treated as a pre-existing file.
Register `AgentWorkflows::CLI::SeamDoctor` from `lib/agent_workflows.rb`, add it to `agent-workflows.gem-manifest` and
`agent-workflows.runtime-manifest`, and add an isolated temporary-gem-home test
that builds and installs the gem, runs `agent-workflow-seam-doctor --help`, and
exercises validation and `--init` from a temporary working directory outside
the checkout. Give the child a controlled `PATH`, `RUBYLIB`, `RUBYOPT`,
`GEM_HOME`, and `GEM_PATH`; reject every checkout path in those values and the
resolved executable/load paths, and assert the loaded gem path is beneath the
temporary `GEM_HOME`. Removing only the checkout from `$LOAD_PATH` is not
sufficient isolation.
Extend the foundation's `test/packaging/public_entrypoints_test.rb` with the seam
constants and run it before this task commits; retain every foundation assertion.
Keep `bin/agent-workflow-seam-doctor` as the source-pack compatibility launcher
and prove both launchers produce the same output and exit status for the shared
corpus.

- [ ] **Step 6: Replace the legacy body and run the full seam suite**

The old path becomes a thin launcher. Run:

```bash
ruby bin/agent-workflow-seam-doctor-test.rb
ruby -Ilib test/gem/seam/shell_command_test.rb
ruby -Ilib test/gem/seam/initializer_test.rb
ruby -Ilib test/gem/seam/validator_test.rb
ruby -Ilib test/gem/policy/autonomous_merge_policy_test.rb
ruby skills/pr-batch/bin/autonomous-merge-contract-test.rb
ruby skills/pr-batch/bin/autonomous-merge-eligibility-test.rb
ruby skills/pr-batch/bin/merge-assurance-test.rb
ruby skills/pr-batch/bin/pr-merge-submit-test.rb
ruby -Ilib test/packaging/installed_seam_doctor_test.rb
ruby -Ilib test/packaging/public_entrypoints_test.rb
bin/agent-workflow-seam-doctor --root test/fixtures/consumer-repo --shared .
bin/validate
```

Expected: all established assertions and full validation pass.

- [ ] **Step 7: Preserve four atomic PR-sized commit boundaries**

As required in Step 4, the policy-parser move, every existing
caller/provenance/fixture rewrite, and all three legacy deletions form the first
atomic commit before any seam implementation or launcher cutover. Before
committing, require this exact search to return exit 1 (no legacy reference)
across every tracked text file except the historical implementation plans. The
focused policy/runtime-trust/installer tests must also enumerate every computed
runtime tree path and installed file and reject a path assembled from components
that reaches the legacy directory. Exit 0 means a forbidden match; exit 2 or any
other status is a search failure and must also stop the commit:

```bash
git rm -- bin/agent_doctor/autonomous_merge_policy.rb \
  bin/agent_doctor/autonomous_merge_policy_globs.rb \
  bin/agent_doctor/autonomous_merge_policy_yaml.rb
git add -- agent-workflows.gem-manifest agent-workflows.runtime-manifest \
  config/ruby-production-boundaries.yml \
  lib/agent_workflows.rb \
  lib/agent_workflows/policy/autonomous_merge_policy.rb \
  lib/agent_workflows/policy/autonomous_merge_policy_globs.rb \
  lib/agent_workflows/policy/autonomous_merge_policy_yaml.rb \
  test/gem/policy/autonomous_merge_policy_test.rb \
  test/packaging/public_entrypoints_test.rb \
  bin/agent-workflow-seam-doctor bin/agent-workflow-seam-doctor-test.rb \
  bin/install-agent-workflows-test.bash \
  skills/pr-batch/lib/autonomous_merge_decision.rb \
  skills/pr-batch/lib/autonomous_merge_runtime_trust.rb \
  skills/pr-batch/bin/autonomous-merge-eligibility \
  skills/pr-batch/bin/autonomous-merge-contract-test.rb \
  skills/pr-batch/bin/autonomous-merge-eligibility-test.rb \
  skills/pr-batch/bin/merge-assurance-test.rb \
  skills/pr-batch/bin/pr-merge-submit-test.rb \
  skills/pr-batch/fixtures/autonomous-merge-policy-sources.json \
  workflows/pr-processing.md
set +e
git grep --cached -n -I -e 'agent_doctor/autonomous_merge_policy' -- . \
  ':!docs/superpowers/plans/**'
legacy_reference_status=$?
set -e
if [ "$legacy_reference_status" -eq 0 ]; then
  exit 1
fi
if [ "$legacy_reference_status" -ne 1 ]; then
  exit "$legacy_reference_status"
fi
policy_commit_expected="$(mktemp)"
policy_commit_actual="$(mktemp)"
trap 'rm -f "$policy_commit_expected" "$policy_commit_actual"' EXIT
printf '%s\t%s\n' \
  D bin/agent_doctor/autonomous_merge_policy.rb \
  D bin/agent_doctor/autonomous_merge_policy_globs.rb \
  D bin/agent_doctor/autonomous_merge_policy_yaml.rb \
  A lib/agent_workflows/policy/autonomous_merge_policy.rb \
  A lib/agent_workflows/policy/autonomous_merge_policy_globs.rb \
  A lib/agent_workflows/policy/autonomous_merge_policy_yaml.rb \
  A test/gem/policy/autonomous_merge_policy_test.rb \
  M agent-workflows.gem-manifest \
  M agent-workflows.runtime-manifest \
  M config/ruby-production-boundaries.yml \
  M lib/agent_workflows.rb \
  M test/packaging/public_entrypoints_test.rb \
  M bin/agent-workflow-seam-doctor \
  M bin/agent-workflow-seam-doctor-test.rb \
  M bin/install-agent-workflows-test.bash \
  M skills/pr-batch/lib/autonomous_merge_decision.rb \
  M skills/pr-batch/lib/autonomous_merge_runtime_trust.rb \
  M skills/pr-batch/bin/autonomous-merge-eligibility \
  M skills/pr-batch/bin/autonomous-merge-contract-test.rb \
  M skills/pr-batch/bin/autonomous-merge-eligibility-test.rb \
  M skills/pr-batch/bin/merge-assurance-test.rb \
  M skills/pr-batch/bin/pr-merge-submit-test.rb \
  M skills/pr-batch/fixtures/autonomous-merge-policy-sources.json \
  M workflows/pr-processing.md | sort > "$policy_commit_expected"
git diff --cached --name-status --no-renames | sort > "$policy_commit_actual"
diff -u "$policy_commit_expected" "$policy_commit_actual"
git commit -m "refactor: package autonomous merge policy parser"
```

Commit the remaining pure seam parsing, initializer/writes, and validator/CLI
cutover separately with messages `refactor: extract seam command parsing`,
`refactor: extract seam initialization`, and `refactor: extract seam validation`.

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
- Create: `lib/agent_workflows/distribution/pinned_copy_exporter.rb`
- Create: `lib/agent_workflows/cli/security_preflight.rb`
- Create: `lib/agent_workflows/cli/export_pinned_copy.rb`
- Create: `test/gem/{github,git,trust,security}/*_test.rb`
- Create: `test/gem/distribution/pinned_copy_exporter_test.rb`
- Create: `test/gem/cli/export_pinned_copy_test.rb`
- Modify: `test/packaging/public_entrypoints_test.rb`
- Create: `bin/export-agent-workflows-pinned-copy`
- Create: `test/pinned_copy/export_test.bash`
- Create: `test/fixtures/pinned-copy-consumer/.agents/*`
- Modify: `lib/agent_workflows/distribution/runtime_bootstrap.rb`
- Modify: `lib/agent_workflows/distribution/generation_transaction.rb`
- Modify: `test/gem/distribution/runtime_bootstrap_test.rb`
- Modify: `test/gem/distribution/generation_transaction_test.rb`
- Modify: `skills/pr-batch/bin/pr-security-preflight`
- Modify: `skills/pr-batch/bin/pr-security-preflight-test.rb`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify: `config/ruby-production-boundaries.yml` in every commit that changes a
  wrapper classification.
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
pinned-copy exporter application/CLI and all atomicity, collision, partial-library,
version-mismatch, source-absent, and rollback cases from the pinned-copy bundle
contract by extending the shared `GenerationTransaction` phase graph and
callbacks. `CLI::ExportPinnedCopy.start(argv, env:, input:, output:, error:)`
owns only option validation/rendering and invokes the injected exporter.
`Distribution::PinnedCopyExporter` owns delivery-mode/helper-set policy and the
union/compact transaction callbacks; it delegates all staging, journaling,
promotion, rollback, recovery, and retention mechanics to
`GenerationTransaction`. The bin launcher owns only the stdlib Ruby-floor guard,
loads `agent_workflows`, verifies the two canonical constants, and calls the CLI.
Add both canonical files to `lib/agent_workflows.rb`, the gem manifest, and the
runtime manifest; direct tests and the production-boundary ratchet reject option
parsing, delivery policy, or transaction callbacks in `bin`. Extend
`RuntimeBootstrap.run(request:, compatibility_json:, argv:, env:)` and its direct
tests for the foundation's version-1 `mode: pinned_generation` request: the trampoline passes
its already-open embedded generation identity, helper name, manifest digest,
compatibility digest, consumer root, and the exact authenticated compatibility
bytes; the bootstrap validates those fields against the immutable bundle and
compatibility matrix, publishes the lease, and then executes the helper.
Prove it never follows `.agents/agent-workflows-current`, rejects every unknown,
traversing, unlisted, stale-digest, or schema-incompatible request, and remains
compatible with the foundation's `mode: current` corpus. No exporter-specific copy of its staging, journal, selector,
recovery, or retention implementation is permitted. Run the entire existing
3,000-plus-line test suite plus direct tests
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
ruby -Ilib test/gem/distribution/pinned_copy_exporter_test.rb
ruby -Ilib test/gem/cli/export_pinned_copy_test.rb
ruby -Ilib test/packaging/public_entrypoints_test.rb
bash test/pinned_copy/export_test.bash
bin/validate
```

Then perform independent adversarial review focused on trust-source precedence, partial API coverage, path binding, timeout cleanup, and fail-closed results.

- [ ] **Step 7: Commit transport, trust, scanners, exporter, and CLI cutover separately**

Use five review-sized commits in this order: transport, trust, scanners,
pinned-copy exporter, then security-preflight CLI cutover. The exporter commit
contains its canonical distribution application and CLI, transaction/bootstrap
extensions, thin bin launcher, `lib/agent_workflows.rb` require registration,
both manifests, public-entrypoint coverage,
production-boundary classification, fixtures, and direct/integration tests. It
must pass the two direct exporter tests, public-entrypoint test, and pinned-copy
integration test before the security wrapper changes. Delete `git_probe_env.rb` only in the final
security-preflight cutover commit after `rg` proves no caller remains. That final
wrapper cutover stages `config/ruby-production-boundaries.yml` with the wrapper
and requires it in the exact staged name-status set; it does not absorb exporter
implementation changes.

### Task 4: Extract batch planning, routing, dependency, and readiness domains

**Files:**

- Create: `lib/agent_workflows/batch/{plan,route,assignment,dependency_graph,stale_assignment_sweep,coordination}.rb`
- Create: `lib/agent_workflows/readiness/{check_run,decision,evaluator}.rb`
- Create: corresponding `lib/agent_workflows/cli/*.rb`
- Create: `test/gem/batch/*_test.rb`, `test/gem/readiness/*_test.rb`
- Modify: `test/packaging/public_entrypoints_test.rb`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify: `config/ruby-production-boundaries.yml` in every commit that changes a
  wrapper classification, including the `pr-file-touch-map` ownership row.
- Modify for every skill-relative wrapper cut over in this task:
  `bin/export-agent-workflows-pinned-copy`, its reviewed bundle manifest,
  `test/fixtures/pinned-copy-consumer/.agents/*`, and
  `test/pinned_copy/export_test.bash`.
- Modify wrappers and legacy tests for `batch-plan-preflight`, `dispatcher-capability-preflight`, `stage-dependency-gate`, `stale-assignment-sweep`, `agent-coord-bounded`, and `pr-ci-readiness`.
- Retain `skills/plan-pr-batch/bin/pr-file-touch-map` and its direct tests as a
  genuinely single-skill helper owned by `plan-pr-batch`; add it to the reviewed
  production-boundary classification with that ownership rationale and prove no
  second caller exists. Revisit extraction only when a second real consumer
  appears.

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

For each command, run its full legacy test, direct domain tests, differential
corpus, `test/packaging/public_entrypoints_test.rb`, and `bin/validate` before
replacing the next body. Do not combine route selection and readiness in one
review diff. The same commit that replaces a skill-relative wrapper must update
the exporter, bundle manifest, pinned fixture, and exporter test named in the
Files list; an exact staged name-status assertion rejects a missing companion
change. The same staged set must include
`config/ruby-production-boundaries.yml`; omission is a hard failure.

- [ ] **Step 6: Commit each independently reviewable domain**

Use separate commits for route/assignment, dependency graph, coordination bounds, stale sweep, and readiness.

### Task 5: Extract merge policy, assurance, and submission

**Files:**

- Move: `skills/pr-batch/lib/autonomous_merge_*.rb` into `lib/agent_workflows/merge/`.
- Reuse: the packaged `AgentWorkflows::Policy` parser extracted by Task 2;
  Task 5 composes it and must not create a second merge-local parser.
- Create: `lib/agent_workflows/merge/{policy,evidence,eligibility,calibration,assurance,submission,trusted_snapshot}.rb`
- Create: `lib/agent_workflows/cli/{autonomous_merge_calibrate,autonomous_merge_eligibility,merge_assurance,pr_merge_submit}.rb`
- Create: `test/gem/merge/*_test.rb`
- Modify: `test/packaging/public_entrypoints_test.rb`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify current merge wrappers and focused tests.
- Modify runtime-trust fixture paths and provenance tests.
- Modify: `config/ruby-production-boundaries.yml` in every commit that changes a
  wrapper classification.
- Modify for every skill-relative wrapper cut over in this task:
  `bin/export-agent-workflows-pinned-copy`, its reviewed bundle manifest,
  `test/fixtures/pinned-copy-consumer/.agents/*`, and
  `test/pinned_copy/export_test.bash`.

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
library files. Reuse the canonical `AgentWorkflows::Policy` paths and
runtime-trust entries established by Task 2; do not relocate, duplicate, or
reintroduce a legacy-policy compatibility lookup. Update the remaining workflow
documentation and installed-copy fixtures in the same cutover.

- [ ] **Step 2: Extract assurance parsing and semantic validation**

Split receipt parsing, target binding, timestamps, evidence digests, authority, walkthrough, operation validation, semantic tracker authentication, and result rendering. Direct tests cover every existing invalid shape and timeout.

- [ ] **Step 3: Extract trusted snapshot materialization**

Create one object owning trusted-base file lookup, shebang parsing, closed environment, private Git root, fixed argv, process execution, cleanup, and cleanup-`UNKNOWN`. Its tests preserve path traversal, mode, object/ref, token redaction, symlink, interpreter, replacement, and cleanup cases.

- [ ] **Step 4: Extract submission state machine**

Keep queue submission and guarded direct submission separate strategies. Both re-fetch exact GitHub state after action. Ambiguous action outcomes remain `UNKNOWN`; a successful child exit never alone proves a merge.

- [ ] **Step 5: Bind runtime provenance to the gem tree**

Replace old path lists with a versioned manifest of canonical library files, wrappers, and calibration fixtures. Tests prove modified, missing, extra-unexpected, and wrong-version bytes fail closed.

- [ ] **Step 6: Prove differential compatibility and run merge closeout gates**

Before each wrapper replacement, run the legacy and extracted implementation
against the same non-mutating and fake-mutation corpus and compare stdout,
stderr, exit status, parsed receipts, and planned GitHub operations. The fake
adapter must prove identical operations without contacting GitHub. Then run all
autonomous, assurance, and submission suites, the installed-gem public-entrypoint
test, full validation, and independent
adversarial review focused on authority separation, exact-head/base binding,
environment closure, trusted snapshot isolation, post-mutation verification,
and cleanup.

- [ ] **Step 7: Commit policy, assurance, snapshot, and submission separately**

Delete old skill-local libraries only after `rg` and packaging tests prove all installed layouts use canonical files. Each skill-relative wrapper commit also
stages and exact-name-status checks its exporter, bundle-manifest, pinned-fixture,
exporter-test, and `config/ruby-production-boundaries.yml` changes.

### Task 6: Extract completed-batch audit and replay

**Files:**

- Create: `lib/agent_workflows/audit/{marker,follow_up,publication_snapshot,publication_preflight,replay,check_timing,renderer}.rb`
- Create: CLI adapters for every `skills/post-merge-audit/bin/*` Ruby command.
- Create: `test/gem/audit/*_test.rb`
- Modify: `test/packaging/public_entrypoints_test.rb`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify post-merge wrappers, tests, fixtures, and package manifest.
- Modify: `config/ruby-production-boundaries.yml` in every commit that changes a
  wrapper classification.
- Modify for every skill-relative wrapper cut over in this task:
  `bin/export-agent-workflows-pinned-copy`, its reviewed bundle manifest,
  `test/fixtures/pinned-copy-consumer/.agents/*`, and
  `test/pinned_copy/export_test.bash`.

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

- [ ] **Step 5: Prove differential compatibility and run full audit gates**

Before replacing each command, compare the legacy and extracted implementation
over every replay fixture and a fake-publication corpus, including exact output,
exit status, managed description section, comment payload, and ambiguous
mutation result. Then run every post-merge-audit Ruby and Bash test, direct
tests, fixture replays, the installed-gem public-entrypoint test, full
validation, and adversarial review focused on
normalization, freshness, target set equality, mutation ambiguity, and blocker
union completeness.

- [ ] **Step 6: Commit parser, preflight, publication, and replay separately**

Each commit leaves all command paths operational. Each skill-relative wrapper
commit also stages and exact-name-status checks its exporter, bundle-manifest,
pinned-fixture, exporter-test, and `config/ruby-production-boundaries.yml`
changes.

### Task 7: Extract distribution, validation, and maintainer commands

**Files:**

- Create: `lib/agent_workflows/distribution/{delivery_state,status,trust_audit,drift,manifest_validator,review_finding_validator,solution_validator}.rb`
- Modify: `lib/agent_workflows/distribution/install_ownership.rb` from the
  foundation as the surrounding distribution abstractions arrive; assert the
  foundation already removed every legacy doctor-ownership caller.
- Create: `lib/agent_workflows/maintainer/{downstream_registry,downstream_sync,changelog,review_data,task_observer}.rb`
- Create corresponding CLI adapters and direct tests.
- Modify: `test/packaging/public_entrypoints_test.rb`
- Modify: `agent-workflows.gem-manifest`, `agent-workflows.runtime-manifest`
- Modify: `lib/agent_workflows.rb`
- Modify root and skill-relative wrappers and legacy tests.
- Modify: `config/ruby-production-boundaries.yml` in every commit that changes a
  wrapper classification.
- Modify for every skill-relative wrapper cut over in this task:
  `bin/export-agent-workflows-pinned-copy`, its reviewed bundle manifest,
  `test/fixtures/pinned-copy-consumer/.agents/*`, and
  `test/pinned_copy/export_test.bash`.

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

- [ ] **Step 5: Run differential, focused, and aggregate validation after each wrapper cutover**

For `push-downstream`, retain dry-run as the default and run its full 2,000-plus-line test plus registry dry-run. For every validator, run its existing test and current live repository validation input.
Before replacing any mutating wrapper, compare legacy and extracted dry-run
plans using bounded fake Git, GitHub, filesystem, and registry adapters; require
identical planned operations, output channels, and exit status. For read-only
commands, run the shared differential harness over the full fixture corpus.
Run the installed-gem public-entrypoint test after each independently committed
domain so a missing root require cannot survive to the next cutover.

- [ ] **Step 6: Commit read-only distribution, validators, downstream sync, and small helpers separately**

Do not combine fleet mutation code with unrelated validators. Each
skill-relative wrapper commit also stages and exact-name-status checks its
exporter, bundle-manifest, pinned-fixture, exporter-test, and
`config/ruby-production-boundaries.yml` changes.

### Task 8: Remove remaining legacy bodies and ratchet quality

**Files:**

- Delete: migrated shared production bodies remaining under root `bin/*` and
  skill paths after replacing them with launchers or canonical library files.
  Retain genuinely single-skill Ruby helpers under their invoking skill.
- Modify: `.rubocop.yml`, `agent-workflows.gemspec`, `Rakefile`, `bin/validate`, docs, and changelog.
- Modify/split: legacy test files whose subject is now a canonical class.
- Create: `test/packaging/require_boundary_test.rb`.
- Modify: `config/ruby-production-boundaries.yml` to complete the reviewed
  retained single-skill helpers and repository-only entrypoints.

**Interfaces:**

- Consumes: all extracted domains.
- Produces: one production implementation tree and enforced reviewability limits.

- [ ] **Step 1: Re-run and complete the tracked Ruby production inventory**

Re-run the same tracked-file classifier used to create the Task 1 manifest and
compare the result with the committed classification. Every
production Ruby file outside canonical `lib` and `exe` must be classified as a
launcher below 30 lines, a genuinely single-skill helper owned by its invoking
skill, or a repository-only validation entrypoint. Require a short ownership
rationale and direct tests for each retained skill-local helper; move any helper
used by multiple skills or repo-wide commands into the gem.

- [ ] **Step 2: Prove there are no obsolete implementation requires**

Run:

```bash
rg -n '(require|require_relative|load|autoload).*bin/agent_doctor' --glob '*.rb' --glob 'bin/*' --glob 'skills/*/bin/*'
rg -n '(require|require_relative|load|autoload).*(?:\.\./)+lib/' --glob '*.rb' --glob 'bin/*' --glob 'skills/*/bin/*'
ruby test/packaging/require_boundary_test.rb
```

The boundary test enumerates tracked production Ruby files and Ruby-shebang
launchers, parses every literal `require`, `require_relative`, `load`, and
`autoload` call with `Ripper`, resolves the target using the applicable Ruby
load-path and optional `.rb` rules, and fails on a missing target or a resolved
target under `bin/agent_doctor`. Include generated launcher/load-path inputs in
the analysis rather than scanning only checked-in source literals. A target
under `skills/*/lib` is accepted only when the boundary manifest classifies it
as genuinely local to that same invoking skill and no tracked caller outside
that skill resolves it. Dynamic load expressions of any of the four forms fail
closed until the boundary manifest explicitly classifies the callsite and its
allowed target set. Expected: searches and resolver report no obsolete or
cross-skill production dependency.

- [ ] **Step 3: Enable gem metrics without blanket exclusions**

Remove temporary migration exclusions. Run RuboCop and split real responsibility violations. Use local documented exceptions only where a parser table or immutable schema definition is clearer intact.

- [ ] **Step 4: Split test files by behavior**

For each test file over 800 lines, split by parser/policy/transport/rendering/CLI behavior when setup and assertions are independent. Keep shared builders under `test/support`; do not hide assertions in helper methods.

- [ ] **Step 5: Run the complete matrix and package smoke**

Run `bin/validate` on Ruby 3.3 and 3.4.6, build/install the gem, run the shared
installed-gem public-entrypoint test and every gem executable, run flat/plugin
copy and symlink installer suites, run `ruby32-source-pack-guard` against every
extracted root and skill-relative launcher in source-pack and both native-plugin
layouts, and run `git diff --check`.

- [ ] **Step 6: Perform final architecture and adversarial reviews**

Use `plan-review` against the approved design for scope completion, `autoreview` on the branch diff, and adversarial review on security/merge/audit changes. Resolve findings and rerun exact touched and aggregate gates.

- [ ] **Step 7: Commit legacy removal and quality ratchet**

Turn the Task 8 inventory and final diff into a reviewed list of literal changed
and deleted paths. Stage each with `git add -- <exact-file>` or
`git rm -- <exact-file>`; directory pathspecs, globs, and `-A` are invalid.
Require `git diff --cached --name-only` to equal that reviewed list, then commit
with message `refactor: complete agent workflows Ruby domain extraction`.

## Plan Completion Gate

- All shared production Ruby behavior lives under `AgentWorkflows`; each
  retained skill-local helper has one invoking-skill owner, direct tests, and no
  cross-skill caller.
- Root and extracted skill-relative Ruby commands are thin launchers; reviewed
  single-skill helpers remain direct implementations under their invoking skill.
- Every old focused test and new direct-domain test passes.
- Security, merge, and audit independent reviews report no unresolved blocking finding.
- Package content contains every runtime file and no repository-only tests.
- Full Ruby 3.3/3.4.6 validation, installer modes, standalone Codex/Claude native
  plugin caches, package smoke, and `git diff --check` pass.
- No package publication occurs under this plan.
