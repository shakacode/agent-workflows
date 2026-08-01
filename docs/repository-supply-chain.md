# Repository Supply-Chain Policy

Agent Workflows ships shell and Ruby helpers plus instruction files that can
cause an agent to execute commands. Treat changes to those surfaces as code
execution changes even when the file is Markdown.

## Human review boundary

Automated reviews are advisory. They do not satisfy the human review boundary.
A current-head approval must come from a human collaborator other than the pull
request author, with `write`, `maintain`, or `admin` repository permission.

The protected surfaces are:

- `AGENTS.md`, `.agents/**`, `skills/**`, and `workflows/**`;
- `bin/**` and shell files anywhere in the repository;
- `.claude-plugin/**` and `.codex-plugin/**`;
- `.github/**`, including `CODEOWNERS` and workflow definitions.

`.github/workflows/human-security-review.yml` evaluates those paths from the
trusted base commit. It never checks out or executes the pull request branch.
For a protected change, it accepts only an approval bound to the exact current
head SHA. A later `CHANGES_REQUESTED` or dismissed review from the same reviewer
invalidates that reviewer's earlier approval. Renames are checked at both the
old and new path so moving a protected file cannot bypass the gate.
The trusted workflow publishes `human-security-review/exact-head` directly on
the evaluated head commit and rejects an event/live-head mismatch before review.
Because GitHub commit statuses are keyed by commit SHA rather than pull request,
the gate fails closed while two open pull requests share the same head commit.
GitHub's native required-review and code-owner rules are the immediate approval
boundary. The custom status is defense in depth: pull-request updates evaluate
immediately through `pull_request_target`, while a trusted-base five-minute
schedule and manual dispatch re-evaluate approvals. The schedule is intentional
because `pull_request_review` workflows from public forks receive a read-only
token and cannot safely publish the head status.

`CODEOWNERS` assigns the same surfaces to `@shakacode/admins`. The repository's
autonomous-merge policy independently routes them to human review, so agent
automation cannot treat them as a safe autonomous lane.

## Required GitHub settings

The checked-in gate is an auditable mechanism, but it becomes an enforcement
boundary only when the default branch ruleset is active. Configure `main` to:

- require pull requests and at least one approving review;
- dismiss stale approvals, require approval after the latest push, require code
  owner review, and require review-thread resolution;
- require the `validate` and `human-security-review/exact-head` status checks;
- prohibit deletion and non-fast-forward updates, with no routine bypass;
- default `GITHUB_TOKEN` permissions to read-only and prevent Actions from
  approving pull requests;
- require full-SHA action references and allow only GitHub-owned actions plus
  the explicitly reviewed `anthropics/claude-code-action`;
- enable Dependabot vulnerability alerts/security updates, secret scanning,
  and push protection where the repository plan supports them.

Do not enable required full-SHA references until the SHA-pinned workflow change
is present on the default branch; otherwise existing workflows will stop before
the replacement can be validated.

## Installing and upgrading

Do not pipe remote content into a shell. Clone the expected repository, verify
its `origin`, and review the exact commit before running an installer from it.
The install receipt records the source revision; preserve it as the provenance
anchor for later status and rollback checks.

`upgrade-agent-workflows` can fetch and fast-forward the recorded source before
installing it. Use that one-step mode only when the default-branch human review
and branch rules above are active and trusted. For an explicit local review,
use the two-step form:

```bash
git -C "$HOME/src/agent-workflows" fetch origin main
git -C "$HOME/src/agent-workflows" diff --stat HEAD..origin/main
git -C "$HOME/src/agent-workflows" log --oneline HEAD..origin/main
# Review the complete diff, then fast-forward the checkout yourself.
git -C "$HOME/src/agent-workflows" merge --ff-only origin/main
upgrade-agent-workflows --host codex --no-fetch
```

Native plugin updates remain controlled by the host marketplace. Do not enable
unattended marketplace updates unless that host can pin the reviewed source and
preserve its revision provenance.

## Updating workflow dependencies

Every external GitHub Action reference is pinned to a full commit SHA. Updating
one is an ordinary human-reviewed pull request: inspect the upstream comparison
and release notes, replace the SHA and version comment together, run
`bin/validate`, and retain the exact-head approval gate. A version comment is
documentation only; the commit SHA is the executable identity.
