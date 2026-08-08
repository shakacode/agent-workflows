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

At `origin/main` commit `ee4729c`, this repository contains 118 Ruby files and
75,064 lines of Ruby. Runtime code accounts for 23,737 lines in 35 command
files, while 48,257 test lines remain in 63 files. The largest production
commands include:

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

Ruby require paths and constants use underscores and CamelCase:

```ruby
require "agent_workflows"
AgentWorkflows

require "agent_coordination"
AgentCoordination
```

The project will not publish underscore aliases such as `agent_workflows` or
`agent_coordination`. It will not publish a dashboard Ruby gem. Alias and
placeholder packages would split documentation, create permanent security and
ownership surface, and conflict with the registries' anti-squatting intent.

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
  organization ownership when supported;
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
  configuration/
  git/
  github/
  trust/
  doctor/
  seam/
  security/
  batch/
  merge/
  audit/
  distribution/
  maintainer/
  cli/
```

The boundaries mean:

- `cli`: parse options, invoke an application object, render a result, return an
  integer; never own domain policy;
- `process`: bounded subprocess execution, process-group cleanup, and closed
  environment construction;
- `git` and `github`: transport adapters and typed transport errors;
- `configuration`: safe file loading and validated policy values;
- domain folders: policy, parsing, state transitions, and domain-specific
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

The initial gem declares Ruby `>= 3.2`, matching the existing package-ready
Agent Coordination gem. CI tests the lowest supported Ruby and the current
project Ruby. Raising the floor requires a documented compatibility decision.

The initial runtime dependency set is the Ruby standard library only. A new
runtime gem dependency requires a security, license, installation, and
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
a fallback. Missing, partial, or version-mismatched libraries exit `64` with a
concise actionable diagnostic.

## Testing Strategy

1. Characterization tests freeze each legacy CLI contract before extraction.
2. Unit tests exercise parsers, policies, and state transitions directly.
3. CLI contract tests cover argv, environment, channels, and exit status.
4. Integration tests use bounded fake `git`, `gh`, and child processes.
5. Packaging tests build and install the gem into an isolated gem home.
6. Installer tests cover source, copy, symlink, flat, plugin-companion, missing
   library, partial library, rollback, and offline cases.
7. Differential tests run legacy and extracted implementations against the
   same non-mutating corpus until each cutover.
8. Linux CI and a recorded macOS smoke validate platform-specific packaging.
9. The repository's `bin/validate` remains the canonical aggregate gate.

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
count. Tests move with their behavior rather than accumulating in a final
cleanup PR.

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
source revision. Copy mode stages and validates one immutable complete runtime,
then changes one current-generation pointer while preserving the prior
generation for rollback. Symlink mode atomically selects the explicit editable
clone and intentionally exposes later source edits while still validating path,
manifest, and compatibility boundaries. Any cleanup failure is reported
explicitly rather than reclassifying a partial install as success.

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
