# Writing Good Tests

Use this reference when writing or materially changing tests, mocks, or test
helpers.

## Name the break

Before writing a test body, name one realistic production break it should catch:
a wrong branch, value, or argument; a missing side effect; a boundary or
validation failure; or an empty or default result. Record the break in the test
plan, test name, or another reviewable note before writing the body.

If the only answer is an intentional source or private-structure change,
redesign the test around observable behavior. Reject constant and
private-structure change detectors when consumer-visible behavior can be tested.

## Derive expectations independently

Use literal expected values or independently hand-checked fixtures when
practical. Do not compute an expected value through the implementation or helper
under test. The only exception is an explicitly named characterization test
backed by independent evidence for the existing behavior.

Keep the expected result visible in the test. A builder, loop, or helper that
repeats production logic can preserve the same defect on both sides of the
assertion.

## Separate behavior from source invariants

Exact source, text, path, or mirror checks prove only source or packaging
invariants. They cannot prove runtime behavior or that an agent follows prose.
Classify these checks honestly and do not market them as behavioral proof.

When scripts, configuration, skills, or prompts claim behavior coverage,
execute the artifact or pressure-test its consumer when practical. Assert
outputs, side effects, exit status, or consuming-agent behavior. If no practical
harness exists, document why and capture the closest useful manual or local
before-and-after evidence. A source invariant can still protect required text,
paths, links, or generated mirrors, but it stays a source or packaging check.

## Keep the behavior real

Preserve the real side effects needed by the behavior under test. Mock only
slow or external boundaries. Use realistic and complete doubles that include
the fields and branches the real dependency supplies. The existence of a mock
is not behavioral proof; assert the real component's consumer-visible result.

If a mock hides a state write, callback, validation, or other required effect,
move the mock to the slower or external boundary below that effect. Prefer a
real component when the double becomes more complex than the behavior being
tested.

## Run a bounded mutation check

Before completion, choose a small, finite set of realistic failure modes for
the changed behavior. Examples include a wrong branch, value, or argument; a
missing side effect; an empty or default result; and missing boundary or input
validation. Confirm that the relevant test fails for each selected mode at the
same behavior assertion, then restore the correct implementation. Do not require
mutation-testing software.

Deleting a searched substring and then asserting that the substring is absent
is not this check. It is tautological because deletion guarantees the absence
assertion. It exercises no artifact or consumer, so it proves only how the
source mutation was constructed.

## Attribution

Material in this reference is substantially adapted from Superpowers v6.2.0's
[Writing Good Tests](https://github.com/obra/superpowers/blob/44c9b2d6e889982ac18c27d05a19fefe335194e1/skills/test-driven-development/writing-good-tests.md)
at commit `44c9b2d6e889982ac18c27d05a19fefe335194e1`, licensed under the MIT
License. The full copyright and permission text is retained in the
[third-party notice](../../THIRD_PARTY-NOTICES.md). The upstream document is
reviewed source material only. This guidance does not install, execute, or
depend on Superpowers at runtime.
