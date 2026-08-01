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

Do not pipe remote content into a shell. Clone the expected repository, verify
its `origin`, and review the exact commit before running an installer from it.
The install receipt records the source revision; preserve it as a provenance
anchor, while remembering that a revision receipt is not a release attestation.

`upgrade-agent-workflows` fetches and fast-forwards the recorded source branch by
default. That is convenient development behavior, not a reviewed stable update.
Without a trusted released baseline, the conservative local-review fallback must
inspect the complete target tree, not merely the changes from the checkout's
current `HEAD`. This is deliberately a high-assurance opt-in path; routine
development upgrades remain unchanged.

```bash
git -C "$HOME/src/agent-workflows" fetch origin main
reviewed_sha=$(git -C "$HOME/src/agent-workflows" rev-parse --verify 'origin/main^{commit}')
empty_tree=$(git -C "$HOME/src/agent-workflows" hash-object -t tree /dev/null)
if [ -n "$(git -C "$HOME/src/agent-workflows" status --porcelain=v1 --untracked-files=all)" ]; then
  printf '%s\n' 'Refusing to upgrade from a checkout with unreviewed local changes.' >&2
  exit 1
fi
if ! git -C "$HOME/src/agent-workflows" merge-base --is-ancestor HEAD "$reviewed_sha"; then
  printf '%s\n' 'Refusing to upgrade from a checkout with local or diverged commits.' >&2
  exit 1
fi
git -C "$HOME/src/agent-workflows" show --no-patch --format=fuller "$reviewed_sha"
git -C "$HOME/src/agent-workflows" --no-pager diff --stat "$empty_tree" "$reviewed_sha"
git -C "$HOME/src/agent-workflows" --no-pager diff --no-ext-diff --no-textconv "$empty_tree" "$reviewed_sha"
# After reviewing the complete target tree, fast-forward the same checkout yourself.
git -C "$HOME/src/agent-workflows" merge --ff-only "$reviewed_sha"
if [ "$(git -C "$HOME/src/agent-workflows" rev-parse HEAD)" != "$reviewed_sha" ] ||
   [ -n "$(git -C "$HOME/src/agent-workflows" status --porcelain=v1 --untracked-files=all)" ]; then
  printf '%s\n' 'Refusing to install because the reviewed checkout changed.' >&2
  exit 1
fi
upgrade-agent-workflows --host codex --source "$HOME/src/agent-workflows" --mode copy --no-fetch
```

Native plugin updates remain controlled by the host marketplace. Do not enable
unattended marketplace updates when you require human-reviewed provenance.

## GitHub Actions

Every external GitHub Action reference is pinned to a full commit SHA. A version
comment is documentation only; the commit SHA is the executable identity.
Dependabot proposes Action updates weekly so a maintainer can inspect the
upstream comparison and release notes, update the SHA and version comment
together, and run `bin/validate`.

After this pinning change reaches the default branch, repository administrators
can safely require full-SHA Action references. Default `GITHUB_TOKEN` permissions
should be read-only, workflows should not approve pull requests, allowed Actions
should be restricted to the reviewed set, and vulnerability alerts, Dependabot
security updates, secret scanning, and push protection should be enabled where
the repository plan supports them.
