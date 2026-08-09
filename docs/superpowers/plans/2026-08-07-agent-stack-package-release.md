# Agent Stack Package Release Implementation Plan

> **Execution note:** Work task-by-task. Host-provided plan-execution or
> subagent capabilities are optional accelerators, not repository dependencies;
> when unavailable, follow the checked steps directly.

**Goal:** Publish legitimate first releases under the canonical Agent Workflows, Agent Coordination, and Dashboard package names, secure their ownership, and decide whether Agent Workflows also ships self-contained Ruby executables.

**Architecture:** Each repository builds and verifies its own native package: `agent-workflows` and `agent-coordination` on RubyGems, `agent-coordination-dashboard` on npm. Registry mutation remains a separately approved release action. A bounded Tebako evaluation consumes the already verified `agent-workflows` gem and may add native release assets without changing the canonical Ruby source or gem.

**Tech Stack:** RubyGems, npm, GitHub Actions OIDC trusted publishing, GitHub Releases, Ruby 3.2 for the existing Agent Coordination compatibility floor, Ruby 3.3 for the new Agent Workflows floor, a pinned Ruby 3.4.6 build, Node 22.12+ runtime smoke, a pinned Node 24.8.0/npm 11.5.1 publication toolchain, Tebako evaluation, SHA-256 artifact manifests.

## Global Constraints

- Canonical package names are exactly `agent-workflows`, `agent-coordination`, and `agent-coordination-dashboard`.
- Do not publish underscore aliases or a dashboard Ruby gem.
- A pending trusted publisher does not prove registry ownership; a successful legitimate package publication does.
- Do not publish an empty, placeholder, alias-only, or name-squatting package.
- Every release authorization contains a versioned grant manifest. Each row
  names the exact human or organization/team principal, registry operation,
  package, role, and access level being approved. For a previously unclaimed
  package, a successful first publication is immediately followed by
  authenticated grants for exactly those manifest rows; no open-ended "all
  supported roles" grant is permitted. Validate every requested row against
  live registry capabilities, reject a supported grant that is absent from or
  inconsistent with the manifest, and record unsupported rows with authenticated
  capability evidence and a registry-specific disposition. Use the registry's
  distinct access operation and read-back when organization/team access is not
  represented in its owner list. Always read the human owner list back and
  require at least two confirmed human owners before the release is complete.
  Carry the complete grant manifest, observed grants, and read-back result into
  the release receipt. If any approved supported grant or required read-back
  fails, stop with publication recorded but release completion blocked;
  verification alone never substitutes for a supported grant operation.
- Store each manifest as
  `release/grants/<package>-<version>.v1.json`. Its canonical JSON contains
  `schema_version`, package, registry, version, and sorted rows with
  `principal_type`, `principal`, `operation`, `role`, `access`, and
  `capability_status`; an unsupported row also carries its authenticated
  capability-evidence reference and disposition. Authorization names the path
  and SHA-256. The workflow verifies both before publication, and the release
  receipt embeds that digest plus the observed result for every row.
- Do not publish without explicit release authorization naming the package,
  version, commit, registry, workflow path and ref, workflow-file digest, and
  rollback/remediation disposition, plus the exact grant manifest.
- The specified stable releases (`agent-coordination` and dashboard `0.1.0`,
  Agent Workflows `0.2.0`) proceed only after the release owner explicitly
  accepts the compatibility commitment. Otherwise stop and write a
  prerelease-version plan; do not silently change the versions below.
- Ruby packages require MFA metadata and GitHub OIDC trusted publishing.
- Package artifacts contain no credentials, local absolute paths, untracked files, test secrets, or private fixtures.
- Every release binds package checksum, Git tag, repository commit, and registry version.
- Both gem releases use Ruby `3.4.6`, RubyGems `3.6.9`, and Bundler `4.0.10`
  in a pinned Linux build environment for the authorization build and
  unprivileged workflow build. The workflow verifies all three versions before
  building; a mismatch stops before the protected publication job begins.
- Both gemspecs set `allowed_push_host` to exactly
  `https://rubygems.org`, packaging tests assert it, and release jobs reject any
  conflicting `RUBYGEMS_HOST`.
- The source-pack installer does not switch to remote gem resolution merely because a gem is published.

### Shared RubyGems release contract

The canonical contract ID for this section is `AW-RELEASE-RUBYGEMS-V1`. Both
Ruby packages use this single release contract. Package tasks below add
only their package-specific inputs and validation; they do not restate or
weaken these controls. The grant-manifest, post-publication grant, and read-back
rules in Global Constraints are the canonical `AW-RELEASE-GRANTS-V1` contract.
Every task call site references these exact IDs; implementation review must
cross-check each call site against the canonical text, and any local paraphrase
is explanatory rather than normative.

Add two distinct verification tasks so Rake's run-once semantics cannot skip
the post-push simulation in the unprivileged release-verification job. A
pre-source-control prerequisite, after the Bundler build,
requires the authorized commit and artifact SHA-256 inputs, compares them with
`HEAD` and the exact built gem, fetches tags, and requires the version tag
either to be absent or to dereference to the authorized commit. A tag at
another commit is a terminal collision. A separate prerequisite of
`release:rubygem_push`, which runs after `release:source_control_push`, refetches
and reads back both the local and remote tag, requires each to dereference to
the authorized commit, and rechecks `HEAD` plus the artifact SHA-256 before gem
publication. Test missing or mismatched authorization, absent, matching, and
colliding pre-push tags, missing or mismatched post-push tags, and a fully
matching sequence without registry mutation.

Every release workflow declares a package-name-keyed `concurrency` group with
`cancel-in-progress: false`. Authorized runs for the same package are therefore
serialized; a later run cannot observe an absent tag concurrently with an
earlier run. The privileged job still fetches and checks the remote tag
immediately before and after its one tag push because workflow serialization
does not replace registry read-back.

Each first-release workflow is protected `workflow_dispatch` only and requires
exact package, version, release branch, commit, artifact SHA-256, workflow path,
workflow ref, workflow-file SHA-256, and grant-manifest path/SHA-256
authorization inputs. Dispatch only
from that exact authorized branch ref. Configure the protected `release`
environment with a deployment-branch rule admitting only that branch and
required human review. Before approving the environment deployment, the
reviewer reads the run metadata and independently verifies its workflow path,
`github.workflow_ref`, and `head_sha` against the authorization; a mismatch is
rejected before any job with `id-token: write` can start.

Split verification from publication. The first job has only `contents: read`,
checks out with persisted credentials disabled, and has no environment,
`id-token: write`, or `contents: write`. It verifies the authorization inputs,
full attached-branch state, workflow path/ref/digest, toolchain, tests, package
contents, tag preconditions, and reproducible build; then it uploads the exact
gem plus a machine-readable receipt binding package, version, commit, workflow
digest, artifact SHA-256, and toolchain versions. All Bundler, Rake, gemspec,
dependency, repository-script, and package-hook execution ends in this
unprivileged job.

Only the second, minimal job uses the protected `release` environment and
job-scoped `id-token: write` plus `contents: write`. It downloads the artifact
and receipt from the same workflow run through pinned actions, compares both to
the pre-recorded authorization without executing repository code, verifies the
checked-out workflow digest independently, fetches the remote tag, and performs
only the exact tag push, tag read-back, and OIDC registry upload. It does not
run Bundler, Rake, tests, gemspec evaluation, dependency installation, build
hooks, or a rebuild. The checkout credential remains unpersisted and is passed
only to the explicit tag push. Configure OIDC only after every receipt,
checksum, branch, workflow, and tag check passes. Test wrong dispatch ref, run
head SHA, workflow path/ref, workflow-file digest, cross-run artifact, receipt,
checksum, and concurrent-run/tag collision as release-stopping cases. A later
tag-triggered release is a separate design change unless an immutable
authorization manifest supplies the same bindings.

Human owners are recovery principals, not an alternate routine publication
path. The authorization explicitly forbids local `gem push` and token-based npm
publication except for the one-time, separately authorized first-dashboard
bootstrap below. That exception permits only the exact reviewed `0.1.0` tarball,
tag, checksum, maintainer identity, and interactive-2FA npm session after all
prepublication gates pass. It never exposes or persists credential values, runs
in CI, creates a reusable automation token, or applies to a later version.
Before opening the session, the maintainer installs an unconditional cleanup
trap/ensure step that logs out or revokes it after every bootstrap attempt,
including publish, grant, trusted-publisher attachment, verification, interrupt,
and error paths. Cleanup is not conditional on the trusted publisher being
attached; a retry opens a new interactive-2FA session. All routine releases
require no standing publish token in CI and record the trusted publisher identity
used for the release.
Registries cannot technically prevent every credentialed owner from publishing
locally, so post-release verification must compare the registry version history
and provenance with the authorized receipt. An unexplained version or provenance
mismatch is a security incident: revoke affected credentials, freeze further
publication, preserve registry and workflow evidence, and require a new
maintainer authorization before recovery.

Rollback means remediation, never tag or version reuse. For RubyGems, preserve
the immutable tag and published bytes; yank only with explicit maintainer
authorization when RubyGems permits and the compatibility/security impact
justifies it, then publish a new corrective version. For npm, unpublish only
when the registry still permits it and a maintainer explicitly authorizes that
destructive action; otherwise deprecate the affected version with an actionable
message and publish a new corrective version. After any failure following tag
creation, reconcile the registry before acting. If the exact authorized artifact
was published successfully, do not republish or bump merely because an owner
grant, trusted-publisher attachment, read-back, smoke, or GitHub Release closeout
step failed; resume those incomplete steps against the published version. If no
publication occurred, the immutable tag and same authorized artifact may be
retried under the existing authorization. Require a new version only when the
published artifact is defective, replacement bytes are required, or live state
shows an ambiguous or mismatched publication. Every authorization selects one
of these registry-specific outcomes, and the closeout receipt records the action
actually taken.

---

## Repository Package Map

| Repository | Package | Current readiness input |
| --- | --- | --- |
| `shakacode/agent-workflows` | RubyGems `agent-workflows` | Gem foundation and domain pilot plans complete |
| `shakacode/agent-coordination` | RubyGems `agent-coordination` | Existing `agent-coordination.gemspec`, packaging tests, version `0.1.0` |
| `shakacode/agent-coordination-dashboard` | npm `agent-coordination-dashboard` | Existing `package.json`, `prepack`, package-ready docs, version `0.1.0` |

### Task 1: Establish live registry and ownership preflight

**Files:**

- Create in each repository: `docs/package-release-checklist.md`.
- Create in each repository:
  `release/grants/<package>-<version>.v1.json`.
- Create after exact approval in each repository:
  `release/authorizations/<package>-<version>.v1.json`, containing the approved
  package, version, commit, tag, artifact digest, workflow binding, grant-manifest
  digest, actor, source URL, timestamp, and rollback/remediation disposition.
- Modify in each repository: package metadata only when a check below reveals a real gap.

**Interfaces:**

- Consumes: RubyGems exact-name API, npm registry exact-name API, repository package metadata, authenticated owner identity.
- Produces: a timestamped release preflight and reviewed v1 grant manifest
  recording availability, intended ownership, capability dispositions, and no
  credentials.

- [ ] **Step 1: Recheck exact names immediately before release work**

Run read-only checks:

```bash
gem search --remote --exact --all --prerelease agent-workflows
gem search --remote --exact --all --prerelease agent-coordination
npm view agent-coordination-dashboard name version repository.url --json
```

Cross-check both Ruby names against the RubyGems exact-name JSON API so an
empty CLI rendering or prerelease-only package cannot be mistaken for
availability. Expected before first publication: the API reports no exact gem
and npm reports no exact package. Any stable or prerelease result blocks
publication pending authenticated ownership verification; do not choose an
underscore variant as an automatic workaround.

- [ ] **Step 2: Verify authenticated publisher identity without printing credentials**

Use registry account pages or identity commands that print only account handles. Verify MFA on human owners. Do not print API keys, npm tokens, RubyGems credentials, OIDC assertions, or environment values.

- [ ] **Step 3: Record intended ownership**

Create the canonical v1 grant manifest from the release checklist. Both RubyGems
manifests name at least two human owners and the exact supported ShakaCode
organization access. The unscoped npm manifest names at least two human owners
and the trusted-publisher attachment. It also names the exact ShakaCode npm team
and requested package access, with capability status initially `unknown` until
the authenticated preflight proves whether the registry supports that row for
the unscoped package. A supported row is mandatory and uses npm's distinct team
access grant plus authenticated read-back; only a genuinely unavailable row may
be recorded unsupported with evidence. Missing confirmed backup human ownership
or a supported team grant is a release blocker, not a post-release reminder.

- [ ] **Step 4: Configure RubyGems publishers and prepare npm bootstrap**

For each Ruby gem, configure its exact GitHub owner, repository, release
workflow filename, and protected `release` environment. Record that this
enables OIDC but does not claim the name before first push. npm cannot attach a
trusted publisher before a package exists, so prepare and review the dashboard
workflow and environment but do not claim they are configured. Record the
separately authorized, interactive-2FA bootstrap publication required in Task 4.

- [ ] **Step 5: Review the preflight**

Confirm package spelling, registry, repository, workflow, environment, owners,
and every canonicalized grant-manifest row. Record and independently verify the
manifest SHA-256. A reviewer explicitly verifies that no underscore alias,
dashboard gem, or unsupported-by-assumption npm team disposition is included.

### Task 2: Prepare and release `agent-coordination` 0.1.0

**Files in `shakacode/agent-coordination`:**

- Modify: `agent-coordination.gemspec`
- Modify: `Gemfile`, `Gemfile.lock`
- Create: `lib/agent_coordination.rb`
- Create: `lib/agent_coordination/version.rb`
- Create: `test/public_api_test.rb`
- Modify: `bin/agent-coord`
- Modify: `test/packaging_test.rb`
- Create/modify: `Rakefile`
- Create/modify: `.github/workflows/release-gem.yml`
- Modify: `README.md`, `CHANGELOG.md`, release runbook.

**Interfaces:**

- Consumes: current `AgentCoord::VERSION = "0.1.0"`, existing package manifest and packaging tests.
- Produces: RubyGems `agent-coordination` 0.1.0 and matching GitHub release/tag.

- [ ] **Step 1: Add the canonical Ruby require and namespace**

Move the version constant into `lib/agent_coordination/version.rb`. Define
`AgentCoordination::VERSION` as canonical, keep `AgentCoord::VERSION` as a
compatibility constant through the `0.x` series, and require the version from
`bin/agent-coord`. In the same change, replace the gemspec's regex read of the
literal constant in `bin/agent-coord` with a require of the canonical version
file and `spec.version = AgentCoordination::VERSION`; add a test that loading the
gemspec succeeds after the old literal is gone. Create
`lib/agent_coordination.rb` as the conventional public entrypoint. Add a
cold-process test proving:

```ruby
require "agent_coordination"
AgentCoordination::VERSION # => "0.1.0"
AgentCoord::VERSION        # => "0.1.0" compatibility surface
```

Add both new library files to the gemspec's explicit manifest. Do not claim the
existing `AgentCoord` implementation classes have moved namespaces in this
release.

- [ ] **Step 2: Add metadata contract assertions**

Extend `test/packaging_test.rb` to assert exact name, version, Ruby `>= 3.2`,
MIT license, ShakaCode author, source/changelog URIs,
`rubygems_mfa_required == "true"`,
`allowed_push_host == "https://rubygems.org"`, executables `agent-coord` and
`agent-coord-harvest`, and the existing bounded runtime dependencies
`base64 >= 0.1.1, < 1.0` and `sqlite3 >= 2.9.5, < 3.0`. Any dependency change is
a separately explained compatibility decision, not release-plan cleanup.
Set the gemspec's `allowed_push_host` metadata to that exact URL in the same
change; the release workflow clears or rejects a conflicting `RUBYGEMS_HOST`
before invoking Bundler.

Cut `CHANGELOG.md` from `[Unreleased]` to `[0.1.0]` with the release date while
retaining a fresh empty `[Unreleased]` section. Update the packaging contract to
require both headings in order and to bind the versioned entry to the gem
version.

- [ ] **Step 3: Build and inspect the exact gem**

Build the authorization artifact in the pinned Linux release-preflight
environment with Ruby 3.4.6, RubyGems 3.6.9, and Bundler 4.0.10. Record the
immutable environment/image digest and verify all tool versions before the
build. The unprivileged release-verification job uses the same environment and
requires its rebuilt artifact SHA-256 to equal this authorization artifact.
The protected OIDC job consumes those bytes and never rebuilds them.

Run:

```bash
mkdir -p pkg
gem build agent-coordination.gemspec --output pkg/agent-coordination-0.1.0.gem
gem specification pkg/agent-coordination-0.1.0.gem --yaml
unpack_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-coordination-unpacked.XXXXXX")"
gem unpack pkg/agent-coordination-0.1.0.gem --target "${unpack_root}"
find "${unpack_root}" -type f -print | sort
shasum -a 256 pkg/agent-coordination-0.1.0.gem
```

Expected: only manifest files, no credentials or absolute local paths, and metadata exactly matches the release.

- [ ] **Step 4: Install and smoke in an isolated gem home**

Install locally with documentation disabled. From outside the source checkout,
run `ruby -e 'require "agent_coordination"; abort unless
AgentCoordination::VERSION == "0.1.0"'`, `agent-coord version --json`,
`agent-coord --help`, `agent-coord-harvest --help`, a disposable local-state
doctor, and packaging tests. Assert version `0.1.0`, no source-checkout
dependency, and no credential output.

- [ ] **Step 5: Add OIDC-only release workflow**

Add `gem "rake", require: false` to `Gemfile`, update the lockfile, require
`bundler/gem_tasks` from `Rakefile`, and test that `bundle exec rake -T` exposes
the build and release tasks in a clean bundle.

Implement `AW-RELEASE-RUBYGEMS-V1` above with package
`agent-coordination`, version and tag `0.1.0`/`v0.1.0`, and the exact
`pkg/agent-coordination-0.1.0.gem` artifact. The authorization inputs come from
Step 7.

- [ ] **Step 6: Run repository release gates**

Run the repository's configured validate/test wrappers, packaging test, RuboCop, and Git diff checks. Obtain independent current-head review.

- [ ] **Step 7: Stop for explicit publication authorization**

Present exact package `agent-coordination`, version `0.1.0`, attached release
branch, commit SHA, artifact SHA-256, workflow path/ref and file digest, owners,
grant-manifest path and SHA-256, and rollback/disposition. No tag or registry mutation occurs before
authorization.

- [ ] **Step 8: Publish and verify only after authorization**

Create/push the signed or protected release tag through the authorized workflow;
the workflow must verify that tag before it permits the gem-push hook. Verify
RubyGems metadata, the checksum of the bytes actually published, owners, MFA
status, and install from RubyGems into a clean gem home. For a first
publication, execute `AW-RELEASE-GRANTS-V1`, record
every manifest row's result in the release receipt, and verify the receipt binds
the authorized manifest digest before continuing. Then create the GitHub
Release explicitly from the verified tag and commit, attach the checksum
manifest and versioned changelog notes, and read it back. A failed or ambiguous
push or release creation is investigated through live registry and GitHub state
before retrying.

### Task 3: Prepare and release `agent-workflows` 0.2.0

**Files in `shakacode/agent-workflows`:**

- Consume: outputs of the gem-foundation plan.
- Modify: `VERSION`, `lib/agent_workflows/version.rb`, `.codex-plugin/plugin.json`,
  `.claude-plugin/plugin.json`, `test/packaging/*`,
  `agent-workflows.gemspec`, `agent-workflows.gem-manifest`,
  `agent-workflows.runtime-manifest`, release docs,
  `CHANGELOG.md`.
- Create: `.github/workflows/release-gem.yml`.

**Interfaces:**

- Consumes: canonical gem, executables, package tests, source-pack compatibility tests.
- Produces: RubyGems `agent-workflows` 0.2.0 without changing source-pack resolution.

- [ ] **Step 1: Define minimum useful first release contents**

Require at least `agent-workflows-doctor`, `agent-stack-doctor`, the complete canonical doctor library, package metadata, license, README, changelog, and version. Do not publish a version-only gem merely to claim the name.

The repository already declares source-pack/plugin version `0.1.0` and has a
historical `### [0.1.0] - 2026-06-24` changelog section. Preserve that history.
Atomically bump root `VERSION`, `AgentWorkflows::VERSION`, native plugin
manifests, package tests, and release metadata to `0.2.0`; do not create another
0.1.0 section or retag the historical version. If a live preflight discovers an
existing `v0.2.0`, stop and select a new version through explicit release-owner
approval rather than moving the tag.

Inventory every live `0.1.0` assertion before the bump. Update assertions bound
to the repository's current version, preferably deriving them from root
`VERSION`; retain literal old-version, mismatch, and migration fixtures only
when the test's stated purpose requires historical bytes. Update the manifest
in the same staged change and assert it still includes `LICENSE`, `README.md`,
and `CHANGELOG.md`.

- [ ] **Step 2: Prove package/source-pack parity**

Build and install the gem, install the source pack from the same commit, and run equivalent doctor help, JSON, malformed-input, and missing-delegate cases. Compare stdout, stderr, and exit status after normalizing only install roots.

- [ ] **Step 3: Inspect package contents and source links**

Assert the package contains no source-pack-only tests, skills, private fixtures, local paths, credentials, or generated build cache. Verify source and changelog URLs resolve to the exact public repository.

Cut the repository's current `Unreleased` entries into a new
`### [0.2.0] - YYYY-MM-DD` section above the untouched historical `0.1.0`
section, restore an empty `Unreleased`, and update comparison links and
changelog contract tests before authorization.

- [ ] **Step 4: Add the OIDC-only release workflow**

Implement `AW-RELEASE-RUBYGEMS-V1` above with package
`agent-workflows`, version and tag `0.2.0`/`v0.2.0`, and its exact built gem.
Confirm the foundation `Gemfile` includes Rake and its `Rakefile` still
exposes Bundler's release task under `bundle exec`, then run `bin/validate`, gem
packaging tests, isolated install smoke, and source-pack parity before
`rubygems/release-gem`. Require the foundation workflow's exact-commit
`macos-packaging-smoke` receipt; an older or skipped macOS run does not satisfy
this release gate. Build the authorization artifact and the unprivileged
workflow artifact in the same pinned Linux environment with Ruby 3.4.6,
RubyGems 3.6.9, and Bundler 4.0.10; verify the exact versions and require
byte-identical SHA-256. The minimal privileged job consumes that verified
artifact and never rebuilds or executes repository package code before
configuring RubyGems OIDC.

- [ ] **Step 5: Run current-head release gates and stop for authorization**

Present exact package, version, attached release branch, commit, artifact
checksum, workflow path/ref and file digest, executables, owners, grant-manifest
path and SHA-256, and evidence. The workflow and release receipt must bind that
exact digest.
Publication approval for `agent-coordination` does not authorize
`agent-workflows`.

- [ ] **Step 6: Publish and verify only after authorization**

After the workflow reports success, independently query RubyGems, install the
public gem, run each executable, verify tag/release SHA, and confirm the
source-pack installer still uses its own pinned library bytes. For a first
RubyGems publication under this name, execute and read back the global
`AW-RELEASE-GRANTS-V1` before treating the release as complete.

### Task 4: Prepare and release npm `agent-coordination-dashboard` 0.1.0

**Files in `shakacode/agent-coordination-dashboard`:**

- Modify: `package.json`, `scripts/package.test.ts`.
- Modify if required: remaining package tests and `README.md`.
- Create: `CHANGELOG.md` with `Unreleased` and `0.1.0` entries.
- Modify: `.github/workflows/ci.yml` for the supported Node matrix.
- Create/modify: `.github/workflows/release-npm.yml`.
- Create: `docs/npm-publishing-access-runbook.md`.
- Create: `release/schemas/npm-postpublish-receipt-v1.schema.json`.
- Create: `scripts/write-npm-postpublish-receipt.mjs` and
  `scripts/verify-npm-postpublish-receipt.mjs`.
- Create: `scripts/npm-postpublish-receipt.test.mjs`.
- Create after publication:
  `release/evidence/agent-coordination-dashboard-0.1.0-publishing-access.v1.json`.
- Create after publication: `release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json`.

**Interfaces:**

- Consumes: Node `>=22.12.0`, existing `prepack`, build, test, lifecycle CLI.
- Produces: npm `agent-coordination-dashboard` 0.1.0 and matching GitHub release/tag.

The dashboard has three deliberately distinct Node.js toolchain requirements:

| Purpose | Node.js | npm | Publication authority |
| --- | --- | --- | --- |
| Runtime and CI compatibility floor | `22.12.0` | Repository-supported npm | Never authorizes publication |
| npm trusted-publisher platform minimum | `22.14.0` | `11.5.1` | Compatibility threshold only |
| Authorized publication toolchain | `24.8.0` | `11.5.1` | The only toolchain allowed to publish |

- [ ] **Step 1: Add package-content assertions**

Run `npm pack --dry-run --json` and assert the tarball contains only the
declared `bin`, built `dist`, `scripts/demo.ts`, required server/shared runtime
sources, license, package metadata, README, and changelog. Add `CHANGELOG.md` to
the explicit package file list. Reject tests, local environment files, logs,
state, source maps not intended for release, and secrets. Preserve the existing
installed `--demo` contract.

After the dry-run passes, create the one reviewed artifact and bind its npm
integrity plus SHA-256 into the authorization before any tag or publication:

```bash
mkdir -p release/artifacts
npm pack --json --pack-destination release/artifacts \
  > release/artifacts/npm-pack.json
test "$(node -e 'const p=require("./release/artifacts/npm-pack.json");process.stdout.write(p[0].filename)')" = \
  "agent-coordination-dashboard-0.1.0.tgz"
shasum -a 256 release/artifacts/agent-coordination-dashboard-0.1.0.tgz \
  > release/artifacts/agent-coordination-dashboard-0.1.0.tgz.sha256
```

The reviewed `npm-pack.json` integrity, SHA-256 file, tarball bytes, commit, and
tag must exactly match
`release/authorizations/agent-coordination-dashboard-0.1.0.v1.json`.

- [ ] **Step 2: Install the tarball into a disposable project**

Run the packaged command's help, foreground smoke on a disposable port/state root, start/status/logs/restart/stop lifecycle, doctor JSON, and clean shutdown. Prove the installed command does not import the source checkout.

- [ ] **Step 3: Prepare npm trusted publishing and bootstrap controls**

Prepare npm provenance/OIDC from a protected GitHub release environment with no
long-lived npm token. Use the same package-keyed non-cancelling concurrency and
two-job privilege split as `AW-RELEASE-RUBYGEMS-V1`. The unprivileged job
runs install, test, typecheck, build, package-content checks, and tarball smoke,
then uploads the exact tarball and bound receipt. The minimal OIDC job downloads
those same-run artifacts with pinned actions, verifies their authorization and
integrity without installing dependencies or running repository/package hooks,
and publishes the exact tarball with scripts disabled; it never rebuilds.
Pin actions, exact Node `24.8.0`, and exact npm `11.5.1` for publication; assert
those versions before requesting an OIDC token. This deliberately exceeds npm
trusted publishing's Node `22.14.0` and meets its npm `11.5.1` minimum. Bind the future job to the authorized
workflow path, dispatch ref, run head SHA, and workflow-file digest with the
same external environment-approval boundary as Task 2. Because
the trusted publisher cannot be attached until the package exists, the exact
reviewed `0.1.0` tarball is bootstrapped by a human maintainer using interactive
2FA only after Step 4 authorization; the OIDC-capable job must not publish the
bootstrap version. Before Step 4, use authenticated npm account/organization
capability checks and the current registry trusted-publisher contract to prove
that this package type and GitHub organization can attach the reviewed workflow
immediately after first publication; record the exact attachment and read-back
procedure. If that capability cannot be established before the irreversible
bootstrap upload, stop. Do not create a reusable automation token.

Add CI and release-preflight jobs for both exact Node `22.12.0` and the current
`.nvmrc` release. Run package tests and installed-tarball CLI/lifecycle smoke on
both; keep the full browser/build suite on current Node if it is
version-neutral. Runtime compatibility at `22.12.0` does not authorize using
that version for trusted publication.

- [ ] **Step 4: Run current-head release gates and stop for authorization**

Present exact npm name, version, commit, tarball integrity/checksum, Node floor,
bootstrap method, future workflow path/ref and file digest, pinned publication
Node/npm pair, owners, grant-manifest path and SHA-256, and smoke evidence.
RubyGems approvals do not authorize
npm publication.

- [ ] **Step 5: Bootstrap, secure, and verify only after authorization**

Fetch tags, require `v0.1.0` to be absent or already dereference to the
authorized commit, then create/push and read back the protected tag before npm
publication. A tag at another commit is a terminal collision. Before login,
install the global bootstrap contract's unconditional cleanup trap and test its
success, grant-failure, attachment-failure, verification-failure, interrupt, and
unexpected-exit cases with a fake npm credential store. Publish the exact
reviewed tarball interactively with 2FA only after the tag is verified. Verify
npm registry metadata, owners, and tarball integrity; install the downloaded
`agent-coordination-dashboard@0.1.0` tarball whose integrity matches the reviewed
artifact, then run its installed `--help` and lifecycle smoke without resolving
an unversioned `latest`. Use the authenticated bootstrap owner to grant exactly
the approved backup human-owner rows and every supported ShakaCode team-access
row. Read the owner list and each distinct team access row back through
authenticated registry interfaces. Record an organization/team row as
unsupported only when the live preflight proved that exact operation unavailable
for this package and preserved the capability evidence in the manifest.
Immediately attach the protected release workflow as
the package's trusted publisher. Through an authenticated npm interface, set
the package Settings > Publishing access value to **Require two-factor
authentication and disallow tokens** using npm's documented authenticated web
procedure and an interactive 2FA challenge. The checked-in runbook pins the
package URL, exact Settings > Publishing access navigation and control label,
the required selection, save/2FA confirmation, logout, and fresh-login read-back
steps. Capture only a non-secret evidence reference plus its digest.
`write-npm-postpublish-receipt.mjs` consumes the exact release authorization,
grant manifest, reviewed tarball integrity/SHA-256, commit, tag, observed setting,
trusted-publisher identity, actor handle, timestamp, and evidence reference/digest
to write `release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json`.
`verify-npm-postpublish-receipt.mjs` validates it against
`npm-postpublish-receipt-v1.schema.json`, independently supplied expected
authorization/artifact/commit values, and the exact token-disallowing setting;
it rejects credential values, cookies, headers, query strings, response bodies,
wrong artifacts, stale observations, and mismatched actors or publishers. Test
every rejection plus a fresh-login matching receipt. The release is incomplete if either
the trusted-publisher attachment, setting write/read-back, or validated
postpublication receipt fails. The cleanup trap logs out or revokes the interactive session before
Step 5 returns on either success or failure; read back the absence of reusable
local credentials without printing values. Record every grant-manifest row's
result and manifest digest in the release receipt. Record that OIDC provenance
starts with the next release because the bootstrap version was not
workflow-published.

Run the receipt test, writer, and independent verifier against the exact reviewed
inputs:

```bash
node --test scripts/npm-postpublish-receipt.test.mjs
node scripts/write-npm-postpublish-receipt.mjs \
  --authorization release/authorizations/agent-coordination-dashboard-0.1.0.v1.json \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball release/artifacts/agent-coordination-dashboard-0.1.0.tgz \
  --evidence release/evidence/agent-coordination-dashboard-0.1.0-publishing-access.v1.json \
  --output release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json
node scripts/verify-npm-postpublish-receipt.mjs \
  --receipt release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json \
  --authorization release/authorizations/agent-coordination-dashboard-0.1.0.v1.json \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball release/artifacts/agent-coordination-dashboard-0.1.0.tgz
```

Create the GitHub Release explicitly from the already verified tag with tarball
integrity, checksum, and `0.1.0` changelog notes, then read back the tag and
release. If publication fails after the tag is created, do not move or reuse the
tag: reconcile live npm state and record an explicit retry or version-bump
disposition. Do not publish another version merely to test OIDC.

### Task 5: Evaluate self-contained Agent Workflows executables

**Files in `shakacode/agent-workflows`:**

- Create: `packaging/tebako/entrypoint.rb`
- Create: `packaging/tebako/commands.yml`
- Create: `packaging/tebako/network-allowlist.yml`
- Create: `packaging/tebako/build-platform.rb`
- Create: `packaging/tebako/measure-platform.rb`
- Create: `packaging/tebako/write-release-authorization.rb`
- Create: `packaging/tebako/write-release-decision.rb`
- Create: `packaging/tebako/write-publication-instruction.rb`
- Create: `packaging/tebako/write-github-release-receipt.rb`
- Create: `packaging/tebako/write-publication-recovery.rb`
- Create: `packaging/tebako/validate-evaluation.rb`
- Create: `packaging/tebako/write-evaluation.rb`
- Create: `packaging/tebako/write-platform-run.rb`
- Create: `test/packaging/standalone_executable_test.rb`
- Create: `test/packaging/standalone_real_network_test.rb`
- Create: `test/packaging/standalone_evaluation_validator_test.rb`
- Create: `test/packaging/standalone_release_evidence_test.rb`
- Create: `.github/workflows/package-standalone.yml`
- Create: `release/schemas/standalone-platform-input-v1.schema.json`
- Create: `release/schemas/standalone-platform-run-v1.schema.json`
- Create: `release/schemas/standalone-evaluation-v1.schema.json`
- Create: `release/schemas/standalone-release-authorization-v1.schema.json`
- Create: `release/schemas/standalone-release-decision-v1.schema.json`
- Create: `release/schemas/standalone-publication-instruction-v1.schema.json`
- Create: `release/schemas/standalone-mutator-operation-result-v1.schema.json`
- Create: `release/schemas/standalone-github-release-receipt-v1.schema.json`
- Create: `release/schemas/standalone-publication-recovery-v1.schema.json`
- Create from matrix jobs: four
  `release/evidence/standalone/runs/<platform>-<architecture>.v1.json` records.
- Create: `release/evidence/standalone-evaluation-v1.json` for either verdict.
- Create after human approval:
  `release/authorizations/agent-workflows-standalone-v1.json`.
- Create after denial or expiry:
  `release/evidence/standalone-release-decision-v1.json`.
- Create after uploaded-asset read-back:
  `release/evidence/standalone-github-release-receipt-v1.json`.
- Create after an ambiguous toggle or public read-back:
  `release/evidence/standalone-github-publication-recovery-v1.json`.
- Create before protected release mutation:
  `release/evidence/standalone-github-publication-instruction-v1.json`.
- Create: `docs/standalone-installation.md` only if the evaluation passes.

**Interfaces:**

- Consumes: the verified `agent-workflows` gem artifact.
- Produces: an evidence report and optionally platform executables; it does not change gem behavior.

- [ ] **Step 1: Define one multi-command entrypoint**

`commands.yml` is the single command registry: each key is an installed command
name and each value is its canonical CLI constant. `entrypoint.rb` validates
and loads that registry, selects a canonical CLI from the invoked link name,
and has no second hard-coded command list. The canonical `agent-workflows`
artifact consumes the command as its first argument; no arguments, `-h`, or
`--help` prints top-level usage and exits zero:

```ruby
require "psych"
require "agent_workflows"

command = File.basename($PROGRAM_NAME)
commands = Psych.safe_load_file(File.join(__dir__, "commands.yml"), permitted_classes: [], aliases: false)
usage = "usage: agent-workflows <#{commands.keys.sort.join('|')}> [arguments]"
if command == "agent-workflows" && (ARGV.empty? || %w[-h --help].include?(ARGV.first))
  puts usage
  exit 0
end
command = ARGV.shift if command == "agent-workflows"
constant_name = commands.fetch(command) do
  warn "unknown agent-workflows command: #{command.inspect}\n#{usage}"
  exit 64
end
cli = constant_name.split("::").reject(&:empty?).reduce(Object) do |scope, name|
  scope.const_get(name, false)
end
exit cli.start(ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr)
```

Generate small platform command links/wrappers only after the single packaged
entrypoint passes. Validate `commands.yml` as a string-to-string mapping with
safe command/constant-name patterns before constant resolution. Contract tests
derive every expected link from the YAML keys, reject unlisted links, invoke
the canonical artifact with no arguments and both help flags, invoke it with
each explicit command, and invoke every link directly with `--help`. Adding a
future extracted CLI therefore requires one reviewed registry entry and cannot
silently diverge from the packaged dispatch table.

- [ ] **Step 2: Build a pinned Tebako artifact matrix**

Pin Tebako and Ruby versions. Build fat, no-runtime-dependency executables on
macOS arm64/x86_64 and Linux arm64/x86_64 runners. The workflow matrix is a
closed four-row mapping from platform/architecture to a runner image pinned by
immutable image identifier. Its build step runs:

```bash
ruby packaging/tebako/build-platform.rb \
  --platform "$STANDALONE_PLATFORM" \
  --architecture "$STANDALONE_ARCH" \
  --runner-image "$STANDALONE_RUNNER_IMAGE" \
  --gem "$VERIFIED_AGENT_WORKFLOWS_GEM" \
  --artifact "$STANDALONE_ARTIFACT" \
  --provenance "$RUNNER_TEMP/standalone-build-provenance.v1.json"
```

The builder rejects an unpinned runner identity or wrong gem digest and writes
a schema-validated build-provenance input containing the exact Ruby/Tebako and
native toolchain versions, runner image identifier, gem and source digests,
commands registry digest, build arguments and environment allowlist, artifact
SHA-256 and size, and stdout/stderr log digests. It records no credential values.
Do not claim cross-platform support for a platform without a native smoke result.

- [ ] **Step 3: Run compatibility and portability tests**

For every artifact, run help, JSON doctor, malformed input, filesystem reads
from host paths, timeout/process-group cleanup, temporary-file creation,
non-ASCII locale, relocated executable, read-only executable directory, and
offline execution. In the offline contract suite, block network access and put
deterministic fake `git` and `gh` executables first on `PATH`; assert argv,
environment, channels, exit codes, and absence of network access. Separately run
a real-child-command integration suite with installed `git` and `gh`, bounded
credentials, and only endpoints declared in `network-allowlist.yml`.
`standalone_real_network_test.rb` records a sanitized network-observation
fragment required by the acceptance gate and fails on an undeclared endpoint or operation. A
fake-command pass proves wiring, while the real-command pass proves integration.
Each native matrix job writes that fragment without credentials or request
bodies:

```bash
ruby test/packaging/standalone_real_network_test.rb \
  --artifact "$STANDALONE_ARTIFACT" \
  --allowlist packaging/tebako/network-allowlist.yml \
  --output "$RUNNER_TEMP/standalone-network-observations.v1.json"
```

After Step 4 has produced every other measurement, the same matrix job creates
one complete schema-validated platform receipt. Each named input is a
machine-readable result from that job, and the writer binds the artifact,
platform/architecture, complete CLI corpus, sanitized network observations,
cold-start samples and cache reset, compressed size, path/locale results,
signing/notarization result, Linux baseline result, reproducibility manifests
and section diff, and vulnerability/license scans. Every input, including the
network fragment and build provenance, validates against its closed `kind`
variant in `standalone-platform-input-v1.schema.json`; the final receipt
validates against `standalone-platform-run-v1.schema.json`.

Step 4 creates the eight non-network measurement inputs with one explicit
producer. The producer runs the contract/path-locale cases and pinned scanning
tools itself, records the five cold-start samples and cache-reset command, and
consumes the two clean builds needed for the reproducibility comparison:

```bash
ruby packaging/tebako/measure-platform.rb \
  --platform "$STANDALONE_PLATFORM" \
  --architecture "$STANDALONE_ARCH" \
  --runner-image "$STANDALONE_RUNNER_IMAGE" \
  --artifact "$STANDALONE_ARTIFACT" \
  --build-provenance "$RUNNER_TEMP/standalone-build-provenance.v1.json" \
  --output-dir "$RUNNER_TEMP"
```

It writes exactly `standalone-contract-results.v1.json`,
`standalone-cold-start.v1.json`, `standalone-compressed-size.v1.json`,
`standalone-path-locale.v1.json`, `standalone-signing.v1.json`,
`standalone-linux-baseline.v1.json`, `standalone-reproducibility.v1.json`, and
`standalone-scans.v1.json`. The macOS signing input contains a schema-valid
`passed` or `failed` result while its Linux-baseline input is `not_applicable`
with the platform criterion; Linux records the inverse. The schema forbids
`not_applicable` for any other input or platform combination.

A missing, duplicate, malformed, wrong-platform, wrong-artifact, wrong-runner,
or provenance-invalid input stops receipt creation. A schema-valid `failed`
measurement does not: the writer preserves it and derives the exact failed
criterion so Step 5 can produce a durable `NOT_ADOPTED` evaluation:

```bash
ruby packaging/tebako/write-platform-run.rb \
  --platform "$STANDALONE_PLATFORM" \
  --architecture "$STANDALONE_ARCH" \
  --artifact "$STANDALONE_ARTIFACT" \
  --build-provenance "$RUNNER_TEMP/standalone-build-provenance.v1.json" \
  --contract-results "$RUNNER_TEMP/standalone-contract-results.v1.json" \
  --network-results "$RUNNER_TEMP/standalone-network-observations.v1.json" \
  --cold-start-results "$RUNNER_TEMP/standalone-cold-start.v1.json" \
  --size-results "$RUNNER_TEMP/standalone-compressed-size.v1.json" \
  --path-locale-results "$RUNNER_TEMP/standalone-path-locale.v1.json" \
  --signing-results "$RUNNER_TEMP/standalone-signing.v1.json" \
  --baseline-results "$RUNNER_TEMP/standalone-linux-baseline.v1.json" \
  --reproducibility-results "$RUNNER_TEMP/standalone-reproducibility.v1.json" \
  --scan-results "$RUNNER_TEMP/standalone-scans.v1.json" \
  --output "release/evidence/standalone/runs/${STANDALONE_PLATFORM}-${STANDALONE_ARCH}.v1.json"
```

The workflow supplies `STANDALONE_PLATFORM` and `STANDALONE_ARCH` from a closed
four-row matrix and uploads the four complete receipts as same-run artifacts.
Its aggregation job downloads those exact artifacts, rejects duplicate or
missing platform/architecture identities, verifies every embedded evidence
digest, and writes the single evaluation input:

```bash
ruby packaging/tebako/write-evaluation.rb \
  --run release/evidence/standalone/runs/macos-arm64.v1.json \
  --run release/evidence/standalone/runs/macos-x86_64.v1.json \
  --run release/evidence/standalone/runs/linux-arm64.v1.json \
  --run release/evidence/standalone/runs/linux-x86_64.v1.json \
  --output release/evidence/standalone-evaluation-v1.json
```

- [ ] **Step 4: Measure acceptance thresholds**

The standalone path passes only if:

- all CLI contract cases match the gem;
- on each named native runner image and architecture in the evidence report,
  five isolated cold `--help` runs after clearing only the artifact's disposable
  cache have a median at or below 1.5 seconds; record every duration and the
  cache-reset command;
- each compressed download is at most 100 MiB;
- the offline contract corpus performs no runtime/bootstrap dependency fetches
  or other network access; command-requested network traffic is permitted only
  in the separately bounded real-child integration suite. For every artifact,
  that suite must pass the expected operations against an explicit endpoint
  allowlist, produce gem-equivalent results, and fail on any unexpected request.
  Record only redacted credential metadata (principal, scope, expiry, and opaque
  identifier) plus sanitized request method, host, path, and status; omit all
  credential values, headers, secret-bearing query parameters, and request or
  response bodies;
- the artifact runs from a path containing spaces and non-ASCII characters;
- macOS artifacts are signed/notarizable under the project's release identity;
- Linux artifacts run in an Ubuntu 20.04/glibc 2.31 baseline container without
  loading libraries from the build host;
- two clean unsigned builds in the same pinned environment produce identical
  sorted application-payload manifests of path, mode, size, and SHA-256, and
  byte-identical payload files. Compare the outer executable by section and
  permit differences only in toolchain-generated build-id, timestamp, or
  signature-reservation fields named in the report with exact offsets, lengths,
  and decoded values; every other byte must match. Store both manifests,
  executable checksums, and the machine-readable section-diff report before an
  adoption verdict;
- vulnerability and license scanning covers bundled Ruby, standard library, Tebako, and native libraries.

- [ ] **Step 5: Make an explicit adoption decision**

If every threshold passes, record `ADOPTED_PENDING_RELEASE_AUTHORIZATION` and
prepare the optional-download documentation without publishing it. If any
security, behavior, platform, or maintenance threshold fails, record
`NOT_ADOPTED` with the exact failed criteria; retain gem/source-pack
distribution and do not begin a Rust rewrite automatically.
Both outcomes are written to `release/evidence/standalone-evaluation-v1.json`
with every platform artifact, test result, sanitized network observation,
threshold measurement, failure, and evidence digest required by
`standalone-evaluation-v1.schema.json`. Validate the durable result before any
adoption or rejection handoff:

`standalone_real_network_test.rb --unit` is a separately tested, network-disabled
mode that exercises argument validation, credential redaction, allowlist
matching, and unexpected-request rejection with fake child commands. It never
substitutes for the four native real-network fragments already bound into the
evaluation.

```bash
ruby test/packaging/standalone_executable_test.rb
ruby test/packaging/standalone_real_network_test.rb --unit
ruby test/packaging/standalone_evaluation_validator_test.rb
ruby packaging/tebako/validate-evaluation.rb \
  release/evidence/standalone-evaluation-v1.json
```

- [ ] **Step 6: Require separate release authorization for binaries**

Binary release approval names platforms, architectures, checksums, signing
state, Ruby/Tebako versions, immutable GitHub repository/tag/commit target,
source matrix run ID, workflow path/ref/digest, expiry, and rollback. Gem
publication approval does not authorize binary artifacts. Create the
authorization only from durable human approval that names the exact source
evaluation digest:

```bash
ruby packaging/tebako/write-release-authorization.rb \
  --evaluation release/evidence/standalone-evaluation-v1.json \
  --approval-source-url "$BINARY_APPROVAL_SOURCE_URL" \
  --approved-by "$BINARY_APPROVER" \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --target-commit "$AUTHORIZED_BINARY_COMMIT" \
  --source-run-id "$STANDALONE_SOURCE_RUN_ID" \
  --workflow-path .github/workflows/package-standalone.yml \
  --workflow-ref "$STANDALONE_WORKFLOW_REF" \
  --workflow-digest "$STANDALONE_WORKFLOW_DIGEST" \
  --mutator-action "$STANDALONE_MUTATOR_ACTION" \
  --mutator-action-digest "$STANDALONE_MUTATOR_ACTION_DIGEST" \
  --mutator-result-schema \
    release/schemas/standalone-mutator-operation-result-v1.schema.json \
  --expires-at "$BINARY_AUTHORIZATION_EXPIRY" \
  --rollback-disposition "$BINARY_ROLLBACK_DISPOSITION" \
  --rollback-evidence "$BINARY_ROLLBACK_EVIDENCE" \
  --output release/authorizations/agent-workflows-standalone-v1.json
ruby test/packaging/standalone_release_evidence_test.rb
```

The writer requires the input state to be
`ADOPTED_PENDING_RELEASE_AUTHORIZATION`, copies the closed four-platform asset
bindings from that evaluation, requires every target/run/workflow input above,
requires an independently reviewed mutator action at an immutable commit and
content digest, binds the result schema's fixed path, version, and SHA-256, and
validates the result against
`standalone-release-authorization-v1.schema.json`. It rejects a threshold
failure, failed criterion, terminal input, ambiguous approver, mutable target,
missing rollback, or stale authorization. For denial, or when a previously
valid authorization expires before upload, create a separate decision receipt.
For an initial denial, no authorization exists and the argument is forbidden:

```bash
ruby packaging/tebako/write-release-decision.rb \
  --evaluation release/evidence/standalone-evaluation-v1.json \
  --decision authorization-denied \
  --decision-source-url "$BINARY_DECISION_SOURCE_URL" \
  --decided-by "$BINARY_DECISION_PRINCIPAL" \
  --output release/evidence/standalone-release-decision-v1.json
```

For an authorization that became stale before upload, bind the exact expired
authorization:

```bash
ruby packaging/tebako/write-release-decision.rb \
  --evaluation release/evidence/standalone-evaluation-v1.json \
  --decision authorization-stale \
  --decision-source-url "$BINARY_DECISION_SOURCE_URL" \
  --decided-by "$BINARY_DECISION_PRINCIPAL" \
  --authorization release/authorizations/agent-workflows-standalone-v1.json \
  --output release/evidence/standalone-release-decision-v1.json
```

The authorization is required for `authorization-stale` and forbidden for an
initial `authorization-denied` decision. The authorization schema binds the
human-approved rollback disposition and evidence; neither may be synthesized or
defaulted by the writer. The decision writer validates the decision
against `standalone-release-decision-v1.schema.json`, including deciding
principal, decision timestamp, source URL, source-evaluation digest, and either
the explicit denial or the authorization expiry. These schemas and their tests
are the only accepted terminal evidence contracts.

- [ ] **Step 7: Publish binaries only after authorization**

Split standalone publication into five tag-serialized jobs under one concurrency
group with `cancel-in-progress: false`: `prepare-publication`, `stage-draft`,
`verify-draft`, `expose-draft`, and `verify-public`. No build, matrix,
aggregation, verification, or recovery job receives `contents: write`.

`prepare-publication` is unprivileged: `contents: read`, `actions: read`, no
environment, persisted checkout credential, or write permission. All repository
Ruby, Bundler, tests, schemas, and preflight logic end in this job. It checks out
the exact authorized commit, downloads only the bound source-run artifacts,
verifies every workflow/evaluation/authorization/tag/commit/expiry binding and
asset checksum/signature, rejects a public or unowned release for the tag, and
writes a closed publication instruction:

```bash
ruby packaging/tebako/write-publication-instruction.rb \
  --evaluation release/evidence/standalone-evaluation-v1.json \
  --authorization release/authorizations/agent-workflows-standalone-v1.json \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --output release/evidence/standalone-github-publication-instruction-v1.json
```

The instruction schema binds the authorization/evaluation/workflow digests,
source run, repository, immutable tag and target commit, closed four-asset
name/digest/signature matrix, expiry, and the independently reviewed mutator
action's repository, immutable commit, and content digest plus the mutator-result
schema path, version, and digest. Upload the instruction plus exact asset bundle
as one same-run workflow artifact; read back and record its artifact ID and
SHA-256. Any mismatch stops before a write-capable job starts.

`stage-draft` is the first protected write job. It has only job-scoped
`contents: write` and `actions: read`, performs no checkout, and runs no shell,
Ruby, Bundler, repository script, dependency hook, or caller-supplied program.
Its only executable steps are immutable-SHA-pinned artifact download and the
authorization-bound independent mutator action in closed `stage-draft` mode.
That action accepts no arbitrary API route, script, or request-body input. It
independently validates the instruction and artifact bundle, then creates or
resumes only an exporter-owned **draft** release for the exact tag and uploads
exactly the closed asset set. A build artifact, workflow log, or non-draft
release is never an upload target. It emits a closed `stage_succeeded` operation
result binding the protected run, release/asset IDs, and observed `draft: true`
under the bound mutator-result schema. A pinned artifact step uploads those exact
bytes and queries the resulting artifact ID/digest. The unprivileged verifier
owns fresh retrieval and domain-schema validation.

`verify-draft` is again unprivileged and has only `contents: read` plus
`actions: read`. It downloads the stage-result artifact by exact ID/digest into
a fresh directory, verifies its bytes against the authorization-bound schema
path/version/digest with repository validation code, and requires the closed
`stage_succeeded` variant. It then runs the repository's read-only receipt
writer, queries the immutable draft release and asset IDs, downloads every asset
through authenticated API endpoints to a new temporary directory, and rejects
a mismatched tag/target, non-draft release, missing or extra asset,
cross-repository redirect, digest/signature mismatch, or evidence-binding
mismatch:

```bash
ruby packaging/tebako/write-github-release-receipt.rb \
  --expected-state draft \
  --evaluation release/evidence/standalone-evaluation-v1.json \
  --authorization release/authorizations/agent-workflows-standalone-v1.json \
  --operation-result "$STAGE_DRAFT_OPERATION_RESULT" \
  --operation-result-artifact-id "$STAGE_RESULT_ARTIFACT_ID" \
  --operation-result-artifact-digest "$STAGE_RESULT_ARTIFACT_DIGEST" \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --output "$RUNNER_TEMP/standalone-github-draft-release-receipt-v1.json"
```

The `draft_verified` receipt binds the repository, release, tag, target, and
asset IDs; API and authenticated-download timestamps; canonical asset URLs;
downloaded digests; verified signatures; platform/architecture; authorization,
source-evaluation, workflow, instruction, protected-run, and operation-result
artifact IDs/digests; and observed `draft: true`. Upload it as a retention-bounded artifact
named by tag and staging run, then read back its artifact ID and SHA-256. Loss or
mismatch blocks exposure.

`expose-draft` is the second protected write job and has the same no-checkout,
no-repository-code contract as `stage-draft`. Its only mutating step is the same
independently pinned action in closed `expose-draft` mode. It consumes the exact
durable draft receipt, revalidates its digest and the unexpired authorization,
re-reads that exact draft release, downloads and re-verifies every live asset
digest/signature, rejects extra or replaced asset IDs, requires the same
tag/target and `draft: true`, and may then toggle only that receipt's release ID.
The mutator emits either a closed `expose_succeeded` result or a closed ambiguity
result under the authorization-bound result schema. The success result binds
the protected run, release/tag/target, instruction, authorization, draft-receipt
artifact ID/digest, mutator identity/digest, toggle timestamp, and response
status; it accepts no caller-selected fields. An immutable-SHA-pinned artifact
step uploads those exact bytes and queries the resulting artifact ID/digest; it
does not execute repository or domain-validation code. A missing, substituted,
or non-durable success result is `PUBLICATION_UNKNOWN`, never successful
exposure.
The exact mutator action identity/digest and both closed modes are part of human
environment review; a repository-controlled helper never receives a write token.

`verify-public` is unprivileged and read-only. It downloads the expose-result
artifact by exact ID/digest into a fresh directory, verifies its bytes against
the authorization-bound schema path/version/digest with repository validation
code, and requires the closed `expose_succeeded` variant. It then reads back the
public release and emits `published_verified` only when the result's protected
run and evidence bindings plus the tag, target, release ID, asset IDs, digests,
and signatures still match the draft receipt. It then generates a schema-valid
candidate terminal `ADOPTED` evaluation without yet accepting, reporting, or
committing that transition.
Package the published receipt, candidate terminal evaluation, draft receipt,
authorization, and a manifest of their SHA-256 digests as one
`standalone-publication-closeout-<tag>-<expose-run>` workflow artifact. Upload,
query, and download that artifact to a fresh directory, revalidate its manifest
and both schemas, and record the artifact ID/digest in the job summary. Only
that fresh durable read-back accepts and reports the candidate transition as
terminal `ADOPTED`; an ephemeral checkout result is never adoption or closeout
evidence.

A failed preflight exposes nothing. A staging upload or draft read-back failure
before the toggle leaves the release draft and records the exact retry/cleanup
disposition; no fallback path may make it public. An ambiguous toggle response or
failure of the post-toggle public read-back is instead `PUBLICATION_UNKNOWN` and
blocks adoption; failure to persist and read back either the expose-result or
final closeout artifact has the same result. The independently pinned mutator
emits only the closed `publication_ambiguous` result variant, which a pinned
artifact step persists as exact bytes and queries for artifact ID/digest without
executing repository code. The subsequent read-only `verify-public` or recovery
job freshly downloads that exact artifact, verifies its bytes against the
authorization-bound schema path/version/digest, requires the closed ambiguity
variant, and turns it into a schema-validated `publication_unknown` record. A
later recovery dispatch has two mutually exclusive bootstrap origins. An
artifact-backed origin requires the exact mutator-result artifact above. An
`interrupted_without_result` origin is allowed only when the exact protected
run/job entered the bound mutator step but terminated before emitting a result,
the run is terminal, two fresh complete artifact inventories after termination
separated by a writer-owned fixed propagation grace find no expose-result
artifact, and no terminal receipt or recovery artifact exists. That variant
retrieves and digests the original run's durable draft
receipt, queries the protected run/job and step evidence through the GitHub API,
and captures a fresh read-only release observation; it forbids mutator-result
path and artifact fields. The record binds its closed origin variant, expose
run/job and mutator identity/digest, workflow digest, authorization,
draft-receipt artifact ID/digest, conditionally required-or-forbidden
mutator-result artifact ID/digest, release ID, exact asset IDs, first ambiguous
timestamp, recovery deadline, and attempt count. For
`interrupted_without_result`, it additionally binds the mutator step's name,
number, status, start/completion timestamps, and API response digest; both
complete paginated artifact-inventory snapshot digests, query timestamps,
artifact counts, and absent name; the fixed grace duration and its start/end
timestamps; and the terminal-receipt/recovery-artifact absence query's response
digest, timestamp, pagination-completeness flag, and counts. Successor records
preserve that entire origin proof byte-for-byte.

```bash
ruby packaging/tebako/write-publication-recovery.rb \
  --authorization release/authorizations/agent-workflows-standalone-v1.json \
  --draft-receipt "$RUNNER_TEMP/standalone-github-draft-release-receipt-v1.json" \
  --draft-artifact-id "$DRAFT_RECEIPT_ARTIFACT_ID" \
  --draft-artifact-digest "$DRAFT_RECEIPT_ARTIFACT_DIGEST" \
  --original-run-id "$EXPOSE_RUN_ID" \
  --mutator-result "$EXPOSE_MUTATOR_RESULT" \
  --mutator-result-artifact-id "$EXPOSE_RESULT_ARTIFACT_ID" \
  --mutator-result-artifact-digest "$EXPOSE_RESULT_ARTIFACT_DIGEST" \
  --reason "$PUBLICATION_AMBIGUITY" \
  --first-ambiguous-at "$PUBLICATION_AMBIGUOUS_AT" \
  --attempt-count 0 \
  --output release/evidence/standalone-github-publication-recovery-v1.json
```

For the narrowly proven interrupted-job origin, omit every mutator-result
argument and let the writer query and bind the exact terminal evidence:

```bash
ruby packaging/tebako/write-publication-recovery.rb \
  --authorization release/authorizations/agent-workflows-standalone-v1.json \
  --draft-receipt "$RUNNER_TEMP/standalone-github-draft-release-receipt-v1.json" \
  --draft-artifact-id "$DRAFT_RECEIPT_ARTIFACT_ID" \
  --draft-artifact-digest "$DRAFT_RECEIPT_ARTIFACT_DIGEST" \
  --original-run-id "$EXPOSE_RUN_ID" \
  --interrupted-job-id "$EXPOSE_JOB_ID" \
  --current-run-id "$RECOVERY_RUN_ID" \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --reason interrupted_without_result \
  --attempt-count 0 \
  --output release/evidence/standalone-github-publication-recovery-v1.json
```

The writer, not the caller, derives the immutable recovery deadline as exactly
30 minutes after `first_ambiguous_at`. Artifact-backed bootstrap receives the
mutator timestamp; interrupted bootstrap obtains `first_ambiguous_at` from the
bound job's terminal/interruption timestamp through the GitHub API and applies
the same derivation. The caller cannot supply that timestamp for the interrupted
variant.

Recovery is a separate read-only job with explicit `contents: read` and
`actions: read`, the same tag concurrency group, and no environment or write
permission. It always downloads the draft receipt from the bound original run;
for an artifact-backed origin it also downloads the exact mutator-result artifact
by its bound ID/digest and validates the authorization-bound schema and closed
ambiguity variant before using it. For an interrupted origin it instead
revalidates the exact run/job/step terminal evidence, complete absent-artifact
inventories, and fresh live observation bound by attempt 0. It downloads a prior
recovery record from that record's bound producer run, verifies every
run/artifact digest and identity, and re-queries only the exact release and asset
IDs without uploading or toggling. Attempt 0 may omit `--prior-recovery` only
for either a fully validated artifact-backed ambiguity result or an
`interrupted_without_result` origin whose protected run has neither a terminal
release receipt nor any recovery or expose-result artifact. Interrupted
bootstrap invokes the writer with the original draft artifact, exact interrupted
job, `--current-run-id`, repository, and tag; the writer queries and binds the
new live observation itself. Every later attempt additionally supplies
`--prior-recovery` and its producer
run/artifact ID/digest. The writer requires a contiguous chain, increments the
prior count itself, preserves the original deadline and immutable bindings, and
emits an append-only successor. Upload and read back that successor as an
artifact named by the current recovery run and zero-based attempt ordinal before
the attempt ends; the next attempt must name it exactly.

Allow exactly the zero-based ordinals `0`, `1`, and `2`—at most three attempts
total—before that immutable deadline. Bootstrap emits attempt 0; each successor
derives its ordinal by incrementing the prior record, and attempt 3 is forbidden.
A matching public
read-back may generate `published_verified` and a candidate terminal evaluation,
but recovery accepts and reports `ADOPTED` only after packaging them into and
freshly reading back the same final closeout artifact required above. Any
inconclusive, draft, missing, extra, mismatched, or non-durable state preserves
`PUBLICATION_UNKNOWN` and executes the
authorization's incident/remediation disposition when the attempt or deadline
bound is reached. Tests cover stale authorization, wrong workflow
or run binding, substituted local bytes, pre-existing public/unowned releases,
draft-state loss, loss or substitution of the durable draft artifact, missing,
substituted, skipped, repeated, and over-limit recovery records, caller-selected,
extended, or recomputed recovery deadlines, asset replacement between draft
receipt and toggle, upload/draft-read-back failure, an ambiguous toggle response,
a crash after toggle request, public read-back or final-closeout persistence
failure, bounded `PUBLICATION_UNKNOWN` recovery, privileged-job attempts to
execute checkout/repository code or arbitrary mutator inputs, missing or
substituted successful expose-result artifacts, wrong result-schema bindings or
variants, missing or substituted stage/ambiguity result artifacts, false or
racing interrupted-result absence, a job that never entered the mutator step,
caller-supplied interrupted timestamps, altered or missing interrupted-origin
proof in successor records, skipped/repeated/over-limit attempt ordinals, and
refusal to publish before receipt verification.

Only after the public and closeout-artifact read-backs pass, accept and report
the candidate evaluation as terminal `ADOPTED`, then publish
`docs/standalone-installation.md`. The candidate terminal writer receives the
receipt rather than unverified URL strings:

```bash
ruby packaging/tebako/write-evaluation.rb \
  --finalize-status ADOPTED \
  --input release/evidence/standalone-evaluation-v1.json \
  --authorization-evidence release/authorizations/agent-workflows-standalone-v1.json \
  --release-receipt release/evidence/standalone-github-release-receipt-v1.json \
  --output release/evidence/standalone-evaluation-v1.json
ruby packaging/tebako/validate-evaluation.rb \
  release/evidence/standalone-evaluation-v1.json
```

If authorization is denied or stale before upload, record terminal
`NOT_ADOPTED` from the Step 6 decision receipt and retain the evaluation evidence
without public artifacts:

```bash
ruby packaging/tebako/write-evaluation.rb \
  --finalize-status NOT_ADOPTED \
  --failed-criterion "$AUTHORIZATION_FAILURE" \
  --authorization-decision release/evidence/standalone-release-decision-v1.json \
  --input release/evidence/standalone-evaluation-v1.json \
  --output release/evidence/standalone-evaluation-v1.json
ruby packaging/tebako/validate-evaluation.rb \
  release/evidence/standalone-evaluation-v1.json
```

`AUTHORIZATION_FAILURE` is a closed enum containing only
`authorization-denied` and `authorization-stale`. Both finalization modes are
allowed only from `ADOPTED_PENDING_RELEASE_AUTHORIZATION` whose complete
platform matrix passes every threshold and has no failed criterion. A
threshold-derived `NOT_ADOPTED` from Step 5 is already terminal and is never
passed to finalization. The writer rejects any transition from `ADOPTED` or
`NOT_ADOPTED`, never removes or overwrites prior failure evidence, and forbids
release evidence on the authorization-failure path. Tests cover the complete
allowed transition table and every rejected cross-state transition.
`ADOPTED_PENDING_RELEASE_AUTHORIZATION` is never a completion state. In both
terminal paths the writer uses a same-directory temporary file plus atomic
rename so input and output may be the same path without truncating the prior
evidence.

### Task 6: Complete package ownership and post-release audit

**Files:**

- Update release runbooks and changelogs in each repository.
- Create:
  `release/evidence/agent-coordination-dashboard-0.1.0-publishing-access-closeout.v1.json`.
- Create no new alias package.

**Interfaces:**

- Consumes: verified registry releases.
- Produces: durable ownership, provenance, install, and rollback evidence.

- [ ] **Step 1: Confirm owners and trusted publishers**

Verify at least two confirmed human owners, MFA requirements, protected release
environments, and exact repository/workflow bindings on each registry. Verify
supported organization roles for both RubyGems packages. For the unscoped npm
package, verify the trusted publisher and read back every supported ShakaCode
team access row. In a fresh authenticated npm package-settings view, also read
back **Require two-factor authentication and disallow tokens** and validate the
matching `release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json`.
Accept an unsupported disposition only with authenticated live capability
evidence for that exact operation; unscoped naming alone is not such evidence.
Download the registry artifact rather than trusting the prepublication copy,
then replay the verifier with the fresh setting observation and exact expected
commit/tag from the authorization:

```bash
NPM_AUDIT_DIR="$(mktemp -d)"
npm pack agent-coordination-dashboard@0.1.0 --json \
  --pack-destination "$NPM_AUDIT_DIR" > "$NPM_AUDIT_DIR/npm-pack.json"
NPM_AUDIT_TARBALL="$NPM_AUDIT_DIR/agent-coordination-dashboard-0.1.0.tgz"
node scripts/verify-npm-postpublish-receipt.mjs \
  --receipt release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json \
  --authorization release/authorizations/agent-coordination-dashboard-0.1.0.v1.json \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball "$NPM_AUDIT_TARBALL" \
  --fresh-observation release/evidence/agent-coordination-dashboard-0.1.0-publishing-access-closeout.v1.json \
  --expected-commit "$(node -p 'require("./release/authorizations/agent-coordination-dashboard-0.1.0.v1.json").commit')" \
  --expected-tag v0.1.0
```

- [ ] **Step 2: Verify clean-machine installation**

From fresh temporary homes, install each public package by exact version and run its smoke suite. Record versions, registry integrity/checksums, and command results without credentials.

- [ ] **Step 3: Verify tags, releases, and source correspondence**

Each package version maps to one immutable public commit and release. Rebuild from that commit and compare package content manifests. Any unexplained difference blocks closeout.

- [ ] **Step 4: Run cross-package stack smoke**

Install both Ruby gems and the npm dashboard, then run shallow/deep stack doctor, local coordination state, dashboard lifecycle, and cleanup. Version incompatibility or missing component guidance must be actionable and non-secret.

- [ ] **Step 5: Audit package naming**

Confirm no `agent_workflows`, `agent_coordination`, dashboard Ruby gem, or other placeholder alias was published. Record unrelated pre-existing npm `agent-workflows` as an ecosystem naming collision, not an owned ShakaCode package.

- [ ] **Step 6: Publish release closeout evidence**

Record package URLs, exact versions, commits, checksums/integrities, owners, trusted publishers, smoke evidence, known limitations, standalone decision, and rollback instructions in the repositories' release notes.

## Plan Completion Gate

- Canonical names are published only as useful packages and only after separate explicit release approvals.
- Registry owners, MFA, OIDC publishers, tags, commits, and checksums are verified.
- Public clean-install and cross-stack smoke pass.
- No underscore alias or dashboard Ruby gem exists.
- The self-contained executable has a recorded `ADOPTED` or `NOT_ADOPTED` verdict against fixed criteria.
- Source-pack installation remains pinned to repository library bytes and works independently of registry availability.
