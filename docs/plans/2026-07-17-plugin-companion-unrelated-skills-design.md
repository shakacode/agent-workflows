# Plugin Companion Unrelated Skills Design

## Goal

Allow `plugin-companion` installation and repeat installation to coexist with
unrelated skills in the target agent home without weakening the fail-closed
migration guarantees introduced for legacy flat Agent Workflows installs.

## Scope

The change is limited to flat-skill inventory classification and its installer
regression coverage. It does not change native plugin discovery, ownership
proof for Source Pack skills, migration staging, rollback, metadata formats, or
ordinary flat delivery.

## State Distinction

An unrelated direct child of `<target>/skills` has different meaning depending
on the prior delivery state:

- **Fresh companion install:** no Agent Workflows metadata exists. Unrelated
  names are outside the Source Pack and must be preserved without blocking.
- **Existing companion install:** metadata records `plugin-companion`.
  Unrelated names remain outside the Source Pack and must not prevent repeat
  install, upgrade, or status checks.
- **Legacy flat migration:** metadata is absent from the delivery-mode era or
  records `flat`, and pack-managed skills are being migrated. Existing
  fail-closed ownership and transaction behavior remains unchanged, including
  refusal when unknown direct children make the migration ambiguous.

Exact Source Pack skill-name collisions remain blocking unless the legacy flat
migration can prove that they are unchanged pack-owned copies or managed
symlinks. For companion installs, collision names come from the intersection of
the current Source Pack and the verified active native plugin roots. This keeps
a companion install fail-closed when the active plugin adds a skill after the
recorded companion revision, without treating every other direct child as
pack-owned.

## Implementation

Keep the recorded revision only for proving and removing legacy flat ownership.
Seed the list of unknown-name blockers only while migrating a recorded legacy
flat installation. For fresh or already-companion states, block direct children
whose names occur in both the current Source Pack and the verified active native
plugin roots, and ignore other unrelated direct children. No unrelated path is
deleted or modified.

## Verification

Add installer-level regression cases proving:

1. Fresh Codex and Claude companion installs succeed with an unrelated skill.
2. A repeat companion install succeeds after an unrelated skill is added.
3. Unrelated skills remain byte-for-byte present and no flat Source Pack skill
   is installed.
4. The existing legacy flat migration test continues to refuse an unknown
   direct skill without mutation.
5. A companion reinstall fails without mutation when the current Source Pack
   and active native plugin add a colliding skill after the recorded install
   revision.

Follow test-driven development: observe the new regression fail before changing
production code, then run the focused delivery-state and installer suites plus
`bin/validate`.

## Local Rollout

After validation, run the companion installer from the local task worktree.
Verify the installed status and upgrade commands, the component doctor, the
master stack doctor, native plugin delivery, coordination backend, and React on
Rails seam. Do not push or merge.
