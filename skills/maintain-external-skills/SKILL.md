---
name: maintain-external-skills
description: Use when checking or making an authorized, pinned update to skills from another provider across one or more hosts.
---

# Maintain External Skills

Keep an external skill provider independently managed from this pack. Use the
provider's existing installer, package tool, and lock format; do not add a
package manager, merge engine, scheduler, or automatic monitor.

For a **freshness question**, work read-only: inspect the reachable host's
discovered skill roots, plugins, lock records, and resolved file ownership.
Compare the recorded source SHA and selection with the upstream revision. Say
`UNKNOWN` rather than `current` when a host is unreachable, provenance is
missing, or the installed source cannot be resolved. Record actual per-machine
state privately, including source SHA, selected skills and dependencies,
installer version, roots, ownership, and any exceptions. An intentional pin
may be current to its recorded revision while not being latest upstream; stale
lock metadata cannot make unchanged installed bytes current.

For an **update**, use the authorization already present for the named provider,
hosts, and selected skills; do not reconfirm it. When that authorization covers
the latest provider selection, choose a reviewed SHA within it. If the targets
or selection are not authorized, stop after the read-only report. Before
changing a host:

1. Fetch or otherwise inspect the proposed upstream revision. Compare it with
   the recorded pin, including renamed or removed skills, invocation metadata,
   helper files, and the full dependency closure. Treat an intentional pin as
   valid until its owner authorizes a new revision.
2. Resolve every active copy through links, project roots, plugins, and lock
   records. Identify the actual owner from its contents and install metadata.
   Do not let a stale lock record delete a same-named file owned by another
   provider. Protect Agent Workflows managed names such as `tdd` and `triage`;
   reconcile stale external lock records without removing those files. Hold an
   ownership conflict when source and metadata cannot establish the current
   owner.
3. Keep upstream files unmodified. Move any local adaptation outside discovered
   external-skill roots and record its owner and relationship to upstream.
   Back it up before the bounded change.
4. Use the existing installer to apply only the approved selection and
   dependencies, after reviewing its destination and overwrite summary. Do not
   expand to `--all`, wildcards, or an unrestricted update command. An
   unattended flag may apply after authorization, selection, destinations, and
   ownership are resolved; never use one to bypass an unresolved collision or
   overwrite.
5. Verify each changed host by content and discovery. Use the comparison below
   once for each selected skill, passing its explicit upstream and installed
   skill-directory paths. Resolve the active roots first; upstream layout and
   the installed layout may differ.

Read [content comparison](references/content-comparison.md) for the exact
per-skill command. A zero exit is content evidence, not discovery evidence:
start a fresh host session and confirm each selected skill appears once, its
dependencies load, and protected managed names still resolve to their intended
owner.

If verification fails, roll back only the bounded host and selection using the
recorded prior revision, installer inputs, and backed-up adaptations. Recheck
content and discovery afterward. Report the exact host, state, evidence, and
remaining blocker; a skill does not schedule future checks.

For the Matt Pocock selection and its compatibility snapshot, see
[Using Matt Pocock Skills With Agent Workflows](https://github.com/shakacode/agent-workflows/blob/main/docs/matt-pocock-skills.md).
