# Using Matt Pocock Skills With Agent Workflows

Use a selected, versioned set of [Matt Pocock's skills](https://github.com/mattpocock/skills)
for interviews, domain modeling, and debugging. Keep Agent Workflows responsible
for delivery: scope acceptance, lane ownership, execution, verification, review,
and shipping. Compose these techniques through an explicit handoff.

## Recommended installation model

Keep two independently managed sources:

| Source | Owns | Update route |
| --- | --- | --- |
| Agent Workflows | Its skills, helpers, workflows, and install metadata | Existing host installer or native `scw` plugin route |
| Matt Pocock skills | Selected upstream skills and their dependencies | A pinned upstream checkout installed with the skills CLI |

Use the same upstream commit, selected skill names, and installer version on
every machine. Record those choices in your existing configuration repository;
keep personal machine inventories and private paths in private configuration.
Recreate each machine's installation from that record rather than synchronizing
entire Claude or Codex homes. Markdown skills do not need a different version
for different Apple Silicon generations; host tools and dependencies still need
to be available on each machine.

For consistent Claude/Codex selection, prefer the
[skills CLI](https://github.com/vercel-labs/skills) global symlink installation:
one canonical copy under `~/.agents/skills`, with Claude links under
`~/.claude/skills`. Codex [discovers `~/.agents/skills` and follows skill
symlinks](https://developers.openai.com/codex/skills/). Avoid adding another copy
of those same skills under `~/.codex/skills`.

Leave Agent Workflows in its existing delivery mode. Flat Agent Workflows
installs can coexist with distinct third-party skill names. Native `scw` users
retain their plugin plus `plugin-companion` assets; see
[Installation And Upgrades](installation-and-upgrades.md). Neither
`upgrade-agent-workflows` nor its status helper manages Matt's source revision
or establishes that the third-party installation is healthy.

Matt also offers a Claude plugin. That is a valid alternative for users who
want its full bundle and host-managed updates, but do not install both that
plugin and flat copies of Matt's skills in the same Claude profile. The
selected installation above makes it easier to use the same subset and revision
across hosts. Plugin namespaces distinguish names; they do not resolve two
workflows claiming the same job.

## Choose skills and resolve overlaps

The table below was checked against upstream commit
[`3cca18b368ae95cdbdebbff572ccafa662551015`](https://github.com/mattpocock/skills/tree/3cca18b368ae95cdbdebbff572ccafa662551015).
It is a compatibility snapshot, not a promise about future releases.

| Upstream skill | Use alongside Agent Workflows |
| --- | --- |
| `grill-me` + `grilling` | Explicit interview before accepting scope |
| `grill-with-docs` + `grilling` + `domain-modeling` | Interview and updates to the consumer repo's existing glossary/ADR structure |
| `diagnosing-bugs` | Bounded reproduction, diagnosis, and fix inside the assigned worktree; return evidence to the owning workflow |
| `tdd` | Keep Agent Workflows `tdd` as the active implementation; omit upstream `tdd` |
| `triage` | Keep Agent Workflows `triage` as the active inventory/batch entry point; omit upstream `triage` |
| `implement`, `to-spec`, `to-tickets`, `wayfinder`, `code-review` | Omit from the default subset: these overlap execution, publishing, planning, or review ownership |
| `setup-matt-pocock-skills` | Optional, deliberate consumer-repo configuration; review its proposed edits against the existing seam |

Start with the first three rows, including their named dependencies. This is a
small curated subset, not a compatibility endorsement of the entire catalog.
Inspect references and helper files whenever adding another skill.

Two names currently collide directly with this pack: `tdd` and `triage`.
Codex does not merge skills with the same `name`; both can appear in selectors.
Check YAML frontmatter names as well as directory names, all active plugin
surfaces, and project-local skills. A renamed folder alone is not a namespace.
Do not rely on search order to pick the intended provider.

Older installs may contain `diagnose` or `zoom-out`; neither name exists in this
upstream snapshot. Review the old text before replacing it, and choose whether
to retain it as a separately owned local skill or retire it. Do not assume
installing the new catalog removes obsolete skills.

## Install and update across machines

Before an installation or update:

1. Inventory `~/.agents/skills`, `~/.claude/skills`, legacy
   `~/.codex/skills`, project skill roots, and enabled plugins. Resolve links and
   identify each skill's actual owner. Inspect the skills CLI lock records and
   Agent Workflows `.agent-workflows-install.json` separately.
2. Back up locally edited skills outside discovered skill roots. A stale skills
   CLI record for `tdd` does not prove it owns the current Agent Workflows file.
   Inspect removal behavior before using an old manager's remove command on a
   path now owned by another provider; reconcile the stale record without
   deleting the other provider's files.
3. Review and record the upstream full commit SHA, selected skills and dependency
   list, and an exact skills CLI version. Use a clean checkout at that SHA.
4. Install the same selection on each machine, first reviewing the installer's
   destination/overwrite summary. Do not use `--all`, a wildcard selection, or
   unattended overwrite approval when migrating an existing installation.

For example, after setting `MATT_SKILLS_CHECKOUT` to that clean pinned checkout
and `SKILLS_CLI_VERSION` to the reviewed installer version:

```bash
git -C "$MATT_SKILLS_CHECKOUT" rev-parse HEAD
git -C "$MATT_SKILLS_CHECKOUT" status --short
npx "skills@$SKILLS_CLI_VERSION" add "$MATT_SKILLS_CHECKOUT" --list
npx "skills@$SKILLS_CLI_VERSION" add "$MATT_SKILLS_CHECKOUT" \
  --global --agent claude-code codex \
  --skill grill-me grilling grill-with-docs domain-modeling diagnosing-bugs
```

Use the installer's symlink option. Keep your explicit commit/selection record:
the CLI's generated lock file is installation metadata, not a substitute for
that reproducible configuration, especially for local-path sources.

To upgrade, review the difference from the recorded commit to a proposed new
commit, including dependencies and invocation metadata. Reinstall the reviewed
selection from that checkout and repeat verification. An unrestricted
`skills update` follows upstream updates; it is not this pinned rollout. Roll
back by restoring the prior checkout, selection, and any backed-up local
adaptations, then checking discovery again. Reconcile retired dependencies
explicitly; reinstalling an older selection need not remove newer files.

After installation, on **each host on each machine**:

- Confirm the same selected files and supporting resources by content hashes,
  plus the intended Claude symlink targets. Confirm `tdd` and `triage` still
  resolve to Agent Workflows and that obsolete copies are absent or deliberately
  retained under distinct ownership.
- Start a fresh session and inspect the skill picker/catalog. Check each
  selected skill appears once and dependencies can be loaded. Restart Codex if
  discovery is stale; reload Claude plugins when using its plugin route.
- In a disposable consumer checkout, explicitly invoke `grill-me` for an
  interview and `grill-with-docs` for one glossary decision. On Codex, use the
  tool adaptation below. Confirm output and any edits stay within that request.
- Run a small debugging example with `diagnosing-bugs`; verify it returns the
  reproduction and fix evidence to the owning Agent Workflows task. Run the
  normal Agent Workflows status/seam checks separately.

A matching lock file or successful install is insufficient evidence that both
hosts can execute the selected skills.

## The adapter is a handoff contract

Keep upstream files intact. Put this small integration policy in the consumer
repo's `AGENTS.md`, and ensure Claude's `CLAUDE.md` reads the same policy when
both files exist:

```markdown
## Complementary skills

Agent Workflows owns accepted scope, lane/worktree ownership, worker dispatch,
verification, review gates, and shipping. Selected Matt Pocock skills provide
bounded interview, domain-modeling, and diagnosis techniques within that flow.
Use Agent Workflows for tdd and triage. Return findings and test evidence to the
owning workflow before delivery continues.

Use this repo's existing Agent Workflow Configuration, command wrappers, and
policy. Preserve its canonical glossary/ADR paths and terminology. Check the
destination repository's purpose and visibility before saving documents.

When upstream instructions request Claude's Skill tool on a host without that
tool, load the named dependency's SKILL.md from the installed catalog and apply
it within the same bounded request. Do not invent a tool or silently skip the
dependency. If it is missing, report the missing installation.
```

This tool adaptation addresses a concrete portability seam: at the pinned
revision, `grill-me` asks for the Skill tool to load `grilling`, and
`grill-with-docs` asks for `grilling` plus `domain-modeling`. Their
`agents/openai.yaml` files also carry explicit-invocation policy; preserve those
files when installing. Runtime discovery and execution still need verification
on both hosts.

Use an explicit handoff, for example:

```text
Use grill-with-docs to resolve the open requirements and record the agreed
terms in this repo's canonical docs. Stop at the accepted requirements and
open questions. Then pass that artifact to Agent Workflows spec/plan-pr-batch;
Agent Workflows will own any authorized implementation and delivery.
```

Do not run upstream setup blindly in an adopted repo. It writes an `Agent
skills` section and tracker/domain documents, prefers `CLAUDE.md` when present,
and detects triage by its name. That can mistake Agent Workflows `triage` for
Matt's triage. If setup is needed, constrain its draft to the selected skills,
preserve `Agent Workflow Configuration`, avoid an unused second triage label
scheme, and ensure both agents can find the resulting policy. Domain modeling
must respect the repo's existing `CONTEXT.md` contract rather than replacing
an established document structure wholesale.

## When to build more

A generic text merge cannot decide which provider owns shipping or whether an
upstream dependency changed meaning. Avoid concatenating `SKILL.md` files or
patching installer-managed copies in place.

If repeated use demonstrates a missing integration, add one narrowly scoped
adapter with a distinct skill name, declared upstream revision/dependencies,
explicit input/output and mutation boundaries, and a host portability check.
Keep personal adapters in private configuration and domain adapters in their
consumer repo. A shared adapter belongs here only after its portable use case
is demonstrated. Preserve upstream licensing for substantial copied material.
This guide does not add an adapter engine, installer, or automatic conflict
resolver.
