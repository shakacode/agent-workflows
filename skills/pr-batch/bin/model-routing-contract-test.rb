#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
SOURCE_CHECKOUT_ENV = "AGENT_WORKFLOWS_SOURCE_CHECKOUT"
TEXT_FENCE = "```text\n"

ADVISORY_ROUTE_RULE =
  "Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit."
OBSERVED_HOST_RULE =
  "Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report."
ORDINARY_ACTIVATION_RULE =
  "Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required."
REPLAY_IDENTITY_RULE =
  "Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement."
DISPATCH_PERSISTENCE_RULE =
  "Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active."
REPLACEMENT_FENCING_RULE =
  "A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities."
CHECKER_RULE =
  "Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict."
VERDICT_QUALIFICATION_RULE =
  "Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route."
ROUTE_NONDISQUALIFICATION_RULE =
  "A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict."
EXECUTION_ROUTE_ADVISORY_RULE =
  "Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback."
EXECUTION_ROUTE_FALLBACK_RULE =
  "When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks."
MODEL_NEUTRAL_RISK_RULE =
  "Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity."
MODEL_NEUTRAL_ENVELOPE_RULE =
  "Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model."
ADVERSARIAL_ADVISORY_RULE =
  "Preferred route, model, and effort are advisory for adversarial review; mismatch or unavailability alone does not disqualify an otherwise independent, evidence-backed adversarial verdict."
ADVERSARIAL_OBSERVATION_RULE =
  "Record observed host, model, and effort only from host-exposed runtime evidence; use literal `UNKNOWN` for every unavailable field, and never infer observations from the preference, prompt text, or model self-report."
ADVERSARIAL_QUALITY_RULE =
  "Reviewer independence and evidence quality remain mandatory regardless of the preferred or observed route."
HOST_ROLLOUT_MATRIX_RULE =
  "Before any host-owned fact becomes a portable mandatory gate, the proposal must name an accountable owner for each producer, verifier, provisioner, and installer role and define clean-install acceptance for every supported host."
HOST_ROLLOUT_OPTIONAL_RULE =
  "If any role or clean-install acceptance is absent, the capability remains optional and advisory; unavailable host-owned fields use `UNKNOWN` and do not block otherwise valid workflow progress."

ROUTING_SURFACES = %w[
  CONTEXT.md
  docs/pr-batch-skills.md
  docs/agent-workflows-model-routing.md
  skills/plan-pr-batch/SKILL.md
  skills/pr-batch/SKILL.md
  skills/triage/SKILL.md
  workflows/pr-processing.md
].freeze

CHECKER_SURFACES = %w[
  CONTEXT.md
  docs/agent-workflows-model-routing.md
  docs/pr-batch-skills.md
  skills/adversarial-pr-review/SKILL.md
  skills/plan-pr-batch/SKILL.md
  skills/post-merge-audit/SKILL.md
  skills/pr-batch/SKILL.md
  skills/triage/SKILL.md
  workflows/adversarial-pr-review.md
  workflows/continuous-evaluation-loop.md
  workflows/post-merge-audit.md
  workflows/pr-processing.md
].freeze

ROUTE_DISQUALIFICATION_PATTERNS = {
  "named route forbidden from qualifying verdict" =>
    /\b(?:Sol|Terra|Opus|Sonnet)\b.{0,160}(?:may not|must not|does not) issue.{0,80}qualifying/im,
  "qualifying verdict assigned to a named route" =>
    /qualifying.{0,120}\b(?:uses|is)\b.{0,80}\b(?:Sol|Terra|Opus|Sonnet)\b/im,
  "named route limited below qualifying review" =>
    /\b(?:Sol|Terra|Opus|Sonnet)\b.{0,80}limited to routine deterministic QA/im,
  "cheaper route forbidden from qualifying verdict" =>
    /cheaper route.{0,120}(?:may not|must not|does not).{0,80}qualifying/im,
  "route compliance used as checker qualification" => /checker_route_compliance/i,
  "route classified below policy" => /below-policy/i,
  "route mismatch used to downgrade a verdict" => /do not downgrade/i,
  "launch assurance used to qualify a checker" => /launch-assured policy-compliant run/i
}.freeze

NAMED_EXECUTION_ENFORCEMENT_PATTERNS = {
  "named model denied coordinator or initiator work" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,100}may not initiate or coordinate/im,
  "named model allowed only for a worker class" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,40}(?:is |remains )?(?:allowed|available) only/im,
  "named model required to stop editing" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,40}stops without editing/im,
  "execution envelope approved by a named model" =>
    /\b(?:Sol|Opus)-approved execution envelope/im,
  "named worker route requires simple classification" =>
    %r{\b(?:Terra|Sonnet)(?: 5)?/high requires\b}im,
  "named route forced by risk classification" =>
    /(?:boundary|criterion|uncertainty) routes? to \b(?:Sol|Opus|Terra|Sonnet)\b/im,
  "runtime fallback prohibited from inheriting a route" =>
    /workers must not inherit the coordinator preference/im,
  "exact supported pair required before execution" =>
    /(?:needs?|requires?|until dispatch binds).{0,80}exact supported pair|exact supported pair.{0,80}(?:required|prerequisite)/im,
  "exact model identity required for routing" => /require an exact model/im
}.freeze

ROUTE_AUTHORITY_ENFORCEMENT_PATTERNS = {
  "route preference described as requiring authority" =>
    /\b(?:(?:explicit\s+)?route(?:\s+and\s+dispatch)?\s+authority|explicit authority for (?:the )?route)\b/im
}.freeze

CODEX_RECOMMENDATIONS = [
  "Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)",
  "Simple, positively classified worker: Terra/high",
  "Unknown or uncertain worker: Sol/high",
  "Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`",
  "Independent adversarial QA: Sol/xhigh",
  "Routine deterministic QA: Sol/high"
].freeze

CLAUDE_RECOMMENDATIONS = [
  "Multi-lane coordinator: Opus 4.8/xhigh",
  "Simple, positively classified worker: Sonnet 5/high",
  "Unknown or uncertain worker: Opus 4.8/xhigh",
  "High-risk or escalated work: Opus 4.8/xhigh",
  "Independent adversarial QA: Opus 4.8/xhigh",
  "Routine deterministic QA: Opus 4.8/high"
].freeze

MODEL_ROUTING_GUIDE_PATH = "docs/agent-workflows-model-routing.md"
ROUTE_DISPOSITION_TABLE_HEADING = "### Disposition Table"
ROUTE_PROVENANCE_RULES = [
  "A requested route is an instruction; an observed route is host-reported evidence of what actually executed. The two are separate fields and never collapse into one.",
  "Requested-route prose in a plan, handoff, comment, or PR description is never presentable as observed execution evidence; only host-reported session metadata binds.",
  "A route mismatch, unavailability, inherited route, or `UNKNOWN` observed tuple must be recorded honestly and must exclude that execution from route-measurement evidence; it never alone stops otherwise valid work.",
  "A worker records its own observed model/effort separately from the coordinator; an inherited pair is a route mismatch even when the inherited route is stronger than the requested one.",
  "Collaboration, review-fix, and helper subagents spawned inside a lane are workers for this rule",
  "An explicitly user-selected override remains a user override rather than an implicit fallback, and its requested and observed tuples are recorded separately.",
  "An authorized fallback is explicit, recorded before launch, and names the authority that approved it. An unrecorded fallback is a silent substitution and takes that row's disposition."
].freeze
AW_D_ROUTE_REPLAY = [
  { pr: 146, role: "implementation", case_id: "bound-exact-match", disposition: "proceed" },
  { pr: 146, role: "review and QA", case_id: "bound-exact-match", disposition: "proceed" },
  { pr: 147, role: "post-publication review fixes", case_id: "coordinator-pair-inheritance", disposition: "proceed-unmeasured" },
  { pr: 148, role: "implementation", case_id: "silent-substitution", disposition: "proceed-unmeasured" },
  { pr: 148, role: "QA", case_id: "silent-substitution", disposition: "proceed-unmeasured" }
].freeze
# Internal consistency and mutation guard for the audited replay fixture; it is
# not an independent tamper-proof immutable oracle. Sorted so row order is free.
AW_D_ROUTE_REPLAY_FINGERPRINT = [
  "146|implementation|bound-exact-match|proceed",
  "146|review and QA|bound-exact-match|proceed",
  "147|post-publication review fixes|coordinator-pair-inheritance|proceed-unmeasured",
  "148|QA|silent-substitution|proceed-unmeasured",
  "148|implementation|silent-substitution|proceed-unmeasured"
].freeze
EXPECTED_ROUTE_DISPOSITIONS = {
  "bound-exact-match" => "proceed",
  "unbound-exact-route" => "proceed-unmeasured",
  "silent-substitution" => "proceed-unmeasured",
  "coordinator-pair-inheritance" => "proceed-unmeasured",
  "authorized-fallback" => "proceed-as-fallback"
}.freeze
ROUTINE_COORDINATOR_ROUTE_RULE =
  "Routine bounded planning, dispatch bookkeeping, status reconciliation, evidence collation, and routine coordination use the `balanced`/high class. Name the exact `Terra/high` pair only when the active host has verified that pair; otherwise preserve the requested preference and record host-observed values as `UNKNOWN` when unavailable."
ROUTINE_MULTI_LANE_COORDINATOR_ROUTE_RULE =
  "Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)"
SOL_XHIGH_EXCEPTION_ROUTE_RULE =
  "Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`"
AUTHORIZED_FALLBACK_RECORDED_AUTHORITY_RULE =
  "authorized fallback tuple with recorded authority"
SOL_XHIGH_RESERVATION_RULE =
  "Reserve Sol/xhigh for a pinned high-risk trigger, a bounded plan challenge, repeated credible failures, or an evidence-backed `MODEL_ESCALATION_REQUEST`."
SOL_XHIGH_NONTRIGGERS_RULE =
  "Polling, mechanical work, deterministic aggregation, receipt construction, unchanged-state checks, context pollution, and topology alone do not justify Sol/xhigh."
USER_SELECTED_SOL_XHIGH_OVERRIDE_RULE =
  "An explicitly user-selected Sol/xhigh override is honored and reported as an override, not silently rewritten."
# Intentionally duplicates the exact CHANGELOG bullet; update this mirror with any copy edit.
CODEX_CHANGELOG_ROUTING_NOTE =
  "Adopt the recommended Codex GPT-5.6 routing profile: balanced/high routine multi-lane coordination, with Terra/high for host-verified coordination and positively classified simple workers; Sol/xhigh adversarial QA and high-risk escalation; and Sol/high for uncertainty and routine deterministic QA."
MEASURED_PROMOTION_DEFERRAL_RULE =
  "No ten-batch measured promotion decision may be made before #398 usage/cost receipts, #333 execution-provenance receipts, and #335 evaluation runner exist. A promotion experiment must use matched task classes and context topology, record requested-versus-observed execution evidence, and publish its comparison results; this evidence is not complete."
ROUTE_ONLY_FIELD_SOURCE = "model|effort|reasoning[-\\s]effort|route|tuple"
ROUTE_ONLY_SUBJECT_PATTERN = /
  (?:
    (?:#{ROUTE_ONLY_FIELD_SOURCE})\s+(?:mismatch|unavailability) |
    (?:#{ROUTE_ONLY_FIELD_SOURCE})\s+is\s+(?:unavailable|different|`?UNKNOWN`?) |
    preferred\s+route\s+is\s+(?:unavailable|different|`?UNKNOWN`?) |
    unavailable\ (?:observed\ )?(?:#{ROUTE_ONLY_FIELD_SOURCE}) |
    different\ (?:observed\ )?(?:#{ROUTE_ONLY_FIELD_SOURCE}) |
    `?UNKNOWN`?\s+(?:observed\ )?(?:#{ROUTE_ONLY_FIELD_SOURCE}|observation) |
    observed\ route\s+differs\s+from\s+(?:the\ )?requested\ route |
    requested\ route\s+differs\s+from\s+(?:the\ )?observed\ route |
    observed\ route\s+does\s+not\s+match\s+(?:the\ )?requested\ route |
    requested\ route\s+does\s+not\s+match\s+(?:the\ )?observed\ route |
    (?:the\s+)?requested\s+and\s+observed\s+routes\s+do\s+not\s+match |
    inherited\ route |
    silent[-\s]substitution |
    substituted\ route
  )
/imx
ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE = "launch|replay|review|audit|planning|coordination|execution|escalation|fallback"
ROUTE_ONLY_STANDALONE_BLOCKED_ACTIVITY_SOURCE =
  "(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})(?=\\s*(?:[.!?,;:]|\\z|when\\b|if\\b|whenever\\b|unless\\b))".freeze
ROUTE_ONLY_DISQUALIFIED_VERDICT_SOURCE =
  "(?:an?\\s+)?(?:otherwise\\s+)?(?:independent(?:,\\s*|\\s+and\\s+|\\s+))?(?:evidence-backed\\s+)?(?:review|audit|readiness|checker\\s+verdict)"
# This bounded, guide-derived stop/prohibition vocabulary needs matching mutation coverage whenever routing-guide phrasing changes.
ROUTE_ONLY_OUTCOME_SOURCE = "stops?\\s+the\\s+lane|halts?\\s+the\\s+lane|blocks?\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})|blocks?\\s+both\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})\\s+and\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})|(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})(?:\\s+and\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE}))*\\s+(?:is|are)\\s+(?:blocked|stopped|prevented)|(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})(?:\\s+and\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE}))*\\s+(?:must|should|may|can|will|would|could|shall)\\s+be\\s+(?:blocked|stopped|prevented)|disqualif(?:y|ies)\\s+(?:the\\s+lane|#{ROUTE_ONLY_DISQUALIFIED_VERDICT_SOURCE})|requires?\\s+(?:a\\s+)?relaunch\\s+before\\s+editing|prevents?\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})|prevents?\\s+both\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})\\s+and\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})|prevents?\\s+editing\\s+until\\s+(?:a\\s+)?relaunch".freeze
ROUTE_ONLY_OUTCOME_PATTERN = /\b(?:#{ROUTE_ONLY_OUTCOME_SOURCE})\b/i
ROUTE_ONLY_CONTRADICTION_PATTERN =
  /(?:#{ROUTE_ONLY_SUBJECT_PATTERN}[^.!?]*#{ROUTE_ONLY_OUTCOME_PATTERN}|#{ROUTE_ONLY_OUTCOME_PATTERN}[^.!?]*#{ROUTE_ONLY_SUBJECT_PATTERN})/im
ROUTE_ONLY_PROHIBITION_SOURCE =
  "(?:do\\s+not|never|must\\s+not|should\\s+not|cannot|may\\s+not|shall\\s+not)\\s+#{ROUTE_ONLY_STANDALONE_BLOCKED_ACTIVITY_SOURCE}|(?:forbid(?:s)?|prohibit(?:s|ed)?)\\s+(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})|(?:#{ROUTE_ONLY_BLOCKED_ACTIVITY_SOURCE})\\s+(?:is|are)\\s+(?:prohibited|not\\s+allowed)".freeze
ROUTE_ONLY_PROHIBITION_PATTERN =
  /(?:#{ROUTE_ONLY_SUBJECT_PATTERN}[^.!?]*\b(?:#{ROUTE_ONLY_PROHIBITION_SOURCE})\b|\b(?:#{ROUTE_ONLY_PROHIBITION_SOURCE})\b[^.!?]*#{ROUTE_ONLY_SUBJECT_PATTERN})/im
ROUTE_ONLY_OUTCOME_OR_PROHIBITION_PATTERN =
  /\b(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b/i
NEGATED_ROUTE_ONLY_OUTCOME_CLAUSE_PATTERN =
  /
    (?:
      \bnever\s+(?:(?:alone|by\s+itself)\s+)? |
      \bnot\s+a\s+condition\s+that\s+ |
      \b(?:is|are|was|were)\s+not\s+sufficient\s+to\s+ |
      \b(?:is|are|was|were)n['’]?t\s+sufficient\s+to\s+ |
      \b(?:is|are|was|were)\s+insufficient\s+to\s+ |
      \b(?:do|does|did|should|must|may|can|will|would|could|shall)\s+
      not(?:\s+|,\s*)(?:(?:by\s+itself|alone)(?:\s+|,\s*)|(?:necessarily|automatically)\s+)? |
      \b(?:do|does|did|should|must|may|can|would|could|shall)n['’]?t(?:\s+|,\s*)
      (?:(?:by\s+itself|alone|necessarily|automatically)(?:\s+|,\s*))? |
      \bwon['’]?t(?:\s+|,\s*)(?:(?:by\s+itself|alone|necessarily|automatically)(?:\s+|,\s*))? |
      \bcannot(?:\s+|,\s*)(?:(?:by\s+itself|alone|necessarily|automatically)(?:\s+|,\s*))? |
      \bcan['’]?t(?:\s+|,\s*)(?:(?:by\s+itself|alone|necessarily|automatically)(?:\s+|,\s*))?
    )
    \b(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b
  /ix
NEGATED_ROUTE_ONLY_SUBJECT_OUTCOME_CLAUSE_PATTERN =
  /
    \bno\s+(?:#{ROUTE_ONLY_SUBJECT_PATTERN})\s+(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b |
    \bneither\s+(?:an?\s+)?(?:#{ROUTE_ONLY_SUBJECT_PATTERN})\s+nor\s+(?:an?\s+)?(?:#{ROUTE_ONLY_SUBJECT_PATTERN})\s+(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b
  /imx
NEGATED_ROUTE_ONLY_PREDICATE_OUTCOME_CLAUSE_PATTERN =
  /
    (?:#{ROUTE_ONLY_SUBJECT_PATTERN})\s+neither\s+
    (?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\s+nor\s+
    (?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b
  /imx
NEGATED_ROUTE_ONLY_COORDINATED_OUTCOME_CLAUSE_PATTERN =
  /
    (?:#{ROUTE_ONLY_SUBJECT_PATTERN})\s+(?:does\s+not|doesn['’]?t)\s+
    (?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\s+
    (?:or|nor|and)\s+(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b
  /imx
DIRECT_INDEPENDENT_BLOCKER_SOURCE =
  "(?:an?\\s+)?(?:independent\\s+(?:risk|scope|evidence|authority)(?:\\s+gate)?|(?:risk|scope|evidence|authority)\\s+gate|exact-head\\s+CI\\s+gate|(?:destructive\\s+)?scope\\s+expansion)"
INDEPENDENT_GATE_CONDITIONAL_OUTCOME_CLAUSE_PATTERN =
  /\b(?:#{ROUTE_ONLY_OUTCOME_SOURCE})\b\s+only\s+if\s+(?:#{DIRECT_INDEPENDENT_BLOCKER_SOURCE})\s+blocks(?:\s+execution)?\b/i
DIRECT_INDEPENDENT_BLOCKER_BLOCKS_EXECUTION_PATTERN =
  /(?:\b(?:but|and|yet)\b|;)\s+(?:#{DIRECT_INDEPENDENT_BLOCKER_SOURCE})\s+blocks\s+execution\b/i
INDEPENDENT_GATE_FIRST_BLOCKS_EXECUTION_PATTERN =
  /\bonly\s+an\s+independent\s+(?:risk|scope|evidence|authority)\s+gate\s+blocks\s+execution\s+when\s+/i
CONCRETE_INDEPENDENT_BLOCKER_SENTENCE_PATTERN =
  /\b(?:exact-head\s+CI\s+gate|(?:credential|security|risk|scope|evidence|authority)\s+(?:check|gate))\s+(?:fails?|blocks?)\b/i
def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def extract_markdown_section(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  body_start = heading_match.end(0)
  next_heading = text.match(/^###\s+/, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def strip_html_comments(text)
  in_fence = false
  in_html_comment = false

  text.lines.map do |line|
    if markdown_fence_line?(line)
      in_fence = !in_fence
      next line
    end

    next line if in_fence

    stripped_line, in_html_comment = strip_html_comments_from_prose_line(line, in_html_comment)
    stripped_line
  end.join
end

def strip_html_comments_from_prose_line(line, in_html_comment)
  stripped_line = +""
  inline_code = false
  index = 0

  while index < line.length
    if in_html_comment
      comment_end = line.index("-->", index)
      return [stripped_line, true] unless comment_end

      index = comment_end + 3
      in_html_comment = false
    elsif line[index] == "`"
      inline_code = !inline_code
      stripped_line << line[index]
      index += 1
    elsif !inline_code && line[index, 4] == "<!--"
      in_html_comment = true
      index += 4
    else
      stripped_line << line[index]
      index += 1
    end
  end

  [stripped_line, in_html_comment]
end

def normalized(text)
  text.gsub(/\s+/, " ").strip
end

def strip_allowed_route_only_outcome_clauses(text)
  text
    .gsub(NEGATED_ROUTE_ONLY_COORDINATED_OUTCOME_CLAUSE_PATTERN, "")
    .gsub(NEGATED_ROUTE_ONLY_OUTCOME_CLAUSE_PATTERN, "")
    .gsub(NEGATED_ROUTE_ONLY_SUBJECT_OUTCOME_CLAUSE_PATTERN, "")
    .gsub(NEGATED_ROUTE_ONLY_PREDICATE_OUTCOME_CLAUSE_PATTERN, "")
    .gsub(INDEPENDENT_GATE_CONDITIONAL_OUTCOME_CLAUSE_PATTERN, "")
end

def strip_negated_route_outcome_with_independent_blocker_clause(sentence)
  remaining = sentence

  # Each iteration removes one route-owned clause, so route-subject occurrences
  # provide a finite bound while allowing every independently gated clause.
  sentence.scan(ROUTE_ONLY_SUBJECT_PATTERN).length.times do
    stripped = strip_one_negated_route_outcome_with_independent_blocker_clause(remaining)
    break if stripped == remaining

    remaining = stripped
  end

  remaining
end

def strip_one_negated_route_outcome_with_independent_blocker_clause(sentence)
  # Checks before stripping ensure each removed clause has one owned subject/negation/blocker triple.
  subject = sentence.match(ROUTE_ONLY_SUBJECT_PATTERN)
  negated_outcome = sentence.match(NEGATED_ROUTE_ONLY_OUTCOME_CLAUSE_PATTERN)
  independent_blocker = sentence.match(DIRECT_INDEPENDENT_BLOCKER_BLOCKS_EXECUTION_PATTERN)

  return sentence unless subject && negated_outcome && independent_blocker
  return sentence unless subject.begin(0) < negated_outcome.begin(0) && negated_outcome.end(0) <= independent_blocker.begin(0)
  return sentence if sentence[subject.end(0)...negated_outcome.begin(0)].match?(ROUTE_ONLY_OUTCOME_OR_PROHIBITION_PATTERN)
  return sentence if sentence[negated_outcome.end(0)...independent_blocker.begin(0)].match?(ROUTE_ONLY_OUTCOME_OR_PROHIBITION_PATTERN)

  "#{sentence[0...subject.begin(0)]}#{sentence[independent_blocker.end(0)..]}"
end

def strip_independent_gate_first_clause(sentence)
  gate_prefix = sentence.match(INDEPENDENT_GATE_FIRST_BLOCKS_EXECUTION_PATTERN)
  return sentence unless gate_prefix

  subject = sentence.match(ROUTE_ONLY_SUBJECT_PATTERN, gate_prefix.end(0))
  return sentence unless subject

  occurrence = sentence[subject.end(0)..].match(/\A\s+occurs\b/i)
  return sentence unless occurrence

  trailing_text = sentence[subject.end(0) + occurrence.end(0)..]
  return sentence if trailing_text.match?(ROUTE_ONLY_OUTCOME_PATTERN)

  "#{sentence[0...gate_prefix.begin(0)]}#{sentence[subject.end(0) + occurrence.end(0)..]}"
end

def markdown_table_delimiter_line?(line)
  stripped_line = line.strip
  has_leading_pipe = stripped_line.start_with?("|")
  has_trailing_pipe = stripped_line.end_with?("|")
  cells_text = stripped_line
  cells_text = cells_text[1..] if has_leading_pipe
  cells_text = cells_text[0...-1] if has_trailing_pipe
  cells = cells_text.split("|").map(&:strip)

  return false if cells.empty? || cells.any?(&:empty?)
  return false unless cells.all? { |cell| cell.match?(/\A:?-+:?\z/) }

  has_leading_pipe || has_trailing_pipe || cells.length >= 2
end

def markdown_table_line_indexes(lines)
  table_line_indexes = []

  lines.each_with_index do |line, index|
    next unless markdown_table_delimiter_line?(line)

    previous_index = index - 1
    table_line_indexes << previous_index if previous_index >= 0 && lines[previous_index].include?("|")
    table_line_indexes << index

    following_index = index + 1
    while following_index < lines.length && lines[following_index].include?("|")
      table_line_indexes << following_index
      following_index += 1
    end
  end

  table_line_indexes.uniq
end

def markdown_setext_heading_line_indexes(lines)
  lines.each_with_index.filter_map do |underline, index|
    next unless index.positive? && underline.match?(/^\s{0,3}(?:=+|-+)\s*$/)
    next if lines[index - 1].strip.empty?

    [index - 1, index]
  end.flatten.uniq
end

def markdown_fence_line?(line)
  line.match?(/^\s{0,3}(?:```|~~~)/)
end

def markdown_thematic_break_line?(line)
  line.match?(/^\s{0,3}(?:\*(?:\s*\*){2,}|_(?:\s*_){2,}|-(?:\s*-){2,})\s*$/)
end

def markdown_blockquote_line?(line)
  line.match?(/^\s{0,3}>/)
end

def markdown_blockquote_content(line)
  line.sub(/^\s{0,3}>\s?/, "")
end

def markdown_lazy_blockquote_continuation_line?(line)
  return false if line.strip.empty?
  return false if markdown_fence_line?(line) || markdown_thematic_break_line?(line)
  return false if line.match?(/^\s{0,3}\#{1,6}(?:\s|$)/)

  !line.match?(/^\s*(?:[-*+]\s+|\d+[.)]\s+)/)
end

def append_blockquote_structural_segments(segments, blockquote_content)
  return if blockquote_content.empty?

  segments.concat(markdown_structural_segments(blockquote_content))
end

def markdown_structural_segments(block)
  segments = []
  current_segment = +""
  in_blockquote = false
  lines = block.lines
  table_line_indexes = markdown_table_line_indexes(lines)
  setext_heading_line_indexes = markdown_setext_heading_line_indexes(lines)

  lines.each_with_index do |line, index|
    if markdown_blockquote_line?(line)
      content = markdown_blockquote_content(line)

      if content.strip.empty?
        append_blockquote_structural_segments(segments, current_segment)
        current_segment = +""
        in_blockquote = false
        next
      end

      unless in_blockquote
        segments << current_segment unless current_segment.empty?
        current_segment = +""
        in_blockquote = true
      end
      current_segment << content
      next
    end

    if in_blockquote && markdown_lazy_blockquote_continuation_line?(line)
      current_segment << line
      next
    end

    if in_blockquote
      append_blockquote_structural_segments(segments, current_segment)
      current_segment = +""
      in_blockquote = false
    end

    if table_line_indexes.include?(index)
      segments << current_segment unless current_segment.empty?
      segments << line
      current_segment = +""
    elsif markdown_fence_line?(line)
      segments << current_segment unless current_segment.empty?
      segments << line
      current_segment = +""
    elsif setext_heading_line_indexes.include?(index)
      segments << current_segment unless current_segment.empty?
      segments << line
      current_segment = +""
    elsif markdown_thematic_break_line?(line)
      segments << current_segment unless current_segment.empty?
      segments << line
      current_segment = +""
    elsif line.match?(/^\s{0,3}\#{1,6}(?:\s|$)/)
      segments << current_segment unless current_segment.empty?
      segments << line
      current_segment = +""
    elsif line.match?(/^\s*(?:[-*+]\s+|\d+[.)]\s+)/)
      segments << current_segment unless current_segment.empty?
      current_segment = line.dup
    else
      current_segment << line
    end
  end

  if in_blockquote
    append_blockquote_structural_segments(segments, current_segment)
  else
    segments << current_segment unless current_segment.empty?
  end
  segments
end

def route_only_contradiction_segments(text)
  strip_html_comments(text).split(/\n\s*\n/).flat_map { |block| markdown_structural_segments(block) }
end

def unguarded_route_only_sentence(sentence)
  gate_first_clause_stripped = strip_independent_gate_first_clause(sentence)
  permitted_clause_stripped = strip_negated_route_outcome_with_independent_blocker_clause(gate_first_clause_stripped)
  strip_allowed_route_only_outcome_clauses(permitted_clause_stripped)
end

def forbidden_route_only_sentence?(sentence)
  return true if negated_subject_precedes_pronoun_contradiction?(sentence)

  unguarded_sentence = unguarded_route_only_sentence(sentence)
  unguarded_sentence.match?(ROUTE_ONLY_CONTRADICTION_PATTERN) ||
    unguarded_sentence.match?(ROUTE_ONLY_PROHIBITION_PATTERN)
end

def negated_subject_precedes_pronoun_contradiction?(sentence)
  negated_subject_outcome =
    sentence.match(NEGATED_ROUTE_ONLY_SUBJECT_OUTCOME_CLAUSE_PATTERN) ||
    sentence.match(NEGATED_ROUTE_ONLY_PREDICATE_OUTCOME_CLAUSE_PATTERN) ||
    sentence.match(NEGATED_ROUTE_ONLY_COORDINATED_OUTCOME_CLAUSE_PATTERN)
  return false unless negated_subject_outcome

  sentence[negated_subject_outcome.end(0)..].match?(
    /\b(?:it|this|that)\s+(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b/i
  )
end

def route_subject_precedes_pronoun_contradiction?(previous_sentence, sentence)
  previous_sentence.match?(ROUTE_ONLY_SUBJECT_PATTERN) &&
    sentence.match?(/\A\s*(?:it|this|that)\b/i) &&
    forbidden_route_only_sentence?(sentence.sub(/\A\s*(?:it|this|that)\b/i, "A route mismatch"))
end

def route_subject_precedes_bare_outcome_contradiction?(previous_sentence, sentence)
  previous_sentence.match?(ROUTE_ONLY_SUBJECT_PATTERN) &&
    sentence.match?(/\A\s*(?:#{ROUTE_ONLY_OUTCOME_SOURCE}|#{ROUTE_ONLY_PROHIBITION_SOURCE})\b/i) &&
    forbidden_route_only_sentence?("A route mismatch #{sentence}")
end

def independent_blocker_sentence?(sentence)
  sentence.match?(/\b(?:#{DIRECT_INDEPENDENT_BLOCKER_SOURCE})\b/i) ||
    sentence.match?(CONCRETE_INDEPENDENT_BLOCKER_SENTENCE_PATTERN)
end

def forbidden_route_only_contradiction?(text)
  route_only_contradiction_segments(text).any? do |segment|
    sentences = segment.split(/(?<=[.!?])\s+/)
    route_subject_sentence = nil

    sentences.any? do |sentence|
      break true if forbidden_route_only_sentence?(sentence)

      if route_subject_sentence && route_subject_precedes_pronoun_contradiction?(route_subject_sentence, sentence)
        break true
      end

      if route_subject_sentence && route_subject_precedes_bare_outcome_contradiction?(route_subject_sentence, sentence)
        break true
      end

      if independent_blocker_sentence?(sentence)
        route_subject_sentence = nil
      elsif sentence.match?(ROUTE_ONLY_SUBJECT_PATTERN)
        route_subject_sentence = sentence
      end

      false
    end
  end
end

def route_dispositions(text)
  section = extract_markdown_section(text, ROUTE_DISPOSITION_TABLE_HEADING)
  rows = section.scan(/^\|\s*`([a-z-]+)`\s*\|[^|\n]*\|[^|\n]*\|\s*`([A-Za-z_-]+)`\s*\|\s*$/)
  raise "missing route disposition rows under #{ROUTE_DISPOSITION_TABLE_HEADING}" if rows.empty?

  duplicate_case_ids = rows.group_by(&:first).select { |_case_id, entries| entries.length > 1 }.keys
  unless duplicate_case_ids.empty?
    raise "duplicate route disposition case ids: #{duplicate_case_ids.join(', ')}"
  end

  rows.to_h
end

def mutate_route_disposition(text, case_id, disposition)
  text.sub(/(^\|\s*`#{Regexp.escape(case_id)}`[^\n]*\|\s*)`[A-Za-z_-]+`(\s*\|\s*$)/) do
    "#{Regexp.last_match(1)}`#{disposition}`#{Regexp.last_match(2)}"
  end
end

def duplicate_route_disposition(text, case_id, disposition)
  row_pattern = /^\|\s*`#{Regexp.escape(case_id)}`[^\n]*\n/
  row = text.match(row_pattern)&.to_s
  raise "missing route disposition row for #{case_id}" unless row

  duplicate = "| `#{case_id}` | duplicate requested tuple | duplicate observed tuple | `#{disposition}` |\n"
  text.sub(row, "#{row}#{duplicate}")
end

def assert_route_provenance_contract(test, text, label)
  guide = normalized(text)
  ROUTE_PROVENANCE_RULES.each do |rule|
    test.assert_includes guide, rule, "#{label} must carry the exact route-provenance rule: #{rule}"
  end
  test.refute_includes guide, "MODEL_ROUTE_MISMATCH",
                       "#{label} must not restore the former hard route-mismatch disposition"
  test.refute forbidden_route_only_contradiction?(text),
              "#{label} must not pair advisory continuation with an unconditional route-only stop"
end

def aw_d_replay_fingerprint
  AW_D_ROUTE_REPLAY.map do |row|
    [row.fetch(:pr), row.fetch(:role), row.fetch(:case_id), row.fetch(:disposition)].join("|")
  end.sort
end

def assert_aw_d_route_replay(test, text, label)
  dispositions = route_dispositions(text)
  test.assert_includes normalized(text), AUTHORIZED_FALLBACK_RECORDED_AUTHORITY_RULE,
                       "#{label}: authorized fallback must retain its recorded-authority requirement"
  EXPECTED_ROUTE_DISPOSITIONS.each do |case_id, expected|
    test.assert_equal expected, dispositions[case_id],
                      "#{label}: #{case_id} must dispose as #{expected}"
  end
  test.assert_equal AW_D_ROUTE_REPLAY_FINGERPRINT, aw_d_replay_fingerprint,
                    "#{label}: the internal AW D replay fixture changed; keep this consistency and mutation guard aligned with the audited record"
  AW_D_ROUTE_REPLAY.each do |row|
    case_id = row.fetch(:case_id)
    expected = row.fetch(:disposition)
    actual = dispositions[case_id]
    test.assert_equal expected, actual,
                      "#{label}: AW D PR ##{row.fetch(:pr)} #{row.fetch(:role)} (#{case_id}) must dispose as #{expected}"
  end
end

def assert_recommended_profiles(test, text, label)
  guide = normalized(text)
  (CODEX_RECOMMENDATIONS + CLAUDE_RECOMMENDATIONS).each do |recommendation|
    test.assert_includes guide, recommendation, "#{label} is missing #{recommendation}"
  end
  test.assert_includes guide, "advisory", label
end

def assert_constrained_routine_routing(test, text, label)
  guide = normalized(strip_html_comments(text))
  [
    ROUTINE_COORDINATOR_ROUTE_RULE,
    ROUTINE_MULTI_LANE_COORDINATOR_ROUTE_RULE,
    SOL_XHIGH_EXCEPTION_ROUTE_RULE,
    SOL_XHIGH_RESERVATION_RULE,
    SOL_XHIGH_NONTRIGGERS_RULE,
    USER_SELECTED_SOL_XHIGH_OVERRIDE_RULE,
    MEASURED_PROMOTION_DEFERRAL_RULE
  ].each do |rule|
    test.assert_includes guide, rule, "#{label} is missing constrained-routing rule: #{rule}"
  end
  test.refute_includes guide, "Multi-lane coordinator: Sol/xhigh",
                       "#{label} must not present Sol/xhigh as the multi-lane coordinator default"
end

def assert_codex_changelog_routing_note(test, text, label)
  test.assert_includes text, CODEX_CHANGELOG_ROUTING_NOTE,
                       "#{label} must retain the exact Codex routing release note"
end

def assert_no_route_only_contradiction(test, text, label)
  test.refute forbidden_route_only_contradiction?(text),
              "#{label} must not pair advisory continuation with an unconditional route-only outcome"
end

def evidence_status_rows(text)
  section = extract_markdown_section(text, "### Evidence Status")
  lines = section.lines
  header_index = lines.index { |line| line.strip == "| Scenario class | Risk | Recommended route | Samples | Evidence strength |" }
  raise "missing Evidence Status table header" unless header_index

  data_lines = lines[(header_index + 2)..].take_while { |line| line.start_with?("|") }
  raise "missing Evidence Status scenario rows" if data_lines.empty?

  data_lines.map do |line|
    cells = line.strip.split("|", -1)[1...-1].map(&:strip)
    raise "malformed Evidence Status scenario row: #{line.strip}" unless cells.length == 5

    {
      scenario: cells[0],
      samples: cells[3],
      evidence_strength: cells[4].delete("`")
    }
  end
end

def mutate_evidence_status_row(text, scenario, samples: nil, evidence_strength: nil)
  row = text.each_line.find { |line| line.start_with?("| #{scenario} |") }
  raise "missing Evidence Status scenario row for #{scenario}" unless row

  cells = row.strip.split("|", -1)[1...-1].map(&:strip)
  cells[3] = samples if samples
  cells[4] = "`#{evidence_strength}`" if evidence_strength
  text.sub(row, "| #{cells.join(' | ')} |\n")
end

def assert_evidence_status_table_unmeasured(test, text, label)
  evidence_status_rows(text).each do |row|
    test.assert_equal "0", row.fetch(:samples),
                      "#{label}: #{row.fetch(:scenario)} must retain Samples: 0"
    test.assert_equal "UNKNOWN", row.fetch(:evidence_strength),
                      "#{label}: #{row.fetch(:scenario)} must retain Evidence strength: UNKNOWN"
  end
end

def extract_prompt(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  fence_start = text.index(TEXT_FENCE, heading_match.end(0))
  raise "missing text fence after #{heading}" unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  body_end = text.index(/^```\s*$/, body_start)
  raise "missing closing fence after #{heading}" unless body_end

  text[body_start...body_end]
end

class ModelRoutingContractTest < Minitest::Test
  def test_markdown_section_extractor_ignores_a_quoted_heading
    document = <<~MARKDOWN
      <!-- Keep `### Disposition Table` in sync. -->
      decoy body

      ### Disposition Table

      real body

      ### Next
    MARKDOWN

    assert_equal "\n\nreal body\n\n", extract_markdown_section(document, "### Disposition Table")
  end

  def test_prompt_extractor_ignores_a_heading_quoted_before_the_real_fence
    document = <<~MARKDOWN
      <!-- See `## Goal Prompt` before editing. -->
      ```text
      decoy prompt
      ```

      ## Goal Prompt

      ```text
      real prompt
      ```
    MARKDOWN

    assert_equal "real prompt\n", extract_prompt(document, "## Goal Prompt")
  end

  def test_active_routing_surfaces_share_the_advisory_unsigned_lifecycle_contract
    ROUTING_SURFACES.each do |path|
      raw_text = read_repo_file(path)
      text = normalized(raw_text)

      [
        ADVISORY_ROUTE_RULE,
        OBSERVED_HOST_RULE,
        ORDINARY_ACTIVATION_RULE,
        REPLAY_IDENTITY_RULE,
        DISPATCH_PERSISTENCE_RULE,
        REPLACEMENT_FENCING_RULE
      ].each do |rule|
        assert_includes text, rule, "#{path} is missing: #{rule}"
      end
      assert_no_route_only_contradiction(self, raw_text, path)
    end
  end

  def test_active_routing_surfaces_do_not_restore_project_signing_or_hard_route_gates
    ROUTING_SURFACES.each do |path|
      text = read_repo_file(path)

      refute_includes text, ".agents/dispatcher-launch-trust.json", path
      refute_includes text, "RSA-SHA256", path
      refute_includes text, "exact-policy UNKNOWN blocks", path
      refute_includes text, "hard route", path
    end
  end

  def test_goal_prompts_describe_preferences_observations_and_ordinary_activation
    prompts = {
      "workflow" => extract_prompt(read_repo_file("workflows/pr-processing.md"), "### Plan To Goal Handoff"),
      "pr-batch" => extract_prompt(read_repo_file("skills/pr-batch/SKILL.md"), "## Goal Prompt Template"),
      "plan-pr-batch" => extract_prompt(read_repo_file("skills/plan-pr-batch/SKILL.md"), "## Goal Prompt for pr-batch")
    }

    prompts.each do |label, prompt|
      assert_includes prompt, "Coordinator model/effort preference:", label
      assert_includes prompt, "Worker model/effort preferences:", label
      assert_includes prompt, "Observed host/model/effort:", label
      assert_includes prompt, "ordinary pending/active lifecycle", label
      refute_includes prompt, "Launch assurance:", label
      refute_includes prompt, "exact-policy", label
    end
  end

  def test_dispatcher_helper_is_portable_unsigned_and_preserves_dispatcher_fencing
    helper_path = File.join(ROOT, "skills/pr-batch/bin/dispatcher-capability-preflight")
    source = File.read(helper_path, encoding: "UTF-8")

    assert File.executable?(helper_path)
    assert_includes source, "blocked-replacement-fencing"
    assert_includes source, "stop-and-reconcile-prior-instance"
    assert_includes source, "replacement-proof"
    assert_includes source, "launch-pending"
    assert_includes source, '"active"'
    refute_includes source, "OpenSSL"
    refute_includes source, "dispatcher-launch-trust"
    refute_includes source, "launch_confirmation"
  end

  def test_checker_surfaces_preserve_independence_and_quality_without_route_blocking
    CHECKER_SURFACES.each do |path|
      raw_text = read_repo_file(path)
      text = normalized(raw_text)

      assert_includes text, CHECKER_RULE, path
      assert_includes text.downcase, "independent", path
      assert_no_route_only_contradiction(self, raw_text, path)
    end
  end

  def test_active_routing_and_checker_surfaces_reject_route_only_contradiction_mutants
    {
      "routing" => ["skills/pr-batch/SKILL.md", "A route mismatch blocks launch."],
      "checker" => ["skills/adversarial-pr-review/SKILL.md", "A route mismatch disqualifies a checker verdict."]
    }.each do |surface, (path, contradiction)|
      mutant = "#{read_repo_file(path)}\n\n#{contradiction}\n"

      assert_raises(Minitest::Assertion, "#{surface} surface accepted an unconditional route-only outcome") do
        assert_no_route_only_contradiction(self, mutant, "#{path} #{surface} mutant")
      end
    end
  end

  def test_review_audit_and_planning_surfaces_never_qualify_verdicts_by_route
    CHECKER_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      assert_includes text, VERDICT_QUALIFICATION_RULE, path
      assert_includes text, ROUTE_NONDISQUALIFICATION_RULE, path
      ROUTE_DISQUALIFICATION_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
    end
  end

  def test_active_execution_surfaces_never_enforce_named_model_routes
    ROUTING_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      [
        EXECUTION_ROUTE_ADVISORY_RULE,
        EXECUTION_ROUTE_FALLBACK_RULE,
        MODEL_NEUTRAL_RISK_RULE,
        MODEL_NEUTRAL_ENVELOPE_RULE
      ].each do |rule|
        assert_includes text, rule, "#{path} is missing: #{rule}"
      end
      NAMED_EXECUTION_ENFORCEMENT_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
      ROUTE_AUTHORITY_ENFORCEMENT_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
    end
  end

  def test_adversarial_review_surfaces_keep_route_advisory_without_weakening_the_verdict
    %w[
      skills/adversarial-pr-review/SKILL.md
      workflows/adversarial-pr-review.md
    ].each do |path|
      text = normalized(read_repo_file(path))

      assert_includes text, ADVERSARIAL_ADVISORY_RULE, path
      assert_includes text, ADVERSARIAL_OBSERVATION_RULE, path
      assert_includes text, ADVERSARIAL_QUALITY_RULE, path
      refute_includes text, "Do not downgrade this qualifying adversarial verdict", path
      refute_includes text,
                      "remains the route for routine deterministic QA, not this qualifying adversarial verdict",
                      path
    end
  end

  def test_host_owned_hard_gates_require_an_owned_end_to_end_rollout
    contract = normalized(read_repo_file("docs/host-adapter/contract.md"))

    assert_includes contract, HOST_ROLLOUT_MATRIX_RULE
    assert_includes contract, HOST_ROLLOUT_OPTIONAL_RULE
  end

  def test_signed_launch_postmortem_has_accountable_followup_owners_and_resumption_boundary
    postmortem = normalized(
      read_repo_file("docs/postmortems/2026-08-06-unsupported-signed-launch-enforcement.md")
    )

    assert_match %r{Convert incompatible Codex/Claude prompts.*\[justin808\]\(https://github\.com/justin808\).*\[issue #372\]\(https://github\.com/shakacode/agent-workflows/issues/372\)}, postmortem
    assert_match %r{Use observed routing evidence.*\[justin808\]\(https://github\.com/justin808\).*\[issue #151\]\(https://github\.com/shakacode/agent-workflows/issues/151\)}, postmortem
    assert_includes postmortem,
                    "Issue #273 resumes separately after #299 removes the unsupported launch gate; #299 does not implement or redefine #273."
    assert_includes postmortem, "https://github.com/shakacode/agent-workflows/issues/273"
  end

  def test_recommended_profiles_remain_advisory_across_routing_surfaces
    paths = %w[
      docs/agent-workflows-model-routing.md
      docs/pr-batch-skills.md
      skills/plan-pr-batch/SKILL.md
      skills/post-merge-audit/SKILL.md
      skills/pr-batch/SKILL.md
      skills/triage/SKILL.md
      workflows/post-merge-audit.md
      workflows/pr-processing.md
    ]

    paths.each do |path|
      assert_recommended_profiles(self, read_repo_file(path), path)
    end
  end

  def test_profile_surfaces_reject_the_former_sol_xhigh_coordinator_default
    paths = %w[
      docs/agent-workflows-model-routing.md
      docs/pr-batch-skills.md
      skills/plan-pr-batch/SKILL.md
      skills/post-merge-audit/SKILL.md
      skills/pr-batch/SKILL.md
      skills/triage/SKILL.md
      workflows/post-merge-audit.md
      workflows/pr-processing.md
    ]

    paths.each do |path|
      text = read_repo_file(path)
      assert_recommended_profiles(self, text, path)
      mutant = text.sub(
        "Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)",
        "Multi-lane coordinator: Sol/xhigh"
      )

      refute_equal text, mutant, "#{path} former coordinator-default mutant did not change the profile"
      assert_raises(Minitest::Assertion, "#{path} accepted the former Sol/xhigh coordinator default") do
        assert_recommended_profiles(self, mutant, "#{path} former coordinator-default mutant")
      end
    end
  end

  def test_cost_aware_playbook_and_escalation_controls_remain
    guide = read_repo_file("docs/agent-workflows-model-routing.md")
    workflow = normalized(read_repo_file("workflows/pr-processing.md"))

    [
      "GPT-5.6 Sol",
      "GPT-5.6 Terra",
      "Conservative GPT-5.6 Profile",
      "Sol diagnosis and envelope → Terra implementation → Sol check",
      "First-pass acceptance rate",
      "Percentage of tasks escalated",
      "Do not assume that maximum reasoning always improves outcomes"
    ].each { |phrase| assert_includes guide, phrase }
    assert_includes workflow, "MODEL_ESCALATION_REQUEST"
    assert_includes workflow, "old and replacement instances must not overlap"
    assert_includes workflow, "stop and reconcile"
  end

  def test_lane_cards_separate_preference_from_optional_observation
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      text = read_repo_file(path)
      assert_includes text, "preferred model/effort", path
      assert_includes text, "observed host/model/effort", path
      assert_includes text, "UNKNOWN", path
    end
  end

  def test_routing_guide_pins_requested_versus_observed_route_provenance
    assert_route_provenance_contract(self, read_repo_file(MODEL_ROUTING_GUIDE_PATH), MODEL_ROUTING_GUIDE_PATH)
  end

  def test_aw_d_route_mismatches_continue_without_route_measurement_evidence
    assert_aw_d_route_replay(self, read_repo_file(MODEL_ROUTING_GUIDE_PATH), MODEL_ROUTING_GUIDE_PATH)
  end

  def test_route_provenance_rule_mutants_preserve_advisory_continuation
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    assert_route_provenance_contract(self, text, MODEL_ROUTING_GUIDE_PATH)
    guide = normalized(text)
    mutants = {
      "collapsed requested into observed" => guide.sub("never collapse into one", "may be recorded as one field"),
      "prose accepted as evidence" => guide.sub(
        "is never presentable as observed execution evidence",
        "should not usually be presented as observed execution evidence"
      ),
      "mismatch admitted as route-measurement evidence" => guide.sub(
        "must exclude that execution from route-measurement evidence",
        "may include that execution as route-measurement evidence"
      ),
      "mismatch stops otherwise valid work" => guide.sub(
        "never alone stops otherwise valid work",
        "stops otherwise valid work"
      ),
      "worker provenance inherits coordinator observation" => guide.sub(
        "A worker records its own observed model/effort separately from the coordinator",
        "A worker records the coordinator's observed model/effort as its own"
      ),
      "nested spawns exempted" => guide.sub(
        "Collaboration, review-fix, and helper subagents spawned inside a lane are workers for this rule",
        "Nested subagents are exempt from this rule"
      ),
      "user override reduced to generic handling" => guide.sub(
        "An explicitly user-selected override remains a user override rather than an implicit fallback, and its requested and observed tuples are recorded separately.",
        "User overrides are handled separately."
      ),
      "authorized fallback recorded after launch" => guide.sub(
        "An authorized fallback is explicit, recorded before launch, and names the authority that approved it. An unrecorded fallback is a silent substitution and takes that row's disposition.",
        "An authorized fallback is explicit, recorded after launch, and names the authority that approved it. An unrecorded fallback is a silent substitution and takes that row's disposition."
      ),
      "unrecorded fallback treated as authorized" => guide.sub(
        "An authorized fallback is explicit, recorded before launch, and names the authority that approved it. An unrecorded fallback is a silent substitution and takes that row's disposition.",
        "An authorized fallback is explicit, recorded before launch, and names the authority that approved it. An unrecorded fallback is an authorized fallback and takes that row's disposition."
      )
    }

    mutants.each do |mutation, mutant|
      refute_equal guide, mutant, "#{mutation} mutant did not change the guide text"
      assert_raises(Minitest::Assertion, "model-routing guide accepted #{mutation}") do
        assert_route_provenance_contract(self, mutant, "#{MODEL_ROUTING_GUIDE_PATH} #{mutation} mutant")
      end
    end
  end

  def test_aw_d_replay_mutants_keep_mismatches_unmeasured_and_fallback_authorized
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    assert_aw_d_route_replay(self, text, MODEL_ROUTING_GUIDE_PATH)
    mutants = {
      "inherited coordinator pair admitted as measured" =>
        mutate_route_disposition(text, "coordinator-pair-inheritance", "proceed"),
      "silent substitution treated as authorized fallback" =>
        mutate_route_disposition(text, "silent-substitution", "proceed-as-fallback"),
      "unbound exact route admitted as measured" =>
        mutate_route_disposition(text, "unbound-exact-route", "proceed"),
      "authorized fallback stripped of its recorded-authority requirement" =>
        mutate_route_disposition(text, "authorized-fallback", "proceed"),
      "authorized fallback tuple loses recorded authority" =>
        text.sub(AUTHORIZED_FALLBACK_RECORDED_AUTHORITY_RULE, "authorized fallback tuple"),
      "bound exact match excluded from measurement" =>
        mutate_route_disposition(text, "bound-exact-match", "proceed-unmeasured")
    }

    mutants.each do |mutation, mutant|
      refute_equal text, mutant, "#{mutation} mutant did not change the disposition table"
      assert_raises(Minitest::Assertion, "AW D replay accepted #{mutation}") do
        assert_aw_d_route_replay(self, mutant, "#{MODEL_ROUTING_GUIDE_PATH} #{mutation} mutant")
      end
    end
  end

  def test_advisory_continuation_rejects_unconditional_route_only_contradictions
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    assert_route_provenance_contract(self, text, MODEL_ROUTING_GUIDE_PATH)

    {
      "route mismatch" => "A route mismatch stops the lane before any edit begins.",
      "unavailable observed route" => "An unavailable observed route stops the lane before any edit begins.",
      "inherited route" => "An inherited route stops the lane before any edit begins.",
      "silent substitution" => "A silent substitution stops the lane before editing.",
      "substituted route" => "A substituted route stops the lane before editing.",
      "different observed route" => "A different observed route stops the lane before editing.",
      "different route" => "A different route blocks execution before editing.",
      "different tuple" => "A different tuple disqualifies the lane before editing.",
      "UNKNOWN observed tuple" => "An `UNKNOWN` observed tuple stops the lane before any edit begins.",
      "model mismatch" => "A model mismatch stops the lane before editing.",
      "effort mismatch" => "An effort mismatch blocks execution before editing.",
      "reasoning-effort mismatch" => "A reasoning-effort mismatch requires relaunch before editing.",
      "different model" => "A different model blocks execution before editing.",
      "unavailable effort" => "An unavailable effort stops the lane before editing.",
      "UNKNOWN model" => "An UNKNOWN model requires relaunch before editing.",
      "model is unavailable" => "A model is unavailable and stops the lane before editing.",
      "effort is different" => "An effort is different and blocks execution before editing.",
      "reasoning effort is UNKNOWN" => "A reasoning effort is UNKNOWN and requires relaunch before editing.",
      "preferred route is unavailable" => "A preferred route is unavailable and stops the lane before editing.",
      "route mismatch blocks launch" => "A route mismatch blocks launch.",
      "route mismatch blocks replay" => "A route mismatch blocks replay.",
      "route mismatch blocks review" => "A route mismatch blocks review.",
      "route mismatch blocks audit" => "A route mismatch blocks audit.",
      "route mismatch blocks both launch and review" => "A route mismatch blocks both launch and review.",
      "observed requested routes differ passive blocked launch" => "When the observed route differs from the requested route, launch is blocked.",
      "requested observed routes differ passive blocked review" => "When the requested route differs from the observed route, review is blocked.",
      "observed route does not match requested route" => "When the observed route does not match the requested route, launch is blocked.",
      "requested route does not match observed route" => "When the requested route does not match the observed route, review is blocked.",
      "requested and observed routes do not match" => "When the requested and observed routes do not match, launch is blocked.",
      "route mismatch prevents both launch and review" => "A route mismatch prevents both launch and review.",
      "outcome-first prevents both planning and fallback" => "Prevent both planning and fallback when a route mismatch occurs.",
      "outcome-first passive blocked launch" => "When a route mismatch occurs, launch is blocked.",
      "outcome-first passive stopped launch" => "Launch is stopped when a route mismatch occurs.",
      "outcome-first passive prevented review" => "Review is prevented when a route mismatch occurs.",
      "outcome-first modal passive stopped launch" => "Launch must be stopped when a route mismatch occurs.",
      "outcome-first modal passive prevented review" => "Review should be prevented when an inherited route occurs.",
      "outcome-first would-passive stopped launch" => "Launch would be stopped when a route mismatch occurs.",
      "outcome-first could-passive prevented review" => "Review could be prevented when an inherited route occurs.",
      "cross-sentence passive blocked launch" => "A route mismatch occurs. Launch is blocked.",
      "ordinary sentence preserves route antecedent for pronoun outcome" => "A route mismatch occurs. A status note is recorded. This blocks launch.",
      "ordinary CI note preserves route antecedent for pronoun outcome" => "A route mismatch occurs. An exact-head CI note is recorded. This blocks launch.",
      "subject-first passive blocked review" => "A route mismatch means review is blocked.",
      "outcome-first passive blocked plural" => "Launch and replay are blocked when a route mismatch occurs.",
      "outcome-first must-passive blocked launch" => "Launch must be blocked when a route mismatch occurs.",
      "outcome-first should-passive blocked replay" => "Replay should be blocked when there is an inherited route.",
      "outcome-first may-passive blocked review" => "Review may be blocked when there is an UNKNOWN model.",
      "outcome-first can-passive blocked audit" => "Audit can be blocked when there is an unavailable route.",
      "outcome-first will-passive blocked planning" => "Planning will be blocked when there is a route mismatch.",
      "outcome-first shall-passive blocked coordination" => "Coordination shall be blocked when there is a route mismatch.",
      "subject-first modal-passive blocked plural" => "A route mismatch means launch and review must be blocked.",
      "route mismatch prevents launch" => "A route mismatch prevents launch.",
      "route mismatch prevents replay" => "A route mismatch prevents replay.",
      "route mismatch prevents review" => "A route mismatch prevents review.",
      "route mismatch prevents audit" => "A route mismatch prevents audit.",
      "route mismatch prevents planning" => "A route mismatch prevents planning.",
      "route mismatch prevents coordination" => "A route mismatch prevents coordination.",
      "route mismatch prevents execution" => "A route mismatch prevents execution.",
      "route mismatch prevents escalation" => "A route mismatch prevents escalation.",
      "route mismatch prevents fallback" => "A route mismatch prevents fallback.",
      "outcome-first imperative launch" => "Do not launch when there is a route mismatch.",
      "outcome-first imperative replay" => "Do not replay when there is an inherited route.",
      "outcome-first imperative review" => "Do not review when there is an UNKNOWN model.",
      "outcome-first imperative audit" => "Do not audit when there is an unavailable route.",
      "subject-first imperative launch" => "A route mismatch means do not launch.",
      "subject-first prohibition replay" => "An inherited route prohibits replay.",
      "subject-first prohibition review" => "An UNKNOWN model means review is prohibited.",
      "subject-first imperative audit" => "An unavailable route means must not audit.",
      "subject-first prohibition coordination" => "A route mismatch prohibits coordination.",
      "subject-first forbids escalation" => "An inherited route forbids escalation.",
      "subject-first standalone must-not launch" => "A route mismatch must not launch.",
      "subject-first should-not launch" => "A route mismatch should not launch.",
      "subject-first cannot replay" => "An inherited route cannot replay.",
      "subject-first may-not review" => "An UNKNOWN model may not review.",
      "subject-first shall-not audit" => "An unavailable route shall not audit.",
      "subject-first forbids launch" => "A route mismatch forbids launch.",
      "subject-first launch not allowed" => "A route mismatch means launch is not allowed.",
      "outcome-first should-not launch" => "Should not launch when there is a route mismatch.",
      "outcome-first cannot replay" => "Cannot replay when there is an inherited route.",
      "outcome-first may-not review" => "May not review when there is an UNKNOWN model.",
      "outcome-first shall-not audit" => "Shall not audit when there is an unavailable route.",
      "outcome-first forbids launch" => "Forbids launch when there is a route mismatch.",
      "outcome-first launch not allowed" => "Launch is not allowed when there is a route mismatch.",
      "unavailable route blocks planning" => "An unavailable route blocks planning.",
      "inherited route blocks coordination" => "An inherited route blocks coordination.",
      "different tuple blocks escalation" => "A different tuple blocks escalation.",
      "UNKNOWN model blocks fallback" => "An UNKNOWN model blocks fallback.",
      "route mismatch disqualifies review" => "A route mismatch disqualifies review.",
      "route mismatch disqualifies audit" => "A route mismatch disqualifies an independent audit.",
      "route mismatch disqualifies readiness" => "A route mismatch disqualifies readiness.",
      "route mismatch disqualifies checker verdict" => "A route mismatch disqualifies a checker verdict.",
      "outcome-first launch" => "Block launch when there is a route mismatch.",
      "outcome-first replay" => "Block replay when there is a route mismatch.",
      "outcome-first review" => "Block review when there is a route mismatch.",
      "outcome-first audit" => "Block audit when there is a route mismatch.",
      "outcome-first prevention" => "Prevent launch when there is a route mismatch.",
      "outcome-first prevention planning" => "Prevent planning when there is a route mismatch.",
      "outcome-first prevention coordination" => "Prevent coordination when there is an inherited route.",
      "outcome-first prevention execution" => "Prevent execution when there is an UNKNOWN model.",
      "outcome-first prevention escalation" => "Prevent escalation when there is an unavailable route.",
      "outcome-first prevention fallback" => "Prevent fallback when there is a different tuple.",
      "outcome-first planning" => "Block planning when there is an unavailable route.",
      "outcome-first coordination" => "Block coordination when there is an inherited route.",
      "outcome-first escalation" => "Block escalation when there is a different tuple.",
      "outcome-first fallback" => "Block fallback when there is an UNKNOWN model.",
      "outcome-first review disqualification" => "Disqualify review when there is a route mismatch.",
      "outcome-first audit disqualification" => "Disqualify an independent audit when there is a route mismatch.",
      "route mismatch requires relaunch before editing" => "A route mismatch requires relaunch before editing.",
      "route mismatch halts the lane before editing" => "A route mismatch halts the lane before editing.",
      "route mismatch prevents editing until relaunch" => "A route mismatch prevents editing until relaunch.",
      "outcome-first route mismatch" => "Stop the lane before editing when there is a route mismatch.",
      "outcome-first relaunch before route mismatch" => "Require relaunch before editing when there is a route mismatch.",
      "outcome-first different observed route" => "Block execution whenever there is a different observed route.",
      "outcome-first UNKNOWN observed tuple" => "Disqualify the lane when an `UNKNOWN` observed tuple appears.",
      "route mismatch blocks execution" => "A route mismatch blocks execution before any edit begins.",
      "UNKNOWN observed tuple disqualifies the lane" => "An `UNKNOWN` observed tuple disqualifies the lane before any edit begins.",
      "unrelated not before route mismatch stop" => "A route mismatch does not always occur, and it stops the lane before any edit begins.",
      "not authorized before route mismatch stop" => "A route mismatch, when not authorized, stops the lane before any edit begins.",
      "not authorized but blocks execution" => "A route mismatch is not authorized but blocks execution before any edit begins.",
      "may not be authorized yet blocks execution" => "A route mismatch may not be authorized yet blocks execution before any edit begins.",
      "unrelated approval negation before route mismatch stop" => "A route mismatch does not require approval and stops the lane before any edit begins.",
      "negated route outcome followed by but-pronoun outcome before independent blocker" => "A route mismatch does not stop the lane, but it blocks audit; an independent risk gate blocks execution.",
      "negated route outcome followed by and-pronoun outcome before independent blocker" => "A route mismatch does not stop the lane, and it blocks review; an independent risk gate blocks execution.",
      "independent gate followed by unconditional different route" => "A route mismatch does not stop the lane, but an independent risk gate blocks execution, yet a different route disqualifies the lane.",
      "unconditional outcome before independent-gate clause" => "A different route disqualifies the lane, but a route mismatch does not stop the lane, but an independent risk gate blocks execution.",
      "independent-and gate followed by unconditional different route" => "A route mismatch does not stop the lane, and an independent risk gate blocks execution, yet a different route disqualifies the lane.",
      "unconditional outcome before independent-yet gate clause" => "A different route disqualifies the lane, yet a route mismatch does not stop the lane, yet an independent risk gate blocks execution.",
      "semicolon gate followed by unconditional different route" => "A route mismatch does not stop the lane; an independent risk gate blocks execution, yet a different route disqualifies the lane.",
      "unconditional outcome before semicolon gate clause" => "A different route disqualifies the lane; a route mismatch does not stop the lane; an independent risk gate blocks execution.",
      "direct blocker followed by unconditional different route" => "A route mismatch does not stop the lane; destructive scope expansion blocks execution, yet a different route disqualifies the lane.",
      "exact-head CI blocker followed by unconditional route outcome" => "A route mismatch does not stop the lane; an exact-head CI gate blocks execution, yet an inherited route forbids launch.",
      "unconditional outcome before direct blocker" => "A different route disqualifies the lane; a route mismatch does not stop the lane; destructive scope expansion blocks execution.",
      "prohibition between permitted clause and independent blocker" => "A route mismatch does not stop the lane, and an inherited route forbids launch, but an independent risk gate blocks execution.",
      "adjective insufficiency followed by unconditional outcome" => "A route mismatch is insufficient to block launch, but it blocks review.",
      "No-subject negation followed by unconditional different route" => "No route mismatch blocks execution, but a different route stops the lane.",
      "Neither-subject negation followed by unconditional different route" => "Neither a route mismatch nor an inherited route blocks execution, but a different tuple disqualifies the lane.",
      "No-subject negation followed by pronoun outcome" => "No route mismatch blocks launch; it prevents review.",
      "Neither-subject negation followed by pronoun outcome" => "Neither a route mismatch nor an inherited route blocks launch; it prevents review.",
      "Neither-predicate negation followed by pronoun outcome" => "A route mismatch neither blocks launch nor prevents review; it blocks audit.",
      "closed-form negation followed by unconditional outcome" => "A route mismatch cannot by itself block launch, but it blocks audit.",
      "coordinated negation followed by unconditional outcome" => "A route mismatch does not block launch or prevent review, but it blocks audit.",
      "same-paragraph pronoun outcome" => "A route mismatch occurs. It stops the lane before any edit begins.",
      "lazy blockquote pronoun outcome" => "> A route mismatch occurs.\nThis blocks launch.",
      "same-paragraph pronoun prohibition" => "A route mismatch occurs. It prohibits launch.",
      "same-paragraph This outcome" => "A route mismatch occurs. This stops the lane before editing.",
      "same-paragraph That prohibition" => "A route mismatch occurs. That forbids launch.",
      "same-paragraph neutral pronoun outcome" => "A route mismatch occurs. Nothing else changes. It stops the lane before any edit begins.",
      "same-paragraph two-neutral-sentences pronoun outcome" => "A route mismatch occurs. Nothing else changes. The record remains intact. It stops the lane before any edit begins.",
      "pronoun direct blocker followed by unconditional outcome" => "A route mismatch occurs. It does not stop the lane; an independent risk gate blocks execution, yet a different route disqualifies the lane.",
      "unconditional pronoun outcome before direct blocker" => "A route mismatch occurs. It blocks execution before editing. It does not stop the lane; destructive scope expansion blocks execution.",
      "direct conditional followed by unconditional outcome" => "A route mismatch stops the lane only if destructive scope expansion blocks execution, yet a different route disqualifies the lane.",
      "risk gate-first trailing outcome" => "Only an independent risk gate blocks execution when a route mismatch occurs, then stops the lane before editing.",
      "scope gate-first trailing outcome" => "Only an independent scope gate blocks execution when an effort mismatch occurs, then requires relaunch before editing.",
      "evidence gate-first trailing outcome" => "Only an independent evidence gate blocks execution when a different route occurs, then halts the lane before editing.",
      "authority gate-first trailing outcome" => "Only an independent authority gate blocks execution when an UNKNOWN model occurs, then prevents editing until relaunch."
    }.each do |case_name, contradiction|
      mutant = "#{text}\n\n#{contradiction}\n"

      assert_raises(Minitest::Assertion, "advisory continuation accepted #{case_name} as an unconditional route-only stop") do
        assert_route_provenance_contract(self, mutant, "#{MODEL_ROUTING_GUIDE_PATH} #{case_name} unconditional-stop mutant")
      end
    end

    [
      "A route mismatch never blocks execution before any edit begins.",
      "An `UNKNOWN` observed tuple is not a condition that disqualifies the lane before any edit begins.",
      "A route mismatch does not block execution before edits.",
      "A route mismatch should not stop the lane before edits.",
      "A route mismatch does not by itself block execution before edits.",
      "A route mismatch cannot stop the lane before edits.",
      "A route mismatch can't block execution before edits.",
      "A route mismatch cannot by itself block launch.",
      "A route mismatch cannot alone block launch.",
      "An inherited route won't automatically block review.",
      "A route mismatch doesn't stop the lane before edits.",
      "An inherited route shouldn't disqualify the lane before edits.",
      "A route mismatch is not sufficient to stop the lane before edits.",
      "A route mismatch is insufficient to block launch.",
      "A route mismatch does not, by itself, block execution before edits.",
      "A model mismatch does not stop the lane before edits.",
      "An unavailable effort does not block execution before edits.",
      "A route mismatch never alone blocks execution before edits.",
      "A route mismatch never by itself stops the lane before edits.",
      "A route mismatch does not necessarily stop the lane before edits.",
      "A route mismatch does not automatically block execution before edits.",
      "A route mismatch does not prevent launch.",
      "A route mismatch does not block both launch and review.",
      "When the observed route differs from the requested route, launch is not blocked.",
      "When the requested route differs from the observed route, review is not blocked.",
      "When the observed route does not match the requested route, launch is not blocked.",
      "When the requested route does not match the observed route, review is not blocked.",
      "When the observed route does not match the requested route, launch is blocked only if an independent risk gate blocks execution.",
      "When the requested and observed routes do not match, launch is not blocked.",
      "When the requested and observed routes do not match, launch is blocked only if an independent risk gate blocks execution.",
      "A route mismatch does not prevent both launch and review.",
      "A route mismatch does not block launch or prevent review.",
      "A route mismatch does not block launch nor prevent review.",
      "A route mismatch does not block launch and prevent review.",
      "An inherited route never prevents review.",
      "When a route mismatch occurs, launch is not blocked.",
      "Launch is not stopped when a route mismatch occurs.",
      "Review is not prevented when a route mismatch occurs.",
      "Launch must not be stopped when a route mismatch occurs.",
      "Review should not be prevented when an inherited route occurs.",
      "Launch would not be stopped when a route mismatch occurs.",
      "Review could not be prevented when an inherited route occurs.",
      "A route mismatch occurs. Launch is blocked only if an independent risk gate blocks execution.",
      "A route mismatch occurs. Launch must be blocked only if an independent scope gate blocks execution.",
      "A route mismatch means review and audit are not blocked.",
      "Launch must not be blocked when a route mismatch occurs.",
      "Replay should not be blocked when there is an inherited route.",
      "Review may not be blocked when there is an UNKNOWN model.",
      "A route mismatch means launch and review must not be blocked.",
      "A route mismatch does not prevent planning.",
      "An inherited route never prevents fallback.",
      "A route mismatch does not prohibit launch.",
      "A route mismatch must not launch a replacement worker.",
      "An inherited route cannot replay the recorded task.",
      "An UNKNOWN model may not review the diff.",
      "An unavailable route shall not audit the receipt.",
      "A route mismatch occurs. It does not stop the lane, but an independent risk gate blocks execution.",
      "A route mismatch occurs. It does not stop the lane; an independent scope gate blocks execution.",
      "A route mismatch occurs. It does not stop the lane and destructive scope expansion blocks execution.",
      "A route mismatch occurs. This does not stop the lane; an independent scope gate blocks execution.",
      "A route mismatch occurs. Nothing else changes. It does not stop the lane; an independent scope gate blocks execution.",
      "A route mismatch occurs. An independent risk gate blocks execution. It stops the lane before editing.",
      "A route mismatch occurs. Nothing else changes. An independent scope gate blocks execution. It stops the lane before editing.",
      "A route mismatch occurs. An independent risk gate triggers. It blocks execution.",
      "A route mismatch occurs. A credential check fails. This blocks launch.",
      "A route mismatch occurs. An exact-head CI gate fails. This blocks launch.",
      "A route mismatch does not stop the lane; an exact-head CI gate blocks execution.",
      "A route mismatch occurs. An independent scope gate triggers. It blocks execution.",
      "A route mismatch occurs. An independent evidence gate triggers. It blocks execution.",
      "A route mismatch occurs. An independent authority gate triggers. It blocks execution.",
      "A route mismatch occurs. Destructive scope expansion triggers. It blocks execution.",
      "A route mismatch never blocks launch.",
      "A route mismatch does not block replay.",
      "A different route cannot block review.",
      "An UNKNOWN observed tuple should not block audit.",
      "A route mismatch does not disqualify readiness.",
      "An inherited route never disqualifies a checker verdict.",
      "A route mismatch does not stop the lane, but an independent risk gate blocks execution.",
      "A route mismatch does not stop the lane, and an independent scope gate blocks execution.",
      "A route mismatch does not stop the lane, yet an independent evidence gate blocks execution.",
      "A route mismatch does not stop the lane; an independent risk gate blocks execution.",
      "A route mismatch does not stop the lane, but an independent risk gate blocks execution.",
      "No route mismatch blocks launch; it does not prevent review.",
      "Neither a route mismatch nor an inherited route blocks launch; it does not prevent review.",
      "An inherited route does not block execution; an independent scope gate blocks execution.",
      "An unavailable route does not block execution; an independent evidence gate blocks execution.",
      "An UNKNOWN model does not block execution; an independent authority gate blocks execution.",
      "A route mismatch does not stop the lane; destructive scope expansion blocks execution.",
      "A route mismatch does not stop the lane, but destructive scope expansion blocks execution.",
      "A route mismatch does not stop the lane and an independent risk blocks execution.",
      "No route mismatch blocks execution.",
      "Neither a route mismatch nor an inherited route blocks execution.",
      "A route mismatch neither blocks launch nor prevents review.",
      "Only an independent risk gate blocks execution when a route mismatch occurs.",
      "Only an independent scope gate blocks execution when an effort mismatch occurs.",
      "Only an independent evidence gate blocks execution when a different route occurs.",
      "Only an independent authority gate blocks execution when an UNKNOWN model occurs.",
      "A route mismatch stops the lane only if an independent risk gate blocks.",
      "A route mismatch stops the lane only if an independent scope gate blocks.",
      "A route mismatch stops the lane only if an independent evidence gate blocks.",
      "A route mismatch stops the lane only if an independent authority gate blocks.",
      "A route mismatch stops the lane only if destructive scope expansion blocks execution.",
      "A route mismatch does not stop the lane, but an independent risk gate blocks execution; an inherited route does not block execution, but an independent scope gate blocks execution.",
      "A route mismatch does not stop the lane, but an independent risk gate blocks execution; an inherited route does not block execution, but an independent scope gate blocks execution; an unavailable route does not block review, but an independent evidence gate blocks execution."
    ].each do |allowed_condition|
      refute forbidden_route_only_contradiction?(allowed_condition),
             "allowed route condition must not be treated as an unconditional route-only stop: #{allowed_condition}"
      assert_route_provenance_contract(
        self,
        "#{text}\n\n#{allowed_condition}\n",
        "#{MODEL_ROUTING_GUIDE_PATH} allowed route condition"
      )
    end
  end

  def test_route_only_contradictions_do_not_cross_markdown_rows_or_blank_boundaries
    guide = read_repo_file(MODEL_ROUTING_GUIDE_PATH)

    {
      "Markdown table rows" => "| Route condition | route mismatch |\n| --- | --- |\n| Gate result | blocks execution |",
      "leading-only Markdown table rows" => "| Route condition | route mismatch\n| --- | ---\n| Gate result | blocks execution",
      "trailing-only Markdown table rows" => "Route condition | route mismatch |\n--- | --- |\nGate result | blocks execution |",
      "single-column leading-pipe Markdown table rows" => "| route mismatch |\n| --- |\n| blocks execution |",
      "single-dash Markdown table rows" => "| route mismatch |\n| - |\n| blocks execution |",
      "Markdown table rows without outer pipes" => "Route condition | route mismatch\n--- | ---\nGate result | blocks execution",
      "blank boundary" => "A route mismatch\n\nblocks execution.",
      "blank pronoun boundary" => "A route mismatch occurs.\n\nIt stops the lane before any edit begins.",
      "ATX heading boundary" => "### Route mismatch\nDestructive scope expansion blocks execution.",
      "Setext dashed heading boundary" => "Route mismatch\n--------------\nDestructive scope expansion blocks execution.",
      "Setext equals heading boundary" => "Route mismatch\n==============\nDestructive scope expansion blocks execution.",
      "asterisk thematic-break boundary" => "Route mismatch\n***\nDestructive scope expansion blocks execution.",
      "underscore thematic-break boundary" => "Route mismatch\n___\nDestructive scope expansion blocks execution.",
      "dashed thematic-break boundary" => "Route mismatch\n\n---\nDestructive scope expansion blocks execution.",
      "backtick fenced block boundary" => "A route mismatch\n\`\`\`text\nDestructive scope expansion blocks execution.\n\`\`\`",
      "tilde fenced block boundary" => "A route mismatch\n~~~ruby\nDestructive scope expansion blocks execution.\n~~~",
      "HTML comment" => "<!-- A route mismatch blocks launch. -->",
      "multiline HTML comment" => "<!-- A route mismatch\nblocks launch. -->",
      "blockquote boundary" => "A route mismatch does not stop the lane.\n> Destructive scope expansion blocks execution.",
      "blockquote paragraph boundary" => "> Route mismatch\n>\n> Destructive scope expansion blocks execution.",
      "blockquote heading boundary" => "> Route mismatch\n> ### Scope gate\n> Destructive scope expansion blocks execution.",
      "blockquote list boundary" => "> Route mismatch\n> - Scope gate\n> Destructive scope expansion blocks execution.",
      "blockquote fenced boundary" => "> Route mismatch\n> ```text\n> Destructive scope expansion blocks execution.\n> ```",
      "blockquote thematic-break boundary" => "> Route mismatch\n> ***\n> Destructive scope expansion blocks execution.",
      "lazy blockquote continuation boundary" => "> A route mismatch occurs.\nThis remains quoted and advisory.",
      "Markdown list items" => "- route mismatch: record honestly\n- independent risk gate: blocks execution",
      "Markdown list-item pronoun boundary" => "- A route mismatch occurs.\n- It stops the lane before any edit begins.",
      "Markdown table-row pronoun boundary" => "| Route condition | A route mismatch occurs. |\n| --- | --- |\n| Gate result | It stops the lane before any edit begins. |",
      "ordered Markdown list items" => "1. route mismatch: record honestly\n2) independent risk gate: blocks execution"
    }.each do |boundary, boundary_text|
      assert_route_provenance_contract(
        self,
        "#{guide}\n\n#{boundary_text}\n",
        "#{MODEL_ROUTING_GUIDE_PATH} #{boundary} boundary"
      )
    end

    [
      "```text\n<!-- A route mismatch blocks launch. -->\n```",
      "The forbidden example is `<!-- A route mismatch blocks launch. -->`."
    ].each do |visible_comment|
      assert forbidden_route_only_contradiction?(visible_comment),
             "visible code comments must remain subject to route-only contradiction checks: #{visible_comment}"
    end

    [
      "<!-- A route mismatch blocks launch. -->",
      "<!-- A route mismatch\nblocks launch. -->"
    ].each do |hidden_comment|
      refute forbidden_route_only_contradiction?(hidden_comment),
             "actual HTML comments must remain ignored: #{hidden_comment}"
    end

    assert_raises(Minitest::Assertion, "a same-item route-only stop must remain forbidden") do
      assert_route_provenance_contract(
        self,
        "#{guide}\n\n- route mismatch: stops the lane before editing\n",
        "#{MODEL_ROUTING_GUIDE_PATH} Markdown list item"
      )
    end

    {
      "dot ordered list item" => "1. route mismatch: stops the lane before editing",
      "parenthesized ordered list item" => "1) route mismatch: stops the lane before editing"
    }.each do |marker, contradiction|
      assert_raises(Minitest::Assertion, "a same #{marker} must remain forbidden") do
        assert_route_provenance_contract(
          self,
          "#{guide}\n\n#{contradiction}\n",
          "#{MODEL_ROUTING_GUIDE_PATH} #{marker}"
        )
      end
    end

    {
      "wrapped prose before a table" => "A route mismatch\nblocks execution before editing.\n| Gate | advisory |\n| --- | --- |\n| status | recorded |",
      "wrapped prose after a table" => "| Gate | advisory |\n| --- | --- |\n| status | recorded |\nA route mismatch\nblocks execution before editing.",
      "wrapped prose before a table without outer pipes" => "A route mismatch\nblocks execution before editing.\nGate | advisory\n--- | ---\nstatus | recorded",
      "wrapped prose after a table without outer pipes" => "Gate | advisory\n--- | ---\nstatus | recorded\nA route mismatch\nblocks execution before editing.",
      "inline-pipe prose" => "A route mismatch uses requested | observed fields and\nblocks execution before editing.",
      "ATX heading followed by route-only contradiction" => "### Advisory routing\nA route mismatch blocks execution before editing.",
      "Setext heading followed by route-only contradiction" => "Advisory routing\n----------------\nA route mismatch blocks execution before editing.",
      "thematic break followed by route-only contradiction" => "Advisory routing\n***\nA route mismatch blocks execution before editing.",
      "fenced route-only contradiction" => "\`\`\`text\nA route mismatch blocks launch.\n\`\`\`",
      "quoted visible contradiction" => "> A route mismatch blocks launch.",
      "single quoted paragraph pronoun contradiction" => "> A route mismatch occurs.\n> This blocks launch.",
      "quoted paragraph followed by visible contradiction" => "> Route mismatch\n>\nA route mismatch blocks launch.",
      "visible contradiction beside HTML comment" => "<!-- route metadata remains advisory -->\nA route mismatch blocks launch.\n<!-- end advisory note -->",
      "visible prose around HTML comment" => "A route mismatch <!-- advisory metadata --> blocks launch."
    }.each do |position, contradiction|
      assert_raises(Minitest::Assertion, "a #{position} must remain forbidden") do
        assert_route_provenance_contract(
          self,
          "#{guide}\n\n#{contradiction}\n",
          "#{MODEL_ROUTING_GUIDE_PATH} #{position}"
        )
      end
    end
  end

  def test_duplicate_route_dispositions_fail_closed
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    mutant = duplicate_route_disposition(text, "silent-substitution", "proceed")

    refute_equal text, mutant, "duplicate disposition mutant did not change the guide text"
    error = assert_raises(RuntimeError, "duplicate route disposition row was accepted") do
      route_dispositions(mutant)
    end
    assert_includes error.message, "duplicate route disposition case ids: silent-substitution"
  end

  def test_routing_guide_marks_scenario_recommendations_unmeasured
    guide = normalized(read_repo_file(MODEL_ROUTING_GUIDE_PATH))

    [
      "No measured route recommendation is published yet",
      "priors chosen for fail-closed safety, not measurements",
      "do not compare a requested route that lacks an observed receipt against one that has one",
      "Route adherence is itself an outcome measure"
    ].each do |phrase|
      assert_includes guide, phrase, "model-routing guide is missing evidence-status rule: #{phrase}"
    end
  end

  def test_evidence_status_table_keeps_every_scenario_unmeasured
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    assert_evidence_status_table_unmeasured(self, text, MODEL_ROUTING_GUIDE_PATH)

    mutants = {
      "nonzero scenario samples" => mutate_evidence_status_row(text, "Adversarial review", samples: "1"),
      "known scenario evidence strength" => mutate_evidence_status_row(
        text,
        "Exact-head QA and replay",
        evidence_strength: "MEASURED"
      )
    }

    mutants.each do |mutation, mutant|
      refute_equal text, mutant, "#{mutation} mutant did not change the evidence-status table"
      assert_raises(Minitest::Assertion, "evidence-status table accepted #{mutation}") do
        assert_evidence_status_table_unmeasured(self, mutant, "#{MODEL_ROUTING_GUIDE_PATH} #{mutation} mutant")
      end
    end
  end

  def test_routine_coordinator_routing_and_measured_promotion_remain_constrained
    text = read_repo_file(MODEL_ROUTING_GUIDE_PATH)
    assert_constrained_routine_routing(self, text, MODEL_ROUTING_GUIDE_PATH)

    mutants = {
      "routine coordination defaults to strongest" => text.sub(
        "routine coordination use the `balanced`/high class",
        "routine coordination use Sol/xhigh by default"
      ),
      "routine multi-lane coordinator defaults to Sol/xhigh" => text.sub(
        "Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)",
        "Multi-lane coordinator: Sol/xhigh"
      ),
      "routine coordination defaults to strongest only in an HTML comment" =>
        text.sub(
          "routine coordination use the `balanced`/high class",
          "routine coordination use Sol/xhigh by default"
        ) + "\n<!-- #{ROUTINE_COORDINATOR_ROUTE_RULE} -->\n",
      "unverified Terra pair named as exact" => text.sub(
        "only when the active host has verified that pair",
        "whenever the coordinator requests it"
      ),
      "Sol/xhigh reservation broadened" => text.sub(
        "Reserve Sol/xhigh for a pinned high-risk trigger",
        "Use Sol/xhigh for ordinary coordination or a pinned high-risk trigger"
      ),
      "mechanical activity treated as a Sol/xhigh trigger" => text.sub(
        "mechanical work",
        "high-risk mechanical work"
      ),
      "user-selected Sol/xhigh override silently rewritten" => text.sub(
        "An explicitly user-selected Sol/xhigh override is honored and\nreported as an override, not silently rewritten",
        "An explicitly user-selected Sol/xhigh override is silently\nrewritten"
      ),
      "promotion decision made before all prerequisite receipts and runner" => text.sub(
        "#398 usage/cost\nreceipts, #333 execution-provenance receipts, and #335 evaluation runner exist",
        "#398 usage/cost receipts alone exist"
      )
    }

    mutants.each do |mutation, mutant|
      refute_equal text, mutant, "#{mutation} mutant did not change the guide text"
      assert_raises(Minitest::Assertion, "model-routing guide accepted #{mutation}") do
        assert_constrained_routine_routing(self, mutant, "#{MODEL_ROUTING_GUIDE_PATH} #{mutation} mutant")
      end
    end
  end

  def test_changelog_keeps_the_balanced_codex_routing_release_note
    changelog = read_repo_file("CHANGELOG.md")
    assert_codex_changelog_routing_note(self, changelog, "CHANGELOG.md")

    mutant = changelog.sub(
      CODEX_CHANGELOG_ROUTING_NOTE,
      "Adopt the recommended Codex GPT-5.6 routing profile: Sol/xhigh routine multi-lane coordination."
    )

    refute_equal changelog, mutant, "Codex routing release-note mutant did not change the changelog"
    assert_raises(Minitest::Assertion, "changelog accepted unconditional Sol/xhigh Codex multi-lane coordination") do
      assert_codex_changelog_routing_note(self, mutant, "CHANGELOG.md Codex routing release-note mutant")
    end
  end

  def test_docs_index_keeps_model_routing_guide
    skip "source-pack docs are not installed" unless ENV[SOURCE_CHECKOUT_ENV] == "1"

    assert_includes read_repo_file("docs/README.md"),
                    "[Cost-aware model routing](agent-workflows-model-routing.md)"
  end
end
