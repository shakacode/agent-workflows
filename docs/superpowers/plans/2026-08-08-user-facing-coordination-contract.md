# User-Facing Coordination Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Agent Workflows one deterministic user-facing ownership and action-routing contract across active PR work, walkthroughs, cross-task requests, heartbeat wakeups, and closeout.

**Architecture:** Add one canonical user-facing document, keep a compact operational copy in the PR workflow, and make each skill reference or enforce that contract at its own boundary. Use one cross-workflow Minitest contract plus the existing Goal Mode and walkthrough tests to prevent semantic drift.

**Tech Stack:** Markdown workflow/skill contracts, Ruby 3 Minitest contract tests, Bash validation entrypoint, existing Agent Workflows helper gates.

## Global Constraints

- The current task is the sole user-facing coordinator.
- Internal workers are owned by the current task and are never described as separate chats.
- External tasks may request actions but never acquire ownership.
- Automations wake the current task and never own work or authority.
- Preserve security preflight, claim fencing, typed dependencies, exact-head CI/review, QA, autonomous eligibility, merge assurance, and guarded submission.
- Do not restore project-level signing, trust anchors, launch receipts, or hard model/effort routing.
- Do not create a user-visible task unless the user explicitly requests it.

---

### Task 1: Canonical ownership model and action router

**Files:**

- Create: `docs/user-facing-coordination.md`
- Create: `skills/pr-batch/bin/user-facing-coordination-contract-test.rb`
- Modify: `docs/README.md`
- Modify: `skills/pr-batch/SKILL.md`
- Modify: `workflows/pr-processing.md`
- Modify: `bin/validate`

**Interfaces:**

- Consumes: the approved ownership definitions and ordered routing rules in `docs/superpowers/specs/2026-08-08-user-facing-coordination-design.md`.
- Produces: canonical sections named `Ownership Model`, `Deterministic Action Router`, `New-Task Prompt`, and `Ambiguity Guard`, plus a cross-workflow test entrypoint.

- [ ] **Step 1: Write the failing ownership and router contract tests**

Create `skills/pr-batch/bin/user-facing-coordination-contract-test.rb` with the following foundation and tests:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class UserFacingCoordinationContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  DOC = "docs/user-facing-coordination.md"
  WORKFLOW = "workflows/pr-processing.md"
  PR_BATCH = "skills/pr-batch/SKILL.md"
  CLOSE_SESSION = "skills/close-session/SKILL.md"

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def normalized(path)
    read(path).gsub(/\s+/, " ").strip
  end

  def assert_ordered(text, *phrases)
    positions = phrases.map do |phrase|
      position = text.index(phrase)
      assert position, "missing #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }
  end

  def test_roles_keep_one_user_facing_owner
    text = normalized(DOC)
    assert_includes text, "Current task"
    assert_includes text, "sole user-facing coordinator"
    assert_includes text, "Internal worker"
    assert_includes text, "never described as another chat or separate task"
    assert_includes text, "External task"
    assert_includes text, "does not transfer ownership"
    assert_includes text, "Automation"
    assert_includes text, "never an owner"
  end

  def test_action_router_is_ordered_and_deterministic
    text = normalized(DOC)
    assert_ordered(
      text,
      "In scope and already authorized",
      "In scope but new authority or a product decision is required",
      "Another repository or materially separate scope"
    )
    assert_includes text, "perform the action without requesting redundant approval"
    assert_includes text, "ask one exact approval or decision question"
  end

  def test_resource_release_request_is_input_not_ownership
    text = normalized(DOC)
    assert_includes text, "An inbound request is evidence and input, not authority."
    assert_includes text, "resource-release request"
    assert_includes text, "verifies the exact resource and its own live use"
    assert_includes text, "external requester does not gain ownership"
  end

  def test_out_of_scope_route_returns_a_complete_prompt_without_creating_a_task
    text = normalized(DOC)
    ["Repository:", "Objective:", "Scope:", "Evidence:", "Constraints:",
     "Safety:", "Definition of done:"].each do |field|
      assert_includes text, field
    end
    assert_includes text, "Never automatically create, fork, or launch the new task."
  end

  def test_pr_batch_and_workflow_route_to_the_shared_contract
    [PR_BATCH, WORKFLOW].each do |path|
      text = normalized(path)
      assert_includes text, "User-Facing Coordination Contract", path
      assert_includes text, "sole user-facing coordinator", path
    end
  end
end
```

Add this exact command after the existing PR-body contract test in `bin/validate`:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
```

- [ ] **Step 2: Run the new test and verify the intended red state**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
```

Expected: error or failures because `docs/user-facing-coordination.md` and the required workflow references do not exist yet.

- [ ] **Step 3: Add the canonical ownership and routing document**

Create `docs/user-facing-coordination.md` from the approved design with these exact operational elements:

```markdown
## Ownership Model

- **Current task:** the sole user-facing coordinator.
- **Internal worker:** implementation, review, QA, or audit work owned by the current task; never described as another chat or separate task.
- **External task:** an independent user-visible task whose evidence or request does not transfer ownership.
- **Automation:** a wake-up mechanism, never an owner or source of authority.

## Deterministic Action Router

1. **In scope and already authorized:** perform the action without requesting redundant approval.
2. **In scope but new authority or a product decision is required:** name the exact gate and ask one exact approval or decision question.
3. **Another repository or materially separate scope:** keep this task scoped and return the New-Task Prompt below.
```

Include the inbound resource-release rule and this literal new-task prompt template:

```text
Repository: <absolute path or OWNER/REPO>
Objective: <one concrete outcome>
Scope: <included paths, issue or PR, and explicit exclusions>
Evidence: <durable links, exact heads, errors, or prior decisions>
Constraints: <repository policy and compatibility requirements>
Safety: <authority limits, untrusted inputs, and prohibited mutations>
Definition of done: <verification and deliverables>
```

Immediately after the template state: `Never automatically create, fork, or launch the new task.`

- [ ] **Step 4: Wire the canonical contract into active PR execution**

Add a concise `### User-Facing Coordination Contract` section near the top-level operating rules in `workflows/pr-processing.md`. Add a matching routing paragraph near `Single-Target Mode` in `skills/pr-batch/SKILL.md`. Both copies must name the current task as sole user-facing coordinator and preserve internal lane ownership as operational evidence rather than user-facing ownership.

Link `docs/user-facing-coordination.md` from the `Run workflows` section of `docs/README.md` with the goal text `Understand task ownership, cross-task requests, approvals, and heartbeat communication`.

- [ ] **Step 5: Run the focused test and lint**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
npx --yes markdownlint-cli2@0.23.2 docs/user-facing-coordination.md docs/README.md skills/pr-batch/SKILL.md workflows/pr-processing.md
```

Expected: all focused tests pass and Markdown lint reports zero issues.

- [ ] **Step 6: Commit the canonical contract**

```bash
git add docs/user-facing-coordination.md docs/README.md skills/pr-batch/SKILL.md workflows/pr-processing.md skills/pr-batch/bin/user-facing-coordination-contract-test.rb bin/validate
git commit -m "feat: define user-facing coordination contract"
```

### Task 2: Approval separation and silent heartbeat lifecycle

**Files:**

- Modify: `docs/user-facing-coordination.md`
- Modify: `workflows/pr-processing.md`
- Modify: `skills/pr-batch/SKILL.md`
- Modify: `skills/plan-pr-batch/SKILL.md`
- Modify: `skills/triage/SKILL.md`
- Modify: `skills/plan-pr-batch/scripts/check_goal_prompt_size.rb`
- Modify: `skills/pr-batch/bin/user-facing-coordination-contract-test.rb`
- Modify: `skills/pr-batch/bin/goal-completion-contract-test.rb`
- Modify: `skills/pr-batch/bin/autonomous-merge-contract-test.rb`

**Interfaces:**

- Consumes: existing `GMCC-v3`, autonomous merge eligibility, merge assurance, repository submission policy, and `merge_authority` semantics.
- Produces: an `HST-v1` cleanup extension, exact approval-field separation,
  silent no-change wakeups, material notifications, and automatic monitor
  cleanup while preserving `GMCC-v3` verbatim.

- [ ] **Step 1: Add failing approval and heartbeat scenarios**

Append these tests to `UserFacingCoordinationContractTest`:

```ruby
def test_readiness_separates_four_authority_facts
  text = normalized(DOC)
  assert_ordered(
    text,
    "Technical readiness:",
    "Ownership:",
    "Repository submission policy:",
    "Merge authority:"
  )
end

def test_existing_autonomous_authority_acts_without_a_merge_prompt
  text = normalized(DOC)
  assert_includes text, "technically ready and autonomously eligible"
  assert_includes text, "merge without asking the user to perform the authorized mechanical action"
end

def test_exact_head_human_gate_asks_one_final_question
  text = normalized(DOC)
  assert_ordered(text, "full exact head SHA", "sorted gate set", "rollback status", "one final question")
end

def test_no_change_heartbeat_is_silent_and_self_deleting
  [DOC, WORKFLOW, PR_BATCH].each do |path|
    text = normalized(path)
    assert_includes text, "no-change wake", path
    assert_includes text, "no user-visible notification", path
    assert_includes text, "material state change, a required decision, a durable blocker, or completion", path
    assert_includes text, "delete", path
    assert_includes text, "gate clears or becomes durably terminal", path
    assert_includes text, "automation never owns", path
  end
end
```

- [ ] **Step 2: Run the scenarios and verify they fail**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
```

Expected: new approval and heartbeat assertions fail while Task 1 assertions remain green.

- [ ] **Step 3: Implement the approval split in every user-facing closeout path**

Add an `Approval And Readiness` section to `docs/user-facing-coordination.md` and concise matching rules in `pr-batch` and the Coordinator Closeout Lane. Require these four labeled facts in readiness or approval communication:

```text
Technical readiness: <exact-diff gate evidence>
Ownership: current task
Repository submission policy: <required|allowed|not authorized>
Merge authority: <none|ask|auto_merge_when_gates_pass> plus exact-head eligibility
```

State separately that repository-authorized branch/commit/push/PR publication proceeds without another question; autonomous merge proceeds only when ordinary gates, exact-head eligibility, and merge assurance pass; exact-head human approval names the SHA, sorted gates, rollback status, and durable decision needed before asking one final question.

- [ ] **Step 4: Preserve `GMCC-v3` and extend canonical `HST-v1`**

Keep the existing compact `GMCC-v3` line byte-for-byte on every generation
surface. In particular, retain these clauses verbatim:

```text
auto=>exact verdict/head/sorted-gates/rollback; merge iff autonomous-merge-eligible OR human-approved-for-current-head+durable-decision(proven-human+merge-authority); else ready-human-review-required|autonomous-merge-evidence-unknown; merge+close PR/target/issue.
```

Extend `HST-v1` and the shared user-facing contract so they explicitly say:

- no-change wakeups produce no user-visible notification;
- only material change, required decision, durable blocker, or completion notifies;
- the monitor is deleted after gate clear or durable terminal state;
- automation never owns the task; and
- `blocked-user-input` uses no monitor and preserves one exact question.

Add exact regression assertions for the complete `GMCC-v3` line. Reuse the
existing HST fixture and mutation coverage; do not change prompt constants or
accept renamed or abbreviated merge-authority clauses.

- [ ] **Step 5: Run Goal Mode, autonomous merge, prompt-size, and focused tests**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
ruby skills/pr-batch/bin/goal-completion-contract-test.rb
ruby skills/pr-batch/bin/autonomous-merge-contract-test.rb
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```

Expected: all commands pass, generated surfaces retain the exact `GMCC-v3`
contract and `HST-v1` remains the single heartbeat translation policy.

- [ ] **Step 6: Commit approval and heartbeat behavior**

```bash
git add docs/user-facing-coordination.md workflows/pr-processing.md skills/pr-batch/SKILL.md skills/pr-batch/bin/user-facing-coordination-contract-test.rb skills/pr-batch/bin/goal-completion-contract-test.rb
git commit -m "feat: route approvals and heartbeat updates precisely"
```

### Task 3: Tracked close-session consumer and ambiguity guard

**Files:**

- Create: `skills/close-session/SKILL.md`
- Create: `skills/close-session/agents/openai.yaml`
- Modify: `docs/user-facing-coordination.md`
- Modify: `skills/pr-batch/SKILL.md`
- Modify: `workflows/pr-processing.md`
- Modify: `skills/pr-batch/bin/user-facing-coordination-contract-test.rb`

**Interfaces:**

- Consumes: the installed close-session baseline and the shared ownership/router contract.
- Produces: a source-pack-owned close-session skill and the exact four-line ambiguity guard.

- [ ] **Step 1: Add failing close-session and ambiguity tests**

Append:

```ruby
def test_ambiguity_guard_synthesizes_ownership_without_raw_events
  text = normalized(DOC)
  assert_ordered(text, "Current task:", "Internal workers:", "External tasks:", "Next:")
  assert_includes text, "Do not append raw cross-task messages"
  assert_includes text, "backend events"
  assert_includes text, "worker transcripts"
end

def test_close_session_consumes_the_shared_model
  text = normalized(CLOSE_SESSION)
  assert_includes text, "User-Facing Coordination Contract"
  assert_includes text, "current task remains the sole user-facing coordinator"
  assert_includes text, "An internal worker is not another user-visible task."
  assert_includes text, "External tasks and automations do not gain ownership."
  assert_includes text, "delete obsolete heartbeat automations"
end
```

Run the focused test and expect failure because the source-pack close-session skill and ambiguity language are absent.

- [ ] **Step 2: Adopt and update close-session**

Copy the installed close-session skill structure into the repository, retaining its authority/safety, live-state verification, durable capture, archive gate, and exact final `Conversation status:` lines. Add a `## User-Facing Coordination` section that applies the shared contract during closeout.

The section must say that the current task remains coordinator, internal workers are summarized as owned roles, external messages are bounded requests only, obsolete heartbeat automations are deleted, and out-of-scope work receives a copy-paste prompt rather than automatic task creation.

Create `skills/close-session/agents/openai.yaml` with:

```yaml
interface:
  display_name: "Close Session"
  short_description: "Close work cleanly and preserve durable context"
  default_prompt: "Use $close-session to verify this task, capture durable outcomes, and decide whether it is ready to archive."
```

- [ ] **Step 3: Add the ambiguity guard to active and closeout surfaces**

Add the exact compact format to the shared doc, PR workflow, pr-batch Coordinator Closeout Lane, and close-session:

```text
Current task: <responsibility and scoped outcome>
Internal workers: <owned implementation/review/QA/audit roles or none>
External tasks: <request or evidence role only, ownership did not transfer, or none>
Next: <current-task action or exact required decision>
```

Follow it with a prohibition on raw cross-task messages, backend events, heartbeat logs, worker transcripts, and claim telemetry.

- [ ] **Step 4: Run focused and metadata validation**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
ruby bin/validate-openai-agent-metadata-test.rb
ruby bin/validate-openai-agent-metadata
npx --yes markdownlint-cli2@0.23.2 skills/close-session/SKILL.md docs/user-facing-coordination.md skills/pr-batch/SKILL.md workflows/pr-processing.md
```

Expected: all contract, picker metadata, and Markdown checks pass.

- [ ] **Step 5: Commit the close-session consumer**

```bash
git add skills/close-session/SKILL.md skills/close-session/agents/openai.yaml docs/user-facing-coordination.md skills/pr-batch/SKILL.md workflows/pr-processing.md skills/pr-batch/bin/user-facing-coordination-contract-test.rb
git commit -m "feat: adopt task-wide coordination in close-session"
```

### Task 4: Preserve interactive walkthrough ownership and approval return

**Files:**

- Modify: `skills/pr-walkthrough/SKILL.md`
- Modify: `skills/pr-walkthrough/bin/pr-walkthrough-contract-test.rb`
- Modify: `docs/user-facing-coordination.md`

**Interfaces:**

- Consumes: exact diff identity, one-concept walkthrough pacing, and the current task's merge-authority route.
- Produces: explicit current-task ownership during walkthrough and an exact return-to-coordinator boundary after human understanding is established.

- [ ] **Step 1: Write the failing walkthrough integration test**

Append this test:

```ruby
def test_walkthrough_is_an_internal_current_task_phase_not_a_new_owner
  skill = File.read(SKILL).gsub(/\s+/, " ")
  phrases = [
    "The current task remains the sole user-facing coordinator.",
    "The walkthrough is an internal explanatory phase, not another task or owner.",
    "Present exactly one conceptual change per response.",
    "return control to the current task",
    "ask its one final merge decision separately"
  ]
  positions = phrases.map do |phrase|
    position = skill.index(phrase)
    assert position, "expected #{phrase.inspect}"
    position
  end
  positions.each_cons(2) { |before, after| assert_operator before, :<, after }
end
```

Run `ruby skills/pr-walkthrough/bin/pr-walkthrough-contract-test.rb` and expect the new assertions to fail.

- [ ] **Step 2: Add the walkthrough ownership boundary**

Add concise ownership language before the walkthrough map. Keep `Present exactly one conceptual change per response`, the explicit pause, exact diff refresh, and separate approval wording unchanged. At closeout, say `return control to the current task`; do not characterize that transition as cross-task coordination.

- [ ] **Step 3: Run walkthrough and shared contract tests**

Run:

```bash
ruby skills/pr-walkthrough/bin/pr-walkthrough-contract-test.rb
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
```

Expected: both suites pass and the ordering proves ownership is established before conceptual steps and approval remains separate afterward.

- [ ] **Step 4: Commit walkthrough integration**

```bash
git add skills/pr-walkthrough/SKILL.md skills/pr-walkthrough/bin/pr-walkthrough-contract-test.rb docs/user-facing-coordination.md
git commit -m "docs: keep walkthrough ownership with the current task"
```

### Task 5: Changelog, full verification, independent review, and PR publication

**Files:**

- Modify: `CHANGELOG.md`
- Verify: every file changed since `origin/main`

**Interfaces:**

- Consumes: all green focused tests and final exact branch diff.
- Produces: a validated, independently reviewed branch and a human-first PR containing before/after examples.

- [ ] **Step 1: Add the user-facing changelog entry**

Under `### [Unreleased]` → `#### Changed`, add:

```markdown
- **Give each user-visible task one explicit coordinator across internal workers, external requests, walkthroughs, and heartbeat wakeups; route existing authority without redundant prompts, ask one exact question for new authority, generate prompts for separate scope, and keep no-change monitors silent and self-cleaning.**
```

- [ ] **Step 2: Run targeted contract suites**

Run:

```bash
ruby skills/pr-batch/bin/user-facing-coordination-contract-test.rb
ruby skills/pr-batch/bin/goal-completion-contract-test.rb
ruby skills/pr-batch/bin/autonomous-merge-contract-test.rb
ruby skills/pr-walkthrough/bin/pr-walkthrough-contract-test.rb
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```

Expected: zero failures and zero errors.

- [ ] **Step 3: Run the repository-required full validator**

Run:

```bash
bin/validate
```

Expected: final line `PASS agent-workflows validation`.

- [ ] **Step 4: Commit the changelog and any validation-only corrections**

```bash
git add CHANGELOG.md
git commit -m "docs: record user-facing coordination behavior"
```

- [ ] **Step 5: Run the required independent autoreview gate**

Use the repository's `autoreview` skill against `origin/main...HEAD`. Verify every finding against the actual diff. Apply only confirmed in-scope fixes, rerun affected tests, and repeat review until no actionable finding remains.

- [ ] **Step 6: Re-run exact-head validation after review changes**

Run:

```bash
git diff --check origin/main...HEAD
bin/validate
git status --short --branch
git rev-parse HEAD origin/main
```

Expected: diff check clean, validator passes, worktree clean, and exact SHAs are recorded for the PR.

- [ ] **Step 7: Push and open the human-first PR**

Push `codex/user-facing-coordination-contract` and open a PR against `main`. The visible PR body must include:

- why user-facing ownership was confusing;
- the four-role ownership model;
- the three-route action router;
- approval-field separation;
- silent/self-cleaning heartbeat behavior;
- before/after examples for internal work, inbound resource release, redundant publication approval, exact-head human approval, and no-change heartbeat;
- targeted and full validation evidence; and
- the preserved security, dependency, review, QA, merge-assurance, and no-signing boundaries.

- [ ] **Step 8: Monitor the initial exact-head PR state**

Fetch the live PR head, checks, review cohort, and unresolved threads. Report technical readiness, current-task ownership, repository submission policy, and merge authority separately. Do not ask for merge or merge the PR because this task authorizes PR publication but does not grant merge authority.
