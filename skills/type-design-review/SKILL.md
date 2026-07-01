---
name: type-design-review
description: Review changes to data models, signatures, domain types, parsing, or casts so invalid domain states are represented as little as possible.
---

# Type Design Review

Use this as a focused review lens when a diff adds or changes data models,
function signatures, domain types, parsing/validation boundaries, casts, or
state machines.

The central question: what states does this type allow, and which of those does
the domain forbid? A permitted-but-forbidden state is a review finding when it
is realistically reachable, would cause a real bug or repeated defensive checks,
and can be prevented with a reasonably small type change.

## Review Questions

1. **Impossible states.**
   - Are mutually exclusive states modeled as independent booleans or optional
     fields?
   - Could success and error, loading and loaded, present and absent, or two
     incompatible modes be represented at once?
   - Would a tagged union, sum type, enum-with-data, or explicit state object
     make the domain shape clearer?

2. **Parse, do not merely validate.**
   - Does validation return `true`, `false`, or `void` and then throw away the
     proof?
   - Can boundary input be parsed into a narrower type that callers carry
     inward?
   - Does the repo already use a parser/schema library that should be reused?

3. **Primitive confusion.**
   - Are domain identifiers, units, currencies, paths, or statuses plain strings
     or numbers that can be mixed up?
   - Would a branded, opaque, wrapper, or language-native newtype prevent a real
     class of mistakes?

4. **Unsafe assertions and nullability.**
   - Did the diff add unchecked casts, `as any`, non-null assertions, or
     equivalent escape hatches?
   - Is there a nearby runtime check, parser, or control-flow narrowing that
     justifies the assertion?

5. **Exhaustiveness.**
   - Do switches, matches, or conditionals over closed states fail at compile
     time when a new state is added?
   - If the language supports exhaustive matching, is the code using it?

6. **Derived vs duplicated state.**
   - Are count, index, selected item, cache, or status fields stored separately
     from the source that defines them?
   - Can the code derive one from the other to remove desynchronization?

## Proportionality

Do not add type ceremony for free text, throwaway locals, or combinations the
domain genuinely permits. The finding must name the invalid state it prevents.
If every represented state is valid, the type is already precise enough.

Do not recommend a new dependency just to satisfy this review. Prefer an
existing parser/schema tool when the repo already uses one; otherwise suggest a
small local constructor or guard.

## Output

For each finding, include:

- smell: impossible state, lost parse proof, primitive confusion, unsafe
  assertion, missing exhaustiveness, or duplicated state
- invalid state that is currently representable
- location
- concrete restructuring
- severity: `BLOCKER`, `SHOULD`, or `NIT`

If the diff has no type-design issue, say that clearly and leave correctness,
simplicity, and test coverage to the general review workflow.

## Source Note

Inspired by the type-design review lens in
[lucasfcosta/backpressured](https://github.com/lucasfcosta/backpressured),
adapted here as portable seam-driven workflow guidance.
