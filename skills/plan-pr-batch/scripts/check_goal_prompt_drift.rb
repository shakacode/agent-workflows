# frozen_string_literal: true

require "stringio"

# Unrelated workflow-alignment checks historically shared the goal-prompt size
# guard. Keep them separate from the human-prompt shape so prompt simplification
# cannot silently retire routing, restart, HST, continuation, or parent-closeout
# contracts.
module GoalPromptDriftContract
  UP_TO_H3_HEADING = /^(?:#|##|###)\s+/
  ROUTE_ROW =
    /^\|\s*`(?<classification>[a-z-]+)`\s*\|\s*`(?<neutral>[^`]+)`\s*\|\s*`(?<codex>[^`]+)`\s*\|\s*`(?<claude>[^`]+)`\s*\|\s*$/
  DISPOSITION_ROW =
    /^\|\s*`(?<case_id>[A-Za-z-]+)`\s*\|\s*`(?<disposition>[a-z-]+)`\s*\|\s*`(?<max_reviews>[01])`\s*\|\s*`(?<compare>yes|no)`\s*\|\s*`(?<restart>yes|no)`\s*\|\s*$/

  ROUTES = {
    "affirmatively-simple" => ["balanced/medium", "Terra/medium", "Sonnet 5/medium"],
    "routine-multi-lane" => ["balanced/high", "Terra/high", "Sonnet 5/high"],
    "default-or-uncertain-single-target" => ["strongest/high", "Sol/high", "Opus 5/high"],
    "pinned-high-risk-or-escalation" => ["strongest/xhigh", "Sol/xhigh", "Opus 5/xhigh"]
  }.freeze
  DISPOSITIONS = {
    "stronger-current" => %w[future-cost-advisory 0 yes no],
    "weaker-current-host-supported" => %w[bounded-independent-review 1 yes no],
    "any-observed-field-UNKNOWN" => %w[non-blocking-advisory 0 no no]
  }.freeze
  ROUTING_POLICY = [
    "does not select the future batch coordinator",
    "Keep the reviewer distinct from the plan maker",
    "only from host-exposed runtime evidence",
    "Requested preferences, prompt text, and model self-report are not observations",
    "Unavailable, inherited, substituted, or unverifiable route-specific execution gets a non-blocking advisory instead; never require a restart."
  ].freeze

  HOST_CAPS = {
    "codex" => [10, 8],
    "claude" => [5, 3],
    "generic" => [5, 3]
  }.freeze
  HOST_CAP_CLAUSES = {
    "workflows/pr-processing.md" => [
      ["canonical codex", %w[codex], /`codex`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) when/],
      ["canonical claude", %w[claude], /`claude`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) under/],
      ["canonical generic", %w[generic], %r{`generic`:\s+use the Claude-sized (?<normal>\d+)/(?<risky>\d+) limit}]
    ],
    "skills/plan-pr-batch/SKILL.md" => [
      ["planner codex", %w[codex], /`codex`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) when/],
      ["planner claude", %w[claude], /`claude`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) under/],
      ["planner generic", %w[generic], %r{`generic`:\s+use the Claude-sized (?<normal>\d+)/(?<risky>\d+) limit}]
    ],
    "skills/pr-batch/SKILL.md" => [
      ["execution codex", %w[codex], /Codex-targeted waves may use up to (?<normal>\d+) independent\s+lanes, or (?<risky>\d+) when/],
      ["execution claude and generic", %w[claude generic], /Claude and generic waves use up to (?<normal>\d+) lanes, or up to (?<risky>\d+) under/]
    ],
    "skills/triage/SKILL.md" => [
      ["grouping codex", %w[codex], /`codex`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) when/],
      ["grouping claude and generic", %w[claude generic], /`claude` or `generic`:\s+up to (?<normal>\d+) independent items, or (?<risky>\d+) under/],
      ["summary codex", %w[codex], %r{Codex (?<normal>\d+)/(?<risky>\d+) and Claude/generic}],
      ["summary claude and generic", %w[claude generic], %r{Codex \d+/\d+ and Claude/generic (?<normal>\d+)/(?<risky>\d+)}],
      ["negative-rule codex", %w[codex], %r{Do not apply the Codex (?<normal>\d+)/(?<risky>\d+) cap}]
    ],
    "docs/pr-batch-skills.md" => [
      ["documentation codex", %w[codex], /Codex-targeted waves may use up to (?<normal>\d+)\s+fully independent items, or (?<risky>\d+) when/],
      ["documentation claude and generic", %w[claude generic], /Claude and generic waves use up to (?<normal>\d+)\s+independent items, or (?<risky>\d+) under/]
    ]
  }.freeze

  CANONICAL_ISSUE_CREATION_PIN =
    "When search finds no canonical issue or existing PR, create the canonical issue with explicit " \
    "planning-time issue-creation authority, or ask for that authority; do not create a branch, edit, " \
    "or dispatch until the persisted issue identity is rebound into the plan and preflight passes."
  CANONICAL_REPOSITORY_GRAMMAR_PIN =
    "Every typed target repository has exactly two ASCII components separated by `/`: the owner " \
    "matches `[A-Za-z0-9][A-Za-z0-9._-]*`; the repository name contains 1-100 characters from " \
    "`[A-Za-z0-9._-]` but is not exactly `.` or `..`; neither component is exactly `UNKNOWN`; " \
    "parseable authorization-reference `N` values are positive decimals matching `[1-9][0-9]*`."
  IMPLEMENTATION_PR_FILE_TOUCH_REPLAY_PIN =
    "After an issue or trusted ad-hoc lane opens its implementation PR, keep the original canonical " \
    "target unchanged and replace planned-path evidence with the lane-keyed verified PR file-touch map; " \
    "its repository must match the target, while a PR-origin target also requires the exact target PR number."
  REPOSITORY_NAME_PATTERN_PIN = 'REPOSITORY_NAME_PATTERN = /\A[A-Za-z0-9._-]{1,100}\z/'
  COPY_PASTE_IMMUTABLE_REFERENCE_PIN =
    "For `copy-paste`, deliver the exact generated goal prompt with an exact immutable plan-state " \
    "reference plus its exact `batch_plan_binding`; when `coordination_backend: n/a` leaves no " \
    "durable reference, fall back to a byte-preserving inline handoff envelope carrying the exact " \
    "plan bytes and the same `batch_plan_binding`; never rely on rendered clipboard text to preserve " \
    "the frozen Batch Plan bytes."

  RESUME_SNIPPET = <<~TEXT.chomp
    Resume batch processing now.

    Re-read your restart handoff and run the bounded status recovery steps described under "Pausing For An Agent-Runner Restart" in the installed `pr-processing.md` workflow before editing, pushing, polling, or starting any new target.
  TEXT

  HST_SKILL_REFERENCE = "Use `HST-v1` from the canonical " \
                        "[Human-Status Translation Contract](../../workflows/pr-processing.md#human-status-translation-contract) " \
                        "for every recurring wake or workflow-owned heartbeat."
  MODEL_EFFORT_DOC_PHRASES = [
    "Group lanes by model/effort preference",
    "MODEL_ESCALATION_REQUEST",
    "stronger-model plan review",
    "if the runtime inherits"
  ].freeze
  MODEL_EFFORT_CONTEXT_PHRASES = [
    "**Coordinator model/effort preference**",
    "**Observed host/model/effort**",
    "**Worker execution envelope**",
    "**Worker model/effort route**",
    "**Model escalation request**",
    "**Model replacement handoff**",
    "**Dispatch-resolved model class**",
    "prompt target"
  ].freeze
  HST_WORKFLOW_PHRASES = [
    "### Human-Status Translation Contract",
    "internal telemetry",
    "successful, intermediate, repeated, or unchanged wake is silent",
    "DONT_NOTIFY: No user action is needed. Monitoring will continue.",
    "Send an actionable notification only when a decision or action is required,",
    "a target is ready for walkthrough or approval, a blocker exhausted its bounded",
    "retries and needs intervention, or closeout/archive completed.",
    "What changed:",
    "Action needed:",
    "Next:",
    "explicit technical or diagnostic status",
    "Expand identifiers on first use, retain exact values, and mark unavailable",
    "meanings `UNKNOWN` rather than translating them speculatively.",
    "automatically delete an obsolete heartbeat or monitor when its",
    "gate clears or becomes durably terminal; retain it on a no-change wake.",
    "The current task remains",
    "the owner, and automation output must not imply that ownership changed.",
    "At closeout/archive completion, place the three labeled parts before, not",
    "instead of, the existing mandatory closeout handoff.",
    "required handoff evidence and exact `Conversation status:` line",
    "security, ownership, retry, scope, continuous integration (CI), review, or",
    "merge gates"
  ].freeze

  CONTINUATION_INVOCATION = "Use $pr-batch to continue PR-batch closeout, not to start a new implementation batch."
  CONTINUATION_TITLE = "Batch title: <PROJECT> <A?> <ID?> <MM-DD HH:MM> - <continuation title>."
  CONTINUATION_THREAD_HANDLE = "Thread handle: <batch-short>-<lane>-<word>"
  CONTINUATION_PHRASES = [
    CONTINUATION_INVOCATION,
    CONTINUATION_TITLE,
    CONTINUATION_THREAD_HANDLE,
    "HST-v1",
    "determine the exact targets from the visible request, pasted handoff target section, PR URLs, GitHub shorthand refs, or final-bucket table",
    "Extract only explicit PR/issue refs such as OWNER/REPO#123, PR #123, issue #123, or GitHub URLs when they are presented as batch targets or final-bucket entries.",
    "If other refs appear only as evidence, blocker links, dependency context, next actions, comments, or examples, do not include them as targets; ask if the target boundary is unclear.",
    "Exclude anything explicitly marked excluded, deferred, next-major, out of scope, or not part of this batch.",
    "Do not broaden to all open PRs, labels, milestones, or inferred related work unless I explicitly ask for discovery.",
    "If the extracted targets have mixed states, split internally by action type: checks/review polling, conflict recovery, draft/product-decision blockers, and excluded/deferred items.",
    "Do not let blocked/deferred targets stop progress on independent actionable targets, and report true user-input blockers separately with exact PR/thread URLs.",
    "Pass only its verified target identity and sanitized handoff to workers; do not copy target content or security policy into this continuation prompt.",
    "Apply the [PR-Batch Security Floor](pr-batch-security-floor.md) to every target.",
    "merge_authority: ask (use auto_merge_when_gates_pass only when the visible request explicitly grants it)",
    "Mode: continue from live GitHub state; previous handoffs are stale hints only.",
    "Re-fetch every target's current head SHA, branch, draft status, merge state, conflicts/behind state, review decision, unresolved current-head review threads, configured review-agent state, and current-head checks.",
    "Split current-head state into a complete configured/requested review cohort and validation CI.",
    "Do not mark the overall goal complete while any target is `waiting-on-checks-or-review`, has pending/missing/untriaged current-head checks or configured review agents, unresolved current-head review threads, fixable failures, or `UNKNOWN`.",
    "If CI/reviews are pending, finish runnable in-scope closeout work before each bounded poll.",
    "Triage only after the complete review cohort settles; do not wait for unrelated validation CI before that consolidated triage.",
    "GMCC-v5 compatibility fallback:",
    "reuse or create one bounded current-thread monitor before handoff and do not create a duplicate",
    "Use at most four 15-minute fast-window polls followed by exponential backoff capped at four hours",
    "On each wake, refresh live blocker evidence and resume if a blocker clears.",
    "Stop the monitor when the goal unblocks or before completion.",
    "`blocked-user-input` does not start a monitor; preserve its exact question and manual resume instructions.",
    "If recurring current-thread wake-ups are unavailable, preserve exact manual resume instructions.",
    "Terminal or NOT COMPLETE handoff states allowed: `merged`, `ready-gates-clean`, `ready-no-merge-authority`, `ready-human-review-required`, `autonomous-merge-evidence-unknown`, `waiting-on-checks-or-review` after bounded polling, `blocked-user-input` with exact question/thread URL, `external-gate-failing` with evidence and no local fix, or `no-pr-evidence` where applicable.",
    "With `auto_merge_when_gates_pass`, done requires ordinary readiness plus `autonomous-merge-eligible`, or `human-approved-for-current-head` whose exact live verdict/head, exact sorted gate set, rollback disposition, and durable proven-human decision with verified merge authority are established; otherwise stop in the exact autonomous eligibility state, and unless another real blocker prevents it, merge and close the PR, target, and issue.",
    "With `ask`, after ordinary gates are clean, automatically start the exact-diff PR walkthrough before approval.",
    "After it completes or is skipped, refresh the diff identity and ordinary readiness.",
    "If the diff identity changed, invalidate the walkthrough and readiness evidence, then restart the walkthrough or stop.",
    "If an ordinary gate newly fails, stop.",
    "Ask one final merge decision only when the refreshed diff identity matches the recorded identity, ordinary readiness remains clean, and merge is allowed; a completed walkthrough must have explained that same diff identity.",
    "Walkthrough participation is not merge approval.",
    "Final handoff must include detected target list, links, tests, blockers, next action, confidence/UNKNOWN, QA evidence, merge_authority, and per-target terminal state."
  ].freeze

  PRESSURE_SCENARIOS = [
    "A handoff containing final buckets for placeholder PRs #101, #102, #103, #104, and #105 extracts exactly those five targets and excludes explicitly deferred/excluded PRs.",
    "A mixed-state handoff containing placeholder PRs #201, #202, #203, #204, and #205 splits checks/review polling from draft/product-decision blockers and conflict recovery.",
    "A pasted handoff with no exact PR/issue refs stops and asks for targets instead of broadening to all open PRs.",
    "A normal resume prompt routes to bounded status recovery, not cancellation/relaunch."
  ].freeze
  ALLOWED_PRESSURE_REFS = (101..105).to_a.concat((201..205).to_a).map { |number| "##{number}" }.freeze

  PARENT_RECONCILIATION_PIN = "After terminal batch handoffs, parent reconciliation is a post-batch/pre-release-or-archive gate, not a per-PR/pre-merge gate. Before a coordinated release action or parent archive, the parent determines applicability for every exact target/surface and performs a bounded read-only refresh and comparison with durable terminal handoffs/manifests only for applicable GitHub, coordination-backend/claim, head/merge, issue, QA, and release-note surfaces. Explicit durable `n/a`, `no-PR`, or `no-code/not-required` evidence with rationale satisfies an inapplicable surface. `UNKNOWN` applicability or missing applicable evidence blocks both release action and parent archive."
  PARENT_AUDIT_PIN = "The completed-batch audit handoff is an always-applicable parent-reconciliation surface for every batch, independent of all target-level `n/a` decisions. The durable coordinator-owned handoff records audit status, verdict, verified scope evidence, checker evidence, findings, and follow-ups/dispositions. Missing handoff, or missing or `UNKNOWN` audit status or verdict, blocks both coordinated release and parent archive. Its marker has separate well-formed, archive-ready, and blocker-union outputs; only `complete`/`clean`/`none` with fully evidenced terminal records is archive-ready, and every OUTSTANDING ref or non-ready record remains in the normalized blocker union. The parent only reconciles this handoff; it never reruns or owns the audit."
  PARENT_MARKER_PIN = "The completed-batch marker has separate well-formed, archive-ready, and blocker-union outputs. A completed-batch audit is release/archive-ready only when `audit_status: complete`, `verdict: clean`, `findings: none`, and `followups_dispositions` is `none` or only fully evidenced terminal records."
  PARENT_SCENARIOS = [
    "Prompt-only single-batch: after all prompts are delivered or registered and stable batch/lane/dependency/ownership state is durable outside the chat, it archives without waiting for workers; closeout owner: the batch coordinator; an unhanded-off question or planner-owned `UNKNOWN` blocks archive, while a durably handed-off coordinator-owned worker state, including worker `UNKNOWN`, does not; final status: use exactly `Conversation status: Ready for archiving.` when prompt-only is clean; otherwise use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.` and list each exact action or blocker.",
    "Parent-orchestrated multi-batch: the parent stays open and read-only while workers execute; each batch coordinator owns checklist+replay closeout; parent cross-batch reconciliation is checklist+replay over durable terminal handoffs/manifests. The completed-batch audit handoff is an always-applicable parent-reconciliation surface for every batch, independent of all target-level `n/a` decisions. Preserve the durable completed-batch handoff, reconcile only applicable surfaces, and use the canonical [Completed-Batch Audit Receipt And Archive Replay](pr-batch-integration-closeout.md#completed-batch-audit-receipt-and-archive-replay) marker grammar; `UNKNOWN` applicability or missing applicable evidence blocks release action and parent archive. For each exact batch/target scope the durable record captures evidence, owner, status, and follow-up for exact scope coverage, dependency outcomes, issue closed or no-PR evidence, released claims, exact-final-head QA replay, changelog/release-note ownership, and shared-path interactions; clean only when parent reconciliation has no OUTSTANDING follow-up or `UNKNOWN`; then final status: use exactly `Conversation status: Ready for archiving.` Otherwise final status: use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.`"
  ].freeze

  module_function

  def fail!(message)
    raise "workflow drift: #{message}"
  end

  def read(repo_root, path, optional: false)
    full_path = File.join(repo_root, path)
    return nil if optional && !File.file?(full_path)

    fail!("missing #{path}") unless File.file?(full_path)

    File.read(full_path, encoding: "UTF-8")
  end

  def section(text, marker, end_heading = /^###\s+/)
    start = text.index(marker)
    fail!("missing section #{marker}") unless start

    body_start = start + marker.length
    ending = text.match(end_heading, body_start)
    text[body_start...(ending ? ending.begin(0) : text.length)]
  end

  def text_fence(text, label)
    start = text.index("```text\n")
    fail!("#{label} is missing text fence") unless start

    body_start = start + "```text\n".length
    body = text[body_start..]
    fences = body.enum_for(:scan, /^```\s*$/).map { Regexp.last_match.begin(0) }
    fail!("#{label} is missing closing fence") if fences.empty?
    fail!("#{label} contains a nested bare fence") if fences.length > 1

    body[0...fences.first]
  end

  def require_phrases(text, phrases, label)
    phrases.each { |phrase| fail!("#{label} missing #{phrase.inspect}") unless text.include?(phrase) }
  end

  def check_routes!(text, label)
    visible = text.gsub(/<!--.*?-->/m, "")
    routes = visible.scan(ROUTE_ROW).to_h { |row| [row[0], row[1..]] }
    dispositions = visible.scan(DISPOSITION_ROW).to_h { |row| [row[0], row[1..]] }
    ROUTES.each { |key, expected| fail!("#{label} route #{key} drifted") unless routes[key] == expected }
    DISPOSITIONS.each do |key, expected|
      fail!("#{label} disposition #{key} drifted") unless dispositions[key] == expected
    end
    require_phrases(visible.gsub(/\s+/, " "), ROUTING_POLICY, "#{label} routing policy")
    ["Default single-target planner:", "Affirmatively simple single-target planner:"].each do |legacy|
      fail!("#{label} contains legacy planner profile") if visible.include?(legacy)
    end
  end

  def check_host_caps!(surfaces)
    HOST_CAP_CLAUSES.each do |path, clauses|
      text = surfaces[path]
      next if path == "docs/pr-batch-skills.md" && !text

      fail!("missing host-cap surface #{path}") unless text

      clauses.each do |label, providers, pattern|
        matches = text.scan(pattern)
        fail!("#{path} #{label} clause count is #{matches.length}, expected 1") unless matches.length == 1

        actual = matches.first.map(&:to_i)
        providers.each do |provider|
          expected = HOST_CAPS.fetch(provider)
          next if actual == expected

          fail!("#{path} #{label} host cap drifted for #{provider}: " \
                "expected #{expected.join('/')}, found #{actual.join('/')}")
        end
      end
    end
  end

  def check_security_pins!(surfaces:, batch_plan_preflight:)
    intake_surfaces = surfaces.slice("workflows/pr-batch-intake.md", "skills/triage/SKILL.md")
    replay_surfaces = surfaces.slice(
      "workflows/pr-processing.md",
      "skills/plan-pr-batch/SKILL.md",
      "skills/pr-batch/SKILL.md",
      "skills/triage/SKILL.md"
    )

    {
      "canonical issue creation" => [CANONICAL_ISSUE_CREATION_PIN, intake_surfaces],
      "canonical repository grammar" => [CANONICAL_REPOSITORY_GRAMMAR_PIN, intake_surfaces],
      "implementation PR file-touch replay" => [IMPLEMENTATION_PR_FILE_TOUCH_REPLAY_PIN, replay_surfaces]
    }.each do |label, (phrase, selected_surfaces)|
      selected_surfaces.each do |path, text|
        visible_text = text.gsub(/<!--.*?-->/m, "")
        count = visible_text.gsub(/\s+/, " ").scan(phrase).length
        fail!("#{path} #{label} count is #{count}, expected 1") unless count == 1
      end
    end

    pattern_count = batch_plan_preflight.scan(REPOSITORY_NAME_PATTERN_PIN).length
    return if pattern_count == 1

    fail!("batch-plan-preflight repository-name pattern count is #{pattern_count}, expected 1")
  end

  def check_copy_paste_handoff!(surfaces)
    pin = COPY_PASTE_IMMUTABLE_REFERENCE_PIN.gsub(/\s+/, " ")

    surfaces.each do |path, text|
      visible_text = text.gsub(/<!--.*?-->/m, "").gsub(/\s+/, " ")
      count = visible_text.scan(pin).length
      next if count == 1

      fail!("#{path} copy-paste handoff count is #{count}, expected 1")
    end
  end

  def check!(repo_root:, source_checkout:)
    workflow = read(repo_root, "workflows/pr-processing.md")
    skills = {
      "skills/plan-pr-batch/SKILL.md" => read(repo_root, "skills/plan-pr-batch/SKILL.md"),
      "skills/pr-batch/SKILL.md" => read(repo_root, "skills/pr-batch/SKILL.md"),
      "skills/triage/SKILL.md" => read(repo_root, "skills/triage/SKILL.md")
    }
    security_surfaces = { "workflows/pr-processing.md" => workflow, **skills }
    prompt_intake = read(repo_root, "workflows/pr-batch-intake.md", optional: true)
    security_surfaces["workflows/pr-batch-intake.md"] = prompt_intake if prompt_intake
    check_security_pins!(
      surfaces: security_surfaces,
      batch_plan_preflight: read(repo_root, "skills/plan-pr-batch/bin/batch-plan-preflight")
    )
    routing_surfaces = {
      "skills/plan-pr-batch/SKILL.md" => skills.fetch("skills/plan-pr-batch/SKILL.md"),
      "docs/agent-workflows-model-routing.md" => read(repo_root, "docs/agent-workflows-model-routing.md"),
      "workflows/pr-processing.md" => workflow
    }
    source_docs = read(repo_root, "docs/pr-batch-skills.md") if source_checkout
    routing_surfaces["docs/pr-batch-skills.md"] = source_docs if source_checkout
    routing_surfaces.each { |path, text| check_routes!(text, path) }

    copy_paste_surfaces = {
      "workflows/pr-processing.md" => workflow,
      "skills/plan-pr-batch/SKILL.md" => skills.fetch("skills/plan-pr-batch/SKILL.md"),
      "skills/pr-batch/SKILL.md" => skills.fetch("skills/pr-batch/SKILL.md")
    }
    copy_paste_surfaces["workflows/pr-batch-intake.md"] = prompt_intake if prompt_intake
    copy_paste_surfaces["docs/pr-batch-skills.md"] = source_docs if source_docs
    check_copy_paste_handoff!(copy_paste_surfaces)

    check_host_caps!(
      {
        "workflows/pr-processing.md" => workflow,
        **skills,
        "docs/pr-batch-skills.md" => source_docs
      }
    )

    require_phrases(workflow, HST_WORKFLOW_PHRASES, "workflow HST-v1")
    skills.each do |path, text|
      count = text.scan(HST_SKILL_REFERENCE).length
      fail!("#{path} must contain one canonical HST-v1 reference, found #{count}") unless count == 1
    end

    fail!("workflow restart snippet drifted") unless workflow.include?(RESUME_SNIPPET)
    if source_checkout
      restart_docs = read(repo_root, "docs/agent-runner-restarts.md")
      fail!("restart docs snippet drifted") unless restart_docs.include?(RESUME_SNIPPET)
      require_phrases(source_docs, MODEL_EFFORT_DOC_PHRASES, "docs/pr-batch-skills.md model/effort routing")
      require_phrases(
        read(repo_root, "CONTEXT.md"),
        MODEL_EFFORT_CONTEXT_PHRASES,
        "CONTEXT.md model/effort vocabulary"
      )
    end

    continuation_section = section(workflow, "### Generic PR-Batch Continuation Prompt")
    continuation = text_fence(continuation_section, "continuation prompt")
    require_phrases(workflow, CONTINUATION_PHRASES, "continuation contract")
    expected_prefix = "#{CONTINUATION_INVOCATION}\n\n#{CONTINUATION_TITLE}\n\n#{CONTINUATION_THREAD_HANDLE}\n"
    fail!("continuation prompt header drifted") unless continuation.start_with?(expected_prefix)

    pressure_section = section(workflow, "Pressure scenarios this prompt must satisfy:")
    require_phrases(workflow, PRESSURE_SCENARIOS, "continuation pressure scenarios")
    unexpected_refs = pressure_section.scan(/#\d+/).uniq - ALLOWED_PRESSURE_REFS
    fail!("pressure scenarios contain live refs: #{unexpected_refs.join(', ')}") unless unexpected_refs.empty?

    lifecycle = section(workflow, "### Planning-Chat Lifecycle", UP_TO_H3_HEADING)
    require_phrases(lifecycle, PARENT_SCENARIOS, "parent reconciliation scenarios")
    return unless source_checkout

    require_phrases(
      lifecycle,
      [PARENT_RECONCILIATION_PIN, PARENT_AUDIT_PIN],
      "parent reconciliation source pins"
    )
    require_phrases(
      read(repo_root, "workflows/pr-batch-integration-closeout.md"),
      [PARENT_MARKER_PIN],
      "integration-closeout marker source pin"
    )
  end
end
