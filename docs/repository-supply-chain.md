# Repository Supply-Chain Policy

Agent Workflows ships shell and Ruby helpers plus instruction files that can
cause an agent to execute commands. Treat changes to those surfaces as code
execution changes even when the file is Markdown.

## Low-friction trust boundary

Stable release promotion, not ordinary pull-request development, is the right
place for a mandatory independent human review. Automated reviews remain advisory.
They can find defects, but they do not establish that a stable release was
inspected and approved by a human maintainer.

The stable channel uses protected, immutable, annotated `vX.Y.Z` tags; exact-ref
installs, updates, and rollbacks; a protected `stable-release` environment; and
a durable receipt binding independent human approval to the exact peeled
commit. Cryptographic tag signatures are not required or checked. See
[Stable Release Channel](release-channel.md).
Release operators must dispatch the workflow from that exact tag ref; the
workflow rejects a run whose workflow definition came from another commit.

This distinction keeps routine development fast. It also gives cautious users a
clear boundary: use the stable channel, while maintainers who intentionally
want branch-tip changes can choose the development channel.

## Installing And Upgrading

Stable operations name the exact tag: `install-agent-workflows --release
vX.Y.Z` and `upgrade-agent-workflows --release vX.Y.Z`. The installer verifies
and materializes the tagged tree before executing its installer. Updates and
rollbacks never select “latest” or silently cross into development.

For intentional development-channel use, do not pipe remote content into a
shell. Clone the expected repository, verify its `origin`, inspect the checkout
to the degree appropriate for development, and run the installer locally with
`--channel development`. The install receipt records the source revision, but
it is not a release attestation. Development upgrades likewise require
`--channel development`; this remains convenient development behavior, not a
reviewed stable update.

Native plugin updates remain controlled by the host marketplace. Do not enable
unattended marketplace updates when you require human-reviewed provenance.

## GitHub Actions

`skills/secure-github-actions/bin/secure-github-actions-scan` mechanically
enforces the repository policy for repository-based GitHub Actions and reusable
workflows, including nested composite actions:

- no `${{ ... }}` expression appears inside any `run:` scalar;
- YAML aliases cannot enter job or step boundaries where they could hide
  `run`, `uses`, or `secrets` content;
- reusable workflows never use `secrets: inherit`;
- every external `uses:` ref has a lowercase full 40-hex commit SHA plus a
  readable version comment; and
- every external action identity appears in the closed repo-owned
  `trusted_actions` allowlist in `.agents/agent-workflow.yml`.

A missing or malformed allowlist trusts nothing. Wildcards, refs, and subpaths
are not entries, and allowlisting an action never weakens the SHA or comment
rules. Job-level local reusable workflows must be regular non-symlink files
under `.github/workflows`. Step-level local actions must be regular non-symlink
directories with regular `action.yml` / `action.yaml` descriptors, and excluded
temporary or metadata roots cannot be referenced. For `docker://` references,
the scanner enforces digest immutability, but `trusted_actions` does not
mechanically approve the container. Maintainers must manually review the exact
registry, image, and digest. Recursive discovery scans tracked and unignored
regular descriptors, omits unreferenced ignored descriptors and excluded roots,
and separately resolves explicitly referenced ignored local actions.
`agent-workflow-seam-doctor` and `bin/validate` run this gate.

A clean mechanical result is necessary but not sufficient. Review permissions,
event triggers, untrusted checkout and execution, credential persistence,
shell/data boundaries, and third-party action behavior separately. Review
workflows as code even when the scanner is clean.

Dependabot proposes Action updates weekly in this source repository so a
maintainer can inspect the upstream comparison and release notes, update the SHA
and version comment together, review continued allowlist trust, and run
`bin/validate`. Consumer repositories make their own explicit Dependabot
decision; the read-only fleet audit does not enable or modify it.

After this pinning change reaches the default branch, repository administrators
can safely require full-SHA Action references. Default `GITHUB_TOKEN` permissions
should be read-only, workflows should not approve pull requests, allowed Actions
should be restricted to the reviewed set, and vulnerability alerts, Dependabot
security updates, secret scanning, and push protection should be enabled where
the repository plan supports them.
