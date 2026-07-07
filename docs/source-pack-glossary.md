# Source Pack Glossary

Canonical vocabulary for distribution, seam, readiness, review, and
state-machine terms in this source pack. Keep batch coordination terms in the
root [CONTEXT.md](../CONTEXT.md).

## Language

**Source Pack**:
The shared `agent-workflows` repository that supplies portable skills,
workflows, helpers, and validation.
_Avoid_: plugin when referring to the whole repository before a native plugin
manifest is involved.

**Consumer Repo**:
A repository that uses the Source Pack while keeping its own policy in
`AGENTS.md`, `.agents/bin/`, and `.agents/agent-workflow.yml`.
_Avoid_: downstream when the important distinction is ownership of repo policy.

**Agent Workflow Configuration Seam**:
The `AGENTS.md` pointer section plus the Consumer Repo's repo-owned workflow
contract files.
_Avoid_: plugin settings, global config.

**Host Installer Path**:
The existing `bin/install-agent-workflows --host <host>` route that installs
skills, workflows, helper binaries, and metadata into a Codex or Claude home.
_Avoid_: legacy path.

**Native Plugin Path**:
A host-specific plugin manifest route, such as a Codex plugin manifest, that
exposes Source Pack skills through the host's plugin mechanism.
_Avoid_: universal plugin path.

**Workflow Lessons Library**:
A lightweight, curated `docs/solutions/` area for reusable Source Pack workflow
failure modes and fixes.
_Avoid_: full compounding system, session memory.

**Readiness Vocabulary**:
The canonical human-facing state language for planning and batch handoffs, with
optional machine-readable blocks where automation needs them.
_Avoid_: mandatory JSON contract for every user-facing plan.

**Review Finding**:
A shared structured record for actionable or advisory review output across
review and audit skills.
_Avoid_: per-skill finding shapes with later ad hoc mapping.

**State-Machine Fixture**:
A deterministic test fixture that models a GitHub or git workflow state and its
expected transition.
_Avoid_: broad prose-only hardening.

## Relationships

- A **Source Pack** can be installed through a **Host Installer Path** or a
  **Native Plugin Path**.
- A **Consumer Repo** owns exactly one canonical **Agent Workflow Configuration
  Seam**.
- The **Native Plugin Path** and **Host Installer Path** are separate delivery
  routes; choose the route that supplies the helper binaries, metadata, and host
  behavior the repo needs.
- The **Workflow Lessons Library** captures portable Source Pack lessons, not
  Consumer Repo domain policy.
- The **Readiness Vocabulary** must preserve explicit `UNKNOWN` states and must
  not collapse them into ready or blocked.
- A **Review Finding** schema can be adopted incrementally, but the shape should
  be shared from the first implementation.
- The first **State-Machine Fixture** target is `autoreview` target selection;
  broader batch and current-head readiness fixtures come later.
## Flagged Ambiguities

- "plugin" can mean the Codex-native manifest surface or the entire Source
  Pack. Resolved: use **Native Plugin Path** for host plugin manifests and
  **Source Pack** for the repository as a whole.
- `docs/solutions/` could mean a broad knowledge system or a small curated
  library. Resolved: use **Workflow Lessons Library** for the lightweight
  curated form.
- "machine-readable readiness contract" could mean mandatory JSON in every
  planning output. Resolved: define a **Readiness Vocabulary** first and keep
  structured blocks optional unless a workflow explicitly needs automation.
- "structured review output" could mean each skill emits its own JSON shape.
  Resolved: define one shared **Review Finding** schema and adopt it
  incrementally.
- "state-machine hardening" could target the whole batch workflow at once.
  Resolved: start with `autoreview` target selection fixtures.
