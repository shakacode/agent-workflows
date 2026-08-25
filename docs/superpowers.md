# Using Superpowers With Agent Workflows

Use this guide to evaluate one Superpowers technique without creating a second
delivery authority. [ADR 0004](adr/0004-compose-superpowers-inside-agent-workflows.md)
is the governing decision: Agent Workflows remains the sole orchestrator.

## Ownership Boundary

| Concern | Agent Workflows | Superpowers in a coexistence pilot |
| --- | --- | --- |
| Requirements and plan | Owns accepted scope and artifacts | May return one bounded analysis artifact |
| Lane and worktree | Owns target, claim, branch, dependencies, and isolation | Must not create, switch, or clean them |
| Execution | Owns worker dispatch and allowed mutations | May perform only the named inner technique |
| Review and verification | Owns proof, finding disposition, and final validation | Returns evidence; does not declare readiness |
| Shipping | Owns commit, push, PR, CI, merge, and closeout | Stops before the shipping tail |

Do not invoke Superpowers branch-finishing, worktree-owning, planning-to-
execution, or end-to-end subagent workflows inside an Agent Workflows lane.
The normal profile should keep the complete Superpowers plugin disabled.

## Advisory Diagnostic

Run the read-only status helper against the intended Codex home:

```bash
agent-workflows-status --host codex --json
```

The JSON `superpowers.state` field has exactly four values:

| State | Meaning | Action |
| --- | --- | --- |
| `active` | At least one recognized Superpowers catalog identity is installed and enabled | Keep Agent Workflows in control; disable the peer methodology manually outside an active lane or use only the disposable pilot |
| `installed-disabled` | A recognized identity is installed but no recognized identity is active | Normal coexistence boundary is preserved |
| `available-not-installed` | A recognized catalog entry is visible but not installed | No coexistence conflict is active |
| `UNKNOWN` | The host, catalog query, duplicate rows, status text, or catalog visibility is insufficient | Inspect host state manually; do not infer disabled or absent |

The helper checks the distinct `superpowers@openai-curated`,
`superpowers@openai-curated-remote`, and pinned-pilot
`superpowers@superpowers-dev` identities. `catalog_entries` reports the
marketplace name, the `installed_version` reported by the host CLI, and the
`catalog_version` read from the catalog manifest when available. The
host-reported installed version is not a marketplace snapshot revision. These
are observations only. The diagnostic
does not contact upstream and does not claim an upstream version. It performs no
plugin installation, enablement, disablement, removal, upgrade, or
configuration write, and an advisory state never changes the Agent Workflows
status exit code.

## Version Provenance

Keep these facts separate in every pilot report:

- **Catalog package:** the OpenAI plugins catalog manifest on 2026-08-24
  reported `5.1.3` at blob
  `c031b834dc32cee0030d21bb85c06c3acc07de80`, last changed by commit
  `c33199897758cab145bb7fdab1ca8fb1cbd9de50`.
- **Pinned upstream pilot:** Superpowers release `v6.2.0`, annotated tag object
  `0e5cc50e782429b95f933e46443898435b8b37a8`, peeled commit
  `3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9`.

Those values document this pilot, not “latest” aliases. A native marketplace
upgrade is controlled by the host and refreshes a marketplace snapshot. It is
not direct synchronization with `obra/superpowers`, and matching display names
do not prove matching content.

## Disposable Pinned Codex Pilot

The pilot must not layer onto the normal Codex home. Start from the Agent
Workflows repository checkout that you intend to evaluate, record its full
`HEAD`, and create a task-owned temporary directory:

```bash
SUPERPOWERS_PILOT_ROOT="$(mktemp -d)"
bin/install-agent-workflows \
  --host codex \
  --target "$SUPERPOWERS_PILOT_ROOT/codex"

CODEX_HOME="$SUPERPOWERS_PILOT_ROOT/codex" \
  codex plugin marketplace add obra/superpowers \
  --ref 3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9

CODEX_HOME="$SUPERPOWERS_PILOT_ROOT/codex" \
  codex plugin add superpowers@superpowers-dev
```

These commands intentionally mutate only the disposable Codex home. Before
continuing, run the repository helper against that exact directory and require
`superpowers.state: active` plus catalog metadata consistent with upstream
`6.2.0` in the pinned checkout:

```bash
bin/agent-workflows-status \
  --host codex \
  --target "$SUPERPOWERS_PILOT_ROOT/codex" \
  --source "$PWD" \
  --json
```

Use a disposable repository copy fixed at known base and head SHAs. The outer
Agent Workflows coordinator creates and owns its lane and worktree. In the pilot
prompt, name exactly one Superpowers skill and require it to return one bounded
artifact. Explicitly prohibit it from creating worktrees, dispatching workers,
committing, pushing, opening or updating a PR, merging, cleaning the lane, or
declaring the task complete. Agent Workflows then reviews the artifact, chooses
any mutation, and runs the repository's normal verification and closeout.

Do not reuse the temporary Codex home for normal work. Preserve the evidence
record first, then remove the verified task-owned temporary directory using the
normal operating-system cleanup mechanism.

## Pilot Evidence And Decision

Capture one record for the baseline and one for the selected Superpowers
technique:

- repository and exact base/head SHA;
- host and host version;
- Agent Workflows revision;
- Superpowers marketplace identity, host-reported installed version, catalog
  version,
  upstream tag, tag object, and peeled commit;
- selected Superpowers skill and exact bounded role;
- allowed and observed mutations;
- elapsed time and agent/tool usage;
- unique verified signal found by the technique;
- duplicated work, false positives, and out-of-scope suggestions;
- final Agent Workflows verification command and result; and
- one verdict: `promote`, `revise`, or `reject`, with rationale.

`promote` means adapt the proven technique into Agent Workflows with focused
repository-owned tests and attribution. It never means enabling the complete
Superpowers methodology beside Agent Workflows in the normal profile.

## Attribution

The coexistence analysis and pilot vocabulary were informed by the Superpowers
workflow and plugin metadata at commit
`3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9`. Superpowers is copyright © 2025
Jesse Vincent and licensed under the
[MIT License](https://github.com/obra/superpowers/blob/3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9/LICENSE).
No Superpowers source code is copied here. Any future substantial adaptation
must retain the applicable copyright and MIT permission notice.
