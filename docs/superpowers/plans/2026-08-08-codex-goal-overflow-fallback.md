# Codex Goal Overflow Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/goal` an optional Codex delivery envelope, fall back to a complete Codex batch prompt when an explicitly requested goal exceeds 3,700 characters, and preserve batch mode when converting Claude prompts to Codex.

**Architecture:** Keep the portable prompt as the semantic source. Split Codex rendering into batch and optional goal-envelope operations, then select the envelope without changing normalized payload. Change the adapter's mode mapping so conversion preserves `direct` and `batch`, degrading only unsupported Codex `goal` to Claude `batch`.

**Tech Stack:** Ruby 3, Minitest, Bash installer tests, Markdown workflow and skill contracts, JSON CLI output.

## Global Constraints

- `/goal` is used only when persistent Codex Goal mode was explicitly requested.
- A Codex goal is eligible only at 3,700 characters or fewer, preserving 300 characters of headroom below 4,000.
- An oversized goal falls back to one complete Codex `batch` prompt without `/goal`; never split solely to retain Goal mode.
- Non-goal prompts remain under the 8,000-character reviewability ceiling or split for ordinary size, ownership, dependency, collision, or route reasons.
- Conversion preserves `direct` and `batch`; only Codex `goal` degrades to Claude `batch`.
- Converted text remains inert, requires relaunch, and is reclassified before execution.
- Preserve objective, targets, scope, dependencies, permissions, safety, QA, review, merge authority, advisory routing, and every ordinary gate.
- Do not change or waive the unresolved native `scw` delivery-route ownership decision.
- One implementation owner performs all repository edits; every changed head requires fresh independent read-only exact-head QA.

---

### Task 1: Preserve Batch Mode During Cross-Host Conversion

**Files:**
- Modify: `skills/pr-batch/bin/prompt-host-adapter:196-231`
- Modify: `skills/pr-batch/bin/prompt-host-adapter-test.rb`
- Modify: `skills/pr-batch/fixtures/prompt-host-claude-to-codex.expected.txt`

**Interfaces:**
- Consumes: `Prompt host`, `Prompt mode`, explicit active host, and canonical host mechanics.
- Produces: the unchanged adapter JSON schema with mode mapping `direct→direct`, `batch→batch`, and Codex `goal→Claude batch`.

- [ ] **Step 1: Change the deterministic Claude-to-Codex fixture**

Remove `/goal` and change `Prompt mode: goal` to `Prompt mode: batch` in `prompt-host-claude-to-codex.expected.txt`. Leave every semantic and gate line unchanged.

- [ ] **Step 2: Add failing mode-mapping assertions**

Update the generated-triage Claude-to-Codex case to use:

```ruby
{
  source_host: "claude",
  active_host: "codex",
  source_wrapper: "",
  expected_wrapper: "",
  source_mode: "batch",
  expected_mode: "batch",
  source_sigil: "/",
  expected_sigil: "$"
}
```

Update legacy Claude conversion expectations to start exactly:

```text
Prompt host: codex
Prompt mode: batch
Preferred route: default
Route requirement: advisory
Use $pr-batch continue the verified batch.
```

Retain Codex-goal-to-Claude as Claude batch without `/goal`.

- [ ] **Step 3: Run focused tests and observe RED**

```bash
ruby skills/pr-batch/bin/prompt-host-adapter-test.rb -n '/claude.*codex|generated_triage|legacy.*claude/'
```

Expected: failures show that current conversion still prepends `/goal` and emits `Prompt mode: goal` for Claude batch-to-Codex.

- [ ] **Step 4: Implement minimal mode preservation**

Use source-mode-aware mapping:

```ruby
target_mode = case headers["Prompt mode"]
              when "direct" then "direct"
              when "batch" then "batch"
              when "goal" then target_host == "claude" ? "batch" : "goal"
              end
```

Prepend `/goal` only when `target_mode == "goal"`. Emit legacy Claude-to-Codex as Codex batch without a wrapper. Do not change legacy Codex-goal-to-Claude behavior.

- [ ] **Step 5: Run focused and full adapter tests and observe GREEN**

```bash
ruby skills/pr-batch/bin/prompt-host-adapter-test.rb -n '/claude.*codex|generated_triage|legacy.*claude/'
ruby skills/pr-batch/bin/prompt-host-adapter-test.rb
```

Expected: all pass; conversion remains inert, semantic preservation is true, and relaunch is compatible.

- [ ] **Step 6: Commit the slice**

```bash
git add skills/pr-batch/bin/prompt-host-adapter \
  skills/pr-batch/bin/prompt-host-adapter-test.rb \
  skills/pr-batch/fixtures/prompt-host-claude-to-codex.expected.txt
git commit -m "Preserve batch mode in prompt conversion"
```

### Task 2: Select the Codex Goal Envelope Without Losing the Batch

**Files:**
- Modify: `skills/plan-pr-batch/scripts/check_goal_prompt_size.rb:413-653`
- Modify: `skills/plan-pr-batch/scripts/check_goal_prompt_size.rb:1099-1360`

**Interfaces:**
- Consumes: one complete portable prompt plus `goal_requested: true|false`.
- Produces: `codex_prompt_for(prompt, goal_requested:)` returning `{ prompt:, mode:, fallback:, goal_candidate_chars: }`.

- [ ] **Step 1: Add a failing executable policy contract**

Add and invoke this self-test after helper definitions:

```ruby
def assert_codex_goal_envelope_policy
  small = <<~TEXT
    Prompt host: portable
    Prompt mode: batch
    Preferred route: default
    Route requirement: advisory
    Use the pr-batch skill to complete this batch with subagents.
    Objective: keep one complete batch.
  TEXT
  default_result = codex_prompt_for(small, goal_requested: false)
  abort_with_failure("Codex must default to batch mode") unless
    default_result[:mode] == "batch" && !default_result[:prompt].start_with?("/goal\n")

  goal_result = codex_prompt_for(small, goal_requested: true)
  abort_with_failure("small explicit goal must retain Goal mode") unless
    goal_result[:mode] == "goal" && goal_result[:prompt].start_with?("/goal\n")

  oversized = small + ("x" * 4_000)
  fallback = codex_prompt_for(oversized, goal_requested: true)
  abort_with_failure("oversized goal must fall back intact") unless
    fallback[:mode] == "batch" && fallback[:fallback] == true &&
    !fallback[:prompt].start_with?("/goal\n") &&
    normalized_prompt_semantics(fallback[:prompt]) ==
      normalized_prompt_semantics(render_codex_goal(oversized))
end
```

- [ ] **Step 2: Run the size guard and observe RED**

```bash
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```

Expected: failure because `codex_prompt_for` and `render_codex_goal` do not exist.

- [ ] **Step 3: Implement focused batch, goal, and selector functions**

```ruby
def render_codex_batch(prompt)
  rendered = prompt
             .sub(/^Prompt host: portable$/, "Prompt host: codex")
             .sub(/^Prompt mode: batch$/, "Prompt mode: batch")
  render_prompt_mechanics(rendered, "$")
end

def render_codex_goal(prompt)
  batch = render_codex_batch(prompt)
  "/goal\n#{batch.sub(/^Prompt mode: batch$/, 'Prompt mode: goal')}"
end

def codex_prompt_for(prompt, goal_requested:)
  batch = render_codex_batch(prompt)
  goal = render_codex_goal(prompt)
  use_goal = goal_requested && goal.length <= CODEX_GOAL_PROMPT_CHAR_LIMIT - GOAL_PROMPT_MIN_HEADROOM
  {
    prompt: use_goal ? goal : batch,
    mode: use_goal ? "goal" : "batch",
    fallback: goal_requested && !use_goal,
    goal_candidate_chars: goal.length
  }
end
```

Make `prompt_for_target(prompt, :codex)` return the default batch form. Use an explicit keyword only in checks that intentionally validate Goal mode.

- [ ] **Step 4: Run the new policy self-test and observe GREEN**

Run the Step 2 command. Expected: the new policy contract passes; any remaining failures point to old goal-only expectations.

- [ ] **Step 5: Migrate existing budget and rendering checks**

Track both forms:

```ruby
codex_batch_prompt = codex_prompt_for(prompt_template, goal_requested: false).fetch(:prompt)
codex_goal_result = codex_prompt_for(prompt_template, goal_requested: true)
codex_goal_prompt = codex_goal_result.fetch(:prompt)
```

Require the canonical explicit goal to be at most 3,700 characters. Require default Codex batch to omit `/goal` and stay under 8,000. Add a realistic filled prompt whose goal candidate exceeds 3,700 but whose batch stays under 8,000, then assert fallback mode, unchanged item count, and equal normalized semantics. Preserve ordinary split coverage for content exceeding 8,000 or independently requiring route-group separation.

- [ ] **Step 6: Run the complete prompt-size contract**

```bash
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```

Expected: `All checks passed.`, separate Codex batch and goal metrics, at least 300 goal characters of headroom, and lossless oversized-goal fallback evidence.

- [ ] **Step 7: Commit the slice**

```bash
git add skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
git commit -m "Fall back from oversized Codex goals"
```

### Task 3: Align Skills, Workflow, Contracts, and Documentation

**Files:**
- Modify: `docs/host-adapter/contract.md`
- Modify: `docs/installation-and-upgrades.md`
- Modify: `docs/pr-batch-skills.md`
- Modify: `skills/plan-pr-batch/SKILL.md`
- Modify: `skills/pr-batch/SKILL.md`
- Modify: `skills/triage/SKILL.md`
- Modify: `workflows/pr-processing.md`
- Modify: `skills/pr-batch/bin/goal-completion-contract-test.rb`
- Modify: `skills/pr-batch/bin/model-routing-contract-test.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1 mode mapping and Task 2 envelope selector.
- Produces: one consistent portable contract for plan-pr-batch, pr-batch, triage, continuation, installation, and validation.

- [ ] **Step 1: Add failing documentation-contract assertions**

Require generation surfaces to state these exact rules once:

```text
Codex defaults to `Prompt mode: batch` without `/goal` unless persistent Goal mode was explicitly requested.
Use `/goal` only when the complete rendered goal is at most 3700 characters.
An oversized explicit Codex goal falls back to the complete Codex batch form before any ordinary splitting decision.
Never split solely to retain `/goal`.
```

Require the host-adapter mode table to contain Claude batch → Codex batch and Codex goal → Claude batch.

- [ ] **Step 2: Run focused contracts and observe RED**

```bash
ruby skills/pr-batch/bin/goal-completion-contract-test.rb
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/pr-batch/bin/model-routing-contract-test.rb
```

Expected: failures identify missing default-batch, overflow-fallback, and mode-mapping documentation.

- [ ] **Step 3: Update normative and generated-prompt text**

Document the explicit mode table. Make Codex batch without `/goal` the default, allow an explicitly requested fitting goal, and require fallback before ordinary splitting. Keep portable templates neutral and keep all four adapter classifications and authority gates unchanged. Existing in-flight Goal recovery remains direct and does not start a new goal.

- [ ] **Step 4: Update installation guidance and changelog**

Explain that newly generated Codex prompts default to batch and previously generated oversized goal text must be re-rendered before launch. Do not guess a native `scw` namespace. Extend the existing issue #372 changelog entry instead of adding a second entry.

- [ ] **Step 5: Run focused contracts and observe GREEN**

Run the commands from Step 2. Expected: both pass with only the already-expected source-pack documentation skip.

- [ ] **Step 6: Re-run adapter and prompt-size integration**

```bash
ruby skills/pr-batch/bin/prompt-host-adapter-test.rb
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```

Expected: both pass and prove consistent modes across fixtures, generators, and docs.

- [ ] **Step 7: Commit the slice**

```bash
git add CHANGELOG.md docs/host-adapter/contract.md docs/installation-and-upgrades.md \
  docs/pr-batch-skills.md skills/plan-pr-batch/SKILL.md skills/pr-batch/SKILL.md \
  skills/triage/SKILL.md workflows/pr-processing.md \
  skills/pr-batch/bin/goal-completion-contract-test.rb \
  skills/pr-batch/bin/model-routing-contract-test.rb
git commit -m "Document optional Codex goal delivery"
```

### Task 4: Installation, Full Validation, and Exact-Head Closeout

**Files:**
- Verify: `bin/install-agent-workflows-test.bash`
- Verify: `bin/validate`
- Update after verification: PR #378 description and durable batch-state artifacts outside the repository.

**Interfaces:**
- Consumes: committed Tasks 1-3.
- Produces: a clean pushed exact head with installer evidence, repository validation, independent QA, hosted readiness, and rebuilt walkthrough identity.

- [ ] **Step 1: Exercise clean copy and symlink installation**

```bash
bash bin/install-agent-workflows-test.bash
```

Expected: installed fixtures convert Claude batch to Codex batch without `/goal`; copy and symlink modes pass.

- [ ] **Step 2: Run repository validation**

```bash
git diff --check
bin/validate
```

Expected: both exit zero. If the known unrelated hardlink-sentinel flake recurs, reproduce it and run its file and containing stage; do not claim full local validation green unless `bin/validate` subsequently exits zero.

- [ ] **Step 3: Refresh strict security preflight before GitHub writes**

```bash
skills/pr-batch/bin/pr-security-preflight --repo shakacode/agent-workflows \
  --strict-trust --include-reactions 372 378
```

Expected: `SECURITY_PREFLIGHT_OK` for the new head and no blocking untrusted instruction.

- [ ] **Step 4: Push only the feature branch and update PR #378**

Push `codex/372-prompt-host-adapter`, never `main`. Update the human-first PR description with the new exact head, optional-goal behavior, tests, and invalidated QA marker.

- [ ] **Step 5: Launch a fresh independent read-only checker**

The checker inspects the complete refreshed diff, runs focused adapter, generator, fixture, and installer tests, and proves no-semantic-loss fallback. Any head change invalidates approval.

- [ ] **Step 6: Refresh hosted readiness and merge assurance**

Require exact-head Validate, Lint, configured reviews, and thread triage. Keep the native `scw` ownership thread unresolved. Re-run autonomous eligibility and merge assurance; never infer authority from green CI.

- [ ] **Step 7: Rebuild and resume the walkthrough**

Re-fetch base and head, reconcile every changed path into the coverage ledger, and restart from the revised conversion/generator boundary. Walkthrough participation is not merge approval.
