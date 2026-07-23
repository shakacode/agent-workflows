#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for the mandatory Batch Coordination Declaration.
#
# A batch used to be able to run to completion with zero coordination-backend
# writes while still producing a clean-looking final handoff. The declaration
# closes that hole: a handoff must say what it did about coordination, and
# silence is a hard blocker rather than an implicit success.

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PLAN_PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/plan-pr-batch/SKILL.md")
TRIAGE_SKILL_PATH = File.join(ROOT, "skills/triage/SKILL.md")
PR_MONITORING_SKILL_PATH = File.join(ROOT, "skills/pr-monitoring/SKILL.md")
PR_BATCH_DOCS_PATH = File.join(ROOT, "docs/pr-batch-skills.md")
COORDINATION_BACKEND_DOCS_PATH = File.join(ROOT, "docs/coordination-backend.md")
CHANGELOG_PATH = File.join(ROOT, "CHANGELOG.md")

# Every surface that generates, executes, or documents a final batch handoff has
# to carry the rule verbatim, so a reader of any one of them learns the contract.
REQUIRED_SURFACES = {
  "workflows/pr-processing.md" => WORKFLOW_PATH,
  "skills/pr-batch/SKILL.md" => PR_BATCH_SKILL_PATH,
  "skills/plan-pr-batch/SKILL.md" => PLAN_PR_BATCH_SKILL_PATH,
  "skills/triage/SKILL.md" => TRIAGE_SKILL_PATH,
  "skills/pr-monitoring/SKILL.md" => PR_MONITORING_SKILL_PATH,
  "docs/pr-batch-skills.md" => PR_BATCH_DOCS_PATH,
  "docs/coordination-backend.md" => COORDINATION_BACKEND_DOCS_PATH
}.freeze

EM_DASH = "—"

COORDINATION_DECLARATION_RULE = "Batch Coordination Declaration: every final batch handoff must carry exactly " \
                                "one `coordination:` line, and no handoff is complete or clean without it. Use " \
                                "`coordination: registered <batch-id>` only when this batch actually registered " \
                                "with the coordination backend, and quote the exact backend batch id. Otherwise " \
                                "use `coordination: unavailable #{EM_DASH} <reason>` with an exact nonempty " \
                                "reason, such as a repo seam that sets `coordination_backend: n/a`, an " \
                                "unreachable or degraded backend, or a deliberately uncoordinated " \
                                "single-operator run. A missing `coordination:` line, an empty or `UNKNOWN` " \
                                "batch id, an empty or `UNKNOWN` reason, or both forms at once is a hard " \
                                "blocker: report NOT COMPLETE instead of a clean handoff. Silence is not an " \
                                "accepted value; a batch " \
                                "that wrote nothing to the coordination backend must say so in the declaration.".freeze

MISSING_DECLARATION_BLOCKER = "final handoff is missing the mandatory `coordination:` declaration; " \
                              "declare `coordination: registered <batch-id>` or " \
                              "`coordination: unavailable #{EM_DASH} <reason>`".freeze

# Accepts an optional list marker so a declaration reads naturally inside a
# bulleted Lane Card or handoff section.
DECLARATION_LINE = /^[[:space:]]*(?:[-*+][[:space:]]+)?coordination:[[:space:]]*(.*?)[[:space:]]*$/

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def normalize_prose(text)
  text.gsub(/\s+/, " ")
end

def unknown_sentinel?(value)
  value.strip.casecmp("UNKNOWN").zero?
end

# The gate itself. Returns the list of blockers for a candidate final handoff;
# an empty list means the handoff declared its coordination state acceptably.
def coordination_declaration_blockers(handoff_text)
  values = handoff_text.to_s.lines.filter_map { |line| line[DECLARATION_LINE, 1] }

  return [MISSING_DECLARATION_BLOCKER] if values.empty?

  if values.length > 1
    return ["final handoff declares `coordination:` #{values.length} times; exactly one declaration is allowed"]
  end

  declared_value_blockers(values.first)
end

def declared_value_blockers(value)
  # Require whitespace (or end of value) after the keyword. `\b` is a zero-width
  # boundary, so `registered-aw-1` would otherwise parse as a valid declaration.
  case value
  when /\Aregistered(?:[[:space:]]+(.*))?\z/m
    registered_blockers(Regexp.last_match(1).to_s.strip)
  when /\Aunavailable(?:[[:space:]]+(.*))?\z/m
    unavailable_blockers(Regexp.last_match(1).to_s)
  else
    ["unrecognized `coordination:` declaration #{value.inspect}; " \
     "use `registered <batch-id>` or `unavailable #{EM_DASH} <reason>`"]
  end
end

def registered_blockers(batch_id)
  return ["`coordination: registered` is missing its exact backend batch id"] if batch_id.empty?

  if unknown_sentinel?(batch_id)
    return ["`coordination: registered` batch id is `UNKNOWN`; an unregistered batch must " \
            "declare `unavailable #{EM_DASH} <reason>`"]
  end

  []
end

def unavailable_blockers(remainder)
  unless remainder.lstrip.start_with?(EM_DASH)
    return ["`coordination: unavailable` must separate its reason with an em dash (#{EM_DASH})"]
  end

  reason = remainder.lstrip.delete_prefix(EM_DASH).strip
  return ["`coordination: unavailable` is missing its exact nonempty reason"] if reason.empty?

  if unknown_sentinel?(reason)
    return ["`coordination: unavailable` reason is `UNKNOWN`; the declaration must state the exact " \
            "reason coordination did not happen"]
  end

  []
end

class CoordinationDeclarationContractTest < Minitest::Test
  # --- Gate behavior: the declared forms the contract accepts -----------------

  def test_registered_declaration_is_accepted
    handoff = <<~HANDOFF
      Final handoff
      coordination: registered aw-20260723-1124-koa
      final state: merged
    HANDOFF

    assert_empty coordination_declaration_blockers(handoff),
                 "a batch that registered with the backend must pass the declaration gate"
  end

  def test_unavailable_declaration_is_accepted
    handoff = <<~HANDOFF
      Final handoff
      coordination: unavailable #{EM_DASH} repo seam declares coordination_backend: "n/a" (single-operator mode)
      final state: merged
    HANDOFF

    assert_empty coordination_declaration_blockers(handoff),
                 "a deliberately uncoordinated run must stay possible when it says so"
  end

  def test_declaration_is_accepted_inside_a_bulleted_handoff
    handoff = "- coordination: registered aw-20260723-1124-koa\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "a Lane Card bullet is a valid place to declare coordination"
  end

  # --- The actual bug: silence must fail loudly ------------------------------

  def test_absent_declaration_fails_loudly
    handoff = <<~HANDOFF
      Final handoff
      final state: merged
      merge SHA: 1234567
      All gates passed and every target is closed out.
    HANDOFF

    blockers = coordination_declaration_blockers(handoff)

    refute_empty blockers, "a handoff with zero coordination writes must not look clean"
    assert_equal [MISSING_DECLARATION_BLOCKER], blockers
    assert_includes blockers.first, "missing the mandatory `coordination:` declaration"
  end

  def test_an_otherwise_perfect_handoff_is_still_blocked_without_the_declaration
    coordinated = "coordination: registered aw-20260723-1124-koa\nfinal state: merged\n"
    uncoordinated = coordinated.lines.reject { |line| line.start_with?("coordination:") }.join

    assert_empty coordination_declaration_blockers(coordinated)
    refute_empty coordination_declaration_blockers(uncoordinated),
                 "a coordinated and an uncoordinated batch must not produce identical-looking handoffs"
  end

  # --- Degenerate declarations are blockers, not loopholes --------------------

  def test_registered_without_a_batch_id_fails
    blockers = coordination_declaration_blockers("coordination: registered\n")

    assert_equal ["`coordination: registered` is missing its exact backend batch id"], blockers
  end

  def test_registered_with_an_unknown_batch_id_fails
    blockers = coordination_declaration_blockers("coordination: registered UNKNOWN\n")

    refute_empty blockers
    assert_includes blockers.first, "batch id is `UNKNOWN`"
  end

  def test_unavailable_without_a_reason_fails
    blockers = coordination_declaration_blockers("coordination: unavailable #{EM_DASH}\n")

    assert_equal ["`coordination: unavailable` is missing its exact nonempty reason"], blockers
  end

  def test_unavailable_with_an_unknown_reason_fails
    blockers = coordination_declaration_blockers("coordination: unavailable #{EM_DASH} UNKNOWN\n")

    refute_empty blockers, "`UNKNOWN` is the silence the declaration exists to remove, not a reason"
    assert_includes blockers.first, "reason is `UNKNOWN`"
  end

  def test_unavailable_with_the_em_dash_and_an_unknown_variant_reason_fails
    blockers = coordination_declaration_blockers("coordination: unavailable #{EM_DASH}   unknown  \n")

    refute_empty blockers, "the `UNKNOWN` sentinel check is case- and whitespace-insensitive"
  end

  def test_unavailable_without_the_em_dash_fails
    blockers = coordination_declaration_blockers("coordination: unavailable - backend down\n")

    refute_empty blockers
    assert_includes blockers.first, "em dash"
  end

  def test_keyword_must_be_followed_by_whitespace_not_a_word_boundary
    {
      "coordination: registered-aw-1\n" => "registered",
      "coordination: unavailable-backend down\n" => "unavailable"
    }.each do |handoff, keyword|
      blockers = coordination_declaration_blockers(handoff)

      refute_empty blockers, "#{keyword} glued to its value must not parse as a valid declaration"
      assert_includes blockers.first, "unrecognized",
                      "#{keyword} glued to its value must fall through to the unrecognized branch"
    end
  end

  def test_unrecognized_declaration_form_fails
    blockers = coordination_declaration_blockers("coordination: fine\n")

    refute_empty blockers
    assert_includes blockers.first, "unrecognized"
  end

  def test_duplicate_declarations_fail
    handoff = "coordination: registered aw-1\ncoordination: unavailable #{EM_DASH} backend down\n"
    blockers = coordination_declaration_blockers(handoff)

    refute_empty blockers
    assert_includes blockers.first, "exactly one declaration is allowed"
  end

  # --- The rule text is present, and its removal is detected -----------------

  def test_every_required_surface_carries_the_canonical_rule
    normalized_rule = normalize_prose(COORDINATION_DECLARATION_RULE)
    missing = REQUIRED_SURFACES.reject do |_label, path|
      normalize_prose(read_repo_file(path)).include?(normalized_rule)
    end

    assert_empty missing.keys, "surfaces missing the Batch Coordination Declaration rule"
  end

  def test_removing_the_rule_from_a_surface_is_detected
    normalized_rule = normalize_prose(COORDINATION_DECLARATION_RULE)
    workflow = normalize_prose(read_repo_file(WORKFLOW_PATH))

    assert_includes workflow, normalized_rule
    refute_includes workflow.sub(normalized_rule, ""), normalized_rule,
                    "the rule must appear once per surface so deleting it is detectable"
  end

  def test_canonical_rule_lives_in_the_batch_handoff_format_section
    workflow = read_repo_file(WORKFLOW_PATH)
    start_index = workflow.index("### Batch Handoff Format")
    refute_nil start_index, "workflows/pr-processing.md must keep the canonical Batch Handoff Format section"

    end_match = workflow.match(/^###\s+/, start_index + 1)
    section = workflow[start_index...(end_match ? end_match.begin(0) : workflow.length)]

    assert_includes normalize_prose(section), normalize_prose(COORDINATION_DECLARATION_RULE),
                    "the declaration belongs in the canonical handoff contract the goal prompt routes to"
  end

  # The continuation prompt is a supported entry point that emits its own final
  # handoff, so it has to demand the declaration too or it reopens the bug.
  def test_continuation_prompt_requires_the_declaration
    workflow = read_repo_file(WORKFLOW_PATH)
    start_index = workflow.index("### Generic PR-Batch Continuation Prompt")
    refute_nil start_index, "workflows/pr-processing.md must keep the continuation prompt section"

    end_match = workflow.match(/^###\s+/, start_index + 1)
    section = normalize_prose(workflow[start_index...(end_match ? end_match.begin(0) : workflow.length)])

    assert_includes section, "coordination: registered <batch-id>",
                    "the continuation prompt must require the registered form"
    assert_includes section, "coordination: unavailable #{EM_DASH} <reason>",
                    "the continuation prompt must require the unavailable form"
    assert_includes section, "A missing declaration is a hard blocker, not a clean handoff.",
                    "the continuation prompt must make an absent declaration a blocker"
  end

  def test_rule_states_both_declared_forms_verbatim
    assert_includes COORDINATION_DECLARATION_RULE, "`coordination: registered <batch-id>`"
    assert_includes COORDINATION_DECLARATION_RULE, "`coordination: unavailable #{EM_DASH} <reason>`"
  end

  def test_rule_text_round_trips_as_utf8_on_every_surface
    REQUIRED_SURFACES.each do |label, path|
      text = read_repo_file(path)

      assert_equal Encoding::UTF_8, text.encoding, "#{label} must be read as UTF-8"
      assert text.valid_encoding?, "#{label} must contain valid UTF-8"
      assert_includes text, "unavailable #{EM_DASH} <reason>", "#{label} must keep the em-dash form intact"
    end
  end

  def test_changelog_announces_the_mandatory_declaration
    assert_includes normalize_prose(read_repo_file(CHANGELOG_PATH)),
                    "every final batch handoff must declare its coordination state",
                    "CHANGELOG.md must announce the mandatory coordination declaration"
  end
end
