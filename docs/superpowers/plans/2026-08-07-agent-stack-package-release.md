# Agent Stack Package Release Implementation Plan

> **Execution note:** Work task-by-task. Host-provided plan-execution or
> subagent capabilities are optional accelerators, not repository dependencies;
> when unavailable, follow the checked steps directly.

**Goal:** Publish legitimate first releases under the canonical Agent Workflows, Agent Coordination, and Dashboard package names, secure their ownership, and decide whether Agent Workflows also ships self-contained Ruby executables.

**Architecture:** Each repository builds and verifies its own native package: `agent-workflows` and `agent-coordination` on RubyGems, `agent-coordination-dashboard` on npm. Registry mutation remains a separately approved release action. A bounded Tebako evaluation consumes the already verified `agent-workflows` gem and may add native release assets without changing the canonical Ruby source or gem.

**Tech Stack:** RubyGems, npm, GitHub Actions OIDC trusted publishing, GitHub Releases, Ruby 3.2/3.4, Node 22.12+ runtime smoke, a pinned Node 24.8.0/npm 11.5.1 publication toolchain, Tebako evaluation, SHA-256 artifact manifests.

## Global Constraints

- Canonical package names are exactly `agent-workflows`, `agent-coordination`, and `agent-coordination-dashboard`.
- Do not publish underscore aliases or a dashboard Ruby gem.
- A pending trusted publisher does not prove registry ownership; a successful legitimate package publication does.
- Do not publish an empty, placeholder, alias-only, or name-squatting package.
- For every previously unclaimed package, a successful first publication is
  immediately followed by authenticated owner grants from the bootstrap owner
  to every approved backup human and organization/team role. Read the registry
  owner list back and require at least two confirmed human owners before the
  release is complete. If any grant or read-back fails, stop with publication
  recorded but release completion blocked; verification alone never substitutes
  for the grant operation.
- Do not publish without explicit release authorization naming the package,
  version, commit, registry, workflow path and ref, workflow-file digest, and
  rollback/disposition.
- The specified stable releases (`agent-coordination` and dashboard `0.1.0`,
  Agent Workflows `0.2.0`) proceed only after the release owner explicitly
  accepts the compatibility commitment. Otherwise stop and write a
  prerelease-version plan; do not silently change the versions below.
- Ruby packages require MFA metadata and GitHub OIDC trusted publishing.
- Package artifacts contain no credentials, local absolute paths, untracked files, test secrets, or private fixtures.
- Every release binds package checksum, Git tag, repository commit, and registry version.
- Both gem releases use Ruby `3.4.6`, RubyGems `3.6.9`, and Bundler `4.0.10`
  in a pinned Linux build environment for the authorization build and release
  rebuild. The workflow verifies all three versions before building; a mismatch
  stops before OIDC credential configuration.
- Both gemspecs set `allowed_push_host` to exactly
  `https://rubygems.org`, packaging tests assert it, and release jobs reject any
  conflicting `RUBYGEMS_HOST`.
- The source-pack installer does not switch to remote gem resolution merely because a gem is published.

### Shared RubyGems release contract

Both Ruby packages use this single release contract. Package tasks below add
only their package-specific inputs and validation; they do not restate or
weaken these controls.

Add two distinct release tasks so Rake's run-once semantics cannot skip the
post-push check. A pre-source-control prerequisite, after the Bundler build,
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

Each first-release workflow is protected `workflow_dispatch` only and requires
exact package, version, release branch, commit, artifact SHA-256, workflow path,
workflow ref, and workflow-file SHA-256 authorization inputs. Dispatch only
from that exact authorized branch ref. Configure the protected `release`
environment with a deployment-branch rule admitting only that branch and
required human review. Before approving the environment deployment, the
reviewer reads the run metadata and independently verifies its workflow path,
`github.workflow_ref`, and `head_sha` against the authorization; a mismatch is
rejected before any job with `id-token: write` can start.

The OIDC-capable release job declares permissions at job scope, uses the
protected `release` environment, and begins by hashing its checked-out workflow
file and comparing that hash with the pre-recorded authorization digest captured
independently from the reviewed workflow before the run. It never derives the
expected digest from its own checkout. Fetch full history, check out the
authorized release branch as an attached local branch rather than the raw SHA,
and verify both `HEAD` and `origin/<authorized-release-branch>` equal the
authorized commit. Branch movement stops the workflow and requires fresh
authorization; never let Bundler run from detached `HEAD`, because its release
task pushes the current branch before the tag. The job uses `id-token: write`,
`contents: write` for Bundler's release-tag push, pinned actions, package tests,
a rebuilt artifact, checksum verification, and `rubygems/release-gem`. It has
no long-lived RubyGems API token or broader repository permission. Test wrong
dispatch ref, run head SHA, workflow path/ref, and workflow-file digest as
release-stopping cases. A later tag-triggered release is a separate design
change unless an immutable authorization manifest supplies the same bindings.

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
- Modify in each repository: package metadata only when a check below reveals a real gap.

**Interfaces:**

- Consumes: RubyGems exact-name API, npm registry exact-name API, repository package metadata, authenticated owner identity.
- Produces: a timestamped release preflight recording availability/ownership without credentials.

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

The release checklist names at least two human owner handles and the ShakaCode organization role. Missing confirmed backup ownership is a release blocker, not a post-release reminder.

- [ ] **Step 4: Configure RubyGems publishers and prepare npm bootstrap**

For each Ruby gem, configure its exact GitHub owner, repository, release
workflow filename, and protected `release` environment. Record that this
enables OIDC but does not claim the name before first push. npm cannot attach a
trusted publisher before a package exists, so prepare and review the dashboard
workflow and environment but do not claim they are configured. Record the
separately authorized, interactive-2FA bootstrap publication required in Task 4.

- [ ] **Step 5: Review the preflight**

Confirm package spelling, registry, repository, workflow, environment, and owners. A reviewer explicitly verifies that no underscore alias or dashboard gem is included.

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
build. The OIDC release job uses the same environment and rejects a rebuilt
artifact unless its SHA-256 equals this authorization artifact.

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

Implement the shared RubyGems release contract above with package
`agent-coordination`, version and tag `0.1.0`/`v0.1.0`, and the exact
`pkg/agent-coordination-0.1.0.gem` artifact. The authorization inputs come from
Step 7.

- [ ] **Step 6: Run repository release gates**

Run the repository's configured validate/test wrappers, packaging test, RuboCop, and Git diff checks. Obtain independent current-head review.

- [ ] **Step 7: Stop for explicit publication authorization**

Present exact package `agent-coordination`, version `0.1.0`, attached release
branch, commit SHA, artifact SHA-256, workflow path/ref and file digest, owners,
and rollback/disposition. No tag or registry mutation occurs before
authorization.

- [ ] **Step 8: Publish and verify only after authorization**

Create/push the signed or protected release tag through the authorized workflow;
the workflow must verify that tag before it permits the gem-push hook. Verify
RubyGems metadata, the checksum of the bytes actually published, owners, MFA
status, and install from RubyGems into a clean gem home. For a first
publication, execute the global post-publication owner-grant contract before
continuing. Then create the GitHub
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

Implement the shared RubyGems release contract above with package
`agent-workflows`, version and tag `0.2.0`/`v0.2.0`, and its exact built gem.
Confirm the foundation `Gemfile` includes Rake and its `Rakefile` still
exposes Bundler's release task under `bundle exec`, then run `bin/validate`, gem
packaging tests, isolated install smoke, and source-pack parity before
`rubygems/release-gem`. Require the foundation workflow's exact-commit
`macos-packaging-smoke` receipt; an older or skipped macOS run does not satisfy
this release gate. Build both authorization and workflow artifacts in the same
pinned Linux environment with Ruby 3.4.6, RubyGems 3.6.9, and Bundler 4.0.10;
verify the exact versions and require byte-identical SHA-256 before configuring
RubyGems credentials.

- [ ] **Step 5: Run current-head release gates and stop for authorization**

Present exact package, version, attached release branch, commit, artifact
checksum, workflow path/ref and file digest, executables, owners, and evidence.
Publication approval for `agent-coordination` does not authorize
`agent-workflows`.

- [ ] **Step 6: Publish and verify only after authorization**

After the workflow reports success, independently query RubyGems, install the
public gem, run each executable, verify tag/release SHA, and confirm the
source-pack installer still uses its own pinned library bytes. For a first
RubyGems publication under this name, execute and read back the global
post-publication owner-grant contract before treating the release as complete.

### Task 4: Prepare and release npm `agent-coordination-dashboard` 0.1.0

**Files in `shakacode/agent-coordination-dashboard`:**

- Modify: `package.json`, `scripts/package.test.ts`.
- Modify if required: remaining package tests and `README.md`.
- Create: `CHANGELOG.md` with `Unreleased` and `0.1.0` entries.
- Modify: `.github/workflows/ci.yml` for the supported Node matrix.
- Create/modify: `.github/workflows/release-npm.yml`.

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

- [ ] **Step 2: Install the tarball into a disposable project**

Run the packaged command's help, foreground smoke on a disposable port/state root, start/status/logs/restart/stop lifecycle, doctor JSON, and clean shutdown. Prove the installed command does not import the source checkout.

- [ ] **Step 3: Prepare npm trusted publishing and bootstrap controls**

Prepare npm provenance/OIDC from a protected GitHub release environment with no
long-lived npm token. Pin actions, exact Node `24.8.0`, and exact npm `11.5.1`
for the future OIDC publication job; assert those versions before requesting an
OIDC token. This deliberately exceeds npm trusted publishing's Node `22.14.0`
and meets its npm `11.5.1` minimum. Bind the future job to the authorized
workflow path, dispatch ref, run head SHA, and workflow-file digest with the
same external environment-approval boundary as Task 2. Run install, test,
typecheck, build, package-content, and tarball smoke before publication. Because
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
Node/npm pair, owners, and smoke evidence. RubyGems approvals do not authorize
npm publication.

- [ ] **Step 5: Bootstrap, secure, and verify only after authorization**

Fetch tags, require `v0.1.0` to be absent or already dereference to the
authorized commit, then create/push and read back the protected tag before npm
publication. A tag at another commit is a terminal collision. Publish the exact
reviewed tarball interactively with 2FA only after the tag is verified. Verify
npm registry metadata, owners, and tarball integrity; install the downloaded
`agent-coordination-dashboard@0.1.0` tarball whose integrity matches the reviewed
artifact, then run its installed `--help` and lifecycle smoke without resolving
an unversioned `latest`. Use the authenticated bootstrap owner to grant every
approved backup npm owner/team role, then read the owner list back under the
global post-publication owner-grant contract. Immediately attach the protected release workflow as
the package's trusted publisher, restrict token-based publishing, and read the
publisher configuration back. The release is incomplete until that attachment
is verified. Record that OIDC provenance starts with the next release because
the bootstrap version was not workflow-published.
Create the GitHub Release explicitly from the already verified tag with tarball
integrity, checksum, and `0.1.0` changelog notes, then read back the tag and
release. If publication fails after the tag is created, do not move or reuse the
tag: reconcile live npm state and record an explicit retry or version-bump
disposition. Do not publish another version merely to test OIDC.

### Task 5: Evaluate self-contained Agent Workflows executables

**Files in `shakacode/agent-workflows`:**

- Create: `packaging/tebako/entrypoint.rb`
- Create: `packaging/tebako/commands.yml`
- Create: `test/packaging/standalone_executable_test.rb`
- Create: `.github/workflows/package-standalone.yml`
- Create: `docs/standalone-installation.md` only if the evaluation passes.

**Interfaces:**

- Consumes: the verified `agent-workflows` gem artifact.
- Produces: an evidence report and optionally platform executables; it does not change gem behavior.

- [ ] **Step 1: Define one multi-command entrypoint**

`entrypoint.rb` selects a canonical CLI from the invoked link name. The
canonical `agent-workflows` artifact instead consumes the command as its first
argument:

```ruby
require "agent_workflows"

command = File.basename($PROGRAM_NAME)
command = ARGV.shift if command == "agent-workflows"
cli = {
  "agent-workflows-doctor" => AgentWorkflows::CLI::WorkflowsDoctor,
  "agent-stack-doctor" => AgentWorkflows::CLI::StackDoctor
}.fetch(command) { abort "unknown agent-workflows command: #{command.inspect}" }
exit cli.start(ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr)
```

Generate small platform command links/wrappers only after the single packaged
entrypoint passes. Contract tests invoke the canonical artifact with an
explicit command and invoke each link directly with `--help`, proving neither
form mistakes the first user argument for the command name.

- [ ] **Step 2: Build a pinned Tebako artifact matrix**

Pin Tebako and Ruby versions. Build fat, no-runtime-dependency executables on macOS arm64/x86_64 and Linux arm64/x86_64 runners. Record build inputs, artifact SHA-256, size, and build logs. Do not claim cross-platform support for a platform without a native smoke result.

- [ ] **Step 3: Run compatibility and portability tests**

For every artifact, run help, JSON doctor, malformed input, filesystem reads
from host paths, timeout/process-group cleanup, temporary-file creation,
non-ASCII locale, relocated executable, read-only executable directory, and
offline execution. In the offline contract suite, block network access and put
deterministic fake `git` and `gh` executables first on `PATH`; assert argv,
environment, channels, exit codes, and absence of network access. Separately run
a real-child-command integration suite with installed `git` and `gh`, bounded
credentials, and explicitly documented network requirements. A fake-command
pass proves wiring, while the real-command pass proves integration.

- [ ] **Step 4: Measure acceptance thresholds**

The standalone path passes only if:

- all CLI contract cases match the gem;
- on each named native runner image and architecture in the evidence report,
  five isolated cold `--help` runs after clearing only the artifact's disposable
  cache have a median at or below 1.5 seconds; record every duration and the
  cache-reset command;
- each compressed download is at most 100 MiB;
- no runtime network access occurs;
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

- [ ] **Step 6: Require separate release authorization for binaries**

Binary release approval names platforms, architectures, checksums, signing state, Ruby/Tebako versions, and rollback. Gem publication approval does not authorize binary artifacts.

- [ ] **Step 7: Publish binaries only after authorization**

Publish only the authorized artifacts as optional GitHub Release downloads,
verify uploaded checksums and signatures against the reviewed matrix, and then
publish `docs/standalone-installation.md` and record the terminal `ADOPTED`
verdict with release URLs. If authorization is denied or stale, retain the
evaluation evidence without public artifacts.

### Task 6: Complete package ownership and post-release audit

**Files:**

- Update release runbooks and changelogs in each repository.
- Create no new alias package.

**Interfaces:**

- Consumes: verified registry releases.
- Produces: durable ownership, provenance, install, and rollback evidence.

- [ ] **Step 1: Confirm owners and trusted publishers**

Verify at least two confirmed human owners, intended organization roles, MFA requirements, protected release environments, and exact repository/workflow bindings on each registry.

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
