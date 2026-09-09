# Skill input

A skill invocation is an entry point, not a requirement to memorize arguments.
This contract applies to required choices in every skill in this pack, including
choices without an `argument-hint`. It governs missing input; each skill still
owns its operations, scope, validation and authority rules.

## Resolve choices before action

- First reuse explicit choices and authorization from the current request and
  applicable conversation context. Do not ask the user to repeat them. A picker
  default prompt or a skill's internal default is not a user-selected mode.
- When an unresolved mode, target, scope or authority changes what the skill
  would do, ask immediately, before starting that work. A bare skill name must
  not silently select preparation, recovery, execution, merge or deployment.
  Optional tuning with a safe documented default does not need an interview.
- Use the host's multiple-choice question UI when it is available and permitted
  for that kind of question. Otherwise use the host's permitted plain-text
  question path; include numbered choices only when that host allows them.
  Never use a plan-only, optional-input-only or preference-only tool for a
  required decision or approval it cannot collect. If the host only permits
  one direct question, ask that question and wait for the answer.
- Use plain-language outcomes as labels, usually two or three choices. Explain
  the consequence briefly; show internal argument names only when useful.
  Recommend an option when context supports it, without submitting it for the
  user. Permit a free-text answer through the host UI or chat.
- Distinguish user choices from discoverable implementation details. Once the
  user has selected an operation and scope, inspect available state to recover
  missing record paths or task IDs before asking for them. Missing bookkeeping
  alone must not trigger another argument interview.
- Ask only for missing decisions needed by the next stage. Group closely
  related questions when supported; do not dump every possible parameter.
  For a missing target, offer only candidates actually established in context
  or ask for its URL/name. Do not invent targets to populate a menu.
- An unanswered question, timeout, dismissed picker or preselected option is
  not a choice or authorization. Keep dependent work stopped. Continue only
  independent work that does not choose or enact one of the pending options.
- An explicit instructions-only request returns examples, not a live interview
  or execution. A fully specified request proceeds without a redundant menu.

## Examples

| Invocation and context | First response |
| --- | --- |
| Bare restart skill, phase unknown | Ask whether to recover after restart, prepare before restart, or recover this task only; do not pause tasks. |
| Restart skill after “I already installed the update” | Select recovery from that statement; ask only which tasks or machine if scope is unresolved. Never begin preparation. |
| Bare PR-batch with known targets but no merge authority | Ask whether to stop with PRs ready, ask before merging, or merge when the required gates pass. Wait before worker launch. |
| PR-batch with targets and explicit merge authority | Reuse those values; ask only for any other required missing choice. |
| Review skill with one unambiguous current PR | Use that PR; no menu solely because a positional argument was omitted. |
| Fleet recovery on a named host, no manifest or checkpoint | Discover interrupted parent candidates from that host; preserve active tasks; ask only about an unresolved consequential choice. |
| Any choice dismissed without an answer | Leave the dependent action unstarted. |

These instructions guide the agent's behavior. They do not install a native
argument form or guarantee that every host has interactive buttons.
