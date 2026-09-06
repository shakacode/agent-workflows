#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("../../..", __dir__)

class WritingStyleContractTest < Minitest::Test
  RESOLUTION_RULE = "Resolve writing style before authoring human-facing prose"
  COVERED_SURFACES = %w[
    workflows/pr-processing.md
    skills/pr-batch/SKILL.md
    skills/address-review/SKILL.md
    workflows/address-review.md
    skills/post-merge-audit/SKILL.md
    workflows/post-merge-audit.md
    skills/verify-pr-fix/SKILL.md
    skills/plan-issue-triage/SKILL.md
    skills/evaluate-issue/SKILL.md
    workflows/evaluate-issue.md
    skills/pr-monitoring/SKILL.md
    skills/close-session/SKILL.md
  ].freeze

  def read(relative_path)
    File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
  end

  def test_every_initial_authoring_surface_explicitly_resolves_the_shared_guide
    COVERED_SURFACES.each do |relative_path|
      text = read(relative_path)

      assert_includes text, RESOLUTION_RULE, relative_path
      assert_includes text, "agent-workflow-writing-style", relative_path
    end
  end

  def test_style_guidance_cannot_replace_templates_evidence_or_receipts
    workflow = "#{read('workflows/pr-batch-integration-closeout.md')}\n#{read('workflows/pr-processing.md')}"
    address_templates = read("skills/address-review/references/templates.md")
    audit = read("skills/post-merge-audit/SKILL.md")

    assert_includes workflow, "Apply the resolved guide only to prose."
    assert_includes workflow, "machine-readable receipts"
    assert_includes workflow, "exact protocol blocks"
    ["Why", "What changed", "How to review and verify"].each do |heading|
      assert_includes workflow, "## #{heading}"
    end
    assert_includes workflow, "<!-- qa-evidence v2"
    assert_includes workflow, "<!-- priority-finding-dispositions v1"
    assert_includes address_templates, "<!-- address-review-summary -->"
    assert_includes address_templates, "<!-- address-review-source-state:v1"
    assert_includes audit, "<!-- completed-batch-audit v1"
  end

  def test_shared_authoring_contract_distinguishes_tooling_from_invalid_configuration
    workflow = read("workflows/pr-processing.md")

    normalized = workflow.gsub(/\s+/, " ")
    assert_includes normalized, "If presentation tooling is unavailable, continue independent authorized work."
    assert_includes normalized, "no explicit `writing_style` override"
    assert_includes normalized, "no valid user-global override takes precedence"
    assert_includes normalized, "A nonzero resolver exit is not proof of missing tooling"
    assert_includes normalized, "An explicit malformed repository value blocks authoring; never bypass it"
  end

  def test_seam_design_inventories_covered_and_deferred_consumers
    seam_design = read("docs/seam-design.md")

    assert_includes seam_design, "Covered in the first iteration"
    assert_includes seam_design, "Deferred authoring surfaces"
    COVERED_SURFACES.each do |relative_path|
      assert_includes seam_design, "`#{relative_path}`", relative_path
    end
  end

  def test_adoption_and_installation_document_the_user_global_fallback_without_seeding_repo_config
    adoption = read("docs/adoption.md")
    installation = read("docs/installation-and-upgrades.md")
    example = read("examples/agent-workflow.yml")
    source_policy = YAML.safe_load(read(".agents/agent-workflow.yml"), aliases: false)
    fixture_policy = YAML.safe_load(read("test/fixtures/consumer-repo/.agents/agent-workflow.yml"), aliases: false)
    parsed_example = YAML.safe_load(example, aliases: false)

    assert_includes adoption, "~/.agents/agent-workflow.yml"
    assert_includes adoption, "repo → user-global → portable default"
    assert_includes installation, "agent-workflow-writing-style"
    assert_includes installation, "~/.agents/agent-workflow.yml"
    assert_match(
      /\| `codex` .*\n\| `claude` .*\n\| `auto` .*\n\nThe installer also supplies/m,
      installation
    )
    refute source_policy.key?("writing_style"), "source repo must remain a fallback negative control"
    refute fixture_policy.key?("writing_style"), "consumer fixture must exercise fallback compatibility"
    refute parsed_example.key?("writing_style"), "example must not seed a repository override"
    assert_includes example, "# writing_style: docs/writing-style.md"
    refute_includes example, "# writing_style:\n"
  end

  def test_packaged_default_prose_lives_only_in_the_installed_markdown_document
    default_path = "docs/writing-style.md"
    default_lines = read(default_path).lines.map(&:strip).reject(&:empty?)
    prose_paths = (COVERED_SURFACES + [
      default_path,
      "bin/agent-workflow-writing-style",
      "docs/adoption.md",
      "docs/installation-and-upgrades.md",
      "docs/seam-design.md",
      "examples/agent-workflow.yml"
    ]).uniq

    assert_equal 5, default_lines.length
    default_lines.each do |line|
      assert_equal [default_path], prose_paths.select { |path| read(path).include?(line) }, line
    end
    assert_includes read("bin/agent-workflow-writing-style"), "../docs/writing-style.md"
  end

  def test_docs_describe_path_roots_precedence_and_future_trusted_distribution_layer
    adoption = read("docs/adoption.md")
    installation = read("docs/installation-and-upgrades.md")
    seam_design = read("docs/seam-design.md")

    [adoption, installation, seam_design].each do |document|
      normalized = document.gsub(/\s+/, " ")
      assert_includes normalized, "writing-style.md"
      assert_includes normalized, "repo → user-global → portable default"
    end
    normalized_seam_design = seam_design.gsub(/\s+/, " ")
    assert_includes normalized_seam_design, "beneath the repository root"
    assert_includes normalized_seam_design, "beneath `~/.agents`"
    assert_includes normalized_seam_design, "future explicitly trusted distribution/source layer"
    assert_includes normalized_seam_design, "does not perform network or cross-repository lookup"
  end
end
