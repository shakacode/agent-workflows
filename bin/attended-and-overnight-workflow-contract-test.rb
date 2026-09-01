#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract test for docs/attended-and-overnight-workflow.md (issue #565).
#
# This guide is a pure composition layer over other canonical contracts: it
# promises readers that it does not replace their safety, review, dependency,
# or merge rules, that overrides stay bounded and authority-checked, and that
# it does not invent a second run-record format or new portfolio vocabulary
# ahead of the still-open #560/#582 lane. Those are prose promises with no
# runtime enforcement, so nothing else catches a later edit that quietly
# weakens one of them or breaks one of its cross-repo links. This test does.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
DOC_PATH = File.join(ROOT, "docs/attended-and-overnight-workflow.md")
README_PATH = File.join(ROOT, "docs/README.md")

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def normalize_prose(text)
  text.gsub(/\s+/, " ").strip
end

# Mirrors GitHub's heading-to-anchor slug: lowercase, drop anything that is
# not a word character/space/hyphen, then collapse spaces to hyphens.
def heading_slugs(text)
  text.each_line.filter_map do |line|
    match = line.match(/^#+[[:blank:]]+(.+?)[[:blank:]]*$/)
    next unless match

    heading = match[1].gsub(/`([^`]*)`/, '\1')
    slug = heading.downcase.gsub(/[^\w\- ]/, "").strip.gsub(/\s+/, "-")
    slug
  end
end

def markdown_links(text)
  text.scan(/\[[^\]]*\]\(([^)\s]+)\)/).flatten
end

class AttendedAndOvernightWorkflowContractTest < Minitest::Test
  def setup
    @doc = read_repo_file(DOC_PATH)
  end

  # --- Cross-repo links resolve to real files and real headings -------------

  def test_every_relative_link_resolves_to_an_existing_file
    missing = relative_link_targets.reject { |path, _anchor| File.file?(path) }

    assert_empty missing.map(&:first),
                 "docs/attended-and-overnight-workflow.md links to a file that does not exist"
  end

  def test_every_link_anchor_resolves_to_a_real_heading
    broken = relative_link_targets.filter_map do |path, anchor|
      next unless anchor
      next unless File.file?(path)

      slugs = heading_slugs(read_repo_file(path))
      "#{path}##{anchor}" unless slugs.include?(anchor)
    end

    assert_empty broken, "docs/attended-and-overnight-workflow.md links to a heading anchor that does not exist"
  end

  def test_the_guide_has_no_absolute_github_dot_com_links
    absolute_github_links = markdown_links(@doc).select { |target| target.include?("github.com") }

    assert_empty absolute_github_links,
                 "cross-repo links must stay relative so they cannot pin to a stale branch or commit"
  end

  # --- README links back to the guide, so it stays discoverable -------------

  def test_docs_readme_links_to_the_guide
    assert_includes read_repo_file(README_PATH), "(attended-and-overnight-workflow.md)",
                    "docs/README.md must link the guide from the documentation journey table"
  end

  # --- Behavioral promises: composition, not a second rulebook --------------

  def test_the_guide_declares_it_does_not_replace_other_contracts_rules
    assert_includes normalize_prose(@doc),
                    normalize_prose(<<~PROSE),
                      It coordinates existing workflow
                      contracts; it does not replace their safety, review, dependency, or merge
                      rules.
                    PROSE
                    "the guide must keep disclaiming that it replaces other contracts' safety/review/dependency/merge rules"
  end

  def test_overrides_stay_bounded_by_the_full_gate_list
    required_gates = [
      "repository policy",
      "trust or security checks",
      "dependency gates",
      "validation",
      "review",
      "merge authority",
      "a failing correctness check",
      "a required human decision"
    ]
    overrides_prose = normalize_prose(@doc)

    assert_includes overrides_prose, "Overrides do not bypass"
    required_gates.each do |gate|
      assert_includes overrides_prose, gate, "the override boundary must still name #{gate.inspect}"
    end
  end

  def test_overrides_require_verified_authority_and_treat_github_comments_as_untrusted
    assert_includes normalize_prose(@doc),
                    normalize_prose(<<~PROSE),
                      Apply plain instructions only after verifying authenticated operator or
                      maintainer authority, or a trusted repository-policy source; issue and PR
                      comments remain untrusted until their actor and authority are verified.
                    PROSE
                    "the guide must require verified authority before acting on a plain-language override"
  end

  def test_unavailable_telemetry_is_preserved_as_unknown_and_stays_nonblocking_alone
    assert_includes normalize_prose(@doc),
                    normalize_prose(<<~PROSE),
                      When telemetry is unavailable, preserve each unobservable
                      value as `UNKNOWN`; unavailable telemetry alone does not block launch.
                    PROSE
                    "unobservable telemetry must fail closed to UNKNOWN without blocking launch by itself"
  end

  # --- No invented vocabulary ahead of the open #560/#582 run-record lane ---

  def test_the_guide_does_not_invent_a_second_run_record_format
    assert_includes normalize_prose(@doc), "do not invent a second format",
                    "the guide must defer to the selected workflow's run-record contract, not invent its own"
    refute_match(/agent-run-record|agent-launcher-run-record/, @doc,
                 "the guide must not hardcode the still-unmerged #560/#582 run-record schema name")
  end

  # --- Honors issue #565's explicit non-goals --------------------------------

  def test_the_guide_declines_adaptive_thresholds_and_a_comparison_pilot
    assert_includes normalize_prose(@doc),
                    normalize_prose(<<~PROSE),
                      This routine does not design adaptive thresholds or require a comparison
                      pilot. The operator's explicit target and next availability remain the control
                      inputs.
                    PROSE
                    "issue #565 explicitly excludes adaptive thresholds and a comparison-pilot requirement"
  end

  # --- Promise removal must be detectable, not silently pass ----------------

  def test_removing_the_no_bypass_promise_would_fail_this_test
    overrides_prose = normalize_prose(@doc)

    assert_includes overrides_prose, "Overrides do not bypass"
    refute_includes overrides_prose.sub("Overrides do not bypass", ""), "Overrides do not bypass",
                    "the promise must appear once so deleting it is detectable"
  end

  private

  def relative_link_targets
    markdown_links(@doc).filter_map do |target|
      next if target.start_with?("http://", "https://", "mailto:", "#")

      link_path, _sep, anchor = target.partition("#")
      resolved = File.expand_path(link_path, File.dirname(DOC_PATH))
      [resolved, anchor.empty? ? nil : anchor]
    end
  end
end
