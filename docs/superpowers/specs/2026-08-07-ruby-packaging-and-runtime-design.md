# Ruby Packaging And Runtime Design

**Status:** Approved direction

**Date:** 2026-08-07

## Purpose

Move Agent Workflows and Agent Coordination toward maintainable, reviewable Ruby
applications without making Ruby setup an adoption tax. Preserve the current
portable source-pack, plugin, trust, exact-head, and fail-closed behavior while
introducing conventional gems, small Ruby classes, and a distribution boundary
that can later support self-contained binaries.

This design selects Ruby for the workflow and coordination command planes,
keeps TypeScript for the dashboard, fixes public package names, and defines the
migration and release contracts. It does not authorize publishing packages or
changing runtime behavior.

## Evidence

At `origin/main` commit `ee4729c`, the tracked-file classifier finds 118 Ruby
files and 75,064 lines: 84 `.rb` files with 52,444 lines plus 34 executable or
configuration files selected by a Ruby shebang or Ruby filename convention with
22,620 lines. These categories are disjoint and reconcile to the headline
totals. The largest production commands include:

This is a point-in-time migration-priority snapshot, not a live invariant.
Before implementation begins, rerun the tracked-file classifier against the
then-current base, preserve its command and output in the implementation PR,
and revise the extraction order if the refreshed measurements materially differ.

- `bin/agent-workflow-seam-doctor`: 2,161 lines;
- `bin/push-downstream`: 2,117 lines;
- `skills/pr-batch/bin/pr-security-preflight`: 1,778 lines;
- `skills/pr-batch/bin/pr-merge-submit`: 1,489 lines;
- `skills/post-merge-audit/bin/completed-batch-publication-preflight`: 1,386 lines;
- `skills/pr-batch/bin/pr-ci-readiness`: 1,360 lines.

The existing `bin/agent_doctor` subsystem is the useful counterexample: about
1,600 lines are already divided among configuration, contract, runner,
sanitizer, orchestration, rendering, and CLI collaborators. The migration will
use this subsystem as its packaging pilot.

## Decisions

### D1. Language ownership

- Agent Workflows implementation: Ruby.
- Agent Coordination implementation: Ruby.
- Agent Coordination Dashboard server and UI: TypeScript.
- Rust: not selected for product implementation. A small native launcher may
  be reconsidered only if measured distribution failures cannot be addressed by
  the Ruby packaging paths.

Ruby is appropriate because these systems are dominated by parsing, policy,
validation, filesystem operations, Git/GitHub orchestration, and reviewable
state machines rather than CPU-intensive work. Ruby also gives the project a
credible maintainer and contributor community advantage.

### D2. Public package names

Public package names match repository and CLI branding:

| Product | Registry | Package |
| --- | --- | --- |
| Agent Workflows | RubyGems | `agent-workflows` |
| Agent Coordination | RubyGems | `agent-coordination` |
| Agent Coordination Dashboard | npm | `agent-coordination-dashboard` |

The dashboard name is intentionally unscoped to match the repository and CLI
brand and to keep the default install command discoverable. npm organizations
can manage unscoped packages and grant teams package access, so this package's
ownership proof uses the exact approved human-owner list, the verified GitHub
trusted publisher, and the exact ShakaCode organization/team access that live
authenticated capability checks support. It must not claim an
`@shakacode`-scoped package or confuse a team access row with package scope.
Moving to `@shakacode/agent-coordination-dashboard` would be a separately
reviewed package-name migration, not an implicit ownership fix.

Ruby require paths and constants use underscores and CamelCase:

```ruby
require "agent_workflows"
AgentWorkflows

require "agent_coordination"
AgentCoordination
```

The project will not publish RubyGems packages with underscore names such as
`agent_workflows` or `agent_coordination`; those remain the required Ruby
`require` paths. It will not publish a dashboard Ruby gem. Alias and placeholder
packages would split documentation, create permanent security and ownership
surface, and conflict with the registries' anti-squatting intent.

### D3. Package ownership

A name is claimed only by publishing a useful, installable release. Use a
prerelease while compatibility is still being validated; do not publish a
placeholder merely to reserve the name. Pending trusted-publisher configuration
alone is not treated as ownership.

Each public package must have:

- ShakaCode authorship and repository metadata;
- MIT license metadata matching the repository;
- MFA-required metadata where the registry supports it;
- GitHub OIDC trusted publishing;
- at least two confirmed human owners plus the appropriate ShakaCode
  organization/team ownership or access when supported, including authenticated
  capability detection and read-back for the intentionally unscoped npm
  dashboard package;
- an immutable release tag and changelog entry;
- build, install, smoke, and package-content evidence before publication.

Registry publication is a separately authorized release action. Ordinary code
or planning approval does not authorize it.

### D4. Gem and source-pack relationship

The `agent-workflows` gem is developed in this repository first. A separate gem
repository would introduce cross-repository version skew before the internal
API is stable and is therefore deferred.

The same `lib/agent_workflows/**` source is consumed in three ways:

1. RubyGems installs the conventional gem and its `exe/*` commands.
2. A source checkout runs the existing command paths through thin wrappers.
3. `install-agent-workflows` copies or symlinks the same library tree beside
   installed source-pack helpers.

The source pack never downloads an unpinned latest gem at runtime. Wrapper,
library, fixtures, and install metadata move as one compatible unit.

### D5. Stable and internal interfaces

During the migration, the stable interfaces are:

- existing command names and command paths;
- argv and environment inputs;
- stdout and stderr formats;
- JSON and durable-marker schemas;
- documented exit codes;
- mutation, authentication, timeout, provenance, and fail-closed behavior.

Internal classes under `AgentWorkflows` are private implementation details
through the `0.x` series unless a class is explicitly documented as public.
Extraction PRs do not combine behavior redesign with code movement.

### D6. Namespace and object boundaries

Shared production Ruby behavior used by repo-wide commands or multiple skills
moves under `AgentWorkflows`. Genuinely single-skill helpers remain with their
invoking skill under the repository's helper-placement rule and receive direct
tests plus the same quality thresholds. The intended gem top level is:

```text
lib/agent_workflows/
  version.rb
  errors.rb
  result.rb
  process/
  git/
  github/
  trust/
  policy/
  doctor/
  seam/
  security/
  batch/
  readiness/
  merge/
  audit/
  distribution/
  maintainer/
  cli/
```

`AgentCoordination` is the canonical public namespace for the
`agent-coordination` gem entrypoint and version. Its `0.x` compatibility release
does not claim that existing implementation classes have already moved from the
legacy `AgentCoord` namespace. The package-release implementation plan owns only
that conventional entrypoint, compatibility constant, dependency/package
contract, and installed CLI smoke for `0.1.0`. Any later implementation-class
or CLI-construction migration out of `AgentCoord` requires a separately reviewed
design in that repository and is not a prerequisite for this release.

The boundaries mean:

- `cli`: parse options, invoke an application object, render a result, return an
  integer; never own domain policy;
- `process`: bounded subprocess execution, process-group cleanup, and closed
  environment construction;
- `git` and `GitHub`: transport adapters and typed transport errors;
- configuration remains owned by the domain that validates it (`doctor`,
  `trust`, `policy`, and so on) until two real consumers justify a shared
  top-level abstraction;
- `policy`: shared closed-schema policy parsing; `readiness`: typed check/review
  evaluation and fail-closed decisions;
- other domain folders own their parsing, state transitions, and domain-specific
  results;
- `distribution`: source-pack installation, status, ownership, and drift;
- `maintainer`: ShakaCode fleet and repository-maintenance commands that are
  shipped intentionally but are not part of the portable domain API.

There is no generic `Utils` module. A shared abstraction is introduced only
after two real consumers demonstrate the same invariant.

### D7. CLI construction

Every CLI supports dependency injection without a framework:

```ruby
status = AgentWorkflows::CLI::WorkflowsDoctor.start(
  ARGV,
  env: ENV,
  input: $stdin,
  output: $stdout,
  error: $stderr
)
exit status
```

Domain objects return values or typed results. They do not call `exit`, read
global `ARGV`, or print directly. Side effects are supplied as explicit
collaborators such as a process runner, filesystem, clock, Git client, or
GitHub client.

### D8. Ruby version and dependencies

The initial Agent Workflows gem declares Ruby `>= 3.3`; Ruby 3.2 reached end of
life before this decision and is covered only by the negative launcher guard.
The existing package-ready Agent Coordination gem retains its separately owned
`>= 3.2` compatibility contract until that repository makes a coordinated
floor change. These are separate gems in separate repositories; sharing the
source-pack distribution channel does not make their runtime contracts the
same, and continued compatibility is not an endorsement of an end-of-life Ruby.
The Agent Coordination release must create a named follow-up compatibility
decision after `0.1.0`: raise the floor in its next breaking `0.x` release once
its supported downstream matrix no longer requires 3.2, or sooner if a security
or dependency constraint makes 3.2 unsafe. Agent Workflows CI tests Ruby 3.3 and
the exact current project Ruby, 3.4.6. Raising either floor requires a documented
compatibility decision.

The new `agent-workflows` gem initially uses only the Ruby standard library.
The existing `agent-coordination` package retains its separately reviewed
`base64` and `sqlite3` runtime dependencies and version bounds from the package
release plan; this rule does not remove or forbid them. Any new runtime gem
dependency in either package requires a security, license, installation, and
portability justification. Development-only dependencies may include Bundler,
Rake, Minitest, RuboCop, and coverage tooling.

### D9. Runtime distribution

Gem organization and runtime distribution are deliberately separable:

- The first migration retains the currently supported `ruby` executable
  prerequisite and improves detection and diagnostics.
- Source-pack installation vendors application library code, so users do not
  need Bundler or `gem install` to use installed skills.
- A bounded packaging evaluation builds the same gem as self-contained macOS
  and Linux executables. Tebako is the first candidate because it packages a
  Ruby runtime and gem dependencies into one executable. It is adopted only if
  repeatable builds and compatibility tests pass.
- If no self-contained packaging candidate passes, the official fallback is a
  documented compatible Ruby prerequisite, not a custom runtime downloader in
  the installer. Building and securing a private Ruby distribution is a
  separate product decision, not hidden installer behavior.
- Windows-native support is deferred because the current source pack relies on
  POSIX shell tooling. Windows through an existing Unix-compatible host is not
  represented as native support.

The language decision does not depend on the self-contained packaging spike.
The spike determines an additional delivery artifact, not the canonical source
or behavior.

### D10. Quality policy

New gem code does not inherit the repository-wide blanket complexity
disables. The gem starts with scoped, review-oriented RuboCop thresholds:

- line length: 120;
- method length: 30;
- cyclomatic complexity: 8;
- perceived complexity: 9;
- parameter lists: 5;
- class length: 250;
- module length: 300.

These are guardrails, not a reason to create meaningless classes. A local
exception requires an adjacent explanation. A generated blanket todo file is
not accepted.

Thin compatibility wrappers should normally remain below 30 lines. Test files
are split by behavior when a reviewer cannot understand the fixture, action,
and assertion without navigating unrelated cases.

## Compatibility Contract

Each migrated command must preserve:

- current source-checkout invocation;
- current skill-relative invocation;
- flat copy installation;
- plugin-companion installation;
- symlink installation;
- `agent-stack sync` colocated module behavior;
- exact stdout/stderr channel placement and exit status;
- JSON key names, marker grammar, ordering where asserted, and `UNKNOWN`
  semantics;
- timeout and descendant-cleanup behavior;
- trusted-base and runtime-provenance checks;
- offline execution after installation.

Installed wrappers must locate the library relative to their verified install
root. They must not search arbitrary checkouts, `$LOAD_PATH`, or the network as
a fallback. Missing, partial, or version-mismatched libraries exit `78`
(`EX_CONFIG`) with a concise actionable diagnostic; `64` (`EX_USAGE`) remains
reserved for invalid command-line usage.

## Testing Strategy

1. Characterization tests freeze each legacy CLI contract before extraction.
2. Unit tests exercise parsers, policies, and state transitions directly.
3. CLI contract tests cover argv, environment, channels, and exit status.
4. Integration tests use bounded fake `git`, `gh`, and child processes.
5. Packaging tests build and install the gem into an isolated gem home, then
   execute every installed command outside the source checkout.
6. Installer tests cover source, copy, symlink, flat, plugin-companion, missing
   library, partial library, rollback, and offline cases.
7. Differential tests run legacy and extracted implementations against the
   same non-mutating corpus until each cutover.
8. Linux CI runs required, separately named jobs on the Ruby 3.3 floor and the
   exact current project Ruby 3.4.6; both run the package and installer suites. A recorded
   macOS smoke validates platform-specific packaging.
9. The repository's `bin/validate` remains the canonical aggregate local gate
   and invokes isolated gem build/install tests plus source, copy, symlink,
   flat, plugin-companion, missing/partial-library, rollback, and offline
   installer scenarios. Release readiness additionally requires both exact-head
   Linux Ruby-matrix jobs and the macOS packaging smoke; a single Ruby 3.4.6 job
   cannot substitute for that matrix.

## Migration Program

The program uses branch-by-abstraction and review-sized PRs:

1. Gem scaffold and package identity.
2. Shared result/error/process primitives.
3. Doctor subsystem pilot and installer library-tree support.
4. Seam doctor extraction in parser, initializer, and validator slices.
5. Git/GitHub/trust adapters and security-preflight extraction.
6. Batch planning, dependency, routing, and readiness extraction.
7. Merge policy, assurance, and submission extraction.
8. Completed-batch audit and replay extraction.
9. Distribution and maintainer utility extraction.
10. Legacy-body removal and scoped quality-gate ratchet.
11. RubyGems release readiness and separately authorized publication.
12. Optional self-contained executable evaluation and release decision.

No PR should move multiple security-critical domains merely to reduce PR
count. An atomic domain move may mechanically update callers in other domains
only when leaving either path would create a dual-source or partial-cutover
state; those touches may change require paths, manifests, provenance identities,
and fixtures but must not move or redesign the callers' domain behavior. Tests
must prove behavioral equivalence across every touched caller. Tests otherwise
move with their behavior rather than accumulating in a final cleanup PR.

## Alternatives Rejected

### Keep splitting scripts in place

This improves file size but preserves an accidental package layout, scattered
namespaces, and installation coupling. It does not provide a standard Ruby
entrypoint or reusable library boundary.

### Rewrite the command plane in Rust

Rust would produce strong single-binary distribution but would trade away
iteration speed, Ruby community leverage, and straightforward review of
policy-heavy code. The project has no demonstrated CPU, memory, or concurrency
requirement that justifies a rewrite.

### Rewrite in Python

Python retains the runtime and packaging question while providing less project
and maintainer leverage. It does not materially simplify the domain.

### Rewrite in TypeScript

TypeScript remains right for the dashboard, but moving the command plane would
introduce Node and npm supply-chain/runtime requirements without eliminating
the packaging problem. Shared schemas and JSON contracts are sufficient for
cross-language integration.

### Publish separate gem repositories immediately

This creates release ordering, version skew, and ownership complexity before
the internal library boundary is proven. Repository separation can be
reconsidered after stable consumers and independent release cadence exist.

## Release And Rollback

Package publication is blocked until the built artifact passes content,
installation, command smoke, and source-link checks. The first publication is
a prerelease unless the release owner explicitly accepts stable-version
compatibility; neither form replaces the source-pack installer.

Every source-pack install records its application-library version and observed
source revision. Copy mode stages and validates one immutable complete runtime
on the destination filesystem, fsyncs it, and promotes it by same-filesystem
atomic rename. It then fsyncs and atomically renames one same-directory selector
descriptor before changing the current-generation pointer, while preserving the
prior generation for rollback. Symlink mode uses the same descriptor-promotion
and pointer-replacement mechanism to select the explicit editable clone. On
every invocation, before loading application code, the trusted bootstrap opens
that selected descriptor once and revalidates the canonical clone path,
manifest identity and completeness, and compatibility row. Symlink mode still
intentionally exposes source edits made after installation; it never treats an
install-time validation as permanent authorization for later invocations. Any
cleanup failure is reported explicitly rather than reclassifying a partial
install as success.

## Success Criteria

- `agent-workflows` and `agent-coordination` are the only canonical RubyGems
  package names; the dashboard is canonical on npm.
- Production Ruby behavior is organized under conventional namespaces and
  reviewable domain objects.
- Existing command and safety contracts remain byte- or schema-compatible as
  applicable.
- Installed use does not require Bundler or a network request after install.
- Missing or incompatible Ruby produces product-level guidance rather than a
  Ruby stack trace.
- The full source-pack validation passes on the lowest and current supported
  Ruby versions.
- A self-contained artifact is released only after the packaging evaluation
  proves it maintainable; failure of that evaluation does not force a language
  rewrite.

## Implementation Plans

- [Gem foundation](../plans/2026-08-07-agent-workflows-gem-foundation.md)
  establishes the package, doctor pilot, compatibility launchers, and atomic
  source-pack installation.
- [Ruby domain extraction](../plans/2026-08-07-agent-workflows-ruby-domain-extraction.md)
  migrates the remaining large Ruby command bodies in review-sized domains.
- [Package release](../plans/2026-08-07-agent-stack-package-release.md) prepares
  the two RubyGems packages, the dashboard npm package, trusted publication,
  and the bounded standalone-executable evaluation.

## Deferred Decisions

- Separating the gem into another repository.
- Promising a public Ruby API beyond documented CLI contracts.
- Windows-native support.
- Shipping a project-owned private Ruby runtime.
- Using Rust for a launcher after distribution evidence exists.
- Publishing any package or release.
