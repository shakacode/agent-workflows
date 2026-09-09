# Trusted Provenance And Fail-Closed Decisions

Trusted provenance answers a simple question: **Where did the evidence for this
decision come from?** A fail-closed rule answers the next question: **What must
happen when that origin cannot be verified?**

These concepts matter because an agent can read repository content, run tools,
push code, and sometimes merge changes. A green-looking result is not enough
when the content being evaluated can also influence the command that produced
the result.

This document explains the threat model behind
[issue #513](https://github.com/shakacode/agent-workflows/issues/513) and
[PR #523](https://github.com/shakacode/agent-workflows/pull/523). It does not
claim that the PR or its test fixtures are malicious. The project uses inert
negative controls to verify that unsafe inputs are detected without executing
them.

The threat model and the implementation are separate questions. A reachable
trust-boundary failure can be worth fixing while a particular fix is still too
large, too coupled, or too expensive to maintain. Security review must evaluate
both.

## Provenance Does Not Mean Proof

The words are easy to associate, but *provenance* does not come from the English
word *prove*. It comes through French *provenir* from Latin *provenire*, which
means to come forth or originate. See
[Merriam-Webster's word history](https://www.merriam-webster.com/grammar/usage-of-province-providence-provenience-provenance).

In engineering, provenance records origin and history. A provenance record does
not prove that an artifact is safe. It gives the system facts that it can verify:

- which repository and PR produced the change;
- which exact head and merge commits were evaluated;
- which trusted base contained the merge result;
- which policy and executable produced the evidence;
- which paths and risks the decision covered.

Proof is the verification performed over those facts. Provenance is the chain
of custody that makes verification possible.

## What Trusted-Base Provenance Means Here

The security preflight normally treats a changed workflow, script, hook, or
agent instruction as high risk. That default is correct before the change is
accepted. It becomes less useful after the exact change has already been merged
into a trusted base.

Issue #513 adds a narrow way to recognize that history. The helper can accept
the `high-risk-files` finding only when it can bind this complete chain:

```text
trusted policy
  -> authenticated repository remote and base ref
  -> freshly fetched base commit
  -> exact same-repository PR head and merge commit
  -> proof that the merge commit is an ancestor of the base
  -> receipt naming every accepted high-risk path
```

The receipt is not a general approval. It does not waive suspicious text,
untrusted actors, incomplete API evidence, fork mismatches, or another review
finding. A manual acknowledgment also remains separate and target-specific.

## Why A Green Result Can Be Untrustworthy

### Example 1: the repository replaces the verifier

Assume a workflow runs `gh api ...` to confirm that a PR was merged by a trusted
maintainer. The shell searches `PATH` and finds `bin/gh` in the repository before
the installed GitHub CLI.

A hostile shim can print the JSON that the workflow expects. The JSON can say
that the PR is merged, comes from the correct repository, and has the expected
commit. Every parser check can pass because the parser received a convincing
lie.

The required control is small and direct: resolve the trusted executable before
the security-sensitive read, canonicalize its path, reject candidates inside
the repository or temporary directories, and reuse that exact executable for
the full decision. This is the executable-provenance finding raised during PR
#523 review.

### Example 2: approval belongs to an older head

A reviewer approves commit `A`. The author then pushes commit `B`. CI for `B`
passes, but the approval still refers to `A`.

If the workflow combines the old approval with the new CI result, no person or
process reviewed the state being merged. Exact-head binding prevents evidence
from different versions from being assembled into a false green decision.

### Example 3: the API result is incomplete

An API returns the first 100 timeline entries but reports that another page
exists. The missing page contains an unresolved review or an actor whose
identity cannot be verified.

Treating the partial result as complete is a fail-open decision. A fail-closed
workflow records coverage as incomplete and stops until it can fetch and verify
the remaining evidence.

### Example 4: the base moves during verification

The helper fetches the protected base, evaluates a PR, and prepares a receipt.
Meanwhile, another merge moves the base branch.

The older result may still be correct for the commit it examined, but it does
not describe the current base. The receipt therefore includes the base commit,
and a dependent action must refresh the evidence after base movement.

### Example 5: a clean checkout hides local influence

Git configuration, attributes, filters, hooks, and ignored files can affect how
a checkout is inspected. A simple `git status` result does not prove that the
bytes used as trusted policy match the fetched base.

The trusted-base check compares tracked content as raw bytes and isolates Git
configuration for provenance operations. The objective is not to defend
against every Git feature. It is to prevent local, target-controlled behavior
from certifying itself.

## What Fail-Closed Means

A fail-open system interprets missing evidence as permission to continue. A
fail-closed system preserves the restriction until it obtains positive,
current evidence.

| Condition | Fail-open result | Fail-closed result |
| --- | --- | --- |
| A required API page is unavailable | Assume the visible page is complete | Mark coverage `UNKNOWN` and stop |
| The base changed after validation | Reuse the previous result | Re-evaluate the new base and head |
| REST and GraphQL report different SHAs | Pick one | Reject the inconsistent evidence |
| The trusted executable cannot be resolved | Fall back to `PATH` | Keep the high-risk blocker |
| A review finding has no disposition | Treat it as advisory noise | Require fix, rejection with rationale, or explicit acceptance |

Fail-closed does not mean “nothing can ever proceed.” It means the safe default
is preserved while required evidence is absent or contradictory.

## Avoiding Security Theater And Over-Engineering

The concern about over-engineering is valid. A security control can cost more
than the risk it reduces. Extra branches and duplicated checks can also create
new defects.

Use these questions before adding a control:

1. Can the untrusted target influence the evidence or tool used to grant a real
   capability?
2. Would a failure permit a push, merge, secret read, external message, or other
   consequential action?
3. Is the unsafe path reachable with the actual repository and runner model?
4. Can one boundary remove the class of failure instead of adding many special
   cases?
5. Can positive and negative controls verify the boundary without pinning
   incidental implementation details or exact prose?

The `PATH` example clears this bar. Repository content can influence executable
selection, the executable supplies merge-authority evidence, and one pinned
executable boundary closes the path.

PR #523's size also deserves scrutiny. At the September 9, 2026 review point,
GitHub reported roughly 9,200 added lines across 56 commits. Size does not prove
that the design is wrong, especially when many additions are negative controls.
But it does shift the burden of proof: a large security mechanism that saves an
occasional manual acknowledgment must show that its operational benefit exceeds
its review cost, maintenance cost, and new attack surface. If a smaller design
can preserve the core repository, commit, base, ancestry, and tool-provenance
bindings, prefer it.

By contrast, testing an exact sentence in documentation does not protect a
behavior. It makes harmless editing harder and should be replaced with a
structural or behavioral assertion. PR #523 received that review feedback too.
That is a useful reminder: fail-closed security should be precise, not
ceremonial.

## A Practical Policy

Fail closed for facts that authorize consequential actions:

- repository, target, branch, and exact commit identity;
- permission and merge authority;
- required CI and unresolved review state;
- provenance of security-sensitive tools and policy;
- completeness and consistency of evidence.

Keep other controls configurable and proportional:

- which actors a repository trusts;
- which paths receive high-risk treatment;
- which test suites a change requires;
- whether a finding needs a one-time acknowledgment or durable policy.

Drop a proposed control when it has no reachable capability path, duplicates an
existing boundary, cannot be tested meaningfully, or adds more ambiguity than
it removes.

## The Standard

The goal is not mathematical proof or zero risk. The goal is a defensible
decision:

> Know where the evidence came from, bind it to the exact action, and do not
> convert missing knowledge into permission.

That standard becomes more important as agents perform more work in parallel.
Each individual edge case may be unlikely. The integration system still needs
a small set of reliable boundaries because one false authorization can have a
large blast radius.
