# Repository Supply-Chain Policy

Agent Workflows ships shell and Ruby helpers plus instruction files that can
cause an agent to execute commands. Treat changes to those surfaces as code
execution changes even when the file is Markdown.

## Low-friction trust boundary

Stable release promotion, not ordinary pull-request development, is the right
place for a mandatory independent human review. Automated reviews remain advisory.
They can find defects, but they do not establish that a stable release was
inspected and approved by a human maintainer.

The repository does not have a stable release channel yet. Issue
[agent-workflows#296](https://github.com/shakacode/agent-workflows/issues/296)
tracks signed, immutable `vX.Y.Z` releases; exact-ref installs and upgrades;
release receipts; and human approval bound to the exact promoted commit. Until
that ships, `main`, the native marketplaces, and the default upgrade helper are
development channels. Do not present them as human-reviewed releases.

This distinction keeps routine development fast. It also gives cautious users a
clear boundary: use the future stable channel, while maintainers who intentionally
want branch-tip changes can choose the development channel.

## Installing and upgrading today

There is no supported human-reviewed install or upgrade path today. If that
provenance is required, do not install from `main` or use the default upgrader;
wait for the immutable stable channel tracked in issue #296. A live checkout can
change while an installer reads it, so a shell recipe cannot substitute for an
immutable reviewed artifact.

For intentional development-channel use, do not pipe remote content into a
shell. Clone the expected repository, verify its `origin`, inspect the checkout
to the degree appropriate for development, and run the installer locally. The
install receipt records the source revision, but it is not a release
attestation. `upgrade-agent-workflows` fetches and fast-forwards the recorded
source branch by default; this remains convenient development behavior, not a
reviewed stable update.

Native plugin updates remain controlled by the host marketplace. Do not enable
unattended marketplace updates when you require human-reviewed provenance.

## GitHub Actions

Every external GitHub Action reference is pinned to a full commit SHA. A version
comment is documentation only; the commit SHA is the executable identity.
Dependabot proposes Action updates monthly so a maintainer can inspect the
upstream comparison and release notes, update the SHA and version comment
together, and run `bin/validate`.

After this pinning change reaches the default branch, repository administrators
can safely require full-SHA Action references. Default `GITHUB_TOKEN` permissions
should be read-only, workflows should not approve pull requests, allowed Actions
should be restricted to the reviewed set, and vulnerability alerts, Dependabot
security updates, secret scanning, and push protection should be enabled where
the repository plan supports them.
