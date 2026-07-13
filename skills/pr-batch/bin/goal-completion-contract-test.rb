#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SPEC_SKILL_PATH = File.join(ROOT, "skills/spec/SKILL.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PLAN_PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/plan-pr-batch/SKILL.md")
TRIAGE_SKILL_PATH = File.join(ROOT, "skills/triage/SKILL.md")
ADVERSARIAL_REVIEW_WORKFLOW_PATH = File.join(ROOT, "workflows/adversarial-pr-review.md")
PR_MONITORING_SKILL_PATH = File.join(ROOT, "skills/pr-monitoring/SKILL.md")
PR_BATCH_DOCS_PATH = File.join(ROOT, "docs/pr-batch-skills.md")
CHANGELOG_PATH = File.join(ROOT, "CHANGELOG.md")

TEXT_FENCE = "```text\n"
CANONICAL_CONTRACT_LINK = "../../workflows/pr-processing.md#goal-mode-completion-contract"
CANONICAL_READINESS_LINK = "../../workflows/pr-processing.md#batch-handoff-format"
PENDING_CHECKS_PRESSURE = "A batch with 5 PRs, 3 pending hosted checks, and clean review threads is NOT COMPLETE"
COMPACT_CONTRACT_LINE = "GMCC-v2: waiting-on-checks-or-review; pending/missing/untriaged " \
                        "current-head CI/configured review agents; unresolved current-head review threads; " \
                        "fail/UNKNOWN=>NOT COMPLETE; poll/fix; bounded-watch resume handoff; " \
                        "auto-clear block=>host wake: 1 deduped 15m current-thread watch, else exact manual resume; " \
                        "stop unblocked/done; ready-no-merge-authority iff no auth; " \
                        "auto_merge_when_gates_pass=>no real blocker: merge+close any PR; " \
                        "close target+any issue."
CANONICAL_AUTO_MERGE_EXPANSION = "With `auto_merge_when_gates_pass`, unless a real blocker prevents it, " \
                                 "done means the PR is merged and closed out when present, the target is " \
                                 "closed out, and the issue is closed where applicable."
LEGACY_AUTO_MERGE_EXPANSION = "With `auto_merge_when_gates_pass`, done means merged and closed out " \
                              "unless a real blocker prevents it."
CANONICAL_CONTRACT_LINE = "Goal Mode Completion Contract: `waiting-on-checks-or-review` is not an " \
                          "overall Goal-mode terminal state; pending, missing, or untriaged current-head " \
                          "CI or configured review agents, unresolved current-head review threads, failures, " \
                          "or UNKNOWN => NOT COMPLETE; poll/fix; after a watch window, report NOT COMPLETE " \
                          "with resume instructions. When the overall Goal is genuinely blocked by a condition " \
                          "that can clear without user input, treat the host's recurring automation/wakeup " \
                          "capability as available only if it can re-enter this same thread on schedule and be inspected, " \
                          "updated, and stopped; create or update one active 15-minute " \
                          "current-thread monitor before the blocked handoff; do not create a duplicate. On each " \
                          "wake, refresh live blocker evidence and resume work if a blocker clears. Stop the monitor " \
                          "when the goal is unblocked or before completing it. `blocked-user-input` does not start " \
                          "a monitor; preserve its exact question and manual resume instructions. If recurring " \
                          "current-thread wake-ups " \
                          "are unavailable, preserve exact manual resume instructions. A batch with 5 PRs, 3 " \
                          "pending hosted checks, and clean " \
                          "review threads is NOT COMPLETE. `ready-no-merge-authority` is terminal only when " \
                          "`merge_authority` does not allow merging. #{CANONICAL_AUTO_MERGE_EXPANSION}".freeze
COMPACT_CONTRACT_INVARIANTS = [
  "waiting-on-checks-or-review",
  "pending/missing/untriaged current-head CI/configured review agents",
  "unresolved current-head review threads",
  "fail/UNKNOWN=>NOT COMPLETE",
  "poll/fix; bounded-watch resume handoff",
  "auto-clear block=>host wake: 1 deduped 15m current-thread watch, else exact manual resume",
  "stop unblocked/done",
  "ready-no-merge-authority iff no auth",
  "auto_merge_when_gates_pass=>no real blocker:",
  "merge+close any PR",
  "close target+any issue"
].freeze
GMCC_ALIGNMENT_SENTENCE = "`GMCC-v2` is a version key that pins drift, not an external-only pointer; " \
                          "its inline semantics remain normative when the workflow reference is missing or cannot autoload."
PENDING_REVIEW_DRAFT_GUARD = "Current-head `PENDING` review drafts visible to the current authenticated viewer also block readiness; the helper inventories that viewer-visible scope paginated. Its `complete` value means only that pagination completed in the authenticated-viewer scope; other reviewers' unsubmitted drafts are not observable or covered, and incomplete or unavailable inventory is `UNKNOWN`."
CANONICAL_CLOSEOUT_PROMPT_LINE = "Final handoff: canonical closeout;"
BATCH_COORDINATOR_AUDIT_OWNERSHIP = "Once every batch target has a final state, the batch coordinator must run its completed-batch audit before its final handoff. Each completed-batch audit is owned by its batch coordinator. A parent orchestration agent only reconciles the durable audit handoff."
OBSOLETE_PARENT_AUDIT_OWNERSHIP = "Once it detects that every batch target has a final state, the parent orchestration agent must run the completed-batch audit before its final handoff."
PROMPT_ONLY_ARCHIVE_RULE = "Do not archive if an unhanded-off question or planner-owned `UNKNOWN` remains. A durably handed-off coordinator-owned worker state, including a worker `UNKNOWN`, does not block prompt-only archive."
PROMPT_ONLY_NON_CLEAN_STATUS_RULE = "otherwise use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.` and list each exact action or blocker."
PROMPT_ONLY_ARCHIVE_PREREQUISITE = "all prompts are delivered or registered and stable batch/lane/dependency/ownership state is durable outside the chat"
PROMPT_ONLY_ARCHIVE_EXPECTATION = "Prompt-only conversation-status/archive expectation: use exactly `Conversation status: Ready for archiving.` only when #{PROMPT_ONLY_ARCHIVE_PREREQUISITE}; no unhanded-off question or planner-owned `UNKNOWN` remains; a durably handed-off coordinator-owned worker state, including a worker `UNKNOWN`, does not block prompt-only archive; #{PROMPT_ONLY_NON_CLEAN_STATUS_RULE}".freeze
PROMPT_ONLY_DISTINCT_COORDINATOR_HANDOFF_RULE = "Prompt-only is eligible only after durable handoff to a distinct batch coordinator."
PLANNING_CHAT_SELF_LAUNCH_TRANSITION_RULE = "After same-chat self-launch, transition to the batch-coordinator lifecycle only when no cross-batch, dependency, release, or shared-follow-up responsibility is retained."
SELF_LAUNCH_RETAINED_DUTY_PARENT_RULE = "For same-chat launch with retained cross-batch, dependency, release, or shared-follow-up duties, select and record `parent-orchestrator` immediately because retained duties determine the mandatory planning role; list each exact retained responsibility, do not use `prompt-only`, and do not record `Retained responsibilities: none`."
RETAINED_DUTY_NO_HANDOFF_BLOCK_RULE = "Before durable handoff/launch of a distinct batch coordinator succeeds, this is a BLOCKED parent-orchestrator: it stays read-only, starts no workers, records the exact distinct-coordinator handoff blocker/follow-up, and uses final `Conversation status: Follow-ups remain — <each exact action or blocker>.`"
RETAINED_DUTY_DISTINCT_COORDINATOR_RULE = "Once durable handoff/launch of a distinct batch coordinator succeeds, workers may start under that coordinator, which owns PR/check/QA/merge/completed-batch-audit closeout, while the parent remains read-only."
PLANNING_CHAT_ROLE_RULE = "While the chat remains a planning chat, Planning-chat role: exactly one of `prompt-only` or `parent-orchestrator`."
PARENT_ORCHESTRATOR_SELECTOR_RULE = "While the chat remains a planning chat, select `parent-orchestrator` only when the planner explicitly retains one or more cross-batch dependency, release, or shared-follow-up responsibilities."
SELF_LAUNCH_LIFECYCLE_TRANSITION = "Lifecycle transition: transitioned-to-batch-coordinator."
SELF_LAUNCH_PLANNING_CHAT_ROLE = "Planning-chat role: not applicable after self-launch."
SELF_LAUNCH_CLOSEOUT_OWNER = "Archive/closeout owner: batch coordinator."
SELF_LAUNCH_NO_RETAINED_RESPONSIBILITY = "Retained responsibilities: none (no cross-batch, dependency, release, or shared-follow-up responsibility is retained)."
SELF_LAUNCH_NOT_A_THIRD_PLANNING_ROLE = "This is a transition out of planning, not a third planning role; neither `prompt-only` nor `parent-orchestrator` is selectable after the transition."
PLAN_PR_BATCH_RESPONSE_ORDER = "Response order: Batch Plan; generated goal prompt; `Goal prompt character count: N characters (target: codex|claude|generic)`; selected exact `Conversation status: Ready for archiving.` or `Conversation status: Follow-ups remain — <each exact action or blocker>.` line. The selected exact Conversation status line is the actual final user-visible line."
TRIAGE_RESPONSE_ORDER = "Response order: scope/repositories/sources; phase-1 counts/dependency graph; coordination; capacity; wave plan/prompts; lifecycle record; queue summary if applicable; residual risks; maintainer decisions; selected exact `Conversation status: Ready for archiving.` or `Conversation status: Follow-ups remain — <each exact action or blocker>.` line. The selected exact Conversation status line is the actual final user-visible line."
PARENT_RECONCILIATION_RULE = "After terminal batch handoffs, parent reconciliation is a post-batch/pre-release-or-archive gate, not a per-PR/pre-merge gate. Before a coordinated release action or parent archive, the parent determines applicability for every exact target/surface and performs a bounded read-only refresh and comparison with durable terminal handoffs/manifests only for applicable GitHub, coordination-backend/claim, head/merge, issue, QA, and release-note surfaces. Explicit durable `n/a`, `no-PR`, or `no-code/not-required` evidence with rationale satisfies an inapplicable surface. `UNKNOWN` applicability or missing applicable evidence blocks both release action and parent archive."
RELEASE_AUTHORITY_RECONCILIATION_RULE = "Coordinated release may pass this reconciliation gate only under separately established release authority; reconciliation never grants release or merge authority."
OBSOLETE_RELEASE_AUTHORITY_RECONCILIATION_RULE = "may authorize a coordinated release action"
TERMINAL_FOLLOW_UP_EVIDENCE_RULE = "A `findings: OUTSTANDING <refs>` value contributes every exact ref to the blocker union even without a record. Every nonterminal record and every record with imperfect terminal evidence contributes its ref and action/block reason; normalize and dedupe without dropping a distinct ref."
UNRESOLVED_HANDOFF_NON_CLEAN_RULE = "Clean/none permits no records or only fully evidenced terminal records. A blocked/follow-ups marker permits `findings: none` with valid open, pending, unresolved, `UNKNOWN`, or imperfect terminal records, but it is non-ready; an `UNKNOWN` current-status record is valid only in that non-clean state or the all-`UNKNOWN` scalar state."
OUTSTANDING_MARKER_FINDINGS_RULE = "In the marker, `findings` is `none`, `UNKNOWN`, or `OUTSTANDING <refs>`; every OUTSTANDING ref is visible in the final blocker union even when no action record exists, while operational action refs need not be duplicated in findings. For `OUTSTANDING`, before comma/delimiter fallback, an entire canonical findings payload that exactly matches an accepted record ref is that one ref; otherwise retain comma- or whitespace-separated standalone refs, and consume a whitespace-bearing canonical record ref that matches the remaining findings text before standalone fallback."
COMPLETED_BATCH_AUDIT_RELEASE_ARCHIVE_RULE = "A completed-batch audit is release/archive-ready only when `audit_status: complete`, `verdict: clean`, `findings: none`, and `followups_dispositions` is `none` or only fully evidenced terminal records."
COMPLETED_BATCH_AUDIT_EXACT_REPLAY_RULE = "Replay only the exact versioned `<!-- completed-batch-audit v1` wrapper through its single final `-->`, with exactly one each of `batch_id`, `audit_status`, `verdict`, `scope_evidence`, `checker_evidence`, `findings`, and `followups_dispositions`; malformed, missing, duplicate, comment-token, newline, nested/case-varied `UNKNOWN`, or cross-field-inconsistent data fails."
COMPLETED_BATCH_AUDIT_IDENTITY_SCOPE_RULE = "A coordination-backed `batch_id` is an opaque nonempty single-line string and may contain `:` or `;`. Only exact lowercase `non-backend:` and `not-applicable:` prefixes trigger their typed rules; those forms require their rationale and `scope_evidence: targets=<exact refs>; source=<durable ref>`."
COMPLETED_BATCH_AUDIT_TERMINAL_DISPOSITION_RULE = "Terminal dispositions are exactly `resolved`, `accepted-waiver`, `accepted-deferral`, or `not-applicable`; nonterminal actions are exactly `investigate`, `fix`, `await-input`, `retry`, `replay`, or `track`. Terminal dispositions are invalid for nonterminal records and nonterminal actions are invalid for terminal records."
COMPLETED_BATCH_AUDIT_RECORD_GRAMMAR_RULE = "Each record has `ref`, `owner`, `current status`, `disposition`, and `evidence`; current status is exactly `open`, `unresolved`, `pending`, `UNKNOWN`, or `terminal`; duplicate refs block case-insensitively. `ref` and `owner` are nonempty. Nonterminal evidence is nonempty. Terminal evidence may be exact `UNKNOWN` or empty only as an explicitly non-ready blocker; nested/case-varied `UNKNOWN` is invalid."
COMPLETED_BATCH_AUDIT_RECORD_DELIMITER_RULE = "Within every record field (`ref`, `owner`, `current status`, `disposition`, and `evidence`), unescaped `;` and `|` are reserved delimiters and are rejected; escaping is not supported."
COMPLETED_BATCH_AUDIT_RECORD_REF_CANONICALIZATION_RULE = "Each completed-batch follow-up ref uses one canonical normalization: Unicode NFKC, collapse Unicode whitespace with `[[:space:]]+`, trim, and reject empty results; preserve the canonical display and derive identity with Unicode full case folding. Use that identity for record duplicates, findings-to-record lookup, and blocker deduplication; `ß` and `SS` collide. External blockers may share the safe canonical display, while record identity stays consistent. Duplicate canonical refs are invalid; every accepted distinct ref remains in the blocker union."
COMPLETED_BATCH_AUDIT_CANONICAL_DISPLAY_SAFETY_RULE = "After normalization, record and finding refs reject any canonical display that is empty, contains control line breaks, contains `<!--` or `-->`, or is exact/nested `UNKNOWN`. External blockers separately reject empty/control/HTML canonical displays but preserve `UNKNOWN` facts; normalize, dedupe, and render them in the exact Follow-ups union."
COMPLETED_BATCH_AUDIT_SINGLE_LINE_VALUE_RULE = "Every top-level scalar and record value is one physical line; reject embedded CR, LF, CRLF, NUL, control line breaks, and HTML comment tokens."
COMPLETED_BATCH_AUDIT_STRUCTURAL_READINESS_RULE = "A marker has separate well-formed, archive-ready, and blocker-union outputs. Clean/none accepts only no records or fully evidenced terminal records; blocked/follow-ups/OUTSTANDING accepts non-ready records. `UNKNOWN` current status is never ready and cannot appear in a clean/none marker."
COMPLETED_BATCH_AUDIT_WRAPPER_TOKEN_RULE = "Replay only the exact versioned `<!-- completed-batch-audit v1` wrapper through its single final `-->`, with exactly one each of `batch_id`, `audit_status`, `verdict`, `scope_evidence`, `checker_evidence`, `findings`, and `followups_dispositions`; malformed, missing, duplicate, comment-token, newline, nested/case-varied `UNKNOWN`, or cross-field-inconsistent data fails."
COMPLETED_BATCH_AUDIT_FINAL_STATUS_REPLAY_RULE = "Replay the final visible status line from the normalized blocker union: render a nonterminal record as `<ref> (<current status>): <action>`, imperfect terminal evidence as `<ref> (terminal): evidence UNKNOWN` or `evidence missing`, and exact `UNKNOWN` scalars as `<field>: UNKNOWN`. External blockers must be nonempty single-line text without HTML comment tokens; normalize and dedupe them with marker blockers. If marker parsing fails, replay `well=false`, `ready=false`, and the nonempty blocker `completed-batch-audit marker invalid`; normalize and union any sanitized external blockers. Its final status must be exact nonempty `Follow-ups`, never `Ready` or an empty blocker line. Use `Ready` iff archive-ready and the union is empty; otherwise use nonempty `Follow-ups` with that exact union."
COMPLETED_BATCH_AUDIT_INVALID_MARKER_BLOCKER = "completed-batch-audit marker invalid"
COMPLETED_BATCH_AUDIT_INVALID_MARKER_RULE = "If marker parsing fails, replay `well=false`, `ready=false`, and the nonempty blocker `completed-batch-audit marker invalid`; normalize and union any sanitized external blockers. Its final status must be exact nonempty `Follow-ups`, never `Ready` or an empty blocker line."
PARENT_AUDIT_HANDOFF_RULE = "The completed-batch audit handoff is an always-applicable parent-reconciliation surface for every batch, independent of all target-level `n/a` decisions. The durable coordinator-owned handoff records audit status, verdict, verified scope evidence, checker evidence, findings, and follow-ups/dispositions. Missing handoff, or missing or `UNKNOWN` audit status or verdict, blocks both coordinated release and parent archive. #{COMPLETED_BATCH_AUDIT_RELEASE_ARCHIVE_RULE} #{COMPLETED_BATCH_AUDIT_EXACT_REPLAY_RULE} #{COMPLETED_BATCH_AUDIT_IDENTITY_SCOPE_RULE} #{COMPLETED_BATCH_AUDIT_TERMINAL_DISPOSITION_RULE} #{TERMINAL_FOLLOW_UP_EVIDENCE_RULE} #{UNRESOLVED_HANDOFF_NON_CLEAN_RULE} #{OUTSTANDING_MARKER_FINDINGS_RULE} The parent only reconciles this handoff; it never reruns or owns the audit.".freeze
BATCH_TITLE_LINE = "Batch title: <PROJECT> <A?> <MM-DD HH:MM> - <short title>."
PLAN_PR_BATCH_CODEX_GOAL_LINE = "/goal\n"
PLAN_PR_BATCH_INVOCATION_LINE = "Use $pr-batch to complete this batch with subagents.\n"
BATCH_TITLE_PLACEHOLDER = "<PROJECT> <A?> <MM-DD HH:MM> - <short title>"
DATE_COMMAND = "date +'%m-%d %H:%M'"
CANONICAL_READINESS_STATES = %w[
  merged
  ready-gates-clean
  ready-no-merge-authority
  waiting-on-checks-or-review
  external-gate-failing
  blocked-user-input
  no-pr-evidence
].freeze
READINESS_STATE_KEYS = /\b(?:final_state|readiness_state|target_state):\s*`?([A-Za-z0-9_-]+)`?/

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def extract_goal_prompt_template(skill_text, heading, end_heading: /^##\s+/)
  heading_index = skill_text.index(heading)
  raise "missing #{heading} section" unless heading_index

  fence_start = skill_text.index(TEXT_FENCE, heading_index)
  raise "missing text fence in Goal Prompt section" unless fence_start

  fence_body_start = fence_start + TEXT_FENCE.length
  next_heading = skill_text.match(end_heading, fence_body_start)
  section_end = next_heading ? next_heading.begin(0) : skill_text.length
  section_body = skill_text[fence_body_start...section_end]
  fence_offsets = []
  section_body.scan(/^```\s*$/) { fence_offsets << Regexp.last_match.begin(0) }

  raise "missing closing fence in Goal Prompt section" if fence_offsets.empty?
  if fence_offsets.length > 1
    raise "goal prompt template contains a nested bare fence line; use a non-text fence type instead"
  end

  section_body[0...fence_offsets.first]
end

def extract_markdown_section(text, heading, end_heading: /^###\s+/)
  heading_index = text.index(heading)
  raise "missing #{heading} section" unless heading_index

  body_start = heading_index + heading.length
  next_heading = text.match(end_heading, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def contract_line(text)
  text.lines.grep(/^Goal Mode Completion Contract:/).first&.chomp
end

def compact_contract_line(text)
  text.lines.grep(/^\s*GMCC-v2:/).first&.strip
end

def assert_text_includes(text, phrase, label)
  assert text.include?(phrase), "#{label} is missing required phrase: #{phrase}"
end

def invalid_readiness_marker_values(text)
  allowed = CANONICAL_READINESS_STATES + ["UNKNOWN"]
  text.scan(READINESS_STATE_KEYS).flatten.reject { |value| allowed.include?(value) }.uniq
end

def canonical_auto_merge_parity_errors(text)
  errors = []
  count = text.scan(CANONICAL_AUTO_MERGE_EXPANSION).length
  errors << "expected 2 aligned canonical closeout copies, found #{count}" unless count == 2
  errors << "legacy generic closeout sentence remains" if text.include?(LEGACY_AUTO_MERGE_EXPANSION)
  errors
end

def completed_batch_audit_marker(body)
  "<!-- completed-batch-audit v1\n#{body.chomp}\n-->\n"
end

CompletedBatchAuditState = Struct.new(:fields, :records, keyword_init: true)
CompletedBatchAuditReplayResult = Struct.new(:well_formed, :ready, :blockers, keyword_init: true)
CanonicalCompletedBatchAuditRef = Struct.new(:canonical_display, :identity, keyword_init: true)
CompletedBatchAuditRecord = Struct.new(:ref, :ref_identity, :owner, :current_status, :disposition, :evidence, keyword_init: true) do
  def terminal?
    current_status == "terminal"
  end

  def fully_evidenced_terminal?
    terminal? && evidenced_scalar?(evidence)
  end

  def non_ready?
    !fully_evidenced_terminal?
  end
end

COMPLETED_BATCH_AUDIT_FIELDS = %w[
  batch_id audit_status verdict scope_evidence checker_evidence findings followups_dispositions
].freeze
CURRENT_STATUSES = %w[open unresolved pending UNKNOWN terminal].freeze
TERMINAL_DISPOSITIONS = %w[resolved accepted-waiver accepted-deferral not-applicable].freeze
NONTERMINAL_ACTIONS = %w[investigate fix await-input retry replay track].freeze

def completed_batch_audit_marker_fields(marker)
  envelope = marker.match(/\A<!-- completed-batch-audit v1\n(?<body>.*)\n-->\n?\z/m)
  return nil unless envelope

  fields = {}
  envelope[:body].each_line do |line|
    raw_line = line.delete_suffix("\n")
    match = raw_line.match(/\A([a-z_]+):[ \t]*(.*)\z/)
    return nil unless match

    key = match[1]
    return nil unless COMPLETED_BATCH_AUDIT_FIELDS.include?(key)
    return nil if fields.key?(key)
    return nil unless single_physical_line?(match[2])
    return nil if match[2].include?("<!--") || match[2].include?("-->")

    fields[key] = match[2].strip
  end

  fields.keys.sort == COMPLETED_BATCH_AUDIT_FIELDS.sort ? fields : nil
end

def completed_batch_audit_state(marker)
  fields = completed_batch_audit_marker_fields(marker)
  return nil unless fields

  records = followups_disposition_records(fields["followups_dispositions"])
  return nil unless records && completed_batch_audit_scalars_well_formed?(fields, records:) &&
                    completed_batch_audit_fields_are_consistent?(fields, records)

  CompletedBatchAuditState.new(fields:, records:)
end

def completed_batch_audit_marker_well_formed?(marker)
  !completed_batch_audit_state(marker).nil?
end

def completed_batch_audit_release_or_archive_ready?(marker)
  state = completed_batch_audit_state(marker)
  !state.nil? && completed_batch_audit_state_ready?(state)
end

def completed_batch_audit_state_ready?(state)
  fields = state.fields
  return false unless fields["audit_status"] == "complete" && fields["verdict"] == "clean"
  return false unless fields["findings"] == "none"
  return false unless evidenced_scalar?(fields["batch_id"])
  return false unless evidenced_scalar?(fields["scope_evidence"]) && evidenced_scalar?(fields["checker_evidence"])

  state.records.all?(&:fully_evidenced_terminal?)
end

def completed_batch_audit_final_status_replays?(marker, final_line, other_blockers: [])
  return false unless other_blockers.all? { |blocker| well_formed_other_blocker?(blocker) }

  result = completed_batch_audit_replay_result(marker, other_blockers:)
  return final_line == "Conversation status: Ready for archiving." if result.ready && result.blockers.empty?

  blockers = result.blockers
  return false if blockers.empty?

  final_line == "Conversation status: Follow-ups remain — #{blockers.join('; ')}."
end

def completed_batch_audit_marker_blockers(marker)
  completed_batch_audit_replay_result(marker).blockers
end

def completed_batch_audit_replay_result(marker, other_blockers: [])
  state = completed_batch_audit_state(marker)
  marker_blockers = state ? completed_batch_audit_state_blockers(state) : [COMPLETED_BATCH_AUDIT_INVALID_MARKER_BLOCKER]
  external_blockers = other_blockers.select { |blocker| well_formed_other_blocker?(blocker) }

  CompletedBatchAuditReplayResult.new(
    well_formed: !state.nil?,
    ready: !state.nil? && completed_batch_audit_state_ready?(state),
    blockers: deduped_blockers(marker_blockers + external_blockers)
  )
end

def completed_batch_audit_state_blockers(state)
  fields = state.fields
  records = state.records
  scalar_blockers = %w[batch_id audit_status verdict scope_evidence checker_evidence findings].filter_map do |field|
    "#{field}: UNKNOWN" if fields.fetch(field) == "UNKNOWN"
  end
  record_blockers_by_ref = records.filter_map do |record|
    next unless record.non_ready?

    blocker = if record.terminal?
                "#{record.ref} (terminal): evidence #{record.evidence == 'UNKNOWN' ? 'UNKNOWN' : 'missing'}"
              else
                "#{record.ref} (#{record.current_status}): #{record.disposition}"
              end
    [record.ref_identity, blocker]
  end.to_h
  record_blockers = record_blockers_by_ref.values
  finding_blockers = completed_batch_audit_finding_refs(fields.fetch("findings"), records:).to_a.map do |ref|
    record_blockers_by_ref.fetch(ref.identity, ref.canonical_display)
  end
  unlisted_record_blockers = record_blockers.reject do |blocker|
    finding_blockers.any? { |finding| finding.casecmp?(blocker) }
  end

  deduped_blockers(scalar_blockers + finding_blockers + unlisted_record_blockers)
end

def well_formed_other_blocker?(value)
  return false unless value.is_a?(String) && single_physical_line?(value)
  return false if value.include?("<!--") || value.include?("-->")

  safe_canonical_completed_batch_audit_external_blocker?(canonical_completed_batch_audit_ref(value))
end

def normalized_blocker(value)
  canonical_completed_batch_audit_ref(value)&.canonical_display.to_s
end

def deduped_blockers(blockers)
  blockers.each_with_object([]) do |blocker, deduped|
    canonical = canonical_completed_batch_audit_ref(blocker)
    next unless canonical

    deduped << canonical.canonical_display unless deduped.any? do |known|
      canonical_completed_batch_audit_ref(known).identity == canonical.identity
    end
  end
end

def completed_batch_audit_scalars_well_formed?(fields, records: [])
  well_formed_batch_identity?(fields["batch_id"], fields["scope_evidence"]) &&
    %w[complete blocked UNKNOWN].include?(fields["audit_status"]) &&
    %w[clean follow-ups-remain UNKNOWN].include?(fields["verdict"]) &&
    structurally_valid_scalar?(fields["scope_evidence"]) &&
    structurally_valid_scalar?(fields["checker_evidence"]) &&
    structurally_valid_followups_dispositions?(fields["followups_dispositions"]) &&
    well_formed_findings?(fields["findings"], records:)
end

def well_formed_batch_identity?(value, scope_evidence)
  return true if exact_unknown?(value)
  return false unless structurally_valid_scalar?(value) && evidenced_scalar?(value)

  if value.start_with?("non-backend:")
    return value.match?(/\Anon-backend:\s*[^;\s](?:[^;]*[^;\s])?;\s*rationale:\s*[^;\s](?:[^;]*[^;\s])?\z/) &&
           exact_target_scope_evidence?(scope_evidence)
  end
  if value.start_with?("not-applicable:")
    return value.match?(/\Anot-applicable:\s*[^;\s](?:[^;]*[^;\s])?\z/) &&
           exact_target_scope_evidence?(scope_evidence)
  end

  true
end

def well_formed_findings?(value, records: [])
  return true if %w[none UNKNOWN].include?(value)

  refs = completed_batch_audit_finding_refs(value, records:)
  structurally_valid_scalar?(value) && value.match?(/\AOUTSTANDING\s+\S(?:.*\S)?\z/) &&
    !unknown_value?(value) && refs && !refs.empty? && refs.all? { |ref| safe_canonical_completed_batch_audit_ref?(ref) } &&
    refs.map(&:identity).uniq.length == refs.length
end

def completed_batch_audit_fields_are_consistent?(fields, records)
  findings = fields.fetch("findings")
  verdict = fields.fetch("verdict")
  non_ready_records = records.select(&:non_ready?)
  outstanding = findings.start_with?("OUTSTANDING ")
  unknown_marker = fields.fetch("audit_status") == "UNKNOWN" && verdict == "UNKNOWN" && findings == "UNKNOWN"
  clean_marker = fields.fetch("audit_status") == "complete" && verdict == "clean" && findings == "none"

  return true if clean_marker && non_ready_records.empty?
  return true if unknown_marker

  return false unless %w[complete blocked].include?(fields.fetch("audit_status"))
  return false unless verdict == "follow-ups-remain"
  return false unless findings == "none" || outstanding
  return false if non_ready_records.empty? && !outstanding

  true
end

def exact_target_scope_evidence?(value)
  value.match?(/\Atargets=[^;\s](?:[^;]*[^;\s])?; source=[^;\s](?:[^;]*[^;\s])?\z/) && !unknown_value?(value)
end

def evidenced_scalar?(value)
  structurally_valid_scalar?(value) && !unknown_value?(value)
end

def structurally_valid_scalar?(value)
  !value.nil? && !value.empty? && single_physical_line?(value) &&
    !value.include?("<!--") && !value.include?("-->") && (exact_unknown?(value) || !unknown_value?(value))
end

def structurally_valid_followups_dispositions?(value)
  !value.nil? && !value.empty? && single_physical_line?(value) &&
    !value.include?("<!--") && !value.include?("-->")
end

def single_physical_line?(value)
  !value.match?(/[\r\n\0\v\f\u0085\u2028\u2029]/)
end

def exact_unknown?(value)
  value == "UNKNOWN"
end

def unknown_value?(value)
  value.match?(/UNKNOWN/i)
end

def followups_disposition_records(value)
  return [] if value == "none"
  return nil if value.nil? || value.empty?

  records = value.split(/\s+\|\s+/, -1)
  return nil if records.empty? || records.any? { |record| record.empty? || record.include?("|") }

  seen_refs = {}
  records.map do |record|
    fields = record.split(/\s*;\s*/, -1).each_with_object({}) do |entry, parsed|
      match = entry.match(/\A(ref|owner|current status|disposition|evidence):\s*(.*)\z/i)
      break nil unless match

      key = match[1].downcase
      raw_value = match[2]
      break nil unless single_physical_line?(raw_value)

      value = raw_value.strip
      break nil if parsed.key?(key)
      break nil unless value.empty? ? key == "evidence" : structurally_valid_scalar?(value)

      parsed[key] = value
    end
    return nil unless fields&.keys&.sort == ["current status", "disposition", "evidence", "owner", "ref"]

    canonical_ref = canonical_completed_batch_audit_ref(fields.fetch("ref"))
    return nil unless safe_canonical_completed_batch_audit_ref?(canonical_ref)
    return nil if seen_refs.key?(canonical_ref.identity)

    seen_refs[canonical_ref.identity] = true
    status = fields.fetch("current status")
    return nil unless CURRENT_STATUSES.include?(status)

    disposition = fields.fetch("disposition")
    return nil unless status == "terminal" ? TERMINAL_DISPOSITIONS.include?(disposition) : NONTERMINAL_ACTIONS.include?(disposition)
    return nil unless evidenced_scalar?(canonical_ref.canonical_display) && evidenced_scalar?(fields.fetch("owner"))
    return nil unless status == "terminal" || evidenced_scalar?(fields.fetch("evidence"))

    CompletedBatchAuditRecord.new(
      ref: canonical_ref.canonical_display,
      ref_identity: canonical_ref.identity,
      owner: fields.fetch("owner"),
      current_status: status,
      disposition:,
      evidence: fields.fetch("evidence")
    )
  end
end

def canonical_completed_batch_audit_ref(value)
  canonical_display = value.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
  return nil if canonical_display.empty?

  CanonicalCompletedBatchAuditRef.new(
    canonical_display:,
    identity: canonical_display.downcase(:fold)
  )
end

def safe_canonical_completed_batch_audit_ref?(canonical_ref)
  canonical_ref && single_physical_line?(canonical_ref.canonical_display) &&
    !canonical_ref.canonical_display.include?("<!--") &&
    !canonical_ref.canonical_display.include?("-->") && !unknown_value?(canonical_ref.canonical_display)
end

def safe_canonical_completed_batch_audit_external_blocker?(canonical_ref)
  canonical_ref && single_physical_line?(canonical_ref.canonical_display) &&
    !canonical_ref.canonical_display.include?("<!--") && !canonical_ref.canonical_display.include?("-->")
end

def completed_batch_audit_finding_refs(value, records: [])
  return [] unless value.start_with?("OUTSTANDING ")

  raw_refs = value.delete_prefix("OUTSTANDING ")
  known_refs = records.map do |record|
    CanonicalCompletedBatchAuditRef.new(canonical_display: record.ref, identity: record.ref_identity)
  end
  known_refs.sort_by! { |ref| -ref.canonical_display.length }
  canonical_payload = canonical_completed_batch_audit_ref(raw_refs)
  return nil unless canonical_payload

  whole_record_ref = known_refs.find { |ref| ref.identity == canonical_payload.identity }
  return [whole_record_ref] if whole_record_ref

  refs = raw_refs.split(/\s*,\s*/, -1).flat_map do |group|
    completed_batch_audit_finding_group_refs(group, known_refs)
  end
  return nil unless refs && !refs.empty? && refs.none?(&:nil?)

  refs
end

def completed_batch_audit_finding_group_refs(group, known_refs)
  canonical_group = canonical_completed_batch_audit_ref(group)
  return nil unless canonical_group

  tokens = canonical_group.canonical_display.split(" ")
  refs = []
  index = 0
  while index < tokens.length
    remaining_identity = tokens[index..].join(" ").downcase(:fold)
    record_ref = known_refs.find do |known_ref|
      remaining_identity == known_ref.identity || remaining_identity.start_with?("#{known_ref.identity} ")
    end
    if record_ref
      refs << record_ref
      index += record_ref.canonical_display.split(" ").length
    else
      ref = canonical_completed_batch_audit_ref(tokens[index])
      return nil unless ref

      refs << ref
      index += 1
    end
  end

  refs
end

class GoalCompletionContractTest < Minitest::Test
  def setup
    @workflow = read_repo_file(WORKFLOW_PATH)
    @spec_skill = read_repo_file(SPEC_SKILL_PATH)
    @pr_batch_skill = read_repo_file(PR_BATCH_SKILL_PATH)
    @plan_pr_batch_skill = read_repo_file(PLAN_PR_BATCH_SKILL_PATH)
    @triage_skill = read_repo_file(TRIAGE_SKILL_PATH)
    @adversarial_review_workflow = read_repo_file(ADVERSARIAL_REVIEW_WORKFLOW_PATH)
    @pr_monitoring_skill = read_repo_file(PR_MONITORING_SKILL_PATH)
    @pr_batch_docs = read_repo_file(PR_BATCH_DOCS_PATH)
    @changelog = read_repo_file(CHANGELOG_PATH)
    @workflow_contract_section = extract_markdown_section(@workflow, "### Goal Mode Completion Contract")
    @workflow_goal_prompt = extract_goal_prompt_template(
      @workflow,
      "### Plan To Goal Handoff",
      end_heading: /^###\s+/
    )
    @pr_batch_goal_prompt = extract_goal_prompt_template(@pr_batch_skill, "## Goal Prompt Template")
    @plan_goal_prompt = extract_goal_prompt_template(@plan_pr_batch_skill, "## Goal Prompt for pr-batch")
  end

  def test_canonical_workflow_retains_the_full_authoritative_contract
    {
      "workflows/pr-processing.md canonical contract" => @workflow_contract_section
    }.each do |label, text|
      assert_text_includes text, "Goal Mode Completion Contract", label
      assert_text_includes text, "waiting-on-checks-or-review` is not an overall Goal-mode terminal state", label
      assert_text_includes text, "report NOT COMPLETE", label
      assert_text_includes text, "pending, missing, or untriaged current-head CI", label
      assert_text_includes text, "unresolved current-head review threads", label
      assert_text_includes text, "watch window", label
      assert_text_includes text, "resume instructions", label
      assert_text_includes text, "UNKNOWN", label
      assert_equal CANONICAL_CONTRACT_LINE, contract_line(text)
    end
  end

  def test_goal_prompts_retain_every_completion_invariant_inline
    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_equal COMPACT_CONTRACT_LINE, compact_contract_line(text), "#{label} compact contract drifted"
      COMPACT_CONTRACT_INVARIANTS.each { |invariant| assert_text_includes text, invariant, label }
    end

    assert_equal COMPACT_CONTRACT_LINE, compact_contract_line(@triage_skill),
                 "skills/triage/SKILL.md generated-prompt contract drifted"
    COMPACT_CONTRACT_INVARIANTS.each do |invariant|
      assert_text_includes compact_contract_line(@triage_skill), invariant, "skills/triage/SKILL.md compact contract"
    end

    [@workflow_contract_section, @triage_skill].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_text_includes normalized,
                           "inline semantics remain normative when the workflow reference is missing or cannot autoload",
                           "autoload-failure completion guidance"
    end
  end

  def test_blocked_goal_defaults_to_a_deduped_fifteen_minute_current_thread_monitor
    assert_text_includes @workflow_contract_section, "15-minute", "canonical completion contract"
    assert_text_includes @workflow_contract_section, "current-thread monitor", "canonical completion contract"
    assert_text_includes @workflow_contract_section, "do not create a duplicate", "canonical completion contract"
    assert_text_includes @workflow_contract_section, "Stop the monitor", "canonical completion contract"
    assert_text_includes @workflow_contract_section, "manual resume instructions", "canonical completion contract"
    assert_text_includes @workflow_contract_section, "`blocked-user-input` does not start a monitor",
                         "canonical completion contract"

    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt, @triage_skill].each do |text|
      line = compact_contract_line(text)
      assert_text_includes line, "auto-clear block=>host wake: 1 deduped 15m current-thread watch, else exact manual resume",
                           "compact completion contract"
      refute_includes line, "`blocked`=>", "compact completion contract"
      refute_includes line, "non-user block=>", "compact completion contract"
      assert_text_includes line, "else exact manual resume", "compact completion contract"
      assert_text_includes line, "stop unblocked/done", "compact completion contract"
    end

    assert_text_includes @workflow_contract_section, "recurring automation/wakeup capability",
                         "canonical completion contract"
    assert_text_includes @workflow_contract_section,
                         "re-enter this same thread on schedule and be inspected, updated, and stopped",
                         "canonical completion contract"
  end

  def test_continuation_prompt_preserves_blocked_goal_monitor_semantics
    continuation = extract_markdown_section(
      @workflow,
      "### Generic PR-Batch Continuation Prompt",
      end_heading: /^###\s+/
    )

    assert_text_includes continuation, "overall goal is genuinely blocked", "continuation prompt"
    assert_text_includes continuation, "can clear without user input", "continuation prompt"
    assert_text_includes continuation, "recurring automation/wakeup capability", "continuation prompt"
    assert_text_includes continuation,
                         "re-enter this same thread on schedule and be inspected, updated, and stopped",
                         "continuation prompt"
    assert_text_includes continuation, "reuse or create one 15-minute current-thread monitor", "continuation prompt"
    assert_text_includes continuation, "do not create a duplicate", "continuation prompt"
    assert_text_includes continuation, "On each wake", "continuation prompt"
    assert_text_includes continuation, "Stop the monitor", "continuation prompt"
    assert_text_includes continuation, "manual resume instructions", "continuation prompt"
    assert_text_includes continuation, "`blocked-user-input` does not start a monitor", "continuation prompt"
    assert_text_includes continuation, CANONICAL_AUTO_MERGE_EXPANSION, "continuation prompt"
    refute_includes continuation, LEGACY_AUTO_MERGE_EXPANSION, "continuation prompt"
  end

  def test_non_prompt_gmcc_alignment_sentence_is_exact_on_all_generation_surfaces
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/triage/SKILL.md" => @triage_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill
    }
    actual_counts = surfaces.transform_values { |text| text.scan(GMCC_ALIGNMENT_SENTENCE).length }
    expected_counts = surfaces.transform_values { 1 }
    assert_equal expected_counts, actual_counts,
                 "all generation surfaces must carry the exact GMCC-v2 alignment sentence once"

    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt].each do |prompt|
      refute_includes prompt, GMCC_ALIGNMENT_SENTENCE,
                      "the non-prompt alignment sentence must not consume goal-prompt headroom"
    end
  end

  def test_triaged_but_unresolved_current_head_review_thread_is_not_complete
    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt].each do |prompt|
      line = compact_contract_line(prompt)
      assert_text_includes line, "unresolved current-head review threads", "compact completion contract"
      assert_operator line.index("unresolved current-head review threads"), :<, line.index("=>NOT COMPLETE")
    end
  end

  def test_compact_current_head_gate_categories_match_the_canonical_contract
    assert_text_includes @workflow_contract_section,
                         "current-head CI or configured review agents, unresolved current-head review threads",
                         "canonical completion contract"

    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt].each do |prompt|
      line = compact_contract_line(prompt)
      assert_text_includes line,
                           "pending/missing/untriaged current-head CI/configured review agents; " \
                           "unresolved current-head review threads",
                           "compact completion contract"
      refute_includes line, "CI/reviews/review agents",
                      "compact completion contract must not duplicate the review category"
    end
  end

  def test_compact_contract_rejects_configured_reviewer_omission
    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt].each do |prompt|
      line = compact_contract_line(prompt)
      assert_includes line, "CI/configured review agents",
                      "standalone completion must retain the configured-reviewer gate"

      omission_mutation = line.sub("configured review agents", "review agents")
      refute_includes omission_mutation, "CI/configured review agents",
                      "configured-reviewer omission mutation must lose the required invariant"
      assert_includes omission_mutation, "CI/review agents",
                      "mutation fixture must exercise the exact reviewer qualifier omission"
    end
  end

  def test_auto_merge_closeout_handles_pr_only_and_ad_hoc_targets
    [@workflow_goal_prompt, @pr_batch_goal_prompt, @plan_goal_prompt].each do |prompt|
      line = compact_contract_line(prompt)
      assert_text_includes line,
                           "auto_merge_when_gates_pass=>no real blocker: merge+close any PR",
                           "compact completion contract"
      assert_text_includes line, "close target+any issue", "compact completion contract"
      refute_includes line, "merge+close PR+issue",
                      "PR-only and ad-hoc closeout must not require an issue that does not exist"
      refute_match(/applicable issue absent blocker/, line,
                   "the real-blocker exception must scope the entire auto-merge closeout clause")
    end
  end

  def test_goal_prompts_include_thread_handle_and_registration_contract
    prompts = {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }
    registration_patterns = {
      "workflows/pr-processing.md goal prompt" => /register before launch when supported/i,
      "skills/pr-batch goal prompt" => /register before launch when supported/i,
      "skills/plan-pr-batch goal prompt" => /register before launch when supported/i
    }

    prompts.each do |label, text|
      assert_text_includes text, "Thread handle: <batch-short>-<lane>-<word>", label
      assert_match registration_patterns.fetch(label), text, "#{label} is missing registration language"
      assert_text_includes text, "holder/generation", label
      assert_text_includes text, "UNKNOWN", label
    end
  end

  def test_thread_handle_derivation_guidance_is_documented
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, "first worker-specific line", label
      assert_text_includes text, "<batch-short>", label
      assert_text_includes text, "<lane>", label
      assert_text_includes text, "coordinator-chosen session word", label
    end
  end

  def test_lane_card_contract_is_documented
    workflow_worker_rules = extract_markdown_section(@workflow, "### Worker Rules")
    assert_text_includes workflow_worker_rules, "Lane Card", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "after a successful claim", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "when the PR is opened", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "`claim:`", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "holder|UNKNOWN", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "generation|UNKNOWN", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "instance|UNKNOWN", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "dashboard_url", "workflows/pr-processing.md Worker Rules"
    assert_text_includes workflow_worker_rules, "pr_url", "workflows/pr-processing.md Worker Rules"

    {
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, "Lane Card", label
      assert_text_includes text, "after a successful claim", label
      assert_text_includes text, "when the PR is opened", label
      assert_text_includes text, "claim holder", label
      assert_text_includes text, "dashboard_url", label
      assert_text_includes text, "pr_url", label
    end

    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "Lane Card:", label
      assert_text_includes text, "holder", label
      assert_text_includes text, "PR-open", label
      assert_text_includes text, "UNKNOWN", label
    end
  end

  def test_workflow_defines_canonical_readiness_vocabulary
    workflow_text = extract_markdown_section(@workflow, "### Batch Handoff Format", end_heading: /^###\s+/)
    CANONICAL_READINESS_STATES.each do |state|
      assert_text_includes workflow_text, "`#{state}`", "workflows/pr-processing.md"
    end
    assert_text_includes workflow_text, "UNKNOWN", "workflows/pr-processing.md"
  end

  def test_planning_skills_link_to_canonical_readiness_vocabulary
    {
      "skills/spec/SKILL.md" => extract_markdown_section(@spec_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/),
      "skills/plan-pr-batch/SKILL.md" => extract_markdown_section(@plan_pr_batch_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/),
      "skills/pr-batch/SKILL.md" => extract_markdown_section(@pr_batch_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/)
    }.each do |label, text|
      assert_text_includes text, CANONICAL_READINESS_LINK, label
      assert_text_includes text, "UNKNOWN", label
      assert_text_includes text, "JSON is not mandatory", label
    end
  end

  def test_structured_readiness_markers_use_canonical_values
    skill_text = {
      "skills/spec/SKILL.md" => @spec_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill
    }

    skill_text.each do |label, text|
      invalid_values = invalid_readiness_marker_values(text)
      assert_empty invalid_values, "#{label} contains invalid structured readiness values: #{invalid_values.join(', ')}"
    end
  end

  def test_structured_readiness_marker_validation_rejects_vague_ready
    invalid_values = invalid_readiness_marker_values("final_state: ready\nreadiness_state: `UNKNOWN`\ntarget_state: Unknown\n")
    assert_equal %w[ready Unknown], invalid_values
  end

  def test_skill_prose_points_to_canonical_contract_instead_of_pasting_it
    assert_text_includes @pr_batch_skill, CANONICAL_CONTRACT_LINK, "skills/pr-batch/SKILL.md"
    assert_equal 0, @pr_batch_skill.scan(PENDING_CHECKS_PRESSURE).length,
                 "skills/pr-batch/SKILL.md should leave the verbose pressure example in the canonical workflow"
    assert_equal 1, @pr_batch_skill.scan(COMPACT_CONTRACT_LINE).length,
                 "skills/pr-batch/SKILL.md should carry one self-contained compact prompt contract"
  end

  def test_compact_prompt_contracts_stay_byte_for_byte_aligned
    contracts = {
      "workflows/pr-processing.md canonical compact contract" => compact_contract_line(@workflow_contract_section),
      "workflows/pr-processing.md goal prompt" => compact_contract_line(@workflow_goal_prompt),
      "skills/pr-batch goal prompt" => compact_contract_line(@pr_batch_goal_prompt),
      "skills/plan-pr-batch goal prompt" => compact_contract_line(@plan_goal_prompt),
      "skills/triage generated-prompt requirement" => compact_contract_line(@triage_skill)
    }

    contracts.each do |label, line|
      refute_nil line, "#{label} is missing the GMCC-v2 line"
      assert_equal COMPACT_CONTRACT_LINE, line, "#{label} drifted"
    end
  end

  def test_goal_prompt_extractor_rejects_nested_bare_fence_lines
    skill_text = <<~TEXT
      ## Goal Prompt Template

      ```text
      Use $pr-batch.
      ```
      stray prose
      ```

      ## Next Section
    TEXT

    error = assert_raises(RuntimeError) { extract_goal_prompt_template(skill_text, "## Goal Prompt Template") }
    assert_match(/nested bare fence/, error.message)
  end

  def test_pending_hosted_checks_pressure_scenario_is_not_complete
    assert_text_includes @workflow_contract_section, PENDING_CHECKS_PRESSURE, "workflows/pr-processing.md"

    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "pending/missing/untriaged current-head CI", label
      assert_text_includes text, "fail/UNKNOWN=>NOT COMPLETE", label
    end
  end

  def test_current_head_pending_review_draft_readiness_guard_is_aligned
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "workflows/adversarial-pr-review.md" => @adversarial_review_workflow,
      "skills/pr-monitoring/SKILL.md" => @pr_monitoring_skill,
      "docs/pr-batch-skills.md" => @pr_batch_docs
    }.each do |label, text|
      assert_text_includes text, PENDING_REVIEW_DRAFT_GUARD, label
    end
  end

  def test_goal_prompts_put_batch_title_after_target_invocation
    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert text.start_with?("#{PLAN_PR_BATCH_INVOCATION_LINE}#{BATCH_TITLE_LINE}\n"),
             "#{label} must put the standard batch title line after the invocation"
    end

    codex_goal_prompt = "#{PLAN_PR_BATCH_CODEX_GOAL_LINE}#{@plan_goal_prompt}"
    assert codex_goal_prompt.start_with?("#{PLAN_PR_BATCH_CODEX_GOAL_LINE}#{PLAN_PR_BATCH_INVOCATION_LINE}#{BATCH_TITLE_LINE}\n"),
           "skills/plan-pr-batch Codex goal prompt must put the standard batch title line after the Codex prefix"
  end

  def test_batch_title_instructions_pin_local_date_source
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, DATE_COMMAND, label
    end
  end

  def test_batch_title_skill_rules_use_canonical_placeholder
    {
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, BATCH_TITLE_PLACEHOLDER, label
      refute_includes text, "<PROJECT> <A/B/C when multiple> <MM-DD HH:MM> - <descriptive title>",
                      "#{label} should not use the old batch title placeholder"
    end
  end

  def test_ready_no_merge_authority_is_terminal_only_without_merge_authority
    assert_text_includes @workflow_contract_section,
                         "`ready-no-merge-authority` is terminal only when `merge_authority` does not allow merging",
                         "workflows/pr-processing.md"

    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "ready-no-merge-authority iff no auth", label
    end
  end

  def test_auto_merge_done_means_merged_or_blocked
    assert_empty canonical_auto_merge_parity_errors(@workflow_contract_section),
                 "canonical expansion and pressure check must preserve PR, target, and issue closeout parity"

    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text,
                           "auto_merge_when_gates_pass=>no real blocker: merge+close any PR",
                           label
      assert_text_includes text, "close target+any issue", label
    end
  end

  def test_canonical_auto_merge_parity_rejects_legacy_closeout_mutation
    legacy_mutation = @workflow_contract_section.sub(
      CANONICAL_AUTO_MERGE_EXPANSION,
      LEGACY_AUTO_MERGE_EXPANSION
    )

    errors = canonical_auto_merge_parity_errors(legacy_mutation)
    assert_includes errors, "expected 2 aligned canonical closeout copies, found 1"
    assert_includes errors, "legacy generic closeout sentence remains"
  end

  def test_goal_prompts_route_final_handoff_to_canonical_closeout
    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, CANONICAL_CLOSEOUT_PROMPT_LINE, label
    end
  end

  def test_canonical_closeout_requires_audit_before_final_conversation_status
    closeout = extract_markdown_section(@workflow, "### Coordinator Closeout Lane", end_heading: /^##\s+/)
    normalized_closeout = closeout.gsub(/\s+/, " ")

    [
      ["workflows/pr-processing.md", @workflow],
      ["skills/pr-batch/SKILL.md", @pr_batch_skill]
    ].each do |label, text|
      normalized_text = text.gsub(/\s+/, " ")
      assert_includes normalized_text, BATCH_COORDINATOR_AUDIT_OWNERSHIP, label
      refute_includes normalized_text, OBSOLETE_PARENT_AUDIT_OWNERSHIP,
                      "#{label} must not assign completed-batch audits to a parent"
    end

    assert_includes normalized_closeout, "End the final user-visible message after the audit."
    assert_includes normalized_closeout,
                    "A conversation is archive-ready only when the audit is clean and there are no OUTSTANDING findings, follow-ups, unresolved questions, pending work, or `UNKNOWN` facts."
    assert_includes normalized_closeout, TERMINAL_FOLLOW_UP_EVIDENCE_RULE
    assert_includes normalized_closeout, UNRESOLVED_HANDOFF_NON_CLEAN_RULE
    assert_includes normalized_closeout, "Conversation status: Ready for archiving."
    assert_includes normalized_closeout, "Conversation status: Follow-ups remain — <each exact action or blocker>."
    normalized_pr_batch_skill = @pr_batch_skill.gsub(/\s+/, " ")
    assert_includes normalized_pr_batch_skill, TERMINAL_FOLLOW_UP_EVIDENCE_RULE
    assert_includes normalized_pr_batch_skill, UNRESOLVED_HANDOFF_NON_CLEAN_RULE
  end

  def test_planning_chat_lifecycle_defines_only_two_roles_and_prompt_only_archive
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_equal %w[prompt-only parent-orchestrator], lifecycle.scan(/^- \*\*([^*]+)\*\*:/).flatten
    assert_includes lifecycle,
                    "all prompts are delivered or registered and stable batch/lane/dependency/ownership state is durable outside the chat"
    assert_includes lifecycle, "It does not wait for workers."
    assert_includes lifecycle, PROMPT_ONLY_ARCHIVE_RULE

    {
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, "Planning-Chat Lifecycle", label
    end
  end

  def test_planning_chat_self_launch_transitions_to_batch_coordinator_without_a_third_role
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    assert_equal %w[prompt-only parent-orchestrator], lifecycle.scan(/^- \*\*([^*]+)\*\*:/).flatten

    {
      "workflows/pr-processing.md Planning-Chat Lifecycle" => lifecycle,
      "skills/plan-pr-batch/SKILL.md Batch Plan Format" => batch_plan,
      "skills/triage/SKILL.md Output" => triage_output
    }.each do |label, text|
      assert_includes text, PROMPT_ONLY_DISTINCT_COORDINATOR_HANDOFF_RULE, label
      assert_includes text, PLANNING_CHAT_SELF_LAUNCH_TRANSITION_RULE, label
      assert_includes text, SELF_LAUNCH_RETAINED_DUTY_PARENT_RULE, label
    end
  end

  def test_same_chat_launch_now_without_retained_responsibility_has_a_satisfiable_post_transition_record
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "skills/plan-pr-batch/SKILL.md Batch Plan Format" => batch_plan,
      "skills/triage/SKILL.md Output" => triage_output
    }.each do |label, text|
      assert_includes text, PLANNING_CHAT_ROLE_RULE, label
      assert_includes text, PARENT_ORCHESTRATOR_SELECTOR_RULE, label
      assert_includes text, SELF_LAUNCH_LIFECYCLE_TRANSITION, label
      assert_includes text, SELF_LAUNCH_PLANNING_CHAT_ROLE, label
      assert_includes text, SELF_LAUNCH_CLOSEOUT_OWNER, label
      assert_includes text, SELF_LAUNCH_NO_RETAINED_RESPONSIBILITY, label
      assert_includes text, SELF_LAUNCH_NOT_A_THIRD_PLANNING_ROLE, label
    end
  end

  def test_same_chat_launch_with_retained_duties_stays_parent_orchestrated
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "workflows/pr-processing.md Planning-Chat Lifecycle" => lifecycle,
      "skills/plan-pr-batch/SKILL.md Batch Plan Format" => batch_plan,
      "skills/triage/SKILL.md Output" => triage_output
    }.each do |label, text|
      assert_includes text, PLANNING_CHAT_SELF_LAUNCH_TRANSITION_RULE, label
      assert_includes text, SELF_LAUNCH_RETAINED_DUTY_PARENT_RULE, label
      refute_includes text,
                      "select `parent-orchestrator` only after durable handoff/launch of a distinct batch coordinator",
                      label
    end
  end

  def test_same_chat_launch_with_retained_duties_blocks_read_only_before_distinct_coordinator_handoff
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "workflows/pr-processing.md Planning-Chat Lifecycle" => lifecycle,
      "skills/plan-pr-batch/SKILL.md Batch Plan Format" => batch_plan,
      "skills/triage/SKILL.md Output" => triage_output
    }.each do |label, text|
      assert_includes text, RETAINED_DUTY_NO_HANDOFF_BLOCK_RULE, label
    end
  end

  def test_same_chat_launch_with_retained_duties_starts_workers_only_under_the_distinct_coordinator
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "workflows/pr-processing.md Planning-Chat Lifecycle" => lifecycle,
      "skills/plan-pr-batch/SKILL.md Batch Plan Format" => batch_plan,
      "skills/triage/SKILL.md Output" => triage_output
    }.each do |label, text|
      assert_includes text, RETAINED_DUTY_DISTINCT_COORDINATOR_RULE, label
    end
  end

  def test_plan_pr_batch_output_orders_conversation_status_as_the_actual_final_line
    assert_includes @plan_pr_batch_skill, PLAN_PR_BATCH_RESPONSE_ORDER

    ["Batch Plan", "generated goal prompt", "Goal prompt character count",
     "selected exact", "actual final user-visible line"].each_cons(2) do |first, second|
      assert_operator PLAN_PR_BATCH_RESPONSE_ORDER.index(first), :<,
                      PLAN_PR_BATCH_RESPONSE_ORDER.index(second),
                      "plan-pr-batch response order must keep #{first.inspect} before #{second.inspect}"
    end
  end

  def test_triage_output_orders_conversation_status_as_the_actual_final_line
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    assert_includes triage_output, TRIAGE_RESPONSE_ORDER

    ["scope/repositories/sources", "phase-1 counts/dependency graph", "coordination",
     "capacity", "wave plan/prompts", "lifecycle record", "queue summary if applicable",
     "residual risks", "maintainer decisions", "selected exact", "actual final user-visible line"].each_cons(2) do |first, second|
      assert_operator TRIAGE_RESPONSE_ORDER.index(first), :<,
                      TRIAGE_RESPONSE_ORDER.index(second),
                      "triage response order must keep #{first.inspect} before #{second.inspect}"
    end
  end

  def test_prompt_only_non_clean_status_is_explicit_on_every_lifecycle_surface
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)
    pressure_checks = lifecycle[lifecycle.index("Pressure checks:")..]
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "workflows/pr-processing.md prompt-only pressure check" => pressure_checks,
      "skills/plan-pr-batch/SKILL.md Batch Plan prompt-only expectation" => batch_plan,
      "skills/triage/SKILL.md durable lifecycle record" => triage_output
    }.each do |label, text|
      assert_includes text, PROMPT_ONLY_NON_CLEAN_STATUS_RULE, label
    end
  end

  def test_batch_plan_requires_lifecycle_metadata_outside_the_goal_prompt
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)

    refute_includes batch_plan, "## Goal Prompt for pr-batch"

    assert_includes batch_plan, PLANNING_CHAT_ROLE_RULE
    assert_includes batch_plan, "Planning-chat role selector: default to `prompt-only`."
    assert_includes batch_plan, PARENT_ORCHESTRATOR_SELECTOR_RULE
    assert_includes batch_plan, "Retained responsibilities: list each exact retained responsibility."
    assert_includes batch_plan, "Archive/closeout owner:"
    assert_includes batch_plan, PROMPT_ONLY_ARCHIVE_EXPECTATION
    assert_includes batch_plan,
                    "Parent-orchestrator conversation-status/archive expectation: clean only when parent reconciliation has no OUTSTANDING follow-up or `UNKNOWN`; then use exactly `Conversation status: Ready for archiving.` Otherwise use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.` and list each exact action or blocker."
    assert_includes batch_plan, "Keep this lifecycle metadata in the Batch Plan, outside the generated goal prompt."

    refute_includes @plan_goal_prompt, "Planning-chat role:"
    refute_includes @plan_goal_prompt, "Archive/closeout owner:"
    refute_includes @plan_goal_prompt, "Final conversation-status/archive expectation:"
  end

  def test_prompt_only_clean_archive_prerequisite_is_explicit_in_batch_plan_and_triage_output
    batch_plan = extract_markdown_section(@plan_pr_batch_skill, "## Batch Plan Format", end_heading: /^##\s+/)
    triage_output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/)

    {
      "skills/plan-pr-batch/SKILL.md Batch Plan prompt-only expectation" => batch_plan,
      "skills/triage/SKILL.md Output prompt-only expectation" => triage_output
    }.each do |label, text|
      normalized_text = text.gsub(/\s+/, " ")

      assert_includes normalized_text, PROMPT_ONLY_ARCHIVE_EXPECTATION, label
      assert_operator normalized_text.index(PROMPT_ONLY_ARCHIVE_PREREQUISITE), :<,
                      normalized_text.index("no unhanded-off question or planner-owned `UNKNOWN` remains"),
                      "#{label} must put durable planning state before the no-question/planner-UNKNOWN condition"
      assert_includes normalized_text,
                      "a durably handed-off coordinator-owned worker state, including a worker `UNKNOWN`, does not block prompt-only archive",
                      label
    end
  end

  def test_triage_output_requires_one_durable_lifecycle_record_for_all_generated_groups
    output = extract_markdown_section(@triage_skill, "## Output", end_heading: /^##\s+/).gsub(/\s+/, " ")

    assert_includes output, "One durable planning-chat lifecycle record covering every generated group:"
    assert_includes output, PLANNING_CHAT_ROLE_RULE
    assert_includes output, "Planning-chat role selector: default to `prompt-only`."
    assert_includes output, PARENT_ORCHESTRATOR_SELECTOR_RULE
    assert_includes output, "Retained responsibilities: list each exact retained responsibility."
    assert_includes output, "Archive/closeout owner:"
    assert_includes output, PROMPT_ONLY_ARCHIVE_EXPECTATION
    assert_includes output,
                    "Parent-orchestrator conversation-status/archive expectation: clean only when parent reconciliation has no OUTSTANDING follow-up or `UNKNOWN`; then use exactly `Conversation status: Ready for archiving.` Otherwise use exactly `Conversation status: Follow-ups remain — <each exact action or blocker>.` and list each exact action or blocker."
    assert_includes output, "Keep this lifecycle metadata outside generated goal prompts."
  end

  def test_parent_orchestrator_lifecycle_keeps_per_pr_closeout_with_batch_coordinators
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_includes lifecycle,
                    "It may archive only after terminal batch handoffs, narrow live cross-batch reconciliation, and explicit ownership for shared-path, release-note, and external-reservation follow-ups, and no OUTSTANDING follow-up or `UNKNOWN` remains."
    assert_includes lifecycle, "stays open and read-only while workers execute"
    assert_includes lifecycle, "never claims, edits, or duplicates per-PR closeout"
    assert_includes lifecycle, "Batch coordinators retain checks, reviews, QA, merge, and completed-batch audit."
    assert_includes lifecycle,
                    "An open planning chat is not an implicit pre-merge gate under `auto_merge_when_gates_pass`."
    assert_includes lifecycle,
                    "Deliberate pre-merge planner review requires `merge_authority=ask` or an explicit dependency/gate."
    assert_includes lifecycle,
                    "terminal batch handoffs, narrow live cross-batch reconciliation, and explicit ownership for shared-path, release-note, and external-reservation follow-ups"
    assert_includes lifecycle, "no OUTSTANDING follow-up or `UNKNOWN` remains"
    assert_includes lifecycle, RELEASE_AUTHORITY_RECONCILIATION_RULE
    refute_includes lifecycle, OBSOLETE_RELEASE_AUTHORITY_RECONCILIATION_RULE
  end

  def test_parent_cross_batch_reconciliation_replays_durable_terminal_handoffs
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_includes lifecycle,
                    "Parent cross-batch reconciliation is checklist+replay over durable terminal handoffs/manifests."
    assert_includes lifecycle, PARENT_RECONCILIATION_RULE
    assert_includes lifecycle,
                    "For each exact batch/target scope, the durable record captures evidence, owner, status, and follow-up for:"
    [
      "exact scope coverage",
      "dependency outcomes",
      "issue closed or no-PR evidence",
      "released claims",
      "exact-final-head QA replay",
      "changelog/release-note ownership",
      "shared-path interactions"
    ].each { |requirement| assert_includes lifecycle, requirement }
    refute_includes lifecycle, "Before archive, the parent performs"
    refute_includes lifecycle, "Missing evidence or any `UNKNOWN` blocks archive."
  end

  def test_completed_batch_audit_handoff_is_always_applicable_and_parent_reconciled_only
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_includes lifecycle,
                    "The completed-batch audit handoff is an always-applicable parent-reconciliation surface for every batch, independent of all target-level `n/a` decisions."
    assert_includes lifecycle,
                    "independent of all target-level `n/a` decisions"
    assert_includes lifecycle,
                    "Missing handoff, or missing or `UNKNOWN` audit status or verdict, blocks both coordinated release and parent archive."
    assert_includes lifecycle, TERMINAL_FOLLOW_UP_EVIDENCE_RULE
    assert_includes lifecycle, UNRESOLVED_HANDOFF_NON_CLEAN_RULE
    refute_includes lifecycle, "dispositioned/handed off"
    assert_includes lifecycle, "The parent only reconciles this handoff; it never reruns or owns the audit."

    pressure_checks = lifecycle[lifecycle.index("Pressure checks:")..]
    assert_includes pressure_checks,
                    "The completed-batch audit handoff is an always-applicable parent-reconciliation surface for every batch, independent of all target-level `n/a` decisions.",
                    "parent pressure fixture must pin completed-batch reconciliation"
  end

  def test_completed_batch_audit_marker_replay_is_exact_and_fail_closed
    fixtures = {
      "backend identity with no terminal dispositions" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        true
      ],
      "durable non-backend identity with rationale and scope evidence" => [
        completed_batch_audit_marker("batch_id: non-backend: docs-wave-117; rationale: no coordination backend applies\naudit_status: complete\nverdict: clean\nscope_evidence: targets=shakacode/agent-workflows#117; source=coordinator-handoff#117\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        true
      ],
      "not-applicable identity with rationale and scope evidence" => [
        completed_batch_audit_marker("batch_id: not-applicable: direct no-batch audit\naudit_status: complete\nverdict: clean\nscope_evidence: targets=shakacode/agent-workflows#117; source=coordinator-handoff#117\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        true
      ],
      "canonical not-applicable terminal disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: not-applicable; evidence: verified no-code scope"),
        true
      ],
      "missing exact marker wrapper" => [
        "batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none\n",
        false
      ],
      "nonexact marker wrapper" => [
        "<!-- completed-batch-audit v1 extra\nbatch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none\n-->\n",
        false
      ],
      "marker fragment with no exact end" => [
        "<!-- completed-batch-audit v1\nbatch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none\n",
        false
      ],
      "missing required batch identity" => [
        completed_batch_audit_marker("audit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "missing required checker evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "duplicate required scope evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nscope_evidence: duplicate\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "unknown extra scalar field" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none\nextra: ignored before"),
        false
      ],
      "UNKNOWN batch identity" => [
        completed_batch_audit_marker("batch_id: UNKNOWN\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "empty scope evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: \nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "UNKNOWN scope evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: UNKNOWN\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "UNKNOWN checker evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: UNKNOWN\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "case-varied UNKNOWN nested in batch identity" => [
        completed_batch_audit_marker("batch_id: batch-uNkNoWn-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "case-varied UNKNOWN nested in scope evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; UNKNOWN durable audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "case-varied UNKNOWN nested in checker evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; uNkNoWn report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "not-applicable identity requires structured exact-target scope evidence" => [
        completed_batch_audit_marker("batch_id: not-applicable: direct no-batch audit\naudit_status: complete\nverdict: clean\nscope_evidence: exact target #117; durable audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "non-backend identity requires structured exact-target scope evidence" => [
        completed_batch_audit_marker("batch_id: non-backend: docs-wave-117; rationale: no coordination backend applies\naudit_status: complete\nverdict: clean\nscope_evidence: docs targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "blocked + clean" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "UNKNOWN + clean" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: UNKNOWN\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "complete + follow-ups-remain" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "complete + clean + outstanding" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: none"),
        false
      ],
      "complete + clean + bare finding ref" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: #117\nfollowups_dispositions: none"),
        false
      ],
      "complete + clean + duplicate findings fields" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "complete + clean + bare disposition ref" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: #117"),
        false
      ],
      "complete + clean + open disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal active; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "complete + clean + pending disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: pending; evidence: issue comment"),
        false
      ],
      "complete + clean + unresolved disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal reopened; disposition: accepted-deferral; evidence: issue comment"),
        false
      ],
      "complete + clean + UNKNOWN disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: UNKNOWN; current status: terminal; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "complete + clean + UNKNOWN terminal evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: UNKNOWN"),
        false
      ],
      "case-varied UNKNOWN nested in terminal ref" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: issue-uNkNoWn-117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "case-varied UNKNOWN nested in terminal owner" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer-uNkNoWn; current status: terminal; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "case-varied UNKNOWN nested in terminal status" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal-uNkNoWn; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "case-varied UNKNOWN nested in terminal disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver-uNkNoWn; evidence: issue comment"),
        false
      ],
      "case-varied UNKNOWN nested in terminal evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue uNkNoWn comment"),
        false
      ],
      "complete + clean + arbitrary disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: waiver; evidence: issue comment"),
        false
      ],
      "complete + clean + missing owner" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; current status: terminal; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "complete + clean + missing current status" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; disposition: accepted-waiver; evidence: issue comment"),
        false
      ],
      "complete + clean + missing disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; evidence: issue comment"),
        false
      ],
      "complete + clean + missing evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver"),
        false
      ],
      "complete + clean + dangling record separator" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue #117 | "),
        false
      ],
      "complete + clean + multiple fully evidenced terminal dispositions" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue #117 | ref: #118; owner: release-manager; current status: terminal; disposition: accepted-deferral; evidence: issue #118"),
        true
      ],
      "case-insensitive duplicate terminal refs" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: Issue-117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue #117 | ref: issue-117; owner: release-manager; current status: terminal; disposition: accepted-deferral; evidence: issue #117"),
        false
      ],
      "conflicting case-insensitive duplicate terminal refs" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: Issue-117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue #117 | ref: ISSUE-117; owner: release-manager; current status: terminal; disposition: accepted-deferral; evidence: later issue comment"),
        false
      ]
    }

    fixtures.each do |label, (marker, expected)|
      assert_equal expected, completed_batch_audit_release_or_archive_ready?(marker),
                   "#{label} marker replay"
    end

    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/post-merge-audit/SKILL.md" => read_repo_file(File.join(ROOT, "skills/post-merge-audit/SKILL.md")),
      "workflows/post-merge-audit.md" => read_repo_file(File.join(ROOT, "workflows/post-merge-audit.md"))
    }.each do |label, text|
      normalized_text = text.gsub(/\s+/, " ")
      [COMPLETED_BATCH_AUDIT_RELEASE_ARCHIVE_RULE,
       COMPLETED_BATCH_AUDIT_EXACT_REPLAY_RULE,
       COMPLETED_BATCH_AUDIT_IDENTITY_SCOPE_RULE,
       COMPLETED_BATCH_AUDIT_TERMINAL_DISPOSITION_RULE].each do |rule|
        assert_text_includes normalized_text, rule, label
      end
    end
  end

  def test_completed_batch_audit_marker_replay_rejects_embedded_wrapper_tokens
    fixtures = {
      "embedded opener in checker evidence" => completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker <!-- injected\nfindings: none\nfollowups_dispositions: none"),
      "embedded terminator in scope evidence" => completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117 --> audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
      "embedded opener in terminal record evidence" => completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue <!-- comment"),
      "embedded terminator in nonterminal record action" => completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: pending; disposition: fix --> then verify; evidence: issue #117")
    }

    fixtures.each do |label, marker|
      refute completed_batch_audit_marker_well_formed?(marker),
             "#{label} must be structurally rejected"
      refute completed_batch_audit_release_or_archive_ready?(marker),
             "#{label} must not replay as release/archive-ready"
    end
  end

  def test_completed_batch_audit_record_field_delimiters_are_rejected
    ["ref", "owner", "current status", "disposition", "evidence"].each do |field|
      [";", "|"].each do |delimiter|
        field_value = "safe#{delimiter}value"
        record = {
          "ref" => "#117",
          "owner" => "maintainer",
          "current status" => "open",
          "disposition" => "fix",
          "evidence" => "issue #117"
        }
        record[field] = field_value
        marker = completed_batch_audit_marker(
          "batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #{record.fetch('ref')}; owner: #{record.fetch('owner')}; current status: #{record.fetch('current status')}; disposition: #{record.fetch('disposition')}; evidence: #{record.fetch('evidence')}"
        )

        refute completed_batch_audit_marker_well_formed?(marker),
               "#{field} containing #{delimiter.inspect} must be rejected"
      end
    end

    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/post-merge-audit/SKILL.md" => read_repo_file(File.join(ROOT, "skills/post-merge-audit/SKILL.md")),
      "workflows/post-merge-audit.md" => read_repo_file(File.join(ROOT, "workflows/post-merge-audit.md"))
    }.each do |label, text|
      assert_text_includes text.gsub(/\s+/, " "), COMPLETED_BATCH_AUDIT_RECORD_DELIMITER_RULE, label
    end

    ["Issue, 117", "Issue: 117"].each do |ref|
      marker = completed_batch_audit_marker(
        "batch_id: batch:117; lane:closeout\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #{ref}\nfollowups_dispositions: ref: #{ref}; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"
      )

      assert completed_batch_audit_marker_well_formed?(marker),
             "#{ref.inspect} remains an accepted ref while coordination-backed batch_id semicolons remain opaque"
    end

    terminal_record = "ref: #117; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: issue #117"
    {
      "trailing semicolon" => "#{terminal_record};",
      "leading semicolon" => "; #{terminal_record}",
      "doubled semicolon" => terminal_record.sub("; owner", ";; owner")
    }.each do |label, record|
      marker = completed_batch_audit_marker(
        "batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: #{record}"
      )

      refute completed_batch_audit_marker_well_formed?(marker), "#{label} terminal record must be malformed"
      refute completed_batch_audit_release_or_archive_ready?(marker), "#{label} terminal record must be non-ready"
    end

    valid_terminal_marker = completed_batch_audit_marker(
      "batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: #{terminal_record}"
    )
    assert completed_batch_audit_marker_well_formed?(valid_terminal_marker)
    assert completed_batch_audit_release_or_archive_ready?(valid_terminal_marker)
  end

  def test_completed_batch_audit_marker_well_formedness_distinguishes_nonterminal_followups_from_readiness
    fixtures = {
      "blocked with open follow-up" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"),
        true,
        false
      ],
      "follow-ups-remain with pending follow-up" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: pending; disposition: await-input; evidence: issue #117"),
        true,
        false
      ],
      "blocked with unresolved follow-up" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: unresolved; disposition: investigate; evidence: issue #117"),
        true,
        false
      ],
      "UNKNOWN nonterminal status" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: UNKNOWN; disposition: track; evidence: issue #117"),
        false,
        false
      ],
      "nonterminal record missing owner" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; current status: open; disposition: fix; evidence: issue #117"),
        false,
        false
      ],
      "nonterminal record with empty action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: ; evidence: issue #117"),
        false,
        false
      ],
      "nonterminal record with empty evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: pending; disposition: fix; evidence: "),
        false,
        false
      ],
      "nonterminal record with unsupported current status" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: active; disposition: fix; evidence: issue #117"),
        false,
        false
      ],
      "terminal record with noncanonical disposition" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: fix and verify; evidence: issue #117"),
        false,
        false
      ]
    }

    fixtures.each do |label, (marker, well_formed, ready)|
      assert_equal well_formed, completed_batch_audit_marker_well_formed?(marker),
                   "#{label} marker well-formedness"
      assert_equal ready, completed_batch_audit_release_or_archive_ready?(marker),
                   "#{label} marker readiness"
    end
  end

  def test_completed_batch_audit_marker_well_formedness_validates_scalar_and_cross_field_grammar
    fixtures = {
      "typed non-backend identity without rationale" => [
        completed_batch_audit_marker("batch_id: non-backend: docs-wave-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets=shakacode/agent-workflows#117; source=coordinator-handoff#117\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "not-applicable identity without rationale" => [
        completed_batch_audit_marker("batch_id: not-applicable:\naudit_status: complete\nverdict: clean\nscope_evidence: targets=shakacode/agent-workflows#117; source=coordinator-handoff#117\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "case-varied UNKNOWN batch identity" => [
        completed_batch_audit_marker("batch_id: uNkNoWn\naudit_status: UNKNOWN\nverdict: UNKNOWN\nscope_evidence: UNKNOWN\nchecker_evidence: UNKNOWN\nfindings: UNKNOWN\nfollowups_dispositions: none"),
        false
      ],
      "nested UNKNOWN scope evidence" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: UNKNOWN\nverdict: UNKNOWN\nscope_evidence: audit uNkNoWn\nchecker_evidence: UNKNOWN\nfindings: UNKNOWN\nfollowups_dispositions: none"),
        false
      ],
      "unsupported audit status" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: pending\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "unsupported verdict" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: later\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "bare finding reference" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: #117\nfollowups_dispositions: none"),
        false
      ],
      "empty outstanding findings" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix and verify; evidence: issue #117"),
        false
      ],
      "blocked clean" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "follow-ups without an outstanding action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        false
      ],
      "outstanding finding without an action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: none"),
        true
      ],
      "operational actions need not duplicate outstanding findings" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: #118; owner: maintainer; current status: pending; disposition: await-input; evidence: issue #118"),
        true
      ],
      "outstanding and operational action refs may differ" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #11; owner: maintainer; current status: unresolved; disposition: investigate; evidence: issue #11"),
        true
      ],
      "clean with an open action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"),
        false
      ],
      "blocked open action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"),
        true
      ],
      "complete pending action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: pending; disposition: await-input; evidence: issue #117"),
        true
      ],
      "blocked unresolved action" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: unresolved; disposition: investigate; evidence: issue #117"),
        true
      ],
      "exact UNKNOWN marker scalars" => [
        completed_batch_audit_marker("batch_id: UNKNOWN\naudit_status: UNKNOWN\nverdict: UNKNOWN\nscope_evidence: UNKNOWN\nchecker_evidence: UNKNOWN\nfindings: UNKNOWN\nfollowups_dispositions: none"),
        true
      ],
      "partial UNKNOWN findings is cross-field inconsistent" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: UNKNOWN\nfollowups_dispositions: none"),
        false
      ]
    }

    fixtures.each do |label, (marker, expected)|
      assert_equal expected, completed_batch_audit_marker_well_formed?(marker),
                   "#{label} marker well-formedness"
      refute completed_batch_audit_release_or_archive_ready?(marker),
             "#{label} marker must not become ready unless separately covered as ready"
    end
  end

  def test_completed_batch_audit_replay_couples_marker_readiness_to_final_status_line
    ready_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none")
    open_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117")
    pending_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #118\nfollowups_dispositions: ref: #118; owner: maintainer; current status: pending; disposition: await-input; evidence: issue #118")
    unknown_marker = completed_batch_audit_marker("batch_id: UNKNOWN\naudit_status: UNKNOWN\nverdict: UNKNOWN\nscope_evidence: UNKNOWN\nchecker_evidence: UNKNOWN\nfindings: UNKNOWN\nfollowups_dispositions: none")

    assert completed_batch_audit_final_status_replays?(ready_marker, "Conversation status: Ready for archiving.")
    refute completed_batch_audit_final_status_replays?(ready_marker, "Conversation status: Follow-ups remain — #117 (open): fix and verify.")
    assert completed_batch_audit_final_status_replays?(
      ready_marker,
      "Conversation status: Follow-ups remain — release owner confirmation.",
      other_blockers: ["release owner confirmation"]
    )
    refute completed_batch_audit_final_status_replays?(
      ready_marker,
      "Conversation status: Follow-ups remain — release owner confirmation; stale extra.",
      other_blockers: ["release owner confirmation"]
    )

    assert completed_batch_audit_final_status_replays?(
      open_marker,
      "Conversation status: Follow-ups remain — #117 (open): fix."
    )
    assert completed_batch_audit_final_status_replays?(
      pending_marker,
      "Conversation status: Follow-ups remain — #118 (pending): await-input."
    )
    assert completed_batch_audit_final_status_replays?(
      unknown_marker,
      "Conversation status: Follow-ups remain — batch_id: UNKNOWN; audit_status: UNKNOWN; verdict: UNKNOWN; scope_evidence: UNKNOWN; checker_evidence: UNKNOWN; findings: UNKNOWN."
    )

    refute completed_batch_audit_final_status_replays?(open_marker, "Conversation status: Ready for archiving.")
    refute completed_batch_audit_final_status_replays?(pending_marker, "Conversation status: Follow-ups remain — #118 (pending).")
    refute completed_batch_audit_final_status_replays?(unknown_marker, "Conversation status: Follow-ups remain — verdict: UNKNOWN.")
  end

  def test_completed_batch_audit_adversarial_three_output_matrix
    fixtures = {
      "OUTSTANDING refs remain blockers without action records" => [
        completed_batch_audit_marker("batch_id: batch:117; lane:closeout\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117 #118\nfollowups_dispositions: none"),
        true,
        false,
        ["#117", "#118"]
      ],
      "imperfect terminal evidence is well-formed but blocked" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117 #118\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: resolved; evidence: UNKNOWN | ref: #118; owner: maintainer; current status: terminal; disposition: accepted-waiver; evidence: "),
        true,
        false,
        ["#117 (terminal): evidence UNKNOWN", "#118 (terminal): evidence missing"]
      ],
      "UNKNOWN current status is valid only in a non-clean marker" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: UNKNOWN; disposition: track; evidence: issue #117"),
        true,
        false,
        ["#117 (UNKNOWN): track"]
      ],
      "UNKNOWN current status cannot hide in clean none" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: UNKNOWN; disposition: track; evidence: issue #117"),
        false,
        false,
        nil
      ],
      "opaque backend IDs retain colon and semicolon" => [
        completed_batch_audit_marker("batch_id: backend:team;wave:117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        true,
        true,
        []
      ],
      "case-varied typed prefix is opaque rather than typed" => [
        completed_batch_audit_marker("batch_id: Non-backend: docs;wave:117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"),
        true,
        true,
        []
      ],
      "nonterminal terminal enum is invalid" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: resolved; evidence: issue #117"),
        false,
        false,
        nil
      ],
      "terminal nonterminal action is invalid" => [
        completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: fix; evidence: issue #117"),
        false,
        false,
        nil
      ]
    }

    fixtures.each do |label, (marker, well_formed, ready, blockers)|
      assert_equal well_formed, completed_batch_audit_marker_well_formed?(marker), "#{label} well-formed"
      assert_equal ready, completed_batch_audit_release_or_archive_ready?(marker), "#{label} ready"
      assert_equal blockers, completed_batch_audit_marker_blockers(marker), "#{label} blockers" if blockers
    end

    marker = fixtures.fetch("OUTSTANDING refs remain blockers without action records").first
    assert completed_batch_audit_final_status_replays?(
      marker,
      "Conversation status: Follow-ups remain — #117; #118; release owner confirmation.",
      other_blockers: [" release owner confirmation ", "release owner confirmation"]
    )
    refute completed_batch_audit_final_status_replays?(
      marker,
      "Conversation status: Follow-ups remain — ."
    )
    refute completed_batch_audit_final_status_replays?(
      marker,
      "Conversation status: Follow-ups remain — #117; #118; <!-- injected -->.",
      other_blockers: ["<!-- injected -->"]
    )
  end

  def test_completed_batch_audit_terminal_record_does_not_erase_its_outstanding_ref
    marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #117; owner: maintainer; current status: terminal; disposition: resolved; evidence: issue #117")

    assert completed_batch_audit_marker_well_formed?(marker)
    refute completed_batch_audit_release_or_archive_ready?(marker)
    assert_equal ["#117"], completed_batch_audit_marker_blockers(marker)
    assert completed_batch_audit_final_status_replays?(
      marker,
      "Conversation status: Follow-ups remain — #117."
    )
  end

  def test_completed_batch_audit_rejects_duplicate_canonical_finding_refs
    fixtures = {
      "literal whitespace-separated duplicate" => ["#117 #117", "none"],
      "Unicode full-fold duplicate" => ["Straße STRASSE", "none"],
      "whitespace-normalized duplicate matching one record" => [
        "Issue  117 Issue\t117",
        "ref: Issue 117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"
      ],
      "comma-separated duplicate" => ["#117, #117", "none"]
    }

    fixtures.each do |label, (findings, followups_dispositions)|
      marker = completed_batch_audit_marker(
        "batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #{findings}\nfollowups_dispositions: #{followups_dispositions}"
      )

      refute completed_batch_audit_marker_well_formed?(marker), "#{label} must be malformed"
      refute completed_batch_audit_release_or_archive_ready?(marker), "#{label} must be non-ready"
    end
  end

  def test_completed_batch_audit_rejects_control_line_breaks_in_every_scalar_and_record_value
    clean_body = "batch_id: batch:117;lane:closeout\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none"
    followup_body = "batch_id: batch:117;lane:closeout\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117"
    controls = { "CR" => "\r", "LF" => "\n", "CRLF" => "\r\n", "NUL" => "\0", "vertical tab" => "\v", "form feed" => "\f", "line separator" => "\u2028" }
    top_level_values = {
      "batch_id" => "batch:117;lane:closeout", "audit_status" => "complete", "verdict" => "clean",
      "scope_evidence" => "targets #117; audit report", "checker_evidence" => "checker route; report",
      "findings" => "none", "followups_dispositions" => "none"
    }
    record_values = {
      "ref" => "#117", "owner" => "maintainer", "current status" => "open",
      "disposition" => "fix", "evidence" => "issue #117"
    }

    controls.each do |control_label, control|
      assert_equal false,
                   completed_batch_audit_marker_well_formed?(completed_batch_audit_marker(clean_body.sub("batch_id: batch:117;lane:closeout", "batch_id: batch:117;lane#{control}closeout"))),
                   "opaque batch ID with #{control_label} must be rejected"
    end
    top_level_values.each do |field, value|
      controls.each do |control_label, control|
        marker = completed_batch_audit_marker(clean_body.sub("#{field}: #{value}", "#{field}: #{value}#{control}continued"))
        refute completed_batch_audit_marker_well_formed?(marker), "#{field} must reject #{control_label}"
      end
    end
    record_values.each do |field, value|
      controls.each do |control_label, control|
        marker = completed_batch_audit_marker(followup_body.sub("#{field}: #{value}", "#{field}: #{value}#{control}continued"))
        refute completed_batch_audit_marker_well_formed?(marker), "record #{field} must reject #{control_label}"
      end
    end
  end

  def test_completed_batch_audit_invalid_marker_uses_fail_closed_blocker_union_and_final_status
    malformed = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: ; evidence: issue #117")
    result = completed_batch_audit_replay_result(malformed, other_blockers: [" release owner confirmation "])

    refute completed_batch_audit_marker_well_formed?(malformed)
    refute completed_batch_audit_release_or_archive_ready?(malformed)
    assert_equal false, result.well_formed
    assert_equal false, result.ready
    assert_equal [COMPLETED_BATCH_AUDIT_INVALID_MARKER_BLOCKER, "release owner confirmation"], result.blockers
    assert_equal [COMPLETED_BATCH_AUDIT_INVALID_MARKER_BLOCKER], completed_batch_audit_marker_blockers(malformed)
    assert completed_batch_audit_final_status_replays?(
      malformed,
      "Conversation status: Follow-ups remain — completed-batch-audit marker invalid; release owner confirmation.",
      other_blockers: [" release owner confirmation "]
    )
    refute completed_batch_audit_final_status_replays?(malformed, "Conversation status: Ready for archiving.")
    refute completed_batch_audit_final_status_replays?(malformed, "Conversation status: Follow-ups remain — .")

    unparseable = completed_batch_audit_replay_result("not a completed-batch marker")
    assert_equal false, unparseable.well_formed
    assert_equal false, unparseable.ready
    assert_equal [COMPLETED_BATCH_AUDIT_INVALID_MARKER_BLOCKER], unparseable.blockers
  end

  def test_completed_batch_audit_followup_only_and_mixed_findings_replay_matrix
    followup_only = %w[open pending unresolved UNKNOWN].map do |status|
      action = { "open" => "fix", "pending" => "await-input", "unresolved" => "investigate", "UNKNOWN" => "track" }.fetch(status)
      [status, completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: ##{status.length}; owner: maintainer; current status: #{status}; disposition: #{action}; evidence: issue ##{status.length}"), "##{status.length} (#{status}): #{action}"]
    end
    mixed = completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: ref: #118; owner: maintainer; current status: pending; disposition: await-input; evidence: issue #118")
    outstanding_without_record = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #117\nfollowups_dispositions: none")
    malformed_record = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #117; owner: maintainer; current status: open; disposition: resolved; evidence: issue #117")

    followup_only.each do |status, marker, blocker|
      assert completed_batch_audit_marker_well_formed?(marker), "follow-up-only #{status} marker must be well-formed"
      refute completed_batch_audit_release_or_archive_ready?(marker), "follow-up-only #{status} marker must be non-ready"
      assert_equal [blocker], completed_batch_audit_marker_blockers(marker)
    end
    assert completed_batch_audit_marker_well_formed?(mixed)
    refute completed_batch_audit_release_or_archive_ready?(mixed)
    assert_equal ["#117", "#118 (pending): await-input"], completed_batch_audit_marker_blockers(mixed)
    assert completed_batch_audit_marker_well_formed?(outstanding_without_record)
    assert_equal ["#117"], completed_batch_audit_marker_blockers(outstanding_without_record)
    refute completed_batch_audit_marker_well_formed?(malformed_record)
  end

  def test_completed_batch_audit_canonicalizes_record_refs_for_duplicates_and_blocker_union
    duplicate_pairs = {
      "internal spaces" => ["Issue  117", "Issue 117"],
      "tab and space" => ["Issue\t117", "Issue 117"],
      "leading and trailing whitespace" => ["  Issue 117  ", "Issue 117"],
      "case variation" => ["Issue 117", "issue 117"]
    }

    duplicate_pairs.each do |label, (first_ref, second_ref)|
      marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #{first_ref}; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: #{second_ref}; owner: release-manager; current status: pending; disposition: await-input; evidence: issue #117")

      refute completed_batch_audit_marker_well_formed?(marker), "#{label} duplicate refs must be rejected"
    end

    distinct_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117 #118; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: Issue  117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: Issue\t118; owner: release-manager; current status: pending; disposition: await-input; evidence: issue #118")

    assert completed_batch_audit_marker_well_formed?(distinct_marker)
    assert_equal ["Issue 117", "Issue 118"], followups_disposition_records(completed_batch_audit_marker_fields(distinct_marker).fetch("followups_dispositions")).map(&:ref)
    assert_equal ["Issue 117 (open): fix", "Issue 118 (pending): await-input"], completed_batch_audit_marker_blockers(distinct_marker)
    assert completed_batch_audit_final_status_replays?(
      distinct_marker,
      "Conversation status: Follow-ups remain — Issue 117 (open): fix; Issue 118 (pending): await-input."
    )
  end

  def test_completed_batch_audit_uses_unicode_canonical_refs_for_identity_lookup_and_union
    duplicate_pairs = {
      "sharp s full-fold" => ["Issue ß", "Issue SS"],
      "NBSP and ASCII space" => ["\u00A0Issue 117", "Issue 117"],
      "tabs" => ["Issue\t117", "Issue 117"],
      "multiple Unicode spaces" => ["Issue\u2003\u2003117", "Issue 117"],
      "Unicode case variation" => ["Issue Å", "issue å"]
    }

    duplicate_pairs.each do |label, (first_ref, second_ref)|
      marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: #{first_ref}; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: #{second_ref}; owner: release-manager; current status: pending; disposition: await-input; evidence: issue #117")

      refute completed_batch_audit_marker_well_formed?(marker), "#{label} duplicate refs must be rejected"
    end

    findings_lookup_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING Å-117\nfollowups_dispositions: ref: Å-117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117")
    distinct_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117 #118; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: Issue\u00A0Å; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: Issue Ω; owner: release-manager; current status: pending; disposition: await-input; evidence: issue #118")

    assert completed_batch_audit_marker_well_formed?(findings_lookup_marker)
    assert_equal ["Å-117 (open): fix"], completed_batch_audit_marker_blockers(findings_lookup_marker)
    assert completed_batch_audit_marker_well_formed?(distinct_marker)
    assert_equal ["Issue Å (open): fix", "Issue Ω (pending): await-input"], completed_batch_audit_marker_blockers(distinct_marker)
    assert_equal ["Issue Å (open): fix", "Issue Ω (pending): await-input", "Release ß"],
                 completed_batch_audit_replay_result(
                   distinct_marker,
                   other_blockers: [" Release\tß ", "release SS"]
                 ).blockers

    empty_normalized_finding = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING \u00A0\nfollowups_dispositions: none")
    refute completed_batch_audit_marker_well_formed?(empty_normalized_finding)
  end

  def test_completed_batch_audit_rejects_unsafe_nfkc_canonical_displays_at_each_consumer
    {
      "fullwidth opener" => "＜！－－",
      "fullwidth terminator" => "－－＞",
      "fullwidth exact UNKNOWN" => "ＵＮＫＮＯＷＮ",
      "fullwidth nested UNKNOWN" => "IssueＵＮＫＮＯＷＮ-117"
    }.each do |label, ref|
      marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING #{ref}\nfollowups_dispositions: none")
      refute completed_batch_audit_marker_well_formed?(marker), "#{label} finding must be rejected after NFKC"
    end

    record_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: ref: ＜！－－; owner: maintainer; current status: open; disposition: fix; evidence: issue #117")
    ready_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none")

    refute completed_batch_audit_marker_well_formed?(record_marker)
    ["＜！－－", "－－＞"].each do |external_blocker|
      refute well_formed_other_blocker?(external_blocker), "#{external_blocker.inspect} external blocker must be rejected after NFKC"
      refute completed_batch_audit_final_status_replays?(
        ready_marker,
        "Conversation status: Follow-ups remain — #{external_blocker.unicode_normalize(:nfkc)}.",
        other_blockers: [external_blocker]
      )
    end
  end

  def test_completed_batch_audit_replays_canonical_external_unknown_blockers
    ready_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: complete\nverdict: clean\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: none\nfollowups_dispositions: none")
    raw_unknown = " release state UNKNOWN "
    fullwidth_unknown = "release\tstate ＵＮＫＮＯＷＮ"

    assert well_formed_other_blocker?(raw_unknown)
    assert well_formed_other_blocker?(fullwidth_unknown)
    assert_equal ["release state UNKNOWN"],
                 completed_batch_audit_replay_result(
                   ready_marker,
                   other_blockers: [raw_unknown, fullwidth_unknown]
                 ).blockers
    assert completed_batch_audit_final_status_replays?(
      ready_marker,
      "Conversation status: Follow-ups remain — release state UNKNOWN.",
      other_blockers: [raw_unknown, fullwidth_unknown]
    )
  end

  def test_completed_batch_audit_matches_whitespace_bearing_finding_to_whole_record_ref
    marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING Issue 117\nfollowups_dispositions: ref: Issue 117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117")

    assert completed_batch_audit_marker_well_formed?(marker)
    assert_equal ["Issue 117 (open): fix"], completed_batch_audit_marker_blockers(marker)
    assert completed_batch_audit_final_status_replays?(
      marker,
      "Conversation status: Follow-ups remain — Issue 117 (open): fix."
    )
  end

  def test_completed_batch_audit_prefers_whole_comma_bearing_record_refs_before_delimiter_fallback
    comma_record_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING Issue, 117\nfollowups_dispositions: ref: Issue, 117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117")
    ambiguous_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING Issue, 117\nfollowups_dispositions: ref: Issue, 117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: Issue; owner: maintainer; current status: terminal; disposition: resolved; evidence: issue #117 | ref: 117; owner: maintainer; current status: terminal; disposition: resolved; evidence: issue #117")
    comma_mixed_marker = completed_batch_audit_marker("batch_id: batch-117\naudit_status: blocked\nverdict: follow-ups-remain\nscope_evidence: targets #117 #118; audit report\nchecker_evidence: checker route; report\nfindings: OUTSTANDING Issue 117, #118\nfollowups_dispositions: ref: Issue 117; owner: maintainer; current status: open; disposition: fix; evidence: issue #117 | ref: #118; owner: release-manager; current status: pending; disposition: await-input; evidence: issue #118")

    assert completed_batch_audit_marker_well_formed?(comma_record_marker)
    assert_equal ["Issue, 117 (open): fix"], completed_batch_audit_marker_blockers(comma_record_marker)
    assert completed_batch_audit_marker_well_formed?(ambiguous_marker)
    assert_equal ["Issue, 117 (open): fix"], completed_batch_audit_marker_blockers(ambiguous_marker)
    assert completed_batch_audit_marker_well_formed?(comma_mixed_marker)
    assert_equal ["Issue 117 (open): fix", "#118 (pending): await-input"],
                 completed_batch_audit_marker_blockers(comma_mixed_marker)
  end

  def test_completed_batch_audit_record_grammar_is_mirrored_across_closeout_surfaces
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/post-merge-audit/SKILL.md" => read_repo_file(File.join(ROOT, "skills/post-merge-audit/SKILL.md")),
      "workflows/post-merge-audit.md" => read_repo_file(File.join(ROOT, "workflows/post-merge-audit.md"))
    }.each do |label, text|
      normalized_text = text.gsub(/\s+/, " ")
      [COMPLETED_BATCH_AUDIT_RECORD_GRAMMAR_RULE,
       COMPLETED_BATCH_AUDIT_RECORD_REF_CANONICALIZATION_RULE,
       COMPLETED_BATCH_AUDIT_CANONICAL_DISPLAY_SAFETY_RULE,
       COMPLETED_BATCH_AUDIT_SINGLE_LINE_VALUE_RULE,
       COMPLETED_BATCH_AUDIT_STRUCTURAL_READINESS_RULE,
       COMPLETED_BATCH_AUDIT_WRAPPER_TOKEN_RULE,
       COMPLETED_BATCH_AUDIT_FINAL_STATUS_REPLAY_RULE,
       COMPLETED_BATCH_AUDIT_INVALID_MARKER_RULE].each do |rule|
        assert_text_includes normalized_text, rule, label
      end
    end
  end

  def test_parent_reconciliation_is_applicability_scoped_and_fail_closed
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_includes lifecycle, PARENT_RECONCILIATION_RULE
    [
      "PR with backend: refresh GitHub, coordination-backend/claim, head/merge, QA when code changed, and release notes when required.",
      "PR with backend n/a: durable `n/a` rationale satisfies coordination-backend/claim; refresh the remaining applicable surfaces.",
      "Issue no-PR: durable `no-PR` rationale satisfies head/merge; refresh GitHub, issue, and any other applicable surfaces.",
      "Ad hoc no-PR: durable `no-PR` rationale satisfies GitHub, head/merge, and issue when they are inapplicable; refresh QA or release notes only when applicable.",
      "No-code target: durable `no-code/not-required` rationale satisfies QA."
    ].each do |scenario|
      assert_includes lifecycle, scenario
    end

    ["Unknown applicability blocks both release action and parent archive.",
     "Missing applicable evidence blocks both release action and parent archive."].each do |rejection|
      assert_includes lifecycle, rejection
    end
  end

  def test_planning_chat_skill_summaries_keep_live_execution_with_batch_coordinators
    summary = "planning parent supervises worker execution and performs narrow read-only cross-batch reconciliation; " \
              "batch coordinators execute and own live lanes and closeout"

    {
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, summary, label
    end
  end

  def test_changelog_announces_portable_planning_chat_lifecycle_contract
    assert_text_includes @changelog,
                         "Clarify the portable planning-chat lifecycle: batch coordinators own completed-batch audits, prompt-only chats may archive after durable worker handoff, and parents reconcile only durable audit handoffs before release or archive.",
                         "CHANGELOG.md"
  end

  def test_planning_chat_lifecycle_excludes_hidden_planner_gates
    lifecycle = extract_markdown_section(@workflow, "### Planning-Chat Lifecycle", end_heading: /^###\s+/)

    assert_includes lifecycle,
                    "Non-goals: no mandatory second PR review, indefinite open planner, hidden auto-merge gate, or consumer-specific policy."
  end

  def test_normal_restart_stays_pause_resume_not_cancel_relaunch
    assert_text_includes @workflow, "pause, not cancellation", "workflows/pr-processing.md"
    assert_text_includes @workflow, "do not use this pause flow; use", "workflows/pr-processing.md"
    assert_text_includes @workflow, "Cancelling Or Stopping A Batch", "workflows/pr-processing.md"
    assert_text_includes @pr_batch_skill, "Preserve claims and worktrees", "skills/pr-batch/SKILL.md"
    assert_text_includes @pr_batch_skill, "updated skills", "skills/pr-batch/SKILL.md"
    assert_text_includes @pr_batch_skill, "launching fresh workers", "skills/pr-batch/SKILL.md"
  end
end
