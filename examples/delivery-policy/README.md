# Repository-Owned Validation Examples

These executable wrappers demonstrate the [delivery contract](../../docs/delivery-policy.md).
They are examples to adapt, not installed profiles or a shared command API.
Both expect real `.agents/bin/lint`, `.agents/bin/docs`, and `.agents/bin/test`
commands supplied by their repository. A missing or failing command fails the gate.

| Repository | Integration invocation | Complete promotion invocation | Impact and repair owner |
| --- | --- | --- | --- |
| `low-impact` | `.agents/bin/validate` | `.agents/bin/validate promotion` | Internal tool, small audience, reversible changes; tool maintainer repairs full-main failures. |
| `critical` | `.agents/bin/validate` | `.agents/bin/validate promotion` | Customer service with durable data; service owner repairs or authorizes rollback. |

Only the low-impact wrapper selects lint and documentation checks for edits
to its non-operational `docs/overview.md`, with a deliberately small prose
grammar. Operational instructions belong elsewhere. Code examples, unknown
files, policy or test changes, missing base evidence, and dirty trees run all
three checks. The critical wrapper always runs all three. Neither project
label alone grants a gate exemption. Repositories without these wrappers keep
their existing validation behavior; no seam setting enables them implicitly.

`EXAMPLE_BASE_SHA` and the `promotion` argument belong only to these examples.
Shared skills must use each adopting repository's documented invocation.
The caller obtains the base SHA from trusted repository or PR metadata. Run
from the candidate checkout using the wrapper extracted from that base:

```bash
policy=$(mktemp)
git show "$EXAMPLE_BASE_SHA:.agents/bin/validate" > "$policy" || exit 1
EXAMPLE_BASE_SHA="$EXAMPLE_BASE_SHA" ruby "$policy"
result=$?
rm -f "$policy"
exit "$result"
```

Use the documented `promotion` argument on the Ruby invocation for complete
candidate validation. Do not load a candidate's changed selector to qualify
itself. On first adoption, use the repository's existing complete gate until
the policy is reviewed and lands. Unknown invocations block; malformed or
unavailable base identity cannot select reduced coverage. Full local results
from a dirty tree remain diagnostic evidence, and promotion requires a clean
candidate. Current-head CI, independent review, security, and any configured
hosted runtime gate remain required outside these sample local checks.

The wrappers report phase, identities, coverage, required results, omissions,
and reasons as ordinary output. They do not count repair attempts. Existing
verification and review stopping rules own that state: reaching a stopping
boundary leaves failed checks blocking and hands them back for disposition.
Complete mainline feedback and exact-candidate promotion checks are required;
permission to merge does not authorize a release or deployment.

`bin/delivery-policy-replay-test.rb` exercises these wrappers with real sample
lint, document, and arithmetic checks in isolated repositories, including a
required failure repeated through the existing verification retry boundary.
