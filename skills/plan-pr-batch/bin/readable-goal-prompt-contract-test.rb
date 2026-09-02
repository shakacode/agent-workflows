#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check_goal_prompt_drift"

REPO_ROOT = File.expand_path("../../..", __dir__)
TEXT_FENCE = "```text\n"
EXPECTED_PROMPT = <<~TEXT
  Use $pr-batch to complete this batch with subagents.

  Batch title: <PROJECT> <A?> <ID?> <MM-DD HH:MM> - <title>

  Thread handle: <batch-short>-<lane>-<word>
  Lane Card:claim/PR-open/block/cancel/final;route;holder/branch/PR/phase/URLs/UNKNOWN
  Launch:<repo:<issue|pull-request>:N|repo:adhoc:date-slug>;ovr:n/a|name/auth/ref/task;none:reuse/create issue(auth/ask)+bind;invalid|dup|UNKNOWN:stop
  PF:issue/PR=security;adhoc=trusted+task-bound+durable,no-target-security
  Repo:OWNER/REPO
  Objective:...
  merge_authority:<none|ask|auto_merge_when_gates_pass>
  Batch size target: <codex|claude|generic>;wave: <cap/items>
  Coordinator model/effort preference: <model/class>/<effort>.
  Observed host/model/effort: <host|UNKNOWN>/<model|UNKNOWN>/<effort|UNKNOWN>; host-only, no inference.
  Manifest:pack_sha=<rev|UNKNOWN>;coordinator_preference=<model>/<effort>;lanes=<lane-id:dispatcher+preferred-route+observed-host/model/effort>,...;UNKNOWN=field;no guesses
  Worker model/effort preferences: <initial model/class>/<effort> -> <lane ids>; escalation <model/class>/<effort> after MODEL_ESCALATION_REQUEST; max <N>.
  Dispatch <lane>:<dispatcher>@<route>;fallback <dispatcher>@<route>->...|none;auth <y|n>;ordinary pending/active lifecycle
  - Stage deps: v1 edit|validation_open|merge_order; missing/UNKNOWN/stale=>closed; combined-tip@repo-seam
  GMCC-v5:CI@head/configured-reviewers pending|missing|untriaged|failed|threads open|UNKNOWN=>waiting-on-checks-or-review/NOT COMPLETE;poll/fix;auto-clear=>watch(same:0wake,delta:gates);fallback:4x15m+exp/4h|manual;stop clear/done/term/budget/user;noauth=>ready-no-merge-authority;ask=>own:walk|ext:user(merge|auth:add);blocked-user-input=>0retry/watch;auto=>exact verdict/head/sorted-gates/rollback;merge iff autonomous-merge-eligible|human-approved-for-current-head+durable-decision(proven+merge-authority);else ready-human-review-required|autonomous-merge-evidence-unknown;merge+close PR/target/issue.
  HST-v1
  Batch QA Lane:<owner/scope+evidence|none+rationale>
  Scope:titles/deps/exclusions/owners;STAGE_DEPENDENCY_PLAN_PATH=<p>,STAGE_DEPENDENCY_PLAN_ID=<id>,live=<replay/ref>;ft=refs/paths/create/delete/rename/collisions/owner/serial/UNKNOWN
  Items:
  - Target:<repo:<issue|pull-request>:N URL|repo:adhoc:date-slug>
    Orig:<prompt|n/a>;ovr:<n/a|name/auth/ref/task>
    Goal:outcome
    Notes:scope/deps
    Done:req auth+PR/no-PR evidence|no-fix rationale
  Execution rules:
  Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
  - Resolve `$pr-batch`; autoload/self-contained: load persisted state before preflight; persist output before resume/launch; preflight issue/PR only.
  - Routes advisory; observed host/model/effort host-only or UNKNOWN; checker independence/evidence mandatory.
  - Dispatch: pending->persist/reissue token; active->no launch; input->decision; fence->stop/reconcile.
  Current wave:each target/lane exactly once;one target/lane/worker;overlap=>integration advisory;deps/resv/UNKNOWN=>coord
  Workers:paths=coord!=perm;path+resv;multi=>coord;stop:contradiction/ambig/scope-risk/verify-down;Verify live GitHub before edits;unverifiable=>UNKNOWN
  - For coordination, respect coordination claims and dependencies: stable ids+heartbeats; register before launch when supported; claim refusal=>stop; push holder/generation check; known deps=>gate permissions; missing/UNKNOWN deps=>stop.
  Apply Batch QA Lane;include QA Evidence
  merge iff `merge_authority` is `auto_merge_when_gates_pass`|explicit merge approval;release+gates pass;record PR confidence
  - ask=>$pr-walkthrough;large/complex full;refresh;chg=>redo/stop;gate fail=>stop;ask iff same clean
  Final:canonical closeout;links/tests/blockers/next/confidence/UNKNOWN/authority/QA/state
TEXT
GENERIC_PROMPT_BODY = <<~TEXT
  Use $pr-batch to complete this batch with subagents.

  Batch title: <PROJECT> <A?> <ID?> <MM-DD HH:MM> - <title>

  Thread handle: <batch-short>-<lane>-<word>
  Lane Card:claim/PR-open/block/cancel/final;route;holder/branch/PR/phase/URLs/UNKNOWN
  Launch:<repo:<issue|pull-request>:N|repo:adhoc:date-slug>;ovr:n/a|name/auth/ref/task;none:reuse/create issue(auth/ask)+bind;invalid|dup|UNKNOWN:stop
  PF:issue/PR=security;adhoc=trusted+task-bound+durable,no-target-security
  Repo:OWNER/REPO
  Objective:...
  merge_authority:<none|ask|auto_merge_when_gates_pass>
  Batch size target: <codex|claude|generic>;wave: <cap/items>
  Coordinator model/effort preference: <model/class>/<effort>.
  Observed host/model/effort: <host|UNKNOWN>/<model|UNKNOWN>/<effort|UNKNOWN>; host-only, no inference.
  Manifest:pack_sha=<rev|UNKNOWN>;coordinator_preference=<model>/<effort>;lanes=<lane-id:dispatcher+preferred-route+observed-host/model/effort>,...;UNKNOWN=field;no guesses
  Worker model/effort preferences: <initial model/class>/<effort> -> <lane ids>; escalation <model/class>/<effort> after MODEL_ESCALATION_REQUEST; max <N>.
  Dispatch <lane>:<dispatcher>@<route>;fallback <dispatcher>@<route>->...|none;auth <y|n>;ordinary pending/active lifecycle
  - Stage deps: v1 edit|validation_open|merge_order; missing/UNKNOWN/stale=>closed; combined-tip@repo-seam
  GMCC-v5:CI@head/configured-reviewers pending|missing|untriaged|failed|threads open|UNKNOWN=>waiting-on-checks-or-review/NOT COMPLETE;poll/fix;auto-clear=>watch(same:0wake,delta:gates);fallback:4x15m+exp/4h|manual;stop clear/done/term/budget/user;noauth=>ready-no-merge-authority;ask=>own:walk|ext:user(merge|auth:add);blocked-user-input=>0retry/watch;auto=>exact verdict/head/sorted-gates/rollback;merge iff autonomous-merge-eligible|human-approved-for-current-head+durable-decision(proven+merge-authority);else ready-human-review-required|autonomous-merge-evidence-unknown;merge+close PR/target/issue.
  HST-v1
  Batch QA Lane:<owner/scope+evidence|none+rationale>
  Scope:titles/deps/exclusions/owners;STAGE_DEPENDENCY_PLAN_PATH=<p>,STAGE_DEPENDENCY_PLAN_ID=<id>,live=<replay/ref>;ft=refs/paths/create/delete/rename/collisions/owner/serial/UNKNOWN
  Items:
  - Target:<repo:<issue|pull-request>:N URL|repo:adhoc:date-slug>
    Orig:<prompt|n/a>;ovr:<n/a|name/auth/ref/task>
    Goal:outcome
    Notes:scope/deps
    Done:req auth+PR/no-PR evidence|no-fix rationale
  Execution rules:
  Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
  - Resolve `$pr-batch`; autoload/self-contained: load persisted state before preflight; persist output before resume/launch; preflight issue/PR only.
  - Routes advisory; observed host/model/effort host-only or UNKNOWN; checker independence/evidence mandatory.
  - Dispatch: pending->persist/reissue token; active->no launch; input->decision; fence->stop/reconcile.
  Current wave:each target/lane exactly once;one target/lane/worker;overlap=>integration advisory;deps/resv/UNKNOWN=>coord
  Workers:paths=coord!=perm;path+resv;multi=>coord;stop:contradiction/ambig/scope-risk/verify-down;Verify live GitHub before edits;unverifiable=>UNKNOWN
  - For coordination, respect coordination claims and dependencies: stable ids+heartbeats; register before launch when supported; claim refusal=>stop; push holder/generation check; known deps=>gate permissions; missing/UNKNOWN deps=>stop.
  Apply Batch QA Lane;include QA Evidence
  merge iff `merge_authority` is `auto_merge_when_gates_pass`|explicit merge approval;release+gates pass;record PR confidence
  - ask=>$pr-walkthrough;large/complex full;refresh;chg=>redo/stop;gate fail=>stop;ask iff same clean
  Final:canonical closeout;links/tests/blockers/next/confidence/UNKNOWN/authority/QA/state
TEXT
MULTI_TARGET_INSTRUCTION = <<~TEXT
  Instruction: Use PR-batch to execute every target in the accompanying Batch Plan against the repository's configured base branch; Work item identifies this batch's durable coordination anchor, not its sole target.
TEXT

def read_repo_file(path)
  File.read(File.join(REPO_ROOT, path), encoding: "UTF-8")
end

def extract_prompt(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  fence_start = text.index(TEXT_FENCE, heading_match.end(0))
  raise "missing text fence after #{heading}" unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  body_end = text.index(/^```[[:blank:]]*$/, body_start)
  raise "missing closing fence after #{heading}" unless body_end

  text[body_start...body_end]
end

def extract_markdown_section(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  body_start = heading_match.end(0)
  heading_level = heading[/\A#+/].length
  next_heading = text.match(/^#{Regexp.escape('#' * heading_level)}\s+/, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

class ReadableGoalPromptContractTest < Minitest::Test
  def setup
    @plan_skill = read_repo_file("skills/plan-pr-batch/SKILL.md")
    @pr_batch_skill = read_repo_file("skills/pr-batch/SKILL.md")
    @workflow = read_repo_file("workflows/pr-processing.md")
    @prompt_intake = read_repo_file("workflows/pr-batch-intake.md")
    @triage_skill = read_repo_file("skills/triage/SKILL.md")
    @source_docs = read_repo_file("docs/pr-batch-skills.md")
    @batch_plan_preflight = read_repo_file("skills/plan-pr-batch/bin/batch-plan-preflight")

    prompt_intake_handoff = extract_markdown_section(@prompt_intake, "## Plan To Goal Handoff")
    @generated_prompts = {
      "plan-pr-batch" => extract_prompt(@plan_skill, "## Goal Prompt for pr-batch"),
      "pr-batch" => extract_prompt(@pr_batch_skill, "## Goal Prompt Template")
    }
    @prompt_intake_prompt = extract_prompt("## Prompt\n\n#{prompt_intake_handoff}", "## Prompt")
  end

  def test_source_host_cap_drift_rejects_an_in_memory_mutation
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill,
      "workflows/pr-batch-intake.md" => @prompt_intake,
      "docs/pr-batch-skills.md" => @source_docs
    }
    GoalPromptDriftContract.check_host_caps!(surfaces)

    mutated = surfaces.transform_values(&:dup)
    mutated.fetch("workflows/pr-processing.md").sub!(
      "`codex`: up to 10 independent items, or 8",
      "`codex`: up to 11 independent items, or 8"
    )

    error = assert_raises(RuntimeError) do
      GoalPromptDriftContract.check_host_caps!(mutated)
    end
    assert_includes error.message, "expected 10/8, found 11/8"
  end

  def test_security_pin_drift_rejects_an_in_memory_mutation
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill,
      "workflows/pr-batch-intake.md" => @prompt_intake
    }
    GoalPromptDriftContract.check_security_pins!(surfaces:, batch_plan_preflight: @batch_plan_preflight)

    mutated = surfaces.transform_values(&:dup)
    mutated.fetch("workflows/pr-batch-intake.md").sub!(
      "When search finds no canonical issue or existing PR",
      "When no canonical issue or existing PR is found"
    )

    error = assert_raises(RuntimeError) do
      GoalPromptDriftContract.check_security_pins!(surfaces: mutated, batch_plan_preflight: @batch_plan_preflight)
    end
    assert_includes error.message, "canonical issue creation count is 0, expected 1"
  end

  def test_security_pins_support_portable_checkout_without_prompt_intake
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }

    GoalPromptDriftContract.check_security_pins!(surfaces:, batch_plan_preflight: @batch_plan_preflight)
  end

  def test_security_pins_ignore_hidden_html_comments
    surfaces = {
      "workflows/pr-batch-intake.md" => @prompt_intake,
      "skills/triage/SKILL.md" => @triage_skill.sub(
        GoalPromptDriftContract::CANONICAL_ISSUE_CREATION_PIN,
        "<!-- #{GoalPromptDriftContract::CANONICAL_ISSUE_CREATION_PIN} -->"
      )
    }

    error = assert_raises(RuntimeError) do
      GoalPromptDriftContract.check_security_pins!(surfaces:, batch_plan_preflight: @batch_plan_preflight)
    end
    assert_includes error.message, "skills/triage/SKILL.md canonical issue creation count is 0, expected 1"
  end

  def test_copy_paste_handoff_drift_rejects_inline_plan_alternatives_on_every_active_surface
    surfaces = {
      "workflows/pr-batch-intake.md" => @prompt_intake,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "docs/pr-batch-skills.md" => @source_docs,
      "workflows/pr-processing.md" => @workflow
    }

    assert_respond_to GoalPromptDriftContract, :check_copy_paste_handoff!
    GoalPromptDriftContract.check_copy_paste_handoff!(surfaces)

    pin_pattern = Regexp.new(
      Regexp.escape(GoalPromptDriftContract::COPY_PASTE_IMMUTABLE_REFERENCE_PIN).gsub("\\ ", "\\s+")
    )
    surfaces.each_key do |path|
      mutated = surfaces.transform_values(&:dup)
      replaced = mutated.fetch(path).sub!(
        pin_pattern,
        "For `copy-paste`, deliver the exact generated goal prompt with an exact immutable plan-state " \
        "reference plus its exact `batch_plan_binding`; never rely on rendered clipboard text to preserve " \
        "the frozen Batch Plan bytes."
      )
      refute_nil replaced, "#{path} mutation did not replace the copy-paste handoff"

      error = assert_raises(RuntimeError, path) do
        GoalPromptDriftContract.check_copy_paste_handoff!(mutated)
      end
      assert_includes error.message, "#{path} copy-paste handoff count is 0, expected 1"
    end
  end

  def test_all_canonical_surfaces_share_one_readable_prompt
    assert_equal 1, @generated_prompts.values.uniq.length
    assert_equal EXPECTED_PROMPT, @generated_prompts.values.first
    assert_equal GENERIC_PROMPT_BODY, @generated_prompts.values.first
    assert_equal <<~TEXT.strip, @prompt_intake_prompt.strip
      Repository: OWNER/REPO
      Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
      Task name: <repository, work item, and purpose>
      Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
      Merge authority: <auto|ask>
      Human available after: <optional time; omit this line when not supplied>
    TEXT

    @generated_prompts.each do |label, prompt|
      [
        "Repository:", "Work item:", "Task name:",
        "Instruction: Use PR-batch to complete this work item against the repository's configured base branch.",
        "Merge authority: <auto|ask>",
        "Human available after:"
      ].each do |legacy_fragment|
        refute_includes prompt, legacy_fragment, "#{label} leaked #{legacy_fragment}"
      end
    end
  end

  def test_generation_rules_make_one_trusted_source_authoritative
    [@plan_skill, @pr_batch_skill, @prompt_intake, @triage_skill].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized, "Fix issue #123 using $pr-batch with merge authority ask."
      assert_includes normalized, "accepted canonical issue or pull-request body"
      assert_includes normalized, "later trusted maintainer comment"
      assert_includes normalized, "Do not synthesize"
      assert_includes normalized, "same readable prompt vocabulary for every host"
      assert_includes normalized, "outside the human-authored prompt"
    end
  end

  def test_plan_pr_batch_copy_paste_requires_the_immutable_reference
    normalized = @plan_skill.gsub(/\s+/, " ")

    assert_includes normalized,
                    "With no explicit request, record `copy-paste` and deliver the prompt plus its exact immutable plan-state reference, or a byte-preserving inline handoff envelope when `coordination_backend: n/a` leaves no durable reference."
    assert_includes normalized,
                    "The portable `copy-paste` path must carry the exact immutable plan-state reference or, when `coordination_backend: n/a` leaves no durable reference, a byte-preserving inline handoff envelope carrying the exact plan bytes and the same `batch_plan_binding`"
    assert_includes normalized,
                    "A created task receives the exact generated goal prompt and either the exact plan bytes in a byte-preserving handoff envelope or the exact immutable plan-state reference in the same initial handoff"
    refute_includes normalized, "deliver the prompt plus its plan or reference"
    refute_includes normalized, "complete Batch Plan"
  end

  def test_machine_none_renders_as_human_ask_without_changing_durable_authority
    [@plan_skill, @prompt_intake].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized,
                      "An explicitly selected machine `merge_authority: none` renders as human " \
                      "`Merge authority: ask` because the worker has no merge authority and must obtain " \
                      "explicit human authority before merge."
      assert_includes normalized,
                      "This rendering does not change the durable machine value from `none` to `ask`."
    end
  end

  def test_thread_handle_is_resolved_machine_state_without_a_dangling_derivation_reference
    normalized = @pr_batch_skill.gsub(/\s+/, " ")

    assert_includes normalized,
                    "Keep the resolved `Thread handle:` in machine-readable launch state outside that prompt."
    refute_includes normalized, "its stable batch/lane derivation"
  end

  def test_lifecycle_drift_scope_stops_at_the_next_equal_or_higher_heading
    fixture = <<~MARKDOWN
      ### Planning-Chat Lifecycle
      required lifecycle text
      ## Integration And PR Publication
      adjacent section text
      ### Coordinator Closeout Lane
      later section text
    MARKDOWN

    lifecycle = GoalPromptDriftContract.section(
      fixture,
      "### Planning-Chat Lifecycle",
      GoalPromptDriftContract::UP_TO_H3_HEADING
    )

    assert_includes lifecycle, "required lifecycle text"
    refute_includes lifecycle, "adjacent section text"
  end

  def test_multi_target_inline_plan_binds_every_target_to_the_coordination_anchor
    [@plan_skill, @pr_batch_skill, @prompt_intake].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized,
                      "For a multi-target launch, keep `Work item` singular and set it to the " \
                      "durable coordination anchor and record destination for this batch."
      assert_includes normalized,
                      "The accompanying Batch Plan, whether delivered inline or by exact durable reference, " \
                      "is authoritative for scope and enumerates every target with its exact source and provenance."
      assert_includes normalized,
                      "Before prompt creation, retain the exact accepted plan and its `batch_plan_binding` " \
                      "in machine launch state."
      assert_includes normalized, MULTI_TARGET_INSTRUCTION.strip
      assert_includes normalized,
                      "Do not enumerate every target URL in the human prompt or add another prompt field."
    end
  end

  def test_single_target_prompt_stays_direct_without_multi_target_duplication
    @generated_prompts.each do |label, prompt|
      assert_equal EXPECTED_PROMPT, prompt, "#{label} changed the single-target prompt"
      assert_equal 1, prompt.scan(/^Batch title:/).length, "#{label} duplicated Batch title"
      assert_equal 1, prompt.scan(/^Thread handle:/).length, "#{label} duplicated Thread handle"
      refute_includes prompt, "Task name:", "#{label} leaked Task name into the generated prompt"
      refute_includes prompt, "Work item:", "#{label} leaked Work item into the generated prompt"
    end
  end

  def test_timestamped_batch_title_is_durable_metadata_not_a_human_prompt_field
    normalized = @pr_batch_skill.gsub(/\s+/, " ")
    assert_includes normalized,
                    "Keep the timestamped `Batch title:` in durable Batch Plan and task metadata only."
    assert_includes normalized,
                    "The readable human prompt uses `Task name:` and must not regain `Batch title:`."
    refute_includes normalized, "**Batch title**: for pasteable batch prompts"
  end

  def test_source_docs_preserve_complete_handoff_and_digest_integrity
    normalized = @source_docs.gsub(/\s+/, " ")
    [
      "Prompt digest at selection",
      "exact GitHub API `body` string",
      "without Unicode normalization, Markdown rendering, whitespace trimming, or newline insertion or removal",
      "If the selection and launch digests differ, that dispatch stops",
      "deliberately reselected as a new run and the security preflight is rerun",
      "one compact collapsed run record with one entry per target lane",
      "directly appends `Launched at` plus `Prompt digest at launch`",
      "successful security-preflight source URL, `body` field, and SHA-256 snapshot",
      "When GitHub returns `body: null` for a title-only issue or pull request",
      "treat its canonical source bytes as the empty UTF-8 string",
      "verifies identity and digest before it interprets the source",
      "`batch_plan_binding`",
      "workers never race GitHub read-modify-write updates",
      "split the trust boundaries into separate runs",
      "exact immutable plan-state reference plus its exact `batch_plan_binding`",
      "multi-target group remains one coordinator launch with one target per worker lane"
    ].each { |phrase| assert_includes normalized, phrase }
  end

  def test_copy_paste_handoff_delivers_prompt_plan_and_binding
    [@plan_skill, @triage_skill].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized,
                      "Start a new task with the fenced goal prompt, its exact immutable plan-state " \
                      "reference, and the exact batch_plan_binding."
      assert_includes normalized, "Next: Paste all three into that task"
    end
  end

  def test_launcher_record_owns_launch_provenance_and_append_only_observations
    launcher_record = extract_markdown_section(@prompt_intake, "## Launcher Run Record")

    [
      "Run ID: <immutable unique per-execution run_id>",
      "Record destination: <exact issue or pull-request work-item URL authorized for every lane, or existing durable plan/backend destination authorized for every lane>",
      "Batch Plan binding: <SHA-256 of exact delivered UTF-8 plan bytes, or immutable reference plus exact revision/content digest>",
      "Prompt created at: <timestamp>",
      "Model at prompt creation: <observed value or UNKNOWN>",
      "Workflow at prompt creation: <version or UNKNOWN>",
      "Later workflow observations: <timestamped append-only entries or none>",
      "Target lanes:",
      "Lane: <lane id; repeat this entry once per planned target>",
      "Target: <exact issue, pull-request, or durable override identity>",
      "Replay identity: <existing lane_id, dispatcher, instance_id, and launch token>",
      "Prompt source: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>",
      "Selected at: <timestamp>",
      "Prompt digest at selection: <SHA-256 of the canonical source bytes fetched when selected; or not applicable — trusted-ad-hoc-override>",
      "Launched at: <timestamp or pending>",
      "Prompt digest at launch: <SHA-256 of the canonical source bytes re-fetched at launch or pending; or not applicable — trusted-ad-hoc-override>",
      "Worker started at: <timestamp or pending>",
      "Prompt digest observed by worker: <SHA-256 of the canonical source bytes re-fetched by the worker or pending; or not applicable — trusted-ad-hoc-override>",
      "Model observed by worker: <observed value or UNKNOWN>",
      "Workflow observed at worker start: <version or UNKNOWN>"
    ].each { |field| assert_includes launcher_record, field }

    normalized = launcher_record.gsub(/\s+/, " ")
    assert_includes normalized, "field by field"
    assert_includes normalized, "does not block launch"
    assert_includes normalized, "collapsed `<details>`"
    assert_includes normalized, "one entry for every planned target lane"
    assert_includes normalized, "without replacing earlier values"
    assert_includes normalized, "Reruns append a new collapsed record"
    assert_includes normalized, "coordinator directly appends the cheap lane launch timestamp and digest"
    assert_includes normalized, "existing immutable replay identity"
    assert_includes normalized, "exactly matching `run_id`, replay identity, and `batch_plan_binding`"
    assert_includes normalized, "not the deterministic launch token"
    assert_includes normalized, "Do not add these fields to the human-authored prompt"
    assert_includes normalized, "successful `pr-security-preflight` snapshot"
    assert_includes normalized, "do not put the digest inside the bytes it hashes"
    assert_includes normalized, "sole writer for that record"
    assert_includes normalized, "workers return bound observation payloads"
    assert_includes normalized, "Never put a private `plan-state://` or `batch://` identity in a public run record"
    assert_includes normalized, "do not invent another snapshot, byte encoding, or record schema"
    assert_includes normalized, "not applicable — trusted-ad-hoc-override"
    assert_includes normalized,
                    "A trusted ad-hoc override whose durable authorization reference is `issue://` or " \
                    "GitHub HTTPS follows the ordinary GitHub source path"
    assert_includes normalized,
                    "record actual selection, launch, and worker-observed body digests instead of " \
                    "`not applicable — trusted-ad-hoc-override`"
    assert_includes normalized, "exact GitHub API `body` string"
    assert_includes normalized, "without Unicode normalization, Markdown rendering, whitespace trimming, or newline insertion or removal"
    assert_includes normalized, "When GitHub returns `body: null` for a title-only issue or pull request"
    assert_includes normalized, "Retain that SHA-256 digest in the selection, launch, and worker fields"
    assert_includes normalized, "verifies both the replay identity and observed digest before it interprets the source"
    assert_includes normalized, "`auto` maps to machine `auto_merge_when_gates_pass`; `ask` maps to machine `ask`"
    assert_includes normalized, "machine-only `merge_authority: none`"
  end

  def test_post_freeze_launch_digest_uses_the_bound_handoff_envelope
    {
      "canonical intake" => @prompt_intake,
      "planning guide" => @source_docs,
      "triage skill" => @triage_skill
    }.each do |label, text|
      normalized = text.gsub(/\s+/, " ")

      assert_includes normalized, "existing handoff envelope outside the frozen Batch Plan", label
      assert_includes normalized,
                      "do not add the launch digest to the frozen plan or change its binding",
                      label
    end

    refute_match(/launch digest[^.]*through the Batch Plan/, @prompt_intake)
  end
end
