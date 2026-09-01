# Structural Code Smells

Detailed catalog for `structural-review`. Load this when a candidate finding
needs the full test. Each entry has: the symptom, the test that separates a
finding from a preference, and the shape of the restructuring to propose.

Every entry assumes the review has already pinned the fixed point and read the
changed files in full. All thresholds are generic baselines — a repo-local
convention documented in `AGENTS.md` or the policy it names overrides them.

---

## 0. Be Ambitious About Structural Simplification

**Symptom.** The change adds a branch, a mode, a helper, a flag, or a layer
that the diff then has to keep consistent with everything around it.

**Test.** Ask: what would have to be true for this thing to not exist at all?
If the answer is a change the author can plausibly make (resolve a value
earlier, push a decision to the caller, delete the other branch, pick one of
two modes), the ambitious restructuring is the finding. If the answer is "the
domain genuinely has two cases", there is no finding.

**Restructuring shape.** Name what disappears. Good structural findings read
"if X is resolved at the boundary, these three call-site checks stop existing",
not "consider extracting a helper".

**Not a finding.** A rearrangement that moves the same complexity somewhere
else. Splitting a 40-line method into four 10-line methods that are only ever
called in sequence adds names without removing anything.

---

## 1. File Size

**Symptom.** A change pushes a file past roughly 1000 lines, or adds
substantially to a file that is already well past it.

**Test.** Evaluate the **post-change total**, not the lines added. A 12-line
addition to a 1400-line file is in scope; a 600-line new file that is one
cohesive unit usually is not. Then ask whether the file has more than one
reason to change — a file is too big when it has accumulated distinct
responsibilities, and length is the detectable proxy.

**Restructuring shape.** Name the split, along a seam that already exists in
the file: a group of methods that share private state, a mode that is switched
on at the top, a family of cases, a layer that leaked in. "Split this file" is
not actionable; "these six methods only touch the serialization state and move
together" is.

**Severity note.** This is one of only two standards that can reach `P1`, and
only when the growth was avoidable and unjustified. If the author states a
reason (a generated file, a single cohesive state machine, a pending split
tracked elsewhere), it is at most `P2`.

---

## 2. No Random Spaghetti Growth

**Symptom.** A new conditional, early return, or special case is dropped into a
flow that has nothing to do with the feature being added.

**Test.** Would a reader of that flow, who does not know about this feature,
understand why the branch is there? If the branch only makes sense with
knowledge from another part of the system, its placement is the problem. Count
the existing special cases in the same method — a fifth ad-hoc branch is
evidence the method has become a dumping ground regardless of whether the fifth
one is correct.

**Restructuring shape.** Move the decision to where the feature actually lives:
resolve it at the boundary, pass a resolved value, dispatch on a type, or give
the flow a single explicit extension point instead of accumulating branches.

**Not a finding.** A condition that belongs to the flow it sits in, even if the
flow is long. This standard is about placement, not about the count of `if`s.

---

## 3. Clean The Design, Do Not Just Accept Working Code

**Symptom.** The change works by adapting to an awkward existing structure —
re-deriving a value the caller already had, re-checking a condition that was
already checked upstream, or adding a second source of truth because the first
was inconvenient to reach.

**Test.** Is the awkwardness in the *new* code caused by a structure the same
diff could reasonably fix? If yes, that is the finding. If the awkward
structure is large, pre-existing, and out of scope, record it as a `P3`
follow-up rather than demanding the change grow.

**Restructuring shape.** Fix the cause at its own boundary, not the symptom at
the call site. Be explicit about scope: say whether the fix belongs in this
change or in a follow-up.

**Not a finding.** Pre-existing mess the diff merely touches. Review the change,
not the file's history.

---

## 4. Prefer Direct And Boring Over Magical

**Symptom.** Thin abstractions and indirection introduced by the change:

- a wrapper that only forwards arguments to one callee
- an interface, base class, or protocol with exactly one implementation and no
  named second one coming
- a configuration value, registry, or lookup table that exists so the code can
  avoid naming the thing directly
- metaprogramming, dynamic dispatch, or reflection where a direct call would do
- a callback or hook with one registration site

**Test.** Does the indirection buy a *stated* second case, a testing seam that
is actually used, or an ownership boundary that actually holds? One caller and
no named second case means it is speculative structure.

**Restructuring shape.** Inline it. The finding is "call the thing directly and
delete the wrapper", with the count of callers as evidence.

**Not a finding.** Indirection required by a framework, an existing repo
pattern, or a boundary the repo documents.

---

## 5. Type And Boundary Cleanliness (Structural Consequence Only)

`type-design-review` owns representable invalid states and wins on any diff
that adds or changes data models, signatures, domain types, parsing boundaries,
casts, or state machines. This entry covers only the structural residue.

**Symptom.** A boundary is so loosely typed that every call site re-derives or
re-defends the same facts:

- untyped bag parameters where each caller reaches for different keys
- optional or nullable values that every call site immediately checks the same
  way
- casts or escape hatches repeated at several call sites
- silent fallbacks (`|| default`, rescue-and-continue) that paper over an
  unclear invariant, so each caller invents its own recovery

**Test.** Count the call sites performing the same defensive work. Duplicated
defense across three or more sites is the structural finding. If the sharper
statement is "this type permits a state the domain forbids", stop and route it
to `type-design-review`.

**Restructuring shape.** Resolve once at the boundary and pass the narrowed
value inward, so the repeated checks have nothing left to check.

---

## 6. Keep Logic In The Canonical Layer

**Symptom.** Domain or business logic appears in a layer that exists for a
different reason: controllers, views, templates, serializers, migrations,
scripts, config files, test helpers, or workflow definitions.

**Test.** Where does the repo already keep this kind of rule? If an equivalent
rule lives in a service, model, or domain module and this one does not, that is
the finding. If the repo has no canonical location for it, say so and propose
one rather than asserting a violation.

**Restructuring shape.** Move the rule to the canonical layer and leave the
outer layer calling it. Name the existing sibling that establishes the
convention — that is the evidence.

**Severity note.** This is the second standard that can reach `P1`, and only
when the misplacement was avoidable and the author gave no reason. Layer
placement is exactly the kind of drift that gets expensive later, so it earns
severity that a stylistic concern does not.

---

## 7. Feature Flags Must Not Become Permanent Branching Debt

**Symptom.** A flag, kill switch, environment check, or rollout toggle added by
the change.

**Test.** Any one of these makes it a finding:

- three or more conditional sites read the same flag
- there is no named cleanup path — no issue, no removal condition, no stated
  "delete both branches when X"
- flag conditions nest inside other flag conditions, so the code has a
  combinatorial number of live paths
- the flag guards a data write, so the two branches can leave the system in
  states that disagree

**Restructuring shape.** Collapse the reads to one decision point at the
boundary and pass the resolved behavior inward; state the removal condition
explicitly; never nest flags. A flag with one read site and a named removal
condition is fine and needs no finding.

---

## 8. Orchestration Shape (Sequencing And Atomicity Only)

`benchmark-verification` owns every claim about measured speed. This entry may
never assert that something is slow.

**Symptom, sequencing.** Independent work written as a forced sequence: a loop
that performs one unrelated operation per item, a chain of steps where no step
consumes the previous step's output, work serialized only because it was
written in that order.

**Symptom, atomicity.** A multi-step state change with no atomic boundary: two
writes that must both land, a write plus an external call, a cache updated
separately from its source, with a visible window where a failure leaves the
system half-updated.

**Test.** For sequencing, trace the data dependencies — if step N does not
consume step N-1's result, the sequence is structural, not required. For
atomicity, name the concrete failure window: what state exists if the process
dies between the two steps, and who observes it.

**Restructuring shape.** For sequencing: state that the steps are independent
and can be expressed as a batch or a single round trip. For atomicity: name the
transaction, idempotency key, or single-write restructuring that removes the
window.

**Not a finding.** "This could be faster." That is
`benchmark-verification`'s question and requires baseline-vs-patched evidence
this review does not have. Route it and record the routing.

---

## Anti-Findings

Do not report these. They waste the review's credibility and belong to another
owner:

- formatting, naming, import order, comment style — linters and formatters own
  these, and CI already blocks them
- test presence or quality — the repo's test policy owns this
- correctness bugs — `autoreview` owns these; if the review finds one, hand it
  over rather than restyling it as a structural concern
- speculation about future requirements that nobody has stated
- restructurings whose payoff is smaller than the churn they cause
- a preference between two equally direct expressions of the same structure
