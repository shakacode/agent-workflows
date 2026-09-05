#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for the mandatory Batch Coordination Declaration.
#
# A batch used to be able to run to completion with zero coordination-backend
# writes while still producing a clean-looking final handoff. The declaration
# closes that hole: a handoff must say what it did about coordination, and
# silence is a hard blocker rather than an implicit success.
#
# The gate logic lives in the shipped `coordination-declaration` helper that the
# coordinator closeout lane runs, not here; this file loads it so the runtime
# gate and the documented contract cannot drift apart.

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"

COORDINATION_DECLARATION_HELPER = File.expand_path("coordination-declaration", __dir__)
unless File.file?(COORDINATION_DECLARATION_HELPER)
  abort(
    "BLOCKED: the coordination declaration gate requires its sibling pr-batch runtime " \
      "helper from the same Agent Workflows pack revision; " \
      "missing companion: #{COORDINATION_DECLARATION_HELPER}"
  )
end
load COORDINATION_DECLARATION_HELPER

ROOT = File.expand_path("../../..", __dir__)

WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
INTEGRATION_CLOSEOUT_PATH = File.join(ROOT, "workflows/pr-batch-integration-closeout.md")
PLAN_PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/plan-pr-batch/SKILL.md")
TRIAGE_SKILL_PATH = File.join(ROOT, "skills/triage/SKILL.md")
PR_MONITORING_SKILL_PATH = File.join(ROOT, "skills/pr-monitoring/SKILL.md")
PR_BATCH_DOCS_PATH = File.join(ROOT, "docs/pr-batch-skills.md")
COORDINATION_BACKEND_DOCS_PATH = File.join(ROOT, "docs/coordination-backend.md")
CHANGELOG_PATH = File.join(ROOT, "CHANGELOG.md")

# Every surface that generates, executes, or documents a final batch handoff has
# to carry the rule verbatim, so a reader of any one of them learns the contract.
REQUIRED_SURFACES = {
  "workflows/pr-batch-integration-closeout.md" => INTEGRATION_CLOSEOUT_PATH,
  "skills/plan-pr-batch/SKILL.md" => PLAN_PR_BATCH_SKILL_PATH,
  "skills/triage/SKILL.md" => TRIAGE_SKILL_PATH,
  "skills/pr-monitoring/SKILL.md" => PR_MONITORING_SKILL_PATH,
  "docs/pr-batch-skills.md" => PR_BATCH_DOCS_PATH,
  "docs/coordination-backend.md" => COORDINATION_BACKEND_DOCS_PATH
}.freeze

EM_DASH = CoordinationDeclaration::EM_DASH

COORDINATION_DECLARATION_RULE = "Batch Coordination Declaration: every `coordination_required` final batch " \
                                "handoff must carry exactly one `coordination:` line, and no such handoff is " \
                                "complete or clean without it. Use " \
                                "`coordination: registered <batch-id>` only when this batch actually registered " \
                                "with the coordination backend, and quote the exact backend batch id. Otherwise " \
                                "use `coordination: unavailable #{EM_DASH} <reason>` with an exact nonempty " \
                                "reason for a run that was `coordination_required` and could not keep durable " \
                                "coordination, such as an unreachable or degraded backend or a refused " \
                                "registration. A trusted `coordination_backend: n/a` under " \
                                "`coordination_required` is a pre-launch stop, not an unavailable declaration, " \
                                "and a deliberately uncoordinated single-controller run is " \
                                "`coordination_not_applicable` and carries no declaration at all. " \
                                "A missing `coordination:` line, an empty or `UNKNOWN` " \
                                "batch id, an empty or `UNKNOWN` reason, or both forms at once is a hard " \
                                "blocker: report NOT COMPLETE instead of a clean handoff. Silence is not an " \
                                "accepted value; a batch " \
                                "that wrote nothing to the coordination backend must say so in the declaration.".freeze
COORDINATION_APPLICABILITY_DECLARATION_RULE =
  "That declaration rule applies only to `coordination_required`. For `coordination_not_applicable`, " \
  "omit the `coordination:` line and do not invoke the declaration helper."

MISSING_DECLARATION_BLOCKER = CoordinationDeclaration::MISSING_DECLARATION_BLOCKER

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def normalize_prose(text)
  text.gsub(/\s+/, " ")
end

def with_default_external_encoding(encoding)
  original = Encoding.default_external
  Encoding.default_external = encoding
  yield
ensure
  Encoding.default_external = original
end

# Anchored to a whole heading line so a heading quoted in prose or a sync comment
# cannot capture the section.
def extract_anchored_section(text, heading, end_heading:)
  match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading} section" unless match

  tail = text[match.end(0)..]
  stop = tail.match(end_heading)
  stop ? tail[0...stop.begin(0)] : tail
end

# Delegate to the shipped helper so every gate assertion below tests the script
# the coordinator closeout lane actually runs.
def coordination_declaration_blockers(handoff_text)
  CoordinationDeclaration.blockers(handoff_text)
end

def batch_handoff_format_section(workflow)
  extract_anchored_section(
    workflow,
    "### Batch Handoff Format",
    end_heading: /^###[[:blank:]]+/
  )
end

def handoff_prompt_section(workflow, heading)
  extract_anchored_section(workflow, heading, end_heading: /^###[[:blank:]]+/)
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

  def test_unordered_bullet_declaration_accepts_visible_marker_padding
    %w[- + *].product((1..4).to_a).each do |marker, spacing|
      handoff = "#{marker}#{' ' * spacing}coordination: registered aw-#{marker.ord}-#{spacing}\n"

      assert_empty coordination_declaration_blockers(handoff),
                   "#{marker.inspect} with #{spacing} marker-padding spaces must remain visible"
    end

    %w[- + *].each do |marker|
      handoff = "#{marker}\tcoordination: registered aw-#{marker.ord}-tab\n"

      assert_empty coordination_declaration_blockers(handoff),
                   "one immediate tab expands to visible marker padding under CommonMark"
    end
  end

  def test_top_level_unordered_bullet_rejects_code_padding_and_tabs_after_marker
    handoffs = %w[- + *].flat_map do |marker|
      [
        "#{marker}     coordination: registered aw-#{marker.ord}-five-space-code\n",
        "#{marker}\t\tcoordination: registered aw-#{marker.ord}-two-tab-code\n",
        "#{marker}    \tcoordination: registered aw-#{marker.ord}-space-tab-code\n"
      ]
    end

    assert_equal Array.new(handoffs.length, [MISSING_DECLARATION_BLOCKER]),
                 handoffs.map { |handoff| coordination_declaration_blockers(handoff) },
                 "marker padding that reaches the code threshold must not satisfy the declaration gate"
  end

  def test_nested_unordered_bullet_rejects_code_padding_and_tabs_after_marker
    handoffs = %w[- + *].flat_map do |marker|
      [
        "- Outer:\n  #{marker}     coordination: registered aw-nested-#{marker.ord}-five-space-code\n",
        "- Outer:\n  #{marker}\t\tcoordination: registered aw-nested-#{marker.ord}-two-tab-code\n",
        "- Outer:\n  #{marker}    \tcoordination: registered aw-nested-#{marker.ord}-space-tab-code\n"
      ]
    end

    assert_equal Array.new(handoffs.length, [MISSING_DECLARATION_BLOCKER]),
                 handoffs.map { |handoff| coordination_declaration_blockers(handoff) },
                 "nested marker padding that reaches the code threshold must not satisfy the declaration gate"
  end

  def test_mixed_marker_padding_over_four_rendered_columns_is_rejected
    rejected_by_leading_indent = {
      0 => ["   \t", "    \t", "\t  ", "\t\t", "     "],
      1 => ["  \t", "\t   ", "\t\t", "     "],
      2 => [" \t", "\t    ", "\t\t", "     "],
      3 => ["   \t ", "    \t", "\t ", "\t\t", "     "]
    }

    rejected_by_leading_indent.each do |leading_indent, paddings|
      paddings.each do |padding|
        handoff = "#{' ' * leading_indent}-#{padding}coordination: registered aw-code-padding\n"

        assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                     "padding #{padding.inspect} after #{leading_indent} leading spaces renders wider than four columns"
      end
    end
  end

  def test_nested_mixed_marker_padding_over_four_rendered_columns_is_rejected
    rejected_by_leading_indent = {
      0 => [" \t", "\t    ", "\t\t", "     "],
      1 => ["\t ", "   \t ", "    \t", "\t\t", "     "],
      2 => ["   \t", "    \t", "\t  ", "\t\t", "     "],
      3 => ["  \t", "\t   ", "\t\t", "     "]
    }

    rejected_by_leading_indent.each do |leading_indent, paddings|
      paddings.each do |padding|
        item_indent = " " * (2 + leading_indent)
        handoff = "- Outer:\n#{item_indent}-#{padding}coordination: registered aw-nested-code-padding\n"

        assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                     "nested padding #{padding.inspect} after #{leading_indent} relative spaces renders as code"
      end
    end
  end

  def test_mixed_marker_padding_up_to_four_rendered_columns_is_visible
    visible_by_leading_indent = {
      0 => [" \t", "  \t", "\t "],
      1 => [" \t  ", "\t  "],
      2 => ["\t   "],
      3 => [" \t", "   \t"]
    }

    visible_by_leading_indent.each do |leading_indent, paddings|
      paddings.each do |padding|
        handoff = "#{' ' * leading_indent}-#{padding}coordination: registered aw-visible-padding\n"

        assert_empty coordination_declaration_blockers(handoff),
                     "padding #{padding.inspect} after #{leading_indent} leading spaces renders within four columns"
      end
    end
  end

  def test_nested_mixed_marker_padding_up_to_four_rendered_columns_is_visible
    visible_by_leading_indent = {
      0 => ["\t ", "\t  ", "\t   "],
      1 => [" \t", "  \t", "   \t"],
      2 => [" \t", "  \t", "\t "],
      3 => [" \t  ", "\t  "]
    }

    visible_by_leading_indent.each do |leading_indent, paddings|
      paddings.each do |padding|
        item_indent = " " * (2 + leading_indent)
        handoff = "- Outer:\n#{item_indent}-#{padding}coordination: registered aw-nested-visible-padding\n"

        assert_empty coordination_declaration_blockers(handoff),
                     "nested padding #{padding.inspect} after #{leading_indent} relative spaces remains visible"
      end
    end
  end

  def test_deep_nested_mixed_tab_padding_uses_original_marker_column
    handoff = "- Outer:\n    - \tcoordination: registered aw-deep-mixed-tab\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "tab expansion must start from the marker's original column inside the outer list"
  end

  def test_deep_nested_code_padding_uses_original_marker_column
    handoff = "- Outer:\n    -\t  coordination: registered fake-deep-code-padding\n"

    assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                 "padding wider than four columns at the original nested marker column is code"
  end

  def test_mixed_padding_nested_item_continuation_at_plus_four_is_code
    handoff = "- Outer:\n    - \tInner:\n" \
              "            coordination: registered fake-inner-code\n"

    assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                 "four spaces beyond the rendered nested content column is indented code"
  end

  def test_mixed_padding_nested_item_continuation_at_plus_three_is_visible
    handoff = "- Outer:\n    - \tInner:\n" \
              "           coordination: registered aw-inner-visible-boundary\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "up to three spaces beyond the rendered nested content column remains visible"
  end

  def test_declaration_is_accepted_in_a_nested_lane_card_list
    [
      "- Lane Card:\n    - coordination: registered aw-nested-unordered-lane\n",
      "1. Lane Card:\n   - coordination: unavailable #{EM_DASH} backend not configured\n"
    ].each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "a nested Lane Card bullet must not be mistaken for standalone indented code"
    end
  end

  def test_declaration_is_accepted_as_ordinary_list_content
    [
      "- Lane Card:\n    coordination: registered aw-unordered-content\n",
      "1. Lane Card:\n    coordination: registered aw-ordered-content\n"
    ].each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "ordinary visible list content must not be mistaken for standalone indented code"
    end
  end

  def test_declaration_is_accepted_as_genuine_inner_list_content
    [
      "- Outer:\n    - Inner:\n      coordination: registered aw-inner-unordered-content\n",
      "1. Outer:\n   1. Inner:\n      coordination: registered aw-inner-ordered-content\n"
    ].each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "continuation content at the active inner list column must remain visible"
    end
  end

  def test_list_content_indentation_boundary_is_context_relative
    visible = [
      "- Lane Card:\n     coordination: registered aw-unordered-visible-boundary\n",
      "1. Lane Card:\n      coordination: registered aw-ordered-visible-boundary\n"
    ]
    code = [
      "- Lane Card:\n      coordination: registered example-unordered-code-boundary\n",
      "1. Lane Card:\n       coordination: registered example-ordered-code-boundary\n",
      "- Lane Card:\n# Outside list\n    coordination: registered example-after-list-reset\n"
    ]

    visible.each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "up to three spaces relative to list content remains visible Markdown"
    end
    code.each do |handoff|
      assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                   "four relative spaces or reset list state must remain indented code"
    end
  end

  def test_unordered_dedent_to_outer_list_content_discards_inner_list_ancestry
    handoff = "- Outer:\n    - Inner\n\n  Outer continuation\n\n" \
              "      coordination: registered aw-hidden-code\n"

    assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                 "a code block relative to outer list content must not match a stale inner content column"
  end

  def test_ordered_dedent_to_outer_list_content_discards_inner_list_ancestry
    handoff = "1. Outer:\n   1. Inner\n\n   Outer continuation\n\n" \
              "       coordination: registered aw-hidden-ordered-code\n"

    assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                 "an ordered-list code block must not match a stale inner content column"
  end

  def test_declarations_inside_markdown_code_are_ignored
    [
      "```text\ncoordination: registered example-backtick\n```\n",
      "````markdown\ncoordination: registered example-long-backtick\n````\n",
      "~~~text\ncoordination: unavailable #{EM_DASH} example tilde fence\n~~~\n",
      "- ```text\n  coordination: registered example-unordered-list-fence\n  ```\n",
      "1. ~~~~text\n   coordination: registered example-ordered-list-fence\n   ~~~~\n",
      "- Examples:\n    - ```text\n      - coordination: registered example-nested-list-fence\n      ```\n",
      "1. Examples:\n      1. ~~~~text\n         - coordination: registered example-nested-ordered-list-fence\n         ~~~~\n",
      "    coordination: registered example-indented\n",
      "    - coordination: registered example-indented-list-item\n"
    ].each do |handoff|
      assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                   "a declaration shown as Markdown code must not satisfy the runtime gate: #{handoff.inspect}"
    end
  end

  def test_tab_indented_list_fence_hides_its_declaration
    handoff = "- Outer:\n\t```text\n  coordination: registered hidden\n\t```\n"

    assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                 "a tab-indented fence inside list content must hide its example declaration"
  end

  def test_tab_indented_list_fence_closes_before_a_real_declaration
    handoff = "-\t```text\n\tcoordination: registered hidden\n\t```\n" \
              "coordination: registered aw-real\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "a tab-indented closing fence must not hide the later real declaration"
  end

  def test_mixed_space_tab_indentation_controls_list_fence_transitions
    hidden_examples = [
      "- Outer:\n \t```text\n  coordination: registered hidden-mixed-backtick\n \t```\n",
      "- Outer:\n  \t~~~text\n  coordination: registered hidden-mixed-tilde\n  \t~~~\n"
    ]
    closed_examples = [
      "- \t```text\n\tcoordination: registered hidden-marker-padding\n \t```\n" \
        "coordination: registered aw-real-after-mixed-backtick\n",
      "+\t~~~text\n\tcoordination: registered hidden-marker-tab\n  \t~~~\n" \
        "coordination: registered aw-real-after-mixed-tilde\n"
    ]

    hidden_examples.each do |handoff|
      assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                   "mixed leading indentation must open and close the list fence at rendered columns"
    end
    closed_examples.each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "mixed leading indentation must close the fence before the later real declaration"
    end
  end

  def test_dedent_closes_an_unclosed_list_fence_before_a_real_declaration
    handoff = "- ```text\n  coordination: registered hidden\n" \
              "coordination: registered aw-real\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "dedenting out of list content must end its fence before the real declaration"
  end

  def test_list_fence_dedent_uses_each_container_indent
    handoffs = [
      "1. ~~~text\n   coordination: registered hidden-ordered\n" \
        "coordination: registered aw-real-ordered\n",
      "- Outer:\n    - ```text\n      coordination: registered hidden-nested\n" \
        "  coordination: registered aw-real-outer-content\n",
      "- Outer:\n\t~~~text\n  coordination: registered hidden-tab\n" \
        "coordination: registered aw-real-after-tab-fence\n"
    ]

    handoffs.each do |handoff|
      assert_empty coordination_declaration_blockers(handoff),
                   "ordered, nested, tilde, and tab-indented list fences must end at their container dedent"
    end
  end

  def test_over_indented_closer_stays_fenced_until_the_container_dedent
    handoff = "- ```text\n  coordination: registered hidden-before\n" \
              "      ```\n  coordination: registered hidden-after\n" \
              "coordination: registered aw-real-after-over-indented-closer\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "an over-indented closer remains code, while the later container dedent exposes the real declaration"
  end

  def test_blank_lines_and_top_level_fences_do_not_implicitly_dedent
    handoffs = [
      "- ```text\n\n  coordination: registered hidden-after-blank\n",
      "```text\ncoordination: registered hidden-in-top-level-fence\n"
    ]

    handoffs.each do |handoff|
      assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                   "blank lines preserve list fences, and top-level unclosed fences remain fail-closed"
    end
  end

  def test_tilde_fence_info_may_contain_tildes
    [
      "~~~ruby~bad\ncoordination: registered example-top-level-tilde-info\n~~~\n",
      "- ~~~ruby~bad\n  coordination: registered example-list-tilde-info\n  ~~~\n"
    ].each do |handoff|
      assert_equal [MISSING_DECLARATION_BLOCKER], coordination_declaration_blockers(handoff),
                   "tildes in tilde-fence info do not invalidate the fenced code block"
    end
  end

  def test_backtick_in_top_level_backtick_fence_info_does_not_hide_declaration
    handoff = "```ruby`bad\ncoordination: registered aw-real-after-invalid-opener\n```\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "a backtick in backtick-fence info invalidates the opener under CommonMark"
  end

  def test_backtick_in_list_backtick_fence_info_does_not_hide_declaration
    handoff = "- ```ruby`bad\n  coordination: registered aw-real-after-invalid-list-opener\n  ```\n"

    assert_empty coordination_declaration_blockers(handoff),
                 "an invalid backtick-fence opener in a list must not hide visible continuation content"
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

  def test_bare_unavailable_reports_a_missing_reason_not_a_separator_problem
    blockers = coordination_declaration_blockers("coordination: unavailable\n")

    refute_empty blockers, "a bare `unavailable` declares nothing and must be blocked"
    assert_equal ["`coordination: unavailable` is missing its exact nonempty reason"], blockers
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
    with_default_external_encoding(Encoding::US_ASCII) do
      declaration = "fíne"
      blockers = coordination_declaration_blockers("coordination: #{declaration}\n")

      refute_empty blockers
      assert_includes blockers.first, "unrecognized"
      assert_includes blockers.first, declaration
    end
  end

  def test_near_miss_declarations_are_rejected_with_an_exact_correction
    with_default_external_encoding(Encoding::US_ASCII) do
      [
        "`coordination: registered aw-1`",
        "**coordination:** registered aw-1",
        "Coordination: registered aw-1",
        "coordination - registered aw-1",
        "coordination – registered aw-1"
      ].each do |near_miss|
        blockers = coordination_declaration_blockers("#{near_miss}\n")

        refute_empty blockers, "#{near_miss.inspect} must remain rejected"
        assert_includes blockers.first, "near-miss"
        assert_includes blockers.first, near_miss
        assert_includes blockers.first, "coordination: registered <batch-id>"
        assert_includes blockers.first, "coordination: unavailable #{EM_DASH} <reason>"
      end
    end
  end

  def test_both_forms_on_one_line_fail
    with_default_external_encoding(Encoding::US_ASCII) do
      batch_id = "aw-1 unavailable #{EM_DASH} backend flaky"
      blockers = coordination_declaration_blockers("coordination: registered #{batch_id}\n")

      refute_empty blockers, "one line carrying both forms must not pass as a clean declaration"
      assert_includes blockers.first, "single token"
      assert_includes blockers.first, batch_id
      assert_includes blockers.first, "never both on one line"
    end
  end

  def test_registered_batch_id_rejects_trailing_prose
    blockers = coordination_declaration_blockers("coordination: registered aw-1 (probably)\n")

    refute_empty blockers, "a batch id must stay an opaque single token"
    assert_includes blockers.first, "single token"
    assert_includes blockers.first, "drop the trailing text after the batch id"
    refute_includes blockers.first, "never both on one line",
                    "trailing prose is not a two-forms problem and must not be described as one"
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

  def test_every_required_surface_scopes_declaration_and_helper_to_required_coordination
    normalized_rule = normalize_prose(COORDINATION_APPLICABILITY_DECLARATION_RULE)
    missing = REQUIRED_SURFACES.reject do |_label, path|
      normalize_prose(read_repo_file(path)).include?(normalized_rule)
    end

    assert_empty missing.keys, "surfaces missing the coordination-applicability declaration rule"
  end

  def test_no_surface_offers_a_not_applicable_reason_for_an_unavailable_declaration
    stale = [
      "a repo seam that sets `coordination_backend: n/a`",
      "a deliberately uncoordinated single-operator run"
    ]
    offending = REQUIRED_SURFACES.select do |_label, path|
      text = normalize_prose(read_repo_file(path))
      stale.any? { |reason| text.include?(reason) }
    end

    assert_empty offending.keys,
                 "an unavailable declaration must never be offered for work that is not `coordination_required`"
  end

  def test_mechanical_declaration_validation_is_scoped_to_required_coordination
    closeout = normalize_prose(read_repo_file(INTEGRATION_CLOSEOUT_PATH))

    assert_includes closeout,
                    "Before emitting that final message, for `coordination_required`, validate its Batch " \
                    "Coordination Declaration mechanically rather than by self-report"
    assert_includes closeout,
                    "For `coordination_not_applicable`, skip that helper: the handoff carries no " \
                    "`coordination:` line for it to accept, so running it would force a false NOT COMPLETE."
  end

  def test_removing_the_rule_from_a_surface_is_detected
    normalized_rule = normalize_prose(COORDINATION_DECLARATION_RULE)
    workflow = normalize_prose(read_repo_file(INTEGRATION_CLOSEOUT_PATH))

    assert_includes workflow, normalized_rule
    refute_includes workflow.sub(normalized_rule, ""), normalized_rule,
                    "the rule must appear once per surface so deleting it is detectable"
  end

  def test_canonical_rule_lives_in_the_batch_handoff_format_section
    workflow = read_repo_file(INTEGRATION_CLOSEOUT_PATH)
    section = batch_handoff_format_section(workflow)

    assert_includes normalize_prose(section), normalize_prose(COORDINATION_DECLARATION_RULE),
                    "the declaration belongs in the canonical handoff contract the goal prompt routes to"
  end

  def test_legacy_entrypoints_route_to_the_canonical_handoff_contract
    assert_includes read_repo_file(WORKFLOW_PATH),
                    "[Batch Handoff Format](pr-batch-integration-closeout.md#batch-handoff-format)"
    assert_includes read_repo_file(PR_BATCH_SKILL_PATH),
                    "[Batch Handoff Format](../../workflows/pr-batch-integration-closeout.md#batch-handoff-format)"
  end

  def test_batch_handoff_extractor_ignores_a_quoted_heading
    workflow = <<~MARKDOWN
      <!-- Keep `### Batch Handoff Format` synchronized. -->
      decoy body

      ### Batch Handoff Format

      real body

      ### Next
    MARKDOWN

    section = batch_handoff_format_section(workflow)

    assert_includes section, "real body"
    refute_includes section, "decoy body"
  end

  # Every prompt that tells a coordinator what its own final handoff must contain
  # is a supported path to a handoff, so each one has to demand the declaration
  # or it reopens the bug for anyone launched through it.
  def test_handoff_emitting_prompts_require_the_declaration
    workflow = read_repo_file(WORKFLOW_PATH)

    [
      "### Generic PR-Batch Continuation Prompt",
      "### Model-Routing Recovery Prompt"
    ].each do |heading|
      section = normalize_prose(handoff_prompt_section(workflow, heading))

      assert_includes section, "coordination: registered <batch-id>",
                      "#{heading} must require the registered form"
      assert_includes section, "coordination: unavailable #{EM_DASH} <reason>",
                      "#{heading} must require the unavailable form"
      assert_includes section, "A missing declaration is a hard blocker, not a clean handoff.",
                      "#{heading} must make an absent declaration a blocker"
    end
  end

  def test_handoff_prompt_extractor_ignores_a_quoted_heading
    heading = "### Generic PR-Batch Continuation Prompt"
    workflow = <<~MARKDOWN
      <!-- See `#{heading}` for the canonical prompt. -->
      decoy prompt

      #{heading}

      real prompt

      ### Next
    MARKDOWN

    section = handoff_prompt_section(workflow, heading)

    assert_includes section, "real prompt"
    refute_includes section, "decoy prompt"
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

  # --- The shipped runtime helper, not just the gate logic -------------------

  # Open3 tags captured bytes with the default external encoding, which can be
  # US-ASCII. The helper always emits UTF-8, including the em dash in its blockers.
  def parse_report(output)
    JSON.parse(output.dup.force_encoding(Encoding::UTF_8))
  end

  def test_helper_cli_accepts_a_declared_handoff
    out, _err, status = Open3.capture3(
      "ruby", COORDINATION_DECLARATION_HELPER, "--handoff", "-",
      stdin_data: "coordination: registered aw-20260723-1124-koa\nfinal state: merged\n"
    )
    report = parse_report(out)

    assert_equal 0, status.exitstatus
    assert report["ok"]
    assert_equal "registered", report["form"]
    assert_equal "aw-20260723-1124-koa", report["batch_id"]
    assert_empty report["blockers"]
  end

  def test_helper_cli_blocks_a_handoff_with_no_declaration
    out, _err, status = Open3.capture3(
      "ruby", COORDINATION_DECLARATION_HELPER, "--handoff", "-",
      stdin_data: "final state: merged\nAll gates passed and every target is closed out.\n"
    )
    report = parse_report(out)

    assert_equal 1, status.exitstatus, "a silent handoff must exit nonzero so closeout cannot ignore it"
    refute report["ok"]
    assert_equal [MISSING_DECLARATION_BLOCKER], report["blockers"]
  end

  # The `unavailable` form requires an em dash, so the helper must not depend on
  # the caller's locale to read its own required separator.
  def test_helper_cli_reads_the_em_dash_form_under_an_ascii_locale
    out, err, status = Open3.capture3(
      { "LC_ALL" => "C", "LANG" => "C" },
      "ruby", COORDINATION_DECLARATION_HELPER, "--handoff", "-",
      stdin_data: "coordination: unavailable #{EM_DASH} deliberately uncoordinated single-operator run\n"
    )

    assert_equal 0, status.exitstatus, "an em-dash handoff must validate under an ASCII locale: #{err}"

    report = parse_report(out)

    assert report["ok"]
    assert_equal "unavailable", report["form"]
    assert_equal "deliberately uncoordinated single-operator run", report["reason"]
  end

  def test_helper_cli_validates_a_handoff_file
    Dir.mktmpdir("coordination-declaration") do |directory|
      path = File.join(directory, "handoff.md")
      File.write(path, "- coordination: registered aw-1\n", encoding: "UTF-8")

      out, _err, status = Open3.capture3("ruby", COORDINATION_DECLARATION_HELPER, "--handoff", path)

      assert_equal 0, status.exitstatus
      assert parse_report(out)["ok"]
    end
  end

  def test_helper_cli_reports_a_usage_error_without_a_handoff
    _out, err, status = Open3.capture3("ruby", COORDINATION_DECLARATION_HELPER)

    assert_equal 64, status.exitstatus
    assert_equal "Error: missing argument: --handoff\n#{CoordinationDeclaration.usage}\n", err
  end

  def test_helper_cli_reports_invalid_utf8_as_a_clean_input_error
    invalid_handoff = "coordination: registered aw-1\ninvalid: \xFF\n".b

    Dir.mktmpdir("coordination-declaration-invalid-utf8") do |directory|
      path = File.join(directory, "handoff.md")
      File.binwrite(path, invalid_handoff)

      [
        ["stdin", ["--handoff", "-"], { stdin_data: invalid_handoff }],
        ["file", ["--handoff", path], {}]
      ].each do |label, arguments, options|
        out, err, status = Open3.capture3("ruby", COORDINATION_DECLARATION_HELPER, *arguments, **options)

        assert_equal 64, status.exitstatus, "#{label}: invalid UTF-8 is an input error"
        assert_empty out, "#{label}: an input error must not emit a misleading JSON report"
        assert_match(/\AError: .*invalid UTF-8/i, err, "#{label}: stderr must identify the invalid input")
        refute_match(/coordination-declaration:\d+:in|Traceback|from .*coordination-declaration/, err,
                     "#{label}: the helper must not leak a Ruby stack trace")
      end
    end
  end

  def test_missing_runtime_helper_companion_stops_with_a_precise_blocker
    Dir.mktmpdir("isolated-pr-batch") do |directory|
      isolated_test = File.join(
        File.realpath(directory),
        "skills/pr-batch/bin/coordination-declaration-contract-test.rb"
      )
      FileUtils.mkdir_p(File.dirname(isolated_test))
      FileUtils.cp(__FILE__, isolated_test)
      missing_companion = File.expand_path("coordination-declaration", File.dirname(isolated_test))

      out, err, status = Open3.capture3("ruby", isolated_test)

      assert_equal 1, status.exitstatus
      assert_includes err, "missing companion: #{missing_companion}"
      refute_includes "#{out}\n#{err}", "LoadError"
    end
  end

  # The gate was spec-only enforcement until the closeout lane actually ran it.
  def test_coordinator_closeout_lane_runs_the_declaration_helper
    closeout = extract_anchored_section(
      read_repo_file(INTEGRATION_CLOSEOUT_PATH),
      "### Coordinator Closeout Lane",
      end_heading: /^##[[:blank:]]+/
    )
    normalized = normalize_prose(closeout)

    assert_includes normalized, '"${PR_BATCH_SKILL_DIR}/bin/coordination-declaration" --handoff',
                    "the closeout lane must run the declaration helper against the drafted handoff"
    assert_includes normalized, "A nonzero exit is a hard blocker",
                    "the closeout lane must treat a failed declaration check as a hard blocker"
  end
end
