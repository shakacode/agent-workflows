#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanical contract tests for the Step 10 checkpoint template.
# Run with: ruby .agents/skills/address-review/bin/address-review-summary-template-test.rb

require "minitest/autorun"

class AddressReviewSummaryTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../references/templates.md", __dir__)

  def template
    @template ||= File.read(TEMPLATE_PATH, encoding: Encoding::UTF_8)
  end

  def section_after(start_marker, end_marker)
    start = template.index(start_marker)
    refute_nil start, "missing template marker: #{start_marker.inspect}"
    finish = template.index(end_marker, start)
    refute_nil finish, "missing template marker: #{end_marker.inspect}"

    template[start...(finish + end_marker.length)]
  end

  def assert_in_order(text, *fragments)
    cursor = 0
    fragments.each do |fragment|
      position = text.index(fragment, cursor)
      refute_nil position, "missing or out-of-order fragment: #{fragment.inspect}"
      cursor = position + fragment.length
    end
  end

  def test_primary_checkpoint_keeps_marker_first_and_details_collapsed
    primary = section_after(
      '  if [ "${CUTOFF_SAFE:-0}" = "1" ]; then',
      '} > "${summary_body_file}"'
    )

    assert_match(
      /\A\s*if \[ "\$\{CUTOFF_SAFE:-0\}" = "1" \]; then\n    printf '<!-- address-review-summary -->\\n'/,
      primary
    )
    assert_match(
      /else\n    printf '<!-- address-review-status -->\\n'\n  fi\n  printf '## Address-review summary\\n\\n'/,
      primary
    )
    assert_in_order(
      primary,
      "printf '## Address-review summary\\n\\n'",
      "printf 'Scan scope: %s\\n\\n' \"${SCAN_SCOPE}\"",
      "printf '<details>\\n'",
      "printf '<summary>Detailed review outcomes</summary>\\n\\n'",
      "printf '### Mattered\\n'",
      "printf '### Optional\\n'",
      "printf '### Skipped\\n'",
      "printf 'Deferred-work tracking: %s\\n\\n' \"${TRACKING_OUTCOME}\"",
      "printf '</details>\\n\\n'"
    )
    assert_includes primary, "Status: cutoff-safe summary. Detailed review outcomes are collapsed below."
    assert_includes primary, "Status: non-cutoff review status. Detailed review outcomes are collapsed below."
    refute_includes primary, "<details open>"
  end

  def test_source_checkpoint_keeps_auditable_details_and_source_state
    source = section_after(
      "  SOURCE_STATE_HAS_PENDING=0",
      '} > "${source_summary_body_file}"'
    )

    assert_match(
      /if \[ "\$\{SOURCE_CUTOFF_SAFE\}" = "1" \]; then\n      printf '<!-- address-review-summary -->\\n'\n    else\n      printf '<!-- address-review-status -->\\n'\n    fi\n    printf '## Address-review replacement carryover\\n\\n'/,
      source
    )
    assert_in_order(
      source,
      "printf '<!-- address-review-summary -->\\n'",
      "printf '## Address-review replacement carryover\\n\\n'",
      "printf 'Replacement PR: %s\\n\\n' \"${REPLACEMENT_PR_URL}\"",
      "printf '<details>\\n'",
      "printf '<summary>Detailed original PR outcomes</summary>\\n\\n'",
      "printf '### Original PR outcomes\\n'",
      "printf '%s\\n\\n' \"${SOURCE_OUTCOMES}\"",
      "printf '</details>\\n\\n'",
      "printf '<!-- address-review-source-state:v1\\n'",
      "printf '%s\\n' '-->'"
    )
    assert_includes source, "Status: cutoff-safe source carryover. Original PR outcomes are collapsed below."
    assert_includes source, "Status: non-cutoff source carryover. Original PR outcomes are collapsed below."
    refute_includes source, "<details open>"
  end

  def test_template_never_requests_open_details
    refute_includes template, "<details open>"
    assert_equal 2, template.scan("printf '<details>\\n'").length
  end

  def test_template_read_is_independent_of_default_external_encoding
    with_default_external_encoding(Encoding::US_ASCII) do
      assert_equal Encoding::UTF_8, template.encoding
      assert_equal 2, template.scan("printf '<details>\\n'").length
    end
  end

  private

  def with_default_external_encoding(encoding)
    original = Encoding.default_external
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = original
  end
end
