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
# not a word character/space/hyphen, collapse spaces to hyphens, then
# disambiguate repeated headings on the same page with a `-1`, `-2`, ...
# suffix the same way GitHub does.
def heading_slugs(text)
  seen = Hash.new(0)
  text.each_line.filter_map do |line|
    match = line.match(/^#+[[:blank:]]+(.+?)[[:blank:]]*$/)
    next unless match

    heading = match[1].gsub(/`([^`]*)`/, '\1')
    base_slug = heading.downcase.gsub(/[^\w\- ]/, "").strip.gsub(/\s+/, "-")
    count = seen[base_slug]
    seen[base_slug] += 1
    count.zero? ? base_slug : "#{base_slug}-#{count}"
  end
end

def markdown_links(text)
  text.scan(/\[[^\]]*\]\(([^)\s]+)\)/).flatten
end

# Binds an assertion to the one sentence that makes the promise, rather than
# to the whole document, so a common word (e.g. "review") appearing elsewhere
# in the guide can't mask that same word being dropped from the promise.
def extract_clause(prose, starts_with:)
  prose[/#{Regexp.escape(starts_with)}[^.]*\./]
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
  #
  # These assert on short key phrases rather than full sentences (see
  # `test_overrides_stay_bounded_by_the_full_gate_list` for the template), but
  # a phrase is still exact text: a copyedit of the doc that keeps the same
  # guarantee in different words must update the matching phrase here too.

  def test_the_guide_declares_it_does_not_replace_other_contracts_rules
    disclaimer = extract_clause(normalize_prose(@doc), starts_with: "does not replace their")

    refute_nil disclaimer, "the guide must state the composition disclaimer as one clause"
    %w[safety review dependency merge].each do |rule|
      assert_includes disclaimer, rule, "the composition disclaimer clause must still name the #{rule} rules"
    end
  end

  # Mirrors the non-safety-override boundary in
  # workflows/pr-processing.md#dependency-and-conflict-throughput-policy,
  # which also forbids bypassing a correctness check, merge authority,
  # security, production, release, or destructive-action gate.
  def test_overrides_stay_bounded_by_the_full_gate_list
    required_gates = [
      "repository policy",
      "trust or security checks",
      "dependency gates",
      "validation",
      "review",
      "merge authority",
      "a production, release, or",
      "destructive-action gate",
      "a failing correctness check",
      "a required human decision"
    ]
    boundary_clause = extract_clause(normalize_prose(@doc), starts_with: "Overrides do not bypass")

    refute_nil boundary_clause, "the guide must state the override boundary as one clause"
    required_gates.each do |gate|
      assert_includes boundary_clause, gate, "the override boundary clause must still name #{gate.inspect}"
    end
  end

  def test_overrides_require_verified_authority_and_treat_github_comments_as_untrusted
    prose = normalize_prose(@doc)

    assert_includes prose, "verifying authenticated operator or"
    assert_includes prose, "maintainer authority"
    assert_includes prose, "untrusted until their actor and authority are verified"
  end

  def test_unavailable_telemetry_is_preserved_as_unknown_and_stays_nonblocking_alone
    prose = normalize_prose(@doc)

    assert_includes prose, "preserve each unobservable"
    assert_includes prose, "as `UNKNOWN`"
    assert_includes prose, "unavailable telemetry alone does not block launch"
  end

  # --- No invented vocabulary ahead of the open #560/#582 run-record lane ---

  def test_the_guide_does_not_invent_a_second_run_record_format
    assert_includes normalize_prose(@doc), "do not invent a second format",
                    "the guide must defer to the selected workflow's run-record contract, not invent its own"
    refute_match(/agent-run-record|agent-launcher-run-record/, @doc,
                 "the guide must not hardcode the still-unmerged #560/#582 run-record schema name")
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
