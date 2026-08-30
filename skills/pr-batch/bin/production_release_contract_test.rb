# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

class ProductionReleaseContractTest < Minitest::Test
  COMPONENT_PATH = "workflows/pr-production-release.md"

  def setup
    @component = read(COMPONENT_PATH)
    @workflow = read("workflows/pr-processing.md")
    @skill = read("skills/pr-batch/SKILL.md")
    @handbook = read("docs/operator-handbook.md")
  end

  def test_component_owns_the_release_lifecycle_boundary
    normalized = squish(@component)
    assert_includes normalized, "# PR Production And Release"
    assert_includes normalized, "Production and release are downstream"
    assert_includes normalized, "does not own ordinary prompt intake, worker execution, or PR integration"
    assert_includes normalized, "explicit production or release authority"
  end

  def test_release_sections_have_one_canonical_owner
    headings = [
      "## Release Mode Preflight",
      "## Release Phase Gate",
      "## Tracker Update Safety",
      "## Promotion, Publishing, And Rollback Authority",
      "## Accelerated RC Auto-Merge"
    ]

    headings.each do |heading|
      assert_equal 1, @component.scan(/^#{Regexp.escape(heading)}$/).length, heading
      assert_equal 0, @workflow.scan(/^#{Regexp.escape(heading)}$/).length, heading
    end
  end

  def test_compatibility_surfaces_route_without_restatement
    workflow = squish(@workflow)
    skill = squish(@skill)
    assert_includes workflow, "## Production And Release Compatibility Route"
    assert_includes workflow, "[PR Production And Release](pr-production-release.md)"
    assert_includes workflow, "Ordinary base-branch feature work does not load the downstream component"
    assert_includes workflow, "### Ordinary Review Fallback"
    assert_includes workflow, "does not load the production/release component"
    review_gate = @workflow.split("## Review Completion Gate", 2).last
                           .split("### Adversarial Review Gate", 2).first
    refute_includes review_gate, "pr-production-release.md"

    assert_includes skill, "[PR Production And Release](../../workflows/pr-production-release.md)"
    assert_includes skill, "Do not restate its tracker, phase, promotion, or release rules here."

    assert_includes @handbook, "../workflows/pr-production-release.md#release-mode-preflight"
    assert_includes @handbook, "../workflows/pr-production-release.md#release-phase-gate"
    assert_includes @handbook, "../workflows/pr-production-release.md#accelerated-rc-auto-merge"
  end

  def test_safety_and_authority_invariants_survive_extraction
    normalized = squish(@component)
    [
      "Do not auto-create release trackers.",
      "report release mode or phase as `UNKNOWN`",
      "do not auto-merge",
      "explicit maintainer release decision before publishing",
      "SHA being promoted",
      "Merge authority never grants this authority",
      "require explicit authority for the exact action and target"
    ].each { |phrase| assert_includes normalized, phrase }

    assert_includes squish(@workflow), "Do not bypass the queue with administrator privileges"
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def squish(text)
    text.gsub(/\s+/, " ")
  end
end
