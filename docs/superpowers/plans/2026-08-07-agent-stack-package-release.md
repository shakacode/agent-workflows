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
  Bundler `4.0.10` is an existing RubyGems.org release (published 2026-04-08),
  requires Ruby `>= 3.2.0` and RubyGems `>= 3.4.1`, and is therefore compatible
  with these pins. Bundler and RubyGems do not need matching major versions;
  the authoritative compatibility field is Bundler's
  `required_rubygems_version`. Preserve the independent metadata check against
  `https://rubygems.org/gems/bundler/versions/4.0.10` in the release receipt.
  The implementation preflight still resolves this exact
  version from RubyGems.org before building so a typo or unavailable artifact
  fails before authorization.
- Both gemspecs set `allowed_push_host` to exactly
  `https://rubygems.org`, packaging tests assert it, and release jobs reject any
  conflicting `RUBYGEMS_HOST`.
- The source-pack installer does not switch to remote gem resolution merely because a gem is published.

### Shared package-release authorization handoff

The canonical contract ID for this section is
`AW-RELEASE-AUTHORIZATION-HANDOFF-V1`. It applies to both RubyGems releases and
the npm bootstrap/release path. Approval names immutable state that already
exists; the authorization JSON is then produced after approval and therefore is
never expected to exist in the approved commit.

Each repository adds
`.github/workflows/capture-package-release-authorization.yml`, a read-only
`workflow_dispatch` capture with closed job-level `contents: read`,
`actions: read`, `issues: read`, and `pull-requests: read`, no release environment,
persisted checkout credential, OIDC permission, registry credential, or
repository write permission. It runs at the exact approved commit and accepts
the canonical durable GitHub approval URL plus package,
version, registry, tag, commit, artifact digest, workflow path/ref/file digest,
grant-manifest path/digest, expiry, and rollback disposition. For RubyGems only,
it also requires the publisher action full commit and provenance producer
run/artifact ID/service digest/file SHA-256, the exact human grant operator's
GitHub login and RubyGems handle, the exact human observer's GitHub login and
RubyGems handle, and the grant-preparation, observation-PR, and post-grant
capture workflow paths/refs/file digests. It also binds the independently
reviewed `shakacode/agent-release-mutator` full commit, provenance receipt
producer run/artifact ID/service digest/file SHA-256, and action/source/
distribution/`open-closeout-pr` mode/result-schema digests. The observer must differ from the
operator/attestor, release approver, and observation PR's exact-head reviewer;
the schema forbids those
RubyGems-only fields for npm. A reviewed writer
creates canonical JSON in `RUNNER_TEMP`, binds the capture run ID and immutable
capture-workflow path/ref/file digest, and validates it against the repository's
fixed package-release-authorization schema.

A renewed RubyGems recovery authorization that permits orphan acceptance also
binds the exact `orphan_acceptance_principal` GitHub login and recovery reason.
That principal must differ from the original operator, observer, and observation
PR's exact-head reviewer. Ordinary authorizations and late attestations by the
already-bound original operator omit this field; an orphan-acceptance object by
any other author is rejected.

The capture does not accept a free-form approver identity or approval body. The
only accepted object types are a pull-request review or an issue comment on that
pull request. A read-only verifier parses the URL as an exact object ID in the
expected GitHub repository, fetches that object through the API, derives its author and
creation/update timestamps, and validates its canonical approval payload against
every applicable registry-specific release field above. It rejects edited, deleted, cross-repository,
non-human, unlisted, ambiguous, or payload-mismatched approvals. The
derived login must appear in the exact-commit
`release/approvers/package-release.v1.json` allowlist. That file is schema-
validated, protected by CODEOWNERS and branch rules requiring two-person review,
and its canonical SHA-256 is bound into the authorization. The verifier never
attempts organization-team discovery with `GITHUB_TOKEN`. The
authorization binds the durable object/node ID, derived approver login, creation
and update timestamps, canonical body SHA-256, and the distinct capture dispatch
actor from `github.triggering_actor`. Publication re-fetches the object and
requires the same ID, actor, timestamps, and body digest so later edit/deletion
or revocation stops the release. Tests cover forged URLs, actor substitution,
dispatcher/approver confusion, edited or deleted approvals, and every target-
payload mismatch, unavailable object-read authority, a missing or altered
approver allowlist, and static permission expansion or omission.

For npm only, the approval presentation and capture also require the exact
GitHub login `npm_closeout_reviewer_login`. The schema requires that field when
`registry` is `npm`, forbids it for RubyGems, and validates canonical GitHub
login syntax. The writer copies it only from the approved capture input into the
immutable authorization bytes; the verifier rejects a missing, extra, malformed,
or changed value. Observation-closeout verification later requires the live
approving review to match that login and requires the observation actor to be a
different identity. Tests cover missing npm reviewer, reviewer substitution,
self-review, and an npm-only field smuggled into a RubyGems authorization.

The capture uploads exactly that JSON under a package/version/run-specific
artifact name. A separate read-only verification job queries the complete
artifact inventory for the exact capture run, requires one expected artifact,
records its artifact ID and service-reported digest, downloads it into a fresh
directory, and revalidates the file SHA-256, schema, approval source, capture
workflow, and target bindings. The only publication handoff is the tuple of
capture producer run ID, artifact ID, service digest, and authorization-file
SHA-256. A checkout-relative authorization file, artifact-name lookup, workflow
output containing JSON, branch commit made after approval, or latest-run lookup
is forbidden.

Every release or human-bootstrap preparation receives those four selectors,
proves through the GitHub API that the producer run succeeded at the approved
commit under the bound capture workflow, downloads the artifact by exact ID and
service digest, and validates the authorization only from that fresh directory.
The unprivileged release job binds the verified authorization file digest and
capture selectors into its same-run build receipt.

Before either RubyGems release task can proceed, independently build and review
`shakacode/agent-release-publisher`. Its root `action.yml` loads only a checked-in
`dist/index.js` reproduced from `src/index.ts`. Version 1 has one closed
`publish-rubygems` mode: it accepts only the exact authorization, build receipt,
reviewed gem path/digest, and expected fixed package/repository/tag/commit. It
fetches the fixed `release/approvers/package-release.v1.json` path at the exact
authorized commit through the GitHub Contents API and requires its canonical
bytes to match the authorization-bound digest; no checkout-relative allowlist is
accepted. It reads the runner clock itself in canonical UTC,
performs the approval-object API read, schema/digest/remote-tag comparisons and
expiry decision, creates the tag through the fixed Git refs API, reads it back,
performs the OIDC upload of only the reviewed gem, and reads registry metadata
back. It has no caller-supplied time, command, script, URL, route, ref, arbitrary
request body, or arbitrary-payload input. Protected main, CODEOWNERS, two-person review, and tests
that reproduce `dist/index.js` are mandatory. An unprivileged provenance job
downloads that repository at the reviewed full commit and emits a canonical
artifact receipt binding repository, commit, independent review URL,
`action.yml`/source/distribution digests, mode/schema digests, and test result.
The package authorization and environment review bind that receipt's producer
run, artifact ID, service digest, file SHA-256, and the full action commit.

The minimal protected job uses full immutable commit-SHA-pinned generic
artifact/digest actions, never checkout, repository code, or inline scripts, to
compare the build receipt, authorization, and publisher-provenance receipt
before mutation.
It then invokes only
`shakacode/agent-release-publisher@<authorization-bound-full-commit>` in the
closed mode as its only domain action. Immediately after protected-environment
approval and immediately before requesting OIDC or creating a tag, that action
re-fetches the bound approval object and compares canonical UTC with
`expires_at`; expiry equality or a past value fails closed. Its only success
result is a canonical provisional publication-operation receipt with state
`PUBLISHED_GRANTS_PENDING`; it is not the release receipt and cannot claim a
grant result that has not happened. It binds the authorization/capture
selectors and digest, build-receipt identity/digest, publisher-provenance
producer run/artifact ID/service digest/file SHA-256 and action/source/
distribution/mode/schema digests, gem digest, `authorization_checked_at`,
approval-object/allowlist digests and expiry, tag create/read-back identity,
OIDC upload result, exact RubyGems name/version/artifact digest and registry
read-back, protected run/job/action identity, and a closed outcome. A full-SHA
generic artifact step uploads those exact result bytes, queries their artifact
ID/service digest, downloads them into a fresh directory, and verifies their
file SHA-256 before the protected job succeeds. Tests pause
past expiry in the environment-approval queue and race approval edit/deletion
between the unprivileged and protected jobs, and reject publisher receipt,
commit, action, source, distribution, or schema substitution. For the
interactive npm bootstrap, the human
performs the same exact-selector download and validation before login. Tests
cover missing, expired, cross-run, name-selected, substituted, wrong-head,
wrong-workflow, digest-mismatched, and checkout-relative authorizations. Static
workflow tests reject action references pinned by tag, branch, or floating major
version in every privileged job.

Any protected job that performs this re-fetch declares only the object-type
permissions needed by the shared verifier—`issues: read` and
`pull-requests: read`—in addition to its separately enumerated release
permissions. Static workflow tests reject missing object-read permissions and
any broader issue or pull-request permission.

For a first RubyGems publication, `AW-RELEASE-GRANTS-V1` starts only after that
provisional receipt is uploaded and verified by exact producer run, artifact
ID, service digest, and file SHA-256. Version 1 deliberately uses an attended
RubyGems administration ceremony rather than assuming an unconfirmed API can
issue short-lived, owner-only credentials. No grant credential, browser
session, or registry mutation runs in CI.

Before preparation, the authorization-bound independent observer authenticates
directly to RubyGems and posts a canonical durable pre-ceremony observation
object. Its fixed schema contains the complete owner/MFA, organization/team
access, version/yank, and artifact-digest state plus the exact UI controls,
values, observation time, and authentication method. The object contains no
credential or browser-session material. Screenshots alone, caller-supplied
owner lists, an observer other than the authorization-bound principal, or an
observation outside the fixed freshness window fail closed.

The authorization-bound `prepare-rubygems-grant-ceremony.yml` workflow has only
`contents: read`, `actions: read`, `issues: read`, and `pull-requests: read`.
It receives the pre-observation object URL plus the authorization-capture and
provisional-receipt exact selectors, freshly downloads and schema-validates the
artifacts, verifies the grant manifest bytes, and fetches the observation
object through the GitHub API. It derives and verifies the exact observer,
creation/update timestamps, immutable body digest, schema, completeness, and
freshness; it never invents or accepts registry state from workflow inputs. It
then re-fetches the canonical approval object and exact-commit approver
allowlist and compares its own canonical UTC clock with `expires_at`
immediately before writing a short-lived preparation receipt. Edited/deleted
approval or observation, changed allowlist, stale observation, expiry
equality/past, or any selector/digest mismatch fails before the human acts. The
receipt binds the authorization, provisional publication, manifest, exact
package/version, named grant operator, the byte-identical fetched canonical
pre-observation bytes, derived author/object type/object ID, creation/update
timestamps, schema path/version/digest, body digest, verification time,
freshness result, complete registry state, issued-at, and a tighter ceremony expiry.
Full-SHA-pinned generic actions upload it and capture its exact producer run,
artifact ID, service digest, and file SHA-256.

While that preparation receipt and authorization remain valid, the named human
operator downloads and verifies them, authenticates directly to RubyGems with
MFA, rechecks canonical UTC immediately before the first registry mutation, and
applies only the supported manifest rows in the registry UI. Each preparation
receipt authorizes exactly one attended attempt; any second or later attempt
must rerun preparation and its approval/allowlist/expiry checks even when the
outer authorization has not yet expired. The plan
does not pretend the human recovery principal is technically unable to perform
other owner operations; instead it records the attended boundary, forbids gem
upload/yank/version changes during the ceremony, and requires an independent
observer. No credential value or authenticated browser artifact is copied into
the repository, GitHub, logs, or receipts.

Immediately after the attempt, the operator posts a canonical durable GitHub
attestation naming the preparation-receipt selectors and manifest rows
attempted. Its derived creation timestamp must be no later than the ceremony
expiry. The separately authorized observer then authenticates directly to
RubyGems, freshly captures the complete owner/MFA, organization/team access,
version/yank, and artifact-digest state, and posts a canonical durable GitHub
observation object containing the exact UI controls, values, observation time,
and authentication method. Caller-authored owner lists, screenshots alone, and an
observer equal to the operator/attestor, release approver, or PR reviewer are
never accepted. This post-ceremony object must have a distinct object ID and
body digest. Its GitHub-derived creation time and claimed observation time must
both be strictly after preparation issuance and the applicable operation-
evidence object: the ordinary operator attestation, recovery late attestation,
or authorized orphan acceptance. Its
creation time must be no earlier than its claimed observation time.

The observation PR opener receives only the attestation or authorized
orphan-acceptance URL, observation-object URL, and exact
authorization/provisional/preparation/prior-chain selectors; it has
`contents: read`, `actions: read`, `issues: read`, and `pull-requests: read` in
its evidence-verification job, derives both objects' authors and immutable body
digests through the GitHub API, rejects any post object created before
preparation or the applicable operation-evidence object or carrying a backdated
claimed observation, and
renders the verified observation bytes plus derived creation/update metadata at
the one fixed-schema path. Only a separate closed job with `actions: read`,
`contents: write`, and `pull-requests: write` may download that exact verified
payload and open the observation-only PR. That write job has no checkout,
persisted credential, shell, inline code, or repository execution. It verifies
the authorization-bound mutator provenance receipt by exact selectors and may
invoke only
`shakacode/agent-release-mutator@<authorization-bound-full-commit>` in its
closed `open-closeout-pr` mode. The fixed manifest binds the exact repository,
base commit, deterministic branch, sole observation path, payload SHA-256, and
PR title; none is caller-selectable outside the schema. The action's canonical
result binds the PR number/URL, base/head refs and SHAs, committed path/blob
digest, operation identity, and every provenance selector/digest. A separate
full-SHA-pinned generic upload records it under the one fixed expected artifact
name derived from package, version, and attempt. The opener lists the run's
artifact inventory, requires exactly one artifact with that name, and records
its exact opener run ID, numeric artifact ID, service digest, and file SHA-256.
A separate read-only job with a complete permission block of exactly
`actions: read`, `contents: read`, and `pull-requests: read` downloads only those
four exact selectors, verifies the single-artifact inventory, file digest, and
schema, and reads the branch and PR back through GitHub before the PR can be
trusted. It has no write, OIDC, environment, release, package, checkout
credential, or registry credential. Tests
reject checkout or executable code in the write job, mutable/substituted action
or provenance, changed base/branch/path/payload, extra files, cross-run,
name-selected, duplicate/missing artifact, selector/digest substitution, an
omitted or expanded verifier permission block, and missing or mismatched
operation-result read-back. The PR
verifier runs untrusted-head-safe from the trusted base, executes no candidate
code, permits only the one schema-bound observation file, requires the
authorization-bound observer and a distinct allowlisted exact-head reviewer,
and invalidates approval after any head change. After merge, the trusted-base
observation finalizer reads only the exact merge commit, verifies that the
merged final head equals the approved review `commit_id`, renders the fixed
handoff schema, computes its file SHA-256, and uses a full-SHA-pinned generic
upload under the one fixed expected artifact name derived from the attempt ID.
A separate selector job lists that finalizer run's artifact inventory through
the GitHub API and verifies that the producer belongs to the expected
repository, used the authorization-bound finalizer workflow path, trusted-base
ref, and workflow-file digest, was triggered by the expected merged-PR event,
and binds the exact approved head and merge SHA. It does not claim that its
containing run is terminal. It then requires exactly one artifact with the
expected name, downloads only its numeric artifact ID, verifies the service
digest and file SHA-256 by fresh read-back, and emits the exact producer run,
numeric artifact ID, service digest, and file SHA-256 as the only cross-workflow
handoff tuple. The later capture workflow alone independently requires that
producer run to have reached a successful terminal state. Both verifier
and finalizer declare complete job-level permission blocks containing exactly
`contents: read` and `pull-requests: read`; the separate selector job declares
exactly `actions: read` and `contents: read`. Neither has OIDC, release, package,
environment, registry-mutation, or reusable registry-credential permission.
Static tests reject an omitted permission block, any missing/expanded scope,
unnecessary `actions: read`, a mutable upload/download action, a changed
expected artifact name, missing or duplicate artifacts, name-selected download,
cross-run selection, wrong repository/workflow/event/ref/head/merge SHA or
selector, service-digest, or file-digest substitution. Capture tests separately
reject a cancelled, failed, skipped, timed-out, or still-running producer.

`capture-rubygems-post-grant.yml` has only `contents: read`, `actions: read`,
`issues: read`, and `pull-requests: read`. It accepts the attestation or orphan-
acceptance object URL, merged observation PR identity, the merged-observation
handoff's exact producer run, numeric artifact ID, service digest, and file
SHA-256, and exact authorization, provisional, preparation, and prior-chain
selectors. It derives the one expected handoff artifact name from the verified
attempt ID and independently queries the producer run. It requires the expected
repository, authorization-bound finalizer workflow path/ref/file digest, merged-
PR trigger, exact approved head and merge SHA, and successful terminal state;
then it lists that run's complete artifact inventory, requires exactly one
artifact with the expected name and numeric ID, downloads only that ID, and
verifies the service digest, file SHA-256, repository-owned schema path/version/
digest, and byte-identical read-back before using the handoff. It derives object
author/timestamps through the GitHub API, re-fetches the post-observation object,
and requires its update timestamp and body digest to equal the values bound into
the merged observation PR. Edited or deleted evidence fails closed.
It requires the authorized
operator on the ordinary path and the independently authorized observer on both
paths, re-fetches
the unchanged approval object and exact-commit allowlist, rechecks the outer
authorization expiry against canonical UTC immediately before capture, verifies
that the operator attested within the preparation window, and never trusts an
attested result as registry evidence. For a recovery path, it instead verifies
the renewed authorization and either the original operator's explicitly late
attestation or the separate maintainer's orphan acceptance, including author,
exact delta, lateness or missing-operator reason, and recovery disposition. It
requires an orphan acceptance author to equal the renewed authorization's exact
`orphan_acceptance_principal` and to differ from the operator, observer, and
observation PR reviewer; any other author fails closed. It
compares the preparation-bound authenticated pre-observation with the distinct
merged post-observation, verifies both the GitHub-derived creation time and
claimed observation time are strictly after preparation issuance and the
applicable ordinary attestation, late attestation, or orphan acceptance, and
rejects any new, removed, or changed
principal/role/access row not exactly
authorized by the manifest, plus any gem upload, yank, version, or artifact-
digest change during the ceremony. Only the exact expected manifest delta and
unchanged package bytes may proceed.

The reviewed post-grant writer emits an append-only receipt that binds its fixed
schema, attempt identity, authorization/provisional/preparation selectors and
digests, attestation or orphan-acceptance object identity/body digest, the full
pre-observation verification metadata, post-observation author/object ID/
creation/update timestamps/schema/body digest, every manifest row, observed
pre/post state, and resulting state. It
distinguishes a registry-provided operation result from a human-attested
operation; it never invents a machine operation ID. Expired, edited, deleted,
missing, failed, or ambiguous evidence yields
`PUBLISHED_GRANTS_RECONCILIATION_REQUIRED`; only complete fresh observations may
claim `PUBLISHED_CLOSEOUT_PENDING`.

Recovery enumerates the exact preparation receipts, attestations, observation
PRs, post-grant receipts, and current live registry state for the authorized
package/version. If a human operation succeeded but the runner or operator
stopped before attesting, recovery remains fail closed until either the original
operator posts a late attestation bound to the exact preparation and observed
rows, or a renewed authorization carries a separate maintainer's explicit
orphan-acceptance object naming the unexplained live delta and why operator
attestation is unavailable. Recovery never synthesizes either object. After
that evidence exists, a renewed authorization may create a ledger-derived
recovery attempt that imports the orphaned preparation, late attestation or
orphan acceptance, and any earlier discovery observation only as non-terminal
forensic evidence. The authorized observer then re-observes live state and
posts a new post-observation object bound to and created after the late
attestation or orphan acceptance. The closed opener creates the observation-
only PR, but a distinct exact-head reviewer approval and the repository's human
merge gate remain mandatory; only the trusted-base finalizer after that merge
may upload the fixed-name durable merged-observation handoff and its separate
selector job may emit the verified four-selector tuple. Then `capture-rubygems-
post-grant.yml` accepts that exact tuple, rejects a tuple from another run or a
name-selected artifact, downloads and verifies the handoff and complete prior
chain, and writes the append-only successor receipt. An earlier
ordinary or orphan-discovery observation cannot be reused. It never starts a
replacement genesis or repeats a
grant already present. Every
successor binds the prior receipt's exact producer run, artifact ID, service
digest, file SHA-256, and receipt digest and preserves prior evidence
byte-for-byte. Recovery never republishes the gem.

Full-SHA-pinned generic actions upload each post-grant receipt, query its exact
artifact ID/service digest, download it fresh, and verify its file SHA-256. A
separate unprivileged verifier with only `contents: read` and `actions: read`
downloads the complete preparation/attestation/observation/post-grant chain by
exact selectors, schema-validates and replays it, and exposes only the verified
chain tip's four selectors to closeout. Tests cover approval edit/deletion or
expiry before preparation and immediately before observation, operator/attestor
or observer substitution, missing/stale/edited/caller-supplied pre-observation,
pre/post object reuse, a post object created before preparation or its
applicable operation-evidence object,
edited post bytes/update metadata, a backdated claimed observation, reuse of a
pre-recovery post observation, and both late-attestation and orphan-acceptance
ordering,
missing or duplicate fixed-name merged-observation handoffs, name-selected or
cross-run handoff retrieval, and producer-run, numeric-artifact-ID, service-
digest, file-SHA-256, repository, finalizer-workflow path/ref/file-digest,
trigger event, approved-head/merge-SHA, terminal-state, or schema substitution,
unauthorized registry deltas, late-
attestation and explicit-orphan-acceptance recovery after every stop point,
omitted/extra manifest
rows, stale or caller-supplied observations, skipped/rewritten predecessors,
tip-only retention, and premature completion.

The captured JSON's canonical eventual repository path remains
`release/authorizations/<package>-<version>.v1.json`, but a later reviewed
release-evidence PR may commit only the byte-identical captured file. Neither
publication nor bootstrap trusts that later checkout copy.

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
earlier run. The privileged publisher action still fetches and checks the remote
tag immediately before and after its one fixed Git-refs creation because workflow serialization
does not replace registry read-back.

Each first-release workflow is protected `workflow_dispatch` only and requires
the exact authorization-capture producer run, artifact ID, service digest, and
file SHA-256 from `AW-RELEASE-AUTHORIZATION-HANDOFF-V1`. The freshly verified
authorization supplies the exact package, version, release branch, commit,
artifact SHA-256, workflow path/ref/file SHA-256, and grant-manifest
path/SHA-256. Dispatch only from that exact authorized branch ref. Configure the
protected `release`
environment with a deployment-branch rule admitting only that branch and
required human review. Before approving the environment deployment, the
reviewer reads the run metadata and independently verifies its workflow path,
`github.workflow_ref`, and `head_sha` against the authorization; a mismatch is
rejected before any job with `id-token: write` can start.

Split verification from publication. The first job has only `contents: read`
and `actions: read`, checks out with persisted credentials disabled, and has no
environment, `id-token: write`, or `contents: write`. It freshly retrieves and
verifies the authorization by exact capture selectors, then verifies the full attached-
branch state, workflow path/ref/digest, toolchain, tests, package contents, tag
preconditions, and reproducible build. It uploads the exact gem plus a machine-
readable receipt binding package, version, commit, workflow digest, artifact
SHA-256, toolchain versions, authorization-file digest, and all capture
selectors. All Bundler, Rake, gemspec, dependency, repository-script, and
package-hook execution ends in this unprivileged job.

Only the second, minimal job uses the protected `release` environment and
job-scoped `id-token: write`, `contents: write`, `actions: read`, `issues: read`,
and `pull-requests: read`. It
downloads the artifact and receipt from the same workflow run through
full immutable commit-SHA-pinned actions, compares both to
the freshly retrieved exact authorization artifact through the shared handoff
without checkout or repository code, uses the authorization-bound external
publisher to freshly
revalidate the approval object and authorization expiry against canonical UTC
after environment approval, verify the bound workflow digest from authorization
and GitHub API bytes, create/read back the exact tag through the fixed Git refs
API, and perform/read back the OIDC registry upload. The workflow has no shell
tag push or upload step. It does not
run Bundler, Rake, tests, gemspec evaluation, dependency installation, build
hooks, or a rebuild. Configure OIDC only after every receipt,
checksum, branch, workflow, and tag check passes. Test wrong dispatch ref, run
head SHA, workflow path/ref, workflow-file digest, cross-run artifact, receipt,
checksum, and concurrent-run/tag collision as release-stopping cases. A later
tag-triggered release is a separate design change unless an immutable
authorization manifest supplies the same bindings.

### Shared RubyGems durable closeout contract

The canonical contract ID is `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`. A successful
publication job leaves the release in `PUBLISHED_GRANTS_PENDING`; its
retention-limited provisional operation artifact is necessary evidence, but
never a release or terminal receipt. Successful `AW-RELEASE-GRANTS-V1` capture
produces the separate canonical post-grant release receipt and moves the
release to `PUBLISHED_CLOSEOUT_PENDING`. For each Ruby gem, an unprivileged
closeout job with only
`contents: read` and `actions: read` freshly downloads the provisional
operation artifact by exact
producer run and artifact ID, verifies its service digest and file SHA-256,
then follows the verified chain tip's exact four selectors and recursively
downloads and verifies every predecessor by its bound selectors/digest before
freshly downloading the published gem by exact name/version.
It records the original provisional publication-operation receipt, the
complete post-grant receipt chain, authorization-capture selectors and digest,
the byte-identical preparation receipts, operator attestations or authorized
orphan-acceptance records, byte-identical canonical pre-observation objects plus
their derived author/type/ID/timestamps/schema/body-digest/verification/freshness
metadata, and merged post-observation-PR evidence for every attempt,
the freshly downloaded byte-identical authorization JSON itself, published-gem
SHA-256, RubyGems metadata and provenance, tag and GitHub Release commit,
grant-manifest results, owner/MFA read-back, toolchain, and clean-install smoke
in a canonical manifest.

The candidate bundle is uploaded by exact ID, then a separate reviewed closeout
PR commits only allowlisted data beneath
`release/evidence/rubygems/<package>/<version>/`; it contains the byte-identical
provisional publication-operation receipt, byte-identical post-grant release
receipt chain, byte-identical authorization JSON, canonical manifest, and
detached verification record. Its schema binds the authorization file SHA-256
to the capture selectors, provisional receipt, and complete post-grant chain,
and binds the genesis and every successor to the exact provisional and
predecessor selector/digest tuples plus the authorization-bound preparation
workflow identity, attestation object identity/body digest, and authenticated
pre-observation bytes and complete derived verification metadata plus merged
post-observation-PR identity and derived stable object metadata. An orphan-recovery
successor binds the authorized orphan-acceptance identity/body digest in place
of a missing operator attestation. The candidate
contains a canonical chain index and the byte-identical genesis receipt, every
successor receipt, and every attempt's schema-valid preparation, attestation,
pre-observation bytes and derived verification metadata, post-observation, and
post-grant receipt bytes—not only the tip, selector references,
or copied-forward fields—so the PR workflow and trusted-base closeout finalizer
can replay the entire human-grant evidence chain from merged bytes after Actions
artifacts expire. The PR workflow executes
no candidate code, rejects executable or workflow changes, re-downloads the
authorization capture, candidate bundle, and public gem, and checks every
digest and live identity. After merge, a trusted-base finalizer freshly reads the exact
merged commit and public registry state. Only that finalizer may report
`RELEASE_COMPLETE`. An expired Actions artifact, GitHub Release note summary,
or unmerged evidence branch cannot substitute for the merged bytes. Tests cover
artifact substitution, wrong producer run/artifact/service/file digest, changed
or missing authorization bytes, public bytes or metadata, wrong tag/commit,
missing grants, extra files, stale live observations, unmerged evidence, and
premature terminal reporting. They also reject a missing, reordered,
digest-mismatched, or tip-only predecessor set and any chain that requires an
expired Actions artifact to replay.

Within that evidence directory, name the authorization archival copy
`captured-authorization.v1.json`. It is not the canonical eventual checkout path
`release/authorizations/<package>-<version>.v1.json` defined by
`AW-RELEASE-AUTHORIZATION-HANDOFF-V1`, does not authorize publication, and is
never accepted as a checkout input. If the canonical path is committed later,
it must be byte-identical to this verified archival copy and the service
artifact. Closeout verification freshly retrieves the service artifact and
compares all three identities when the canonical path exists.

### npm bootstrap durable closeout contract

The canonical contract ID is `AW-RELEASE-NPM-BOOTSTRAP-CLOSEOUT-V1`. A
successful interactive `0.1.0` bootstrap remains
`PUBLISHED_CLOSEOUT_PENDING`; the maintainer checkout is never the terminal
evidence store. After the unconditional credential cleanup and absence-of-local-
credential read-back pass, use only non-secret evidence to create a candidate
bundle containing the byte-identical postpublish receipt, verified captured-
authorization archival copy, grant-manifest digest/results, reviewed tarball
SHA-256 and npm integrity, trusted-publisher identity, publishing-access
observation reference/digest, cleanup result, and canonical manifest.
The manifest also binds the closed GitHub Release read-back record: numeric
release ID, exact tag, target commit, observation timestamp, tarball/checksum
attachment digests, and release-metadata digest.
Within the committed bundle, the byte-identical receipt's canonical relative
name is `postpublish-receipt.v1.json`; no checkout-level `release/receipts/*`
copy is required after the maintainer checkout is discarded.

A separate evidence-only PR commits that bundle beneath
`release/evidence/npm/agent-coordination-dashboard/0.1.0/`. Its workflow rejects
code, package, or workflow changes; schema-validates every file; freshly
downloads the public exact-version tarball; and compares public metadata,
integrity, owners, provenance disposition, authorization, grants, and evidence
digests without using a reusable publish credential. It also queries the exact
GitHub Release ID and rejects a tag, target commit, attachment digest, or
metadata-digest mismatch.

The first evidence PR merge does not itself make the release terminal. After
that merge, a maintainer performs the checked-in fresh-login authenticated
read-back again and opens a second, observation-only PR containing exactly
`release/evidence/agent-coordination-dashboard-0.1.0-publishing-access-closeout.v1.json`.
That non-secret record binds the package/version, required setting, observing
actor's GitHub login and npm owner handle, observation timestamp, exact control
label/value, `fresh_login_interactive_2fa` authentication-method identifier,
and the exact first evidence-PR merge commit and manifest digest. The JSON is
the complete durable reviewed attestation; it does not refer to a local or
external evidence object. Its base must contain that exact merge commit. The
PR workflow runs the reviewed observation verifier and rejects every other
changed path, unknown or secret-shaped field, stale timestamp, wrong actor,
wrong authentication method/control/value, manifest mismatch, or
missing/non-ancestor first merge. A distinct approving reviewer named by the
release authorization confirms the runbook ceremony and observed value; the
PR workflow requires that approval's `commit_id` to equal the observation PR's
exact final head SHA. Any commit after approval invalidates the review even when
repository settings would otherwise retain it. The finalizer queries GitHub's
exact merged PR and requires its recorded final head SHA to equal the approved
review `commit_id`, then binds the PR number, final head, review ID, reviewer,
and submission timestamp. This merged file plus its exact-head-bound review is the only
handoff for the post-merge observation; workflow inputs, comments, local paths,
screenshots, and retention-limited artifacts are not accepted.

Both the observation PR verification job and trusted-base finalizer declare a
closed job-level permission block containing only `contents: read` and
`pull-requests: read`. Add `actions: read` only to a separate job that actually
downloads an exact artifact; neither of these two jobs does so. They have no
write permission, `id-token: write`, release environment, registry credential,
or persisted checkout credential. Static workflow tests assert the exact
permission blocks and reject inherited/broader permissions, OIDC, write scopes,
registry credentials, or an unnecessary `actions: read` grant.

After the observation-only PR merges, a trusted-base finalizer checks out its
exact merge commit with no caller-supplied evidence, reads the observation only
from that canonical path, revalidates its schema, freshness, observer/reviewer
identities, authenticated-read-back method, and first-merge binding, freshly
revalidates the same GitHub Release identity,
downloads the public tarball again, and replays the verifier. Its result binds
both merge commits and the exact observation-file SHA-256. Only it may report
`RELEASE_COMPLETE`. Tests cover lost or local-only receipts, wrong authorization
or tarball, missing/mutable/stale setting observations, missing, self-approved,
stale, or wrong-head review, a commit after approval, wrong
observer/reviewer/authentication method/control/value, failed
cleanup, wrong or changed GitHub Release identity, extra files, either unmerged PR,
caller-supplied observation bytes, and premature terminal reporting.

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
  a capture artifact whose sole file has canonical eventual path
  `release/authorizations/<package>-<version>.v1.json`, containing the approved
  package, version, commit, tag, artifact digest, workflow binding,
  grant-manifest digest, derived actor, canonical approval-object identity,
  timestamp, expiry, capture identity, and rollback/remediation disposition; a
  RubyGems authorization additionally binds publisher action/provenance
  selectors, while an npm authorization forbids them.
- Create in each repository:
  `.github/workflows/capture-package-release-authorization.yml`, the reviewed
  authorization writer and tests, and a fixed v1 authorization schema.
- Create in each repository:
  `release/approvers/package-release.v1.json` and its fixed schema; protect both
  with CODEOWNERS and branch rules requiring two-person review.
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
- Create: `.github/workflows/rubygems-release-closeout.yml`.
- Create: `.github/workflows/prepare-rubygems-grant-ceremony.yml` and
  `.github/workflows/open-rubygems-grant-observation-pr.yml`,
  `.github/workflows/verify-rubygems-grant-observation-pr.yml`,
  `.github/workflows/finalize-rubygems-grant-observation.yml`, and
  `.github/workflows/capture-rubygems-post-grant.yml`, bound to the authorized
  operator and independent observer, exact approval and allowlist objects, and workflow
  path/ref/file digests.
- Create: `release/schemas/rubygems-publication-operation-v1.schema.json`,
  `release/schemas/rubygems-grant-preparation-v1.schema.json`,
  `release/schemas/rubygems-grant-attestation-v1.schema.json`,
  `release/schemas/rubygems-grant-orphan-acceptance-v1.schema.json`,
  `release/schemas/rubygems-grant-pre-observation-v1.schema.json`,
  `release/schemas/rubygems-grant-observation-v1.schema.json`,
  `release/schemas/rubygems-merged-observation-handoff-v1.schema.json`,
  `release/schemas/rubygems-post-grant-receipt-v1.schema.json`,
  `release/schemas/rubygems-grant-chain-index-v1.schema.json`, and
  `release/schemas/rubygems-release-closeout-v1.schema.json`, with reviewed
  writer/verifier, approval-revalidation, orphan-recovery, and retained-chain
  replay tests for
  `AW-RELEASE-GRANTS-V1` and
  `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`.
- Create after publication through the reviewed closeout PR:
  `release/evidence/rubygems/agent-coordination/0.1.0/*`.
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
authorization. After durable approval, run
`AW-RELEASE-AUTHORIZATION-HANDOFF-V1` at the approved commit and record the
verified capture producer run, artifact ID, service digest, and authorization-
file SHA-256. A branch commit containing the new authorization is neither
required nor accepted as the publication handoff.

- [ ] **Step 8: Publish and verify only after authorization**

Dispatch with the four exact authorization-capture selectors. Create/push the
signed or protected release tag through the authorized workflow;
the workflow must verify that tag before it permits the gem-push hook. Verify
RubyGems metadata, the checksum of the bytes actually published, owners, MFA
status, and install from RubyGems into a clean gem home. For a first
publication, execute `AW-RELEASE-GRANTS-V1`, record
every manifest row's result in the separate canonical post-grant release
receipt, and verify that it binds both the authorized manifest digest and the
exact provisional publication-operation receipt before continuing. Then create the GitHub
Release explicitly from the verified tag and commit, attach the checksum
manifest and versioned changelog notes, and read it back. A failed or ambiguous
push or release creation is investigated through live registry and GitHub state
before retrying. Run `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`; the release remains
`PUBLISHED_CLOSEOUT_PENDING` until its exact evidence PR is merged and the
trusted-base finalizer reports `RELEASE_COMPLETE`.

The release authorization also names one exact human GitHub login as
`ruby_floor_follow_up_owner`. Before the finalizer may report completion, create
and assign a durable `shakacode/agent-coordination` issue titled "Decide the
post-0.1.0 Ruby compatibility floor" to that login. The issue records the
current `>= 3.2` contract, Ruby 3.2 end-of-life risk, the next breaking `0.x`
release as the decision boundary, the supported-downstream-matrix trigger, and
the earlier security/dependency trigger. Bind the issue URL, assignee, and live
assignment read-back in the RubyGems closeout manifest; a role-only owner or
unassigned note does not satisfy this follow-up.

### Task 3: Prepare and release `agent-workflows` 0.2.0

**Files in `shakacode/agent-workflows`:**

- Consume: outputs of the gem-foundation plan.
- Modify: `VERSION`, `lib/agent_workflows/version.rb`, `.codex-plugin/plugin.json`,
  `.claude-plugin/plugin.json`, `test/packaging/*`,
  `agent-workflows.gemspec`, `agent-workflows.gem-manifest`,
  `agent-workflows.runtime-manifest`, release docs,
  `CHANGELOG.md`.
- Create: `.github/workflows/release-gem.yml`.
- Create: `.github/workflows/rubygems-release-closeout.yml`.
- Create: `.github/workflows/prepare-rubygems-grant-ceremony.yml` and
  `.github/workflows/open-rubygems-grant-observation-pr.yml`,
  `.github/workflows/verify-rubygems-grant-observation-pr.yml`,
  `.github/workflows/finalize-rubygems-grant-observation.yml`, and
  `.github/workflows/capture-rubygems-post-grant.yml`, bound to the authorized
  operator and independent observer, exact approval and allowlist objects, and workflow
  path/ref/file digests.
- Create: `release/schemas/rubygems-publication-operation-v1.schema.json`,
  `release/schemas/rubygems-grant-preparation-v1.schema.json`,
  `release/schemas/rubygems-grant-attestation-v1.schema.json`,
  `release/schemas/rubygems-grant-orphan-acceptance-v1.schema.json`,
  `release/schemas/rubygems-grant-pre-observation-v1.schema.json`,
  `release/schemas/rubygems-grant-observation-v1.schema.json`,
  `release/schemas/rubygems-merged-observation-handoff-v1.schema.json`,
  `release/schemas/rubygems-post-grant-receipt-v1.schema.json`,
  `release/schemas/rubygems-grant-chain-index-v1.schema.json`, and
  `release/schemas/rubygems-release-closeout-v1.schema.json`, with reviewed
  writer/verifier, approval-revalidation, orphan-recovery, and retained-chain
  replay tests for
  `AW-RELEASE-GRANTS-V1` and
  `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`.
- Create after publication through the reviewed closeout PR:
  `release/evidence/rubygems/agent-workflows/0.2.0/*`.

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
`agent-workflows`. After this package's durable approval, run and verify
`AW-RELEASE-AUTHORIZATION-HANDOFF-V1`; only its exact producer run, artifact ID,
service digest, and authorization-file SHA-256 may launch publication.

- [ ] **Step 6: Publish and verify only after authorization**

Dispatch the release workflow with those four exact authorization selectors.
After the workflow reports success, independently query RubyGems, install the
public gem, run each executable, verify the protected tag's exact target SHA,
and confirm the source-pack installer still uses its own pinned library bytes.
For a first RubyGems publication under this name, execute and read back the
global `AW-RELEASE-GRANTS-V1` and verify its post-grant release receipt binds the
exact provisional publication-operation receipt. Then create the GitHub Release
explicitly from that already verified tag and commit, attach the checksum
manifest and versioned changelog notes, and read back its numeric release ID,
tag, target commit, attachment digests, and release-metadata digest. A failed or
ambiguous release creation is reconciled against live GitHub state before any
retry; neither a tag alone nor a locally prepared release body satisfies this
gate. Only after that read-back passes, run `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`
with the exact GitHub Release record. Treat the release as
`PUBLISHED_CLOSEOUT_PENDING` until the exact evidence PR is merged and its
trusted-base finalizer reports `RELEASE_COMPLETE`.

### Task 4: Prepare and release npm `agent-coordination-dashboard` 0.1.0

**Files in `shakacode/agent-coordination-dashboard`:**

- Modify: `package.json`, `scripts/package.test.ts`.
- Modify if required: remaining package tests and `README.md`.
- Create: `CHANGELOG.md` with `Unreleased` and `0.1.0` entries.
- Modify: `.github/workflows/ci.yml` for the supported Node matrix.
- Create/modify: `.github/workflows/release-npm.yml`.
- Create: `docs/npm-publishing-access-runbook.md`.
- Create: `release/schemas/npm-postpublish-receipt-v1.schema.json`.
- Create: `release/schemas/npm-publishing-access-observation-v1.schema.json`.
- Create: `scripts/write-npm-publishing-access-observation.mjs` and
  `scripts/verify-npm-publishing-access-observation.mjs`.
- Create: `scripts/npm-publishing-access-observation.test.mjs`.
- Create: `scripts/write-npm-postpublish-receipt.mjs` and
  `scripts/verify-npm-postpublish-receipt.mjs`.
- Create: `scripts/npm-postpublish-receipt.test.mjs`.
- Create: `.github/workflows/npm-bootstrap-closeout.yml`.
- Create: `release/schemas/npm-bootstrap-closeout-v1.schema.json` plus
  writer/finalizer tests for `AW-RELEASE-NPM-BOOTSTRAP-CLOSEOUT-V1`.
- Create after publication:
  `release/evidence/agent-coordination-dashboard-0.1.0-publishing-access.v1.json`.
- Create after publication: `release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json`.
- Create after publication through the reviewed evidence-only PR:
  `release/evidence/npm/agent-coordination-dashboard/0.1.0/*`.
- Create after that PR merges through the reviewed observation-only PR:
  `release/evidence/agent-coordination-dashboard-0.1.0-publishing-access-closeout.v1.json`.

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
tag must exactly match the freshly downloaded, selector-verified package-release
authorization whose canonical eventual path is
`release/authorizations/agent-coordination-dashboard-0.1.0.v1.json`.

- [ ] **Step 2: Install the tarball into a disposable project**

Run the packaged command's help, foreground smoke on a disposable port/state root, start/status/logs/restart/stop lifecycle, doctor JSON, and clean shutdown. Prove the installed command does not import the source checkout.

- [ ] **Step 3: Prepare npm trusted publishing and bootstrap controls**

Prepare npm provenance/OIDC from a protected GitHub release environment with no
long-lived npm token. Use the same package-keyed non-cancelling concurrency and
two-job privilege split as `AW-RELEASE-RUBYGEMS-V1`. The unprivileged job
runs install, test, typecheck, build, package-content checks, and tarball smoke,
then uploads the exact tarball and bound receipt. The minimal OIDC job downloads
those same-run artifacts with full immutable commit-SHA-pinned actions, verifies their
authorization and integrity without installing dependencies or running repository/package hooks,
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
Node/npm pair, owners, exact `npm_closeout_reviewer_login`, grant-manifest path
and SHA-256, and smoke evidence. The named closeout reviewer must be a GitHub
identity distinct from the maintainer who will perform the later authenticated
publishing-access observation.
RubyGems approvals do not authorize
npm publication. After durable npm approval, run
`AW-RELEASE-AUTHORIZATION-HANDOFF-V1`, freshly retrieve the exact authorization
artifact by its verified producer run, artifact ID, and service digest, and
record its file SHA-256. The human bootstrap must validate those selectors and
bytes before opening the interactive session.

- [ ] **Step 5: Bootstrap, secure, and verify only after authorization**

Fetch tags, require `v0.1.0` to be absent or already dereference to the
authorized commit, then create/push and read back the protected tag before npm
publication. A tag at another commit is a terminal collision. Before login,
install the global bootstrap contract's unconditional cleanup trap and test its
success, grant-failure, attachment-failure, verification-failure, interrupt, and
unexpected-exit cases with a fake npm credential store. Run the bootstrap in a
disposable VM or OS user with a fresh isolated home and
`NPM_CONFIG_USERCONFIG`, no unrelated repository checkout, browser profile,
cloud credential, SSH agent, package token, or other reusable secret. Restrict
network access to the exact npm and GitHub endpoints required by the runbook,
open the account-wide npm session immediately before the closed publish/grant/
publisher/settings sequence, and perform no unrelated command while it is
live. The trap logs out and verifies the isolated store is credential-free;
destroy the VM/user/home on both success and failure. A retry starts from a new
environment and session. Tests prove the command uses only the isolated user
config, rejects a pre-populated home, exercises every trap path, and destroys the
environment even when logout/read-back is ambiguous. Immediately before
`npm publish`, and again before each later owner-grant, team-access,
trusted-publisher, or Settings mutation, re-fetch the bound approval object and
the exact-commit `release/approvers/package-release.v1.json` allowlist through
the GitHub API, require the same object ID, derived approver login,
creation/update timestamps, canonical body SHA-256, and allowlist SHA-256 that
the authorization bound, and compare its own canonical UTC clock with
`expires_at`; expiry equality or a past value fails closed. An edited, deleted, or revoked approval,
a changed allowlist, or a session that outlived the authorization stops the
bootstrap before the irreversible upload and before every later mutation. Tests
race approval edit, deletion, and expiry between the pre-login validation and
each mutation boundary. Publish the exact reviewed tarball interactively with
2FA only after the tag is verified and that revalidation passes. Verify
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
trusted-publisher identity, actor handle, timestamp, evidence reference/digest,
and every pre-mutation revalidation's re-fetched approval-object and allowlist
digests plus its `authorization_checked_at`
to write `release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json`.
`verify-npm-postpublish-receipt.mjs` validates it against
`npm-postpublish-receipt-v1.schema.json`, independently supplied expected
authorization/artifact/commit values, and the exact token-disallowing setting;
it rejects credential values, cookies, headers, query strings, response bodies,
wrong artifacts, stale observations, mismatched actors or publishers, and any
missing, stale, or mismatched pre-publish or later pre-mutation revalidation.
Test every rejection plus a fresh-login matching receipt. The release is incomplete if either
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
  --authorization "$VERIFIED_PACKAGE_AUTHORIZATION_PATH" \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball release/artifacts/agent-coordination-dashboard-0.1.0.tgz \
  --evidence release/evidence/agent-coordination-dashboard-0.1.0-publishing-access.v1.json \
  --output release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json
node scripts/verify-npm-postpublish-receipt.mjs \
  --receipt release/receipts/agent-coordination-dashboard-0.1.0.postpublish.v1.json \
  --authorization "$VERIFIED_PACKAGE_AUTHORIZATION_PATH" \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball release/artifacts/agent-coordination-dashboard-0.1.0.tgz
```

Create the GitHub Release explicitly from the already verified tag with tarball
integrity, checksum, and `0.1.0` changelog notes, then read back the tag and
release. If publication fails after the tag is created, do not move or reuse the
tag: reconcile live npm state and record an explicit retry or version-bump
disposition. Do not publish another version merely to test OIDC.

After the cleanup trap has removed the interactive session and its absence is
read back, and after the GitHub Release read-back passes, run
`AW-RELEASE-NPM-BOOTSTRAP-CLOSEOUT-V1`. Do not treat the receipt left in the
maintainer checkout as durable. The dashboard release remains
`PUBLISHED_CLOSEOUT_PENDING` until the exact evidence-only PR and subsequent
observation-only PR are merged and the trusted-base finalizer reports
`RELEASE_COMPLETE` against the canonical post-first-merge authenticated
publishing-access observation.

### Task 5: Evaluate self-contained Agent Workflows executables

The standalone GitHub Release uses the distinct immutable tag
`agent-workflows-standalone-v0.2.0`; `AUTHORIZED_BINARY_TAG` is fixed to that
value throughout this task. It is not the gem/source release tag `v0.2.0`.
Build and verify the `agent-workflows` gem first, then evaluate the standalone
artifacts, obtain the separate binary authorization, and only then create or
resume the draft standalone release. A public GitHub Release for `v0.2.0` does
not conflict with `prepare-publication`'s rejection of a public or unowned
release for the distinct standalone tag. Neither tag may be moved or reused.

**Shared external protected-mutator prerequisite:** before either RubyGems
observation-PR opener or this task's Step 6, create and
independently review the dedicated repository
`shakacode/agent-release-mutator`. Its root `action.yml` loads only the reviewed,
checked-in `dist/index.js` built from `src/index.ts`; tests prove the distribution
matches source. Version 1 exposes only closed `stage-draft`, `expose-draft`, and
`open-closeout-pr` modes with fixed input/result schemas, exact repository/tag/
release/branch/path allowlists, and no arbitrary URL, route, ref, request body,
script, or command input. Protected main, CODEOWNERS, and two-person review are
required. An unprivileged prerequisite job downloads the action repository at
that exact commit, verifies the source/distribution build and the closed schemas,
and emits a canonical receipt binding the independent review URL, repository,
commit, `action.yml` digest, `dist/index.js` digest, and every mode/schema digest.
The release authorization and protected-environment review bind that exact
receipt artifact ID, service digest, and file SHA-256. Record the independent
review URL, repository, exact 40-hex commit,
`action.yml` SHA-256, `dist/index.js` SHA-256, and each mode/schema digest in the
release authorization. Every workflow invocation uses
`shakacode/agent-release-mutator@<that-full-commit>`. The protected job receives
write permission at job start, but before invoking the action it downloads and
compares only the exact unprivileged receipt selected by artifact ID/digest; it
does not claim that an in-job step can delay credential issuance. Test receipt,
action-SHA, source digest, distribution digest, and schema substitution. Step 6
is blocked until this separate deliverable exists and its tests/review pass; a
placeholder, local action, mutable tag, or action code from this repository is
forbidden.

The mutator-provenance handoff is mandatory for every closed mode, including
every `open-closeout-pr` invocation. Each unprivileged preparation job freshly
downloads the exact provenance receipt by producer run, artifact ID, service
digest, and file SHA-256 and binds those four selectors plus the action/source/
distribution/mode/schema digests into its instruction, closed manifest, and
PR-payload artifact. After the protected opener downloads and validates that
payload, full-SHA generic artifact/digest actions retrieve and compare the exact
bound provenance receipt before the full-SHA mutator is invoked. The committed
PR-binding and protected operation-result records repeat all receipt selectors
and digests. Missing, name-selected, checkout-relative, or substituted receipt
evidence stops the opener before branch or PR mutation; tests apply that rule to
all three version-1 modes.

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
- Create: `packaging/tebako/write-closeout-pr-instruction.rb`
- Create: `packaging/tebako/validate-closeout-pr-evidence.rb`
- Create: `packaging/tebako/validate-evaluation.rb`
- Create: `packaging/tebako/write-evaluation.rb`
- Create: `packaging/tebako/write-platform-run.rb`
- Create: `test/packaging/standalone_executable_test.rb`
- Create: `test/packaging/standalone_real_network_test.rb`
- Create: `test/packaging/standalone_evaluation_validator_test.rb`
- Create: `test/packaging/standalone_release_evidence_test.rb`
- Create: `.github/workflows/authorize-standalone.yml`
- Create: `.github/workflows/record-standalone-release-decision.yml`
- Create: `.github/workflows/package-standalone.yml`
- Create: `.github/workflows/standalone-closeout-pr.yml`
- Create: `.github/workflows/finalize-standalone-closeout.yml`
- Create: `release/schemas/standalone-platform-input-v1.schema.json`
- Create: `release/schemas/standalone-platform-run-v1.schema.json`
- Create: `release/schemas/standalone-evaluation-v1.schema.json`
- Create: `release/schemas/standalone-release-authorization-v1.schema.json`
- Create: `release/approvers/standalone-release.v1.json`
- Create: `release/schemas/standalone-approver-allowlist-v1.schema.json`
- Create: `release/schemas/standalone-approval-object-v1.schema.json`
- Create: `release/schemas/standalone-release-decision-v1.schema.json`
- Create: `release/schemas/standalone-publication-instruction-v1.schema.json`
- Create: `release/schemas/standalone-mutator-operation-result-v1.schema.json`
- Create: `release/schemas/standalone-github-release-receipt-v1.schema.json`
- Create: `release/schemas/standalone-publication-recovery-v1.schema.json`
- Create: `release/schemas/standalone-closeout-pr-instruction-v1.schema.json`
- Create: `release/schemas/standalone-closeout-pr-binding-v1.schema.json`
- Create: `release/schemas/standalone-closeout-pr-operation-result-v1.schema.json`
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
- Commit through reviewed closeout PRs:
  `release/evidence/standalone/closeouts/<closeout-key>/` with either the exact
  verified authorization/receipts or denial/stale decision, terminal
  evaluation, and closed manifest. An adopted or stale-authorization closeout
  uses `tag-<authorization-tag>`; an initial denial or threshold failure uses
  the full evaluation-digest form defined below.
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
candidate `NOT_ADOPTED` with the exact failed criteria; retain gem/source-pack
distribution and do not begin a Rust rewrite automatically. The candidate JSON
status does not become a terminal reported outcome until the threshold-failure
closeout below is committed and revalidated from `main`.
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

For a threshold failure, the aggregation job packages the four exact verified
platform-run records, candidate `NOT_ADOPTED` evaluation, and a closed SHA-256
manifest as one
`standalone-threshold-failure-closeout-evaluation-<full-evaluation-sha256>-<aggregation-run>`
artifact. It queries that artifact's exact ID and service digest, downloads it
into a fresh directory, and revalidates every byte and schema. The artifact is
retention-bounded input, never terminal evidence.

Invoke the `threshold-failure-evidence` mode of
`.github/workflows/standalone-closeout-pr.yml` with that exact producer run,
artifact ID, and service digest. This mode uses the same unprivileged payload,
no-checkout opener, committed instruction/binding, post-push operation result,
human review, and exact-merge verification contract as the other closeout
modes. Its fixed directory is
`release/evidence/standalone/closeouts/evaluation-<full-evaluation-sha256>/`
and contains only the four platform runs, candidate evaluation, and closed
manifest; an authorization, authorization decision, or release receipt is
forbidden. `finalize-standalone-closeout.yml` accepts and reports terminal
`NOT_ADOPTED` only after it revalidates those files from the exact merged commit
on `main` and proves no public standalone release or asset exists. Until then,
the workflow reports `NOT_ADOPTED_CLOSEOUT_PENDING` with the PR URL and named
maintainer owner.

- [ ] **Step 6: Require separate release authorization for binaries**

Binary release approval names platforms, architectures, checksums, signing
state, Ruby/Tebako versions, immutable GitHub repository/tag/commit target,
source matrix run ID, workflow path/ref/digest, expiry, and rollback. Gem
publication approval does not authorize binary artifacts. Create the
authorization only from a canonical durable GitHub pull-request review or issue
comment that names the exact source evaluation digest and every binary release
binding. The dispatch accepts that object URL but no approver identity or body.
With closed `contents: read`, `actions: read`, `issues: read`, and
`pull-requests: read` permissions, the read-only authorization job parses the
URL as an exact object ID in `shakacode/agent-workflows`, fetches the object,
derives its author and creation/update timestamps, and validates its canonical
payload against the evaluation, platform/architecture/checksum/signing set,
repository/tag/commit, workflow, expiry, rollback, and mutator-provenance fields.
The derived login must appear in the exact-commit, schema-validated
`release/approvers/standalone-release.v1.json` allowlist, protected by CODEOWNERS
and branch rules requiring two-person review. The verifier binds that allowlist
digest and writes a canonical verified approval-object record in `RUNNER_TEMP`;
the record uses the fixed `standalone-approval-object-v1` schema and binds its
own schema path/version/digest, object type, repository, URL/node ID, derived
author, timestamps, canonical body digest, and, for an approval record, the
validated release payload; the schema requires that payload only for an approval
record and forbids it for the decision record below;
it records `github.triggering_actor` separately and never treats the dispatcher
as the approver. Before invoking the writer, the same read-only job
queries the complete artifact inventory for the exact mutator-provenance
producer run and artifact ID, verifies the service digest, downloads into a
fresh directory, and validates the file SHA-256, fixed receipt schema, action
commit, action/source/distribution digests, and mode/schema digests. A checkout-
relative receipt or artifact-name/latest-run lookup is forbidden:

```bash
ruby packaging/tebako/write-release-authorization.rb \
  --evaluation "$VERIFIED_EVALUATION_PATH" \
  --approval-object "$VERIFIED_STANDALONE_APPROVAL_OBJECT_PATH" \
  --approver-allowlist "$VERIFIED_STANDALONE_APPROVER_ALLOWLIST_PATH" \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --target-commit "$AUTHORIZED_BINARY_COMMIT" \
  --source-run-id "$STANDALONE_SOURCE_RUN_ID" \
  --workflow-path .github/workflows/package-standalone.yml \
  --workflow-ref "$STANDALONE_WORKFLOW_REF" \
  --workflow-digest "$STANDALONE_WORKFLOW_DIGEST" \
  --authorization-run-id "$GITHUB_RUN_ID" \
  --authorization-workflow-path .github/workflows/authorize-standalone.yml \
  --authorization-workflow-ref "$GITHUB_WORKFLOW_REF" \
  --authorization-workflow-digest "$AUTHORIZATION_WORKFLOW_DIGEST" \
  --mutator-receipt "$VERIFIED_MUTATOR_PROVENANCE_RECEIPT_PATH" \
  --mutator-receipt-run-id "$MUTATOR_RECEIPT_RUN_ID" \
  --mutator-receipt-artifact-id "$MUTATOR_RECEIPT_ARTIFACT_ID" \
  --mutator-receipt-service-digest "$MUTATOR_RECEIPT_SERVICE_DIGEST" \
  --mutator-receipt-file-sha256 "$MUTATOR_RECEIPT_FILE_SHA256" \
  --mutator-action "$STANDALONE_MUTATOR_ACTION" \
  --mutator-action-digest "$STANDALONE_MUTATOR_ACTION_DIGEST" \
  --mutator-result-schema \
    release/schemas/standalone-mutator-operation-result-v1.schema.json \
  --expires-at "$BINARY_AUTHORIZATION_EXPIRY" \
  --rollback-disposition "$BINARY_ROLLBACK_DISPOSITION" \
  --rollback-evidence "$BINARY_ROLLBACK_EVIDENCE" \
  --output "$RUNNER_TEMP/agent-workflows-standalone-authorization-v1.json"
ruby test/packaging/standalone_release_evidence_test.rb
```

The writer requires the input state to be
`ADOPTED_PENDING_RELEASE_AUTHORIZATION`, copies the closed four-platform asset
bindings from that evaluation, requires every target/run/workflow input above,
schema-validates the verified approval-object record and fixed approver
allowlist, and binds the canonical object URL/node ID, derived approver login,
creation/update timestamps, body SHA-256, allowlist SHA-256, and distinct
dispatch actor. It
requires and schema-validates that freshly downloaded provenance receipt,
requires its independently reviewed mutator action at an immutable commit and
content digest, binds all four receipt selectors and its action/source/
distribution/mode/schema digests, binds the result schema's fixed path, version,
and SHA-256, and validates the result against
`standalone-release-authorization-v1.schema.json`. It rejects a threshold
failure, failed criterion, terminal input, ambiguous approver, mutable target,
missing rollback, or stale authorization.

Every later preparation and protected publication job freshly retrieves that
same provenance receipt by the authorization-bound producer run, artifact ID,
service digest, and file SHA-256. The protected job compares the receipt through
full-SHA generic artifact/digest actions before invoking the full-SHA mutator;
the unprivileged preparation and protected mutator also re-fetch the exact bound
approval object and require unchanged ID, author, timestamps, body digest,
allowlist digest, payload, and unexpired authorization. Tests reject forged or
cross-repository URLs, dispatcher/approver substitution, edited/deleted approval,
unlisted approvers, payload mismatch, substitution of any receipt selector or
byte, action commit, or recorded digest. They also reject malformed or unknown
approval-record fields, object-type substitution, missing object-read
permissions, or any broader issue/pull-request permission.

Terminal standalone closeouts are irreversible in this plan; there is no
implicit reopening transition. Before authorization capture accepts the source
evaluation, it fetches current `main` and rejects either deterministic terminal
namespace for the same evaluation/tag:
`release/evidence/standalone/closeouts/evaluation-<full-evaluation-sha256>/` or
`release/evidence/standalone/closeouts/tag-<tag>/`. `prepare-publication` repeats
that current-`main` check after verifying the authorization, and the final
protected pre-exposure check repeats it immediately before making a draft
public. Because the lock is released between separately queued jobs, every
mutating job—including `stage-draft`, `expose-draft`, and every
`open-closeout-pr` mode—re-fetches current `main` and rejects either terminal
namespace under its acquired lock immediately before invoking its mutator.

In each authorization, preparation, publication, and pre-merge denial or
threshold-failure opener workflow, a first read-only identity job downloads and
schema-validates the exact evidence selected by producer-run/artifact-ID/service-
digest/file-digest, derives the full evaluation digest itself, pairs it with the
plan-fixed `agent-workflows-standalone-v0.2.0` tag, and emits one canonical lock
key. In each post-merge negative `finalize-standalone-closeout.yml` workflow,
the identity job instead fetches the exact trusted-base merge commit from
current `main`, validates the committed candidate/manifest and deterministic
evaluation namespace, and derives the same digest/tag key from those durable
bytes; retention artifact selectors cannot define that finalizer's lock. No
dispatch or caller-provided lock key is accepted. Each subsequent writer,
finalizer, or publication job declares job-level, non-cancelling concurrency on
only that `needs.identity.outputs.lock_key`; GitHub therefore acquires the lock
after validated identity derivation and before any mutation. The identical key
covers authorization capture, preparation, the entire publication job including
its protected expose action, and every denial or threshold-failure
`finalize-standalone-closeout.yml` job. A merged negative
evidence PR remains a candidate rather than an accepted terminal verdict until
that serialized finalizer revalidates current `main`, the no-public-release
condition, and the absence of any draft release or uploaded asset for the
evaluated tag. A staged but unexposed draft is not a public release, so the
finalizer queries the tag's release and asset state directly and requires either
that no exporter-owned draft or asset exists or a recorded authorized cleanup
that removed it; a surviving draft blocks terminal acceptance rather than being
stranded by a terminal namespace that would reject every later mutator.
A terminal-candidate closeout merged after authorization capture therefore
either invalidates the authorization before staging/exposure or waits for
publication and is rejected by the finalizer after exposure. Tests cover
forged identity inputs, cross-workflow serialization, finalizer/check/toggle
interleavings, terminal acceptance between preparation and `stage-draft`, a
staged-but-unexposed draft or orphaned asset at the finalizer boundary, and
the plan-fixed tag path for no-authorization negative cases,
as well as merge denial,
stale-authorization, and threshold-failure closeouts at each race boundary.
Reopening would require a separately reviewed
state-machine/schema revision and fresh approval; old source artifacts never
reopen themselves.

Run the writer only in `authorize-standalone.yml`, after the named human approval
has been durably recorded. This capture workflow checks out the authorized source
commit with persisted credentials disabled, has only `contents: read` and
`actions: read` plus the exact `issues: read` and `pull-requests: read`
permissions required for approval-object verification, downloads and verifies
the exact source-evaluation artifact and approval object,
resolves `VERIFIED_EVALUATION_PATH` only inside that fresh exact-ID/digest
download, requires the capture run's head SHA to equal that commit, and receives
no release-write permission. The authorization binds its own producer run ID and
immutable capture-workflow path/ref/digest. Upload the single authorization JSON
as a retention-bounded artifact named by tag and capture run. A separate
read-only verification job queries the complete artifact inventory for that
exact producer run, requires exactly one expected authorization artifact,
records its ID and service-reported digest, downloads it to a fresh directory,
checks its SHA-256 and schema, and confirms every approval, evaluation, target,
workflow, mutator, expiry, and rollback binding. Those exact producer-run,
artifact-ID, and artifact-digest values are the only publication handoff; a
workspace file, workflow output containing JSON, branch commit made after
approval, publication-time artifact-name lookup, or "latest" run is forbidden.
Launch `package-standalone.yml` with those three exact values as explicit
dispatch inputs. The inputs are selectors, not trust: `prepare-publication` must
prove all of them against GitHub API and authorization-content evidence before
proceeding.

For denial, or when a previously valid authorization expires before upload,
create a separate decision receipt. For an initial denial, no authorization
exists and the argument is forbidden:

```bash
ruby packaging/tebako/write-release-decision.rb \
  --evaluation "$VERIFIED_EVALUATION_PATH" \
  --decision authorization-denied \
  --decision-source-url "$BINARY_DECISION_SOURCE_URL" \
  --decision-object "$VERIFIED_STANDALONE_DECISION_OBJECT_PATH" \
  --approver-allowlist "$VERIFIED_STANDALONE_APPROVER_ALLOWLIST_PATH" \
  --decided-by "$EXPECTED_BINARY_DECISION_PRINCIPAL" \
  --output "$RUNNER_TEMP/standalone-release-decision-v1.json"
```

For an authorization that became stale before upload, bind the exact expired
authorization:

```bash
ruby packaging/tebako/write-release-decision.rb \
  --evaluation "$VERIFIED_EVALUATION_PATH" \
  --decision authorization-stale \
  --decision-source-url "$BINARY_DECISION_SOURCE_URL" \
  --decision-object "$VERIFIED_STANDALONE_DECISION_OBJECT_PATH" \
  --approver-allowlist "$VERIFIED_STANDALONE_APPROVER_ALLOWLIST_PATH" \
  --decided-by "$EXPECTED_BINARY_DECISION_PRINCIPAL" \
  --authorization "$VERIFIED_AUTHORIZATION_PATH" \
  --output "$RUNNER_TEMP/standalone-release-decision-v1.json"
```

The authorization is required for `authorization-stale` and forbidden for an
initial `authorization-denied` decision. The authorization schema binds the
human-approved rollback disposition and evidence; neither may be synthesized or
defaulted by the writer. The decision writer validates the decision
against `standalone-release-decision-v1.schema.json`, including the derived
deciding principal and its source decision-object URL/node ID, derived login,
creation/update timestamps, canonical body SHA-256, and allowlist SHA-256, the
decision timestamp, source URL, source-evaluation producer
run/artifact ID/artifact digest/file digest, and either the explicit denial or
the authorization expiry plus its producer-run/artifact identity.

The deciding principal is derived, never supplied. As in
`authorize-standalone.yml`, the read-only `capture-decision` and
`finalize-decision` jobs defined below each declare the `issues: read` and
`pull-requests: read` object-type permissions the shared verifier needs.
`capture-decision` parses `--decision-source-url` as an exact object ID in
`shakacode/agent-workflows`, accepts only a pull-request review or an issue
comment on that pull request, fetches that object through the GitHub API, and
writes a canonical verified decision-object record in `RUNNER_TEMP` under the
same fixed `standalone-approval-object-v1` object-record schema, binding its
own schema path/version/digest, object type, repository, URL/node ID, derived
author, creation/update timestamps, and canonical body SHA-256, and carrying no
release payload because a denial authorizes nothing. The derived
login must appear in the schema-validated
`release/approvers/standalone-release.v1.json` allowlist read at the source
evaluation's bound commit through the GitHub Contents API; no checkout-relative
allowlist is accepted. The writer takes the
deciding principal only from that record and binds the canonical object
URL/node ID, derived login, creation/update timestamps, body SHA-256, and
allowlist SHA-256 into the decision; it records `github.triggering_actor`
separately and never treats the dispatcher as the decider. `--decided-by` is at
most an expectation cross-checked against the derived login; any disagreement
fails closed. `finalize-decision` re-fetches the same object and requires an
unchanged ID, derived author, timestamps, body digest, and allowlist digest
before writing the candidate terminal `NOT_ADOPTED` evaluation. Tests reject
forged or cross-repository URLs, dispatcher/decider substitution, edited or
deleted decision objects, unlisted deciders, object-type substitution, an
altered allowlist, missing object-read permissions or any broader
issue/pull-request permission, and a `--decided-by` value that disagrees with
the derived author.

The decision writer also derives and binds an immutable `closeout_key`; callers
cannot supply it. For `authorization-stale`, it is
`tag-<authorization-tag>` from the verified authorization. For an initial
`authorization-denied`, it is
`evaluation-<full-source-evaluation-file-sha256>`. This gives the denial path a
deterministic namespace without inventing or accepting an unauthorized release
tag. The schema binds the closeout key and its derivation inputs, and rejects a
caller-selected, truncated, or mismatched key.

Run this path only through
`.github/workflows/record-standalone-release-decision.yml`, a read-only workflow
with separate `capture-decision` and `finalize-decision` jobs. Exact dispatch
selectors name the source-evaluation run/artifact ID/service digest, the
decision-object URL, the expected deciding principal, and, only for
`authorization-stale`, the authorization producer run/artifact ID/service
digest. `capture-decision` proves those selectors through the GitHub API,
downloads each artifact into a separate fresh directory, verifies its bytes and
schema, runs the writer with only those verified paths plus the `RUNNER_TEMP`
decision-object record and the fetched approver allowlist, and uploads the single
decision JSON as an artifact named by the derived closeout key and capture run.
It queries and records
that artifact's exact ID/service digest, freshly downloads it, and verifies its
file digest and schema before exposing those values to `finalize-decision` as
selectors. A name lookup, checkout evidence path, or workflow output containing
JSON is forbidden.

`finalize-decision` freshly downloads the exact source evaluation and captured
decision by producer run/artifact ID/service digest, revalidates both, and writes
the candidate terminal `NOT_ADOPTED` evaluation into `RUNNER_TEMP`. For
`authorization-stale`, it also freshly downloads and revalidates the exact
expired authorization named by the decision. It packages the source evaluation,
decision, terminal evaluation, conditionally required-or-forbidden expired
authorization, and a closed SHA-256 manifest as one
`standalone-release-decision-closeout-<closeout-key>-<capture-run>` artifact,
queries its
exact ID/service digest, downloads it into a new directory, and revalidates the
manifest and every applicable schema. Evaluation and decision schemas are always
required; the authorization schema and file are required for
`authorization-stale` and forbidden for `authorization-denied`. That retention-
bounded artifact is only the source for
the `negative-decision-evidence` mode of
`.github/workflows/standalone-closeout-pr.yml`; its fresh read-back alone is not
terminal evidence.

The negative mode uses the same unprivileged preparation, exact PR-payload
artifact, limited no-checkout opener, committed instruction/binding, post-push
operation-result, human PR review, and split-contract verification defined below.
Its fixed closeout-key directory contains the source evaluation,
denial/stale decision,
candidate terminal `NOT_ADOPTED` evaluation, closed manifest, and—only for
`authorization-stale`—the exact expired authorization. After merge,
`finalize-standalone-closeout.yml` revalidates those files from the exact commit,
re-fetches the bound decision object and the exact-commit approver allowlist
under the same `issues: read` and `pull-requests: read` object-type permissions
and requires an unchanged object ID, derived author, creation/update timestamps,
canonical body SHA-256, and allowlist SHA-256 against the committed decision,
proves the no-public-artifact condition, and accepts/reports `NOT_ADOPTED` only
from that immutable `main` evidence. A decision object edited, deleted, or
rescinded after `finalize-decision` fails closed at this terminal acceptance
boundary instead of being accepted from the committed snapshot alone. Loss, mismatch, or an unmerged PR leaves the
state `ADOPTED_PENDING_RELEASE_AUTHORIZATION`; temporary files and Actions
artifacts never complete the negative path.

- [ ] **Step 7: Publish binaries only after authorization**

Split standalone publication into five tag-serialized jobs under one concurrency
group with `cancel-in-progress: false`: `prepare-publication`, `stage-draft`,
`verify-draft`, `expose-draft`, and `verify-public`. No build, matrix,
aggregation, verification, or recovery job receives `contents: write`.

`prepare-publication` is unprivileged: `contents: read`, `actions: read`,
`issues: read`, and `pull-requests: read`, with no environment, persisted
checkout credential, or write permission. All repository
Ruby, Bundler, tests, schemas, and preflight logic end in this job. It checks out
the exact authorized commit, downloads the bound source-run artifacts, and
requires exact workflow-dispatch inputs for the authorization producer run,
artifact ID, and service-reported digest. It queries that producer run and
capture workflow, downloads the authorization artifact by ID into a fresh
directory, verifies the artifact and file digests plus the authorization schema,
and requires the file's producer-run/workflow bindings to match the API evidence.
It then verifies every workflow/evaluation/authorization/tag/commit/expiry
binding and asset checksum/signature, freshly downloads and verifies the exact
authorization-bound mutator-provenance receipt by all four selectors, rejects a
public or unowned release for the tag, and writes a closed publication
instruction:

```bash
ruby packaging/tebako/write-publication-instruction.rb \
  --evaluation "$VERIFIED_EVALUATION_PATH" \
  --authorization "$VERIFIED_AUTHORIZATION_PATH" \
  --authorization-producer-run-id "$AUTHORIZATION_PRODUCER_RUN_ID" \
  --authorization-artifact-id "$AUTHORIZATION_ARTIFACT_ID" \
  --authorization-artifact-digest "$AUTHORIZATION_ARTIFACT_DIGEST" \
  --mutator-receipt "$VERIFIED_MUTATOR_PROVENANCE_RECEIPT_PATH" \
  --mutator-receipt-run-id "$MUTATOR_RECEIPT_RUN_ID" \
  --mutator-receipt-artifact-id "$MUTATOR_RECEIPT_ARTIFACT_ID" \
  --mutator-receipt-service-digest "$MUTATOR_RECEIPT_SERVICE_DIGEST" \
  --mutator-receipt-file-sha256 "$MUTATOR_RECEIPT_FILE_SHA256" \
  --repository shakacode/agent-workflows \
  --tag "$AUTHORIZED_BINARY_TAG" \
  --output "$RUNNER_TEMP/standalone-github-publication-instruction-v1.json"
```

The instruction schema binds the authorization/evaluation/workflow digests,
source run, authorization producer run/artifact ID/artifact digest/file digest,
authorization capture-workflow path/ref/digest, repository, immutable tag and
target commit, closed four-asset name/digest/signature matrix, expiry, and the
independently reviewed mutator action's repository, immutable commit, and content
digest, all mutator-provenance receipt selectors and action/source/distribution/
mode/schema digests, plus the mutator-result schema path, version, and digest. Upload the
instruction, freshly downloaded verified authorization, freshly downloaded
verified source evaluation, exact asset bundle, and a closed manifest of every
file and SHA-256 as one same-run preparation artifact; read back and record its
artifact ID and service-reported digest. `VERIFIED_AUTHORIZATION_PATH` and
`VERIFIED_EVALUATION_PATH` must resolve inside fresh artifact download
directories, never the checkout. Every later job downloads this preparation
artifact by exact ID/digest into its own fresh directory and verifies the
manifest before consuming either evidence file. Any missing, expired,
cross-run, name-selected, substituted, or digest-mismatched authorization,
evaluation, or preparation artifact stops before a write-capable job starts.

`stage-draft` is the first protected write job. It has only job-scoped
`contents: write`, `actions: read`, `issues: read`, and `pull-requests: read`,
performs no checkout, and runs no shell,
Ruby, Bundler, repository script, dependency hook, or caller-supplied program.
Its only executable steps are immutable-SHA-pinned artifact download and the
authorization-bound independent mutator action in closed `stage-draft` mode.
That action accepts no arbitrary API route, script, or request-body input. It
downloads the preparation artifact by the exact ID/digest supplied from the
completed `prepare-publication` job, independently validates its manifest,
instruction, artifact bundle, and embedded provenance selectors, separately
downloads and compares the exact provenance receipt, then creates or
resumes only an exporter-owned **draft** release for the exact tag and uploads
exactly the closed asset set. A build artifact, workflow log, or non-draft
release is never an upload target. It emits a closed `stage_succeeded` operation
result binding the protected run, preparation-artifact ID/digest, instruction,
release/asset IDs, every mutator-provenance receipt selector and action/source/
distribution/mode/schema digest, and observed `draft: true` under the bound
mutator-result schema. A pinned artifact step uploads those exact bytes and queries the
resulting artifact ID/digest. The unprivileged verifier owns fresh retrieval and
domain-schema validation.

`verify-draft` is again unprivileged and has only `contents: read` plus
`actions: read`. It downloads both the stage-result artifact and that result's
bound preparation artifact by exact ID/digest into separate fresh directories,
verifies the preparation manifest and result bytes against the
authorization-bound schema path/version/digest with repository validation code,
and requires the closed `stage_succeeded` variant. The verified evaluation and
authorization paths must resolve inside the freshly downloaded preparation
artifact. It then runs the repository's read-only receipt
writer, queries the immutable draft release and asset IDs, downloads every asset
through authenticated API endpoints to a new temporary directory, and rejects
a mismatched tag/target, non-draft release, missing or extra asset,
cross-repository redirect, digest/signature mismatch, or evidence-binding
mismatch:

```bash
ruby packaging/tebako/write-github-release-receipt.rb \
  --expected-state draft \
  --evaluation "$VERIFIED_EVALUATION_PATH" \
  --authorization "$VERIFIED_AUTHORIZATION_PATH" \
  --preparation-artifact-id "$PREPARATION_ARTIFACT_ID" \
  --preparation-artifact-digest "$PREPARATION_ARTIFACT_DIGEST" \
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
source-evaluation, workflow, instruction, preparation-artifact, protected-run,
operation-result artifact IDs/digests, and every mutator-provenance receipt
selector and action/source/distribution/mode/schema digest; and observed
`draft: true`. Upload it
as a retention-bounded artifact
named by tag and staging run, then read back its artifact ID and SHA-256. Loss or
mismatch blocks exposure.

Before `expose-draft`, publish the installation documentation through the
`installation-docs` mode of `.github/workflows/standalone-closeout-pr.yml`.
Its unprivileged preparation job freshly downloads the exact preparation and
draft-receipt artifacts, renders `docs/standalone-installation.md` from their
closed tag/platform/asset bindings, validates every documented command against
the packaged executables, and writes a closed PR instruction binding the target
base SHA, the installation-doc path/digest, fixed tag-specific committed
instruction and PR-binding paths, source-evidence artifact identities,
deterministic branch name, and the fixed binding/result schema paths, versions,
digests, expected result-artifact name, opener action digest, and all four
mutator-provenance receipt selectors plus its action/source/distribution/mode/
schema digests. It packages
the instruction, documentation, and a
closed file manifest into one PR-payload artifact, uploads it, queries its exact
ID/service digest, freshly downloads it, and revalidates every byte. A protected
`open-pr` job has only `actions: read`, `contents: write`, and
`pull-requests: write`, no release permission, checkout, shell, repository code,
or caller-selected path/content.
It receives only the payload producer run, exact artifact ID, and service digest,
freshly downloads that artifact, and independently validates its instruction and
manifest. Its only mutator is the independently reviewed immutable action in
closed `open-closeout-pr` mode; it creates or updates the deterministic branch
and opens a PR but cannot merge or write directly to `main`.

The opener adds the schema-valid PR-binding record at the instruction's fixed
path. That committed record contains only pre-commit values: mode, PR number,
target base, deterministic branch, opener run and immutable action, payload
artifact ID/digest, instruction/file-manifest digests, all mutator-provenance
receipt selectors/digests, and original
preparation/draft artifact identities. It deliberately cannot contain its own
commit SHA. After updating the PR to the resulting final head, the opener emits a
closed operation result binding the observed final head, committed binding-file
digest, every mutator-provenance selector/digest, and every shared PR/payload
value. A pinned artifact step uploads those
exact result bytes; a read-only job queries the exact opener run, requires the
one instruction-named result artifact, records its ID/service digest, freshly
downloads it, and validates both records with
`packaging/tebako/validate-closeout-pr-evidence.rb`.

Exposure requires a later exact dispatch naming that PR and merge commit. The
read-only pre-exposure gate proves through the GitHub API that a human merged the
current exact docs diff through required review/check policy, that the merge
commit is on `main`, and that the committed docs, instruction, and PR-binding
digests equal the exact payload instruction. It retrieves the payload and
opener-result artifacts by the payload identity and exact opener run/expected
result name committed in
that binding record, requires exactly one result, records its service identity,
and replays the instruction, binding, and operation-result schemas before
trusting those expected values. The operation result—not the self-contained
binding file—must match the observed final PR head.
A draft, closed-unmerged, superseded, force-updated, or mismatched documentation
PR blocks the public toggle. Thus supported installation instructions are on the
default branch before any binary becomes public; opening the PR is not release
or merge approval.

`expose-draft` is the second protected write job and has the same closed
`contents: write`, `actions: read`, `issues: read`, and `pull-requests: read`
permissions plus the no-checkout/no-repository-code contract as `stage-draft`.
Its only mutating step is the same
independently pinned action in closed `expose-draft` mode. It freshly downloads
the exact preparation and durable draft-receipt artifacts by their bound
IDs/digests, verifies the preparation manifest and receipt bytes, and revalidates
the unexpired authorization from the preparation artifact. It separately
downloads and compares the exact mutator-provenance receipt bound by the
instruction and draft receipt, then
re-reads that exact draft release, downloads and re-verifies every live asset
digest/signature, rejects extra or replaced asset IDs, requires the same
tag/target and `draft: true`, and may then toggle only that receipt's release ID.
The mutator emits either a closed `expose_succeeded` result or a closed ambiguity
result under the authorization-bound result schema. The success result binds
the protected run, release/tag/target, instruction, authorization,
preparation-artifact ID/digest, draft-receipt artifact ID/digest, mutator
identity/digest, every mutator-provenance receipt selector and action/source/
distribution/mode/schema digest, toggle timestamp, and response status; the
closed ambiguity variant binds that identical provenance set plus its first
ambiguous timestamp and response evidence. Neither accepts caller-selected
fields. An immutable-SHA-pinned artifact
step uploads those exact bytes and queries the resulting artifact ID/digest; it
does not execute repository or domain-validation code. A missing, substituted,
or non-durable success result is `PUBLICATION_UNKNOWN`, never successful
exposure.
The exact mutator action identity/digest and every authorized closed mode are part of human
environment review; a repository-controlled helper never receives a write token.

`verify-public` is unprivileged and read-only. It freshly downloads the exact
preparation, draft-receipt, and expose-result artifacts by their bound
IDs/digests into separate directories, verifies the preparation manifest and
the other artifact bytes against the authorization-bound schema
path/version/digest with repository validation code, and requires the closed
`expose_succeeded` variant. Its evaluation and authorization inputs come only
from the freshly downloaded preparation artifact. It then reads back the
public release and emits `published_verified` only when the result's protected
run and evidence bindings plus the tag, target, release ID, asset IDs, digests,
signatures, and every mutator-provenance receipt selector/digest still match the
instruction, draft receipt, and expose result. The published receipt repeats
that complete provenance set. It then generates a schema-valid
candidate terminal `ADOPTED` evaluation without yet accepting, reporting, or
committing that transition.
Package the published receipt, candidate terminal evaluation, draft receipt,
authorization, and a manifest of their SHA-256 digests as one
`standalone-publication-closeout-<tag>-<expose-run>` workflow artifact. Upload,
query, and download that artifact to a fresh directory, revalidate its manifest
and both schemas, and record the artifact ID/digest in the job summary. This
artifact is the exact source for durable repository closeout, but retention-
bounded Actions storage alone never accepts or reports terminal `ADOPTED`.

Invoke the `release-evidence` mode of `standalone-closeout-pr.yml` with that
exact closeout-artifact producer run, ID, and service digest. Its unprivileged
preparation job freshly downloads and revalidates the bundle, then writes a
closed PR instruction for the derived closeout-key directory
`release/evidence/standalone/closeouts/tag-<tag>/`. The path set is fixed to the
verified authorization, draft and public receipts, candidate terminal
evaluation, closed manifest, original PR instruction, and PR-binding record; each
prepared content digest, fixed binding/result schema paths, versions, digests,
expected result-artifact name, opener action digest, original closeout-artifact
identity, target base SHA, and all mutator-provenance receipt selectors/digests
are bound. Package the
instruction, prepared files, and
closed manifest into one PR-payload artifact, then upload, query, freshly
download, and verify it exactly as in `installation-docs` mode. The same
protected no-checkout `open-pr` job consumes only its exact producer run/artifact
ID/service digest and may create only the deterministic evidence branch and PR.
It cannot merge, modify other paths, reuse release credentials, or push to
`main`.

The opener writes the fixed PR-binding file after the PR number exists and
updates the branch to a final head containing it. That committed record binds the
PR number, target base, deterministic branch, opener run/action digest,
PR-payload artifact ID/service digest, instruction/manifest digests, and original
publication-closeout producer run/artifact ID/service digest plus all mutator-
provenance receipt selectors/digests, but never its own commit SHA. Its closed
operation-result artifact independently binds the observed final head, committed
binding-file digest, and every mutator-provenance selector/digest plus every
shared value. Query the
exact opener run for the one instruction-named result artifact, record its
ID/service digest, freshly download it, and validate both records before the PR
is presented for merge.

`finalize-standalone-closeout.yml` is a separate read-only workflow triggered by
the merged evidence PR. It proves the reviewed PR head/base and merge commit,
required checks/reviews, ancestry on `main`, exact allowed file set and digests,
and current public release/asset identity. It revalidates the committed receipt,
authorization, manifest, PR-binding record, and terminal evaluation from the
merge commit; freshly retrieves the exact PR-payload and opener-result artifacts
selected by that record and exact opener run; validates the instruction, binding,
and operation-result schemas with the owned validator; and requires the split
contract to match the original closeout artifact plus observed final PR head/base.
Only
that immutable repository commit accepts and reports `ADOPTED`; the workflow
artifact, an open PR, or an unmerged branch does not. Rejection or delay leaves
the public release explicitly `closeout_pending` with the PR URL and named
maintainer owner, and blocks batch/release closeout until merge or an authorized
rollback removes the public assets.

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
run/job and mutator identity/digest, workflow digest, authorization, every
mutator-provenance receipt selector and action/source/distribution/mode/schema
digest, preparation-artifact ID/digest, draft-receipt artifact ID/digest, conditionally
required-or-forbidden
mutator-result artifact ID/digest, release ID, exact asset IDs, first ambiguous
timestamp, recovery deadline, and attempt count. For
`interrupted_without_result`, it additionally binds the mutator step's name,
number, status, start/completion timestamps, and API response digest; both
complete paginated artifact-inventory snapshot digests, query timestamps,
artifact counts, and absent name; the fixed grace duration and its start/end
timestamps; and the terminal-receipt/recovery-artifact absence query's response
digest, timestamp, pagination-completeness flag, and counts. Successor records
preserve that entire origin proof byte-for-byte.

The recovery writer derives the provenance selectors/digests from the freshly
verified authorization and preparation instruction. For an artifact-backed
origin it requires the ambiguity result to echo them exactly; for an interrupted
origin it separately retrieves and compares the exact provenance receipt before
creating attempt 0. Callers cannot supply or override provenance fields.

```bash
ruby packaging/tebako/write-publication-recovery.rb \
  --authorization "$VERIFIED_AUTHORIZATION_PATH" \
  --preparation-artifact-id "$PREPARATION_ARTIFACT_ID" \
  --preparation-artifact-digest "$PREPARATION_ARTIFACT_DIGEST" \
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
  --output "$RUNNER_TEMP/standalone-github-publication-recovery-v1.json"
```

For the narrowly proven interrupted-job origin, omit every mutator-result
argument and let the writer query and bind the exact terminal evidence:

```bash
ruby packaging/tebako/write-publication-recovery.rb \
  --authorization "$VERIFIED_AUTHORIZATION_PATH" \
  --preparation-artifact-id "$PREPARATION_ARTIFACT_ID" \
  --preparation-artifact-digest "$PREPARATION_ARTIFACT_DIGEST" \
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
  --output "$RUNNER_TEMP/standalone-github-publication-recovery-v1.json"
```

The writer, not the caller, derives the immutable recovery deadline as exactly
30 minutes after `first_ambiguous_at`. Artifact-backed bootstrap receives the
mutator timestamp; interrupted bootstrap obtains `first_ambiguous_at` from the
bound job's terminal/interruption timestamp through the GitHub API and applies
the same derivation. The caller cannot supply that timestamp for the interrupted
variant.

Recovery is a separate read-only job with explicit `contents: read` and
`actions: read`, the same tag concurrency group, and no environment or write
permission. It always downloads the exact preparation artifact and draft
receipt from their bound producer runs into separate fresh directories, verifies
their IDs/digests, the preparation manifest, and the receipt bytes, and resolves
authorization and evaluation paths only inside the preparation download; no
evidence input path may resolve to the checkout. For an artifact-backed origin it
also
downloads the exact mutator-result artifact
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
but recovery accepts and reports `ADOPTED` only after packaging them into the
same final closeout artifact and the reviewed evidence PR is merged and verified
on `main` as required above. Any
inconclusive, draft, missing, extra, mismatched, or non-durable state preserves
`PUBLICATION_UNKNOWN` and executes the
authorization's incident/remediation disposition when the attempt or deadline
bound is reached. Tests cover stale authorization, wrong workflow
or run binding, missing/expired/name-selected/cross-run/substituted authorization
artifacts, mismatched authorization producer workflow or artifact/file digest,
authorization bytes committed only after the target commit, substituted local
bytes, missing/name-selected/cross-run/substituted preparation artifacts,
checkout-relative evidence inputs in verification or recovery jobs,
pre-existing public/unowned releases,
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
missing or altered provenance selectors/digests in preparation, stage, draft,
expose-success, expose-ambiguity, public, and recovery records,
caller-supplied interrupted timestamps, altered or missing interrupted-origin
proof in successor records, skipped/repeated/over-limit attempt ordinals, and
refusal to publish before receipt verification. Also test refusal to expose
before the exact installation-docs PR is merged, docs-PR base/head/file-digest
substitution, direct-main-write attempts, closeout actions receiving release
credentials or executing repository code, evidence-PR extra/missing paths,
unmerged or superseded evidence PRs, merge commits not on `main`, artifact expiry
before durable closeout, and refusal to accept `ADOPTED` before the committed
closeout bundle is revalidated from the exact merge commit. Cover missing,
name-selected, cross-run, or substituted PR-payload/opener-result artifacts;
payload, instruction, manifest, or committed PR-binding digest mismatch; a
binding that names another PR/head/base or original closeout artifact; and a
privileged opener that accepts bytes outside the exact verified payload. Reject
a committed binding that claims its own head SHA, an opener result whose observed
head does not contain the named binding digest, and missing or mismatched schema
path/version/digest ownership. Apply the same cases to negative-decision
closeouts, including expired decision artifacts, omission or forbidden inclusion
of the stale authorization, a public release on the negative path, and refusal
to report `NOT_ADOPTED` before the exact evidence PR merge is revalidated. Apply
them also to threshold-failure closeouts, including a missing or substituted
platform record, a passing evaluation routed through the failure mode,
authorization/decision/release evidence on that mode, a mismatched evaluation-
digest directory, and any terminal report before the exact merged candidate is
revalidated.

Before assembling the closeout artifact, the candidate terminal writer receives
only the freshly downloaded preparation evaluation/authorization and the
current verified public receipt, never checkout-relative evidence or unverified
URL strings:

```bash
ruby packaging/tebako/write-evaluation.rb \
  --finalize-status ADOPTED \
  --input "$VERIFIED_EVALUATION_PATH" \
  --authorization-evidence "$VERIFIED_AUTHORIZATION_PATH" \
  --release-receipt "$VERIFIED_PUBLIC_RECEIPT_PATH" \
  --output "$RUNNER_TEMP/standalone-candidate-terminal-evaluation-v1.json"
```

Package that exact temporary output into the closeout artifact described above,
then publish the exact bundle through the reviewed `release-evidence` PR path.
Only after `finalize-standalone-closeout.yml` proves the exact evidence PR merge
commit on `main` may it validate the committed candidate and accept/report
terminal `ADOPTED`:

```bash
ruby packaging/tebako/validate-evaluation.rb \
  "$VERIFIED_MERGED_CLOSEOUT_EVALUATION_PATH"
```

If authorization is denied or stale before upload, write the candidate terminal
`NOT_ADOPTED` bytes from the Step 6 decision receipt and retain the evaluation
evidence without public artifacts; do not report the outcome as terminal before
the reviewed closeout below:

```bash
ruby packaging/tebako/write-evaluation.rb \
  --finalize-status NOT_ADOPTED \
  --failed-criterion "$AUTHORIZATION_FAILURE" \
  --authorization-decision "$VERIFIED_AUTHORIZATION_DECISION_PATH" \
  --input "$VERIFIED_EVALUATION_PATH" \
  --output "$RUNNER_TEMP/standalone-candidate-terminal-evaluation-v1.json"
```

The decision-closeout artifact must then pass the reviewed
`negative-decision-evidence` PR path specified in Step 6. Validate and report
only the terminal evaluation path from the exact verified merge commit:

```bash
ruby packaging/tebako/validate-evaluation.rb \
  "$VERIFIED_MERGED_NEGATIVE_CLOSEOUT_EVALUATION_PATH"
```

`AUTHORIZATION_FAILURE` is a closed enum containing only
`authorization-denied` and `authorization-stale`. Both finalization modes are
allowed only from `ADOPTED_PENDING_RELEASE_AUTHORIZATION` whose complete
platform matrix passes every threshold and has no failed criterion. A
threshold-derived candidate `NOT_ADOPTED` from Step 5 is never passed to this
authorization-decision finalization; it becomes terminal only through the
`threshold-failure-evidence` closeout and exact merged-commit validation defined
there. The writer rejects any transition from `ADOPTED` or `NOT_ADOPTED`, never
removes or overwrites prior failure evidence, and forbids release evidence on
the authorization-failure path. Tests cover the complete allowed transition
table and every rejected cross-state transition.
`ADOPTED_PENDING_RELEASE_AUTHORIZATION` is never a completion state. In both
terminal paths the writer uses a same-directory temporary file plus atomic
rename so input and output may be the same path without truncating the prior
evidence.

### Task 6: Complete package ownership and post-release audit

**Files:**

- Update release runbooks and changelogs in each repository.
- Create in each Ruby repository the exact merged
  `release/evidence/rubygems/<package>/<version>/` bundle required by
  `AW-RELEASE-RUBYGEMS-CLOSEOUT-V1`.
- Create in the dashboard repository the exact merged
  `release/evidence/npm/agent-coordination-dashboard/0.1.0/` bundle required by
  `AW-RELEASE-NPM-BOOTSTRAP-CLOSEOUT-V1`.
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
matching merged
`release/evidence/npm/agent-coordination-dashboard/0.1.0/postpublish-receipt.v1.json`.
Accept an unsupported disposition only with authenticated live capability
evidence for that exact operation; unscoped naming alone is not such evidence.
Download the registry artifact rather than trusting the prepublication copy,
freshly retrieve the authorization capture by its durable producer-run,
artifact-ID, service-digest, and file-digest receipt, then replay the verifier
with the fresh setting observation and exact expected commit/tag from that
verified artifact path:

```bash
NPM_AUDIT_DIR="$(mktemp -d)"
npm pack agent-coordination-dashboard@0.1.0 --json \
  --pack-destination "$NPM_AUDIT_DIR" > "$NPM_AUDIT_DIR/npm-pack.json"
NPM_AUDIT_TARBALL="$NPM_AUDIT_DIR/agent-coordination-dashboard-0.1.0.tgz"
node scripts/verify-npm-postpublish-receipt.mjs \
  --receipt release/evidence/npm/agent-coordination-dashboard/0.1.0/postpublish-receipt.v1.json \
  --authorization "$VERIFIED_PACKAGE_AUTHORIZATION_PATH" \
  --grant-manifest release/grants/agent-coordination-dashboard-0.1.0.v1.json \
  --tarball "$NPM_AUDIT_TARBALL" \
  --fresh-observation release/evidence/agent-coordination-dashboard-0.1.0-publishing-access-closeout.v1.json \
  --expected-commit "$(node -e 'process.stdout.write(require(process.argv[1]).commit)' "$VERIFIED_PACKAGE_AUTHORIZATION_PATH")" \
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

Record package URLs, exact versions, commits, checksums/integrities, owners,
trusted publishers, smoke evidence, known limitations, standalone decision, and
rollback instructions in the repositories' release notes. For both Ruby gems,
link the exact merged closeout PR and commit plus the durable receipt and
manifest path under `release/evidence/rubygems/<package>/<version>/`; freshly
rerun the trusted-base finalizer and require `RELEASE_COMPLETE`. A release-note
summary or expired publication-run artifact is never a substitute for those
committed evidence bytes.
For the dashboard, link both the exact merged npm bootstrap closeout PR/commit
and subsequent observation-only PR/commit, the durable postpublish receipt and
manifest paths, and the canonical fresh authenticated publishing-access
observation used by the trusted-base finalizer. Require its `RELEASE_COMPLETE`;
a maintainer-checkout receipt, workflow input, comment, or expired candidate
artifact is not terminal evidence.
For an adopted standalone release, link the exact merged installation-docs and
release-evidence PRs plus the immutable merge commit containing
`release/evidence/standalone/closeouts/tag-<tag>/`. A release-note summary or
expired Actions artifact is never a substitute for those committed evidence
bytes.

## Plan Completion Gate

- Canonical names are published only as useful packages and only after separate explicit release approvals.
- Registry owners, MFA, OIDC publishers, tags, commits, and checksums are verified.
- Public clean-install and cross-stack smoke pass.
- No underscore alias or dashboard Ruby gem exists.
- The self-contained executable has a recorded `ADOPTED` or `NOT_ADOPTED` verdict against fixed criteria.
- Source-pack installation remains pinned to repository library bytes and works independently of registry availability.
