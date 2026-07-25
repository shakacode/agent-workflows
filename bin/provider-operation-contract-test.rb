#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

class ProviderOperationContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ENTRY_SKILLS = %w[
    address_review
    adversarial_pr_review
    autoreview
    evaluate_issue
    pause
    plan_issue_triage
    plan_pr_batch
    post_merge_audit
    pr_batch
    pr_monitoring
    run_ci
    spec
    tdd
    triage
    update_changelog
    verify
  ].freeze
  OPERATION_BOUND_SURFACES = (
    ENTRY_SKILLS.map { |name| "skills/#{name.tr('_', '-')}/SKILL.md" } +
    %w[
      workflows/address-review.md
      workflows/adversarial-pr-review.md
      workflows/continuous-evaluation-loop.md
      workflows/evaluate-issue.md
      workflows/post-merge-audit.md
      workflows/pr-processing.md
      workflows/tdd.md
    ]
  ).freeze
  FORBIDDEN_PROVIDER_FALLBACKS = {
    "consumer shared-skill/workflow copy" => %r{\.agents/(?:skills|workflows)/},
    "host-tree relative workflow link" => %r{\.\./\.\./workflows/},
    "unbound shared asset path" => %r{`(?:\.\.?/)*(?:docs|skills|workflows)/[a-z]},
    "relative shared asset link" => %r{\]\(\.\.?/(?:\.\.?/)*(?:docs|skills|workflows)/},
    "installed/shared fallback" => %r{installed/shared}i,
    "installed workflow fallback" => /installed `pr-processing\.md`|installed workflow/i,
    "installed/repo-local skill fallback" => /installed or repo-local `[^`]*skill|repo-local skill/i,
    "loaded-skill fallback" => /loaded[- ]skill/i,
    "repo-pinned fallback" => /repo[- ]pinned/i,
    "repo-local path fallback" => %r{live/repo-local fallback}i,
    "live-plugin fallback" => /live plugin/i,
    "another-checkout fallback" => /another checkout|other checkout/i,
    "unnamed PR-processing asset" => /(?:resolved|operation-provided) `pr-processing\.md`/i,
    "environment skill-directory fallback" => /PR_BATCH_SKILL_DIR.{0,80}environment variable/im,
    "same-directory workflow link" => /\]\(pr-processing\.md(?:#|\))/,
    "bare shared workflow filename" => %r{(?<![\w/])pr-processing\.md(?![\w/])}
  }.freeze

  def test_registry_declares_every_operation_bound_entry_skill
    registry = JSON.parse(read("operation-capabilities.json"))
    declared = registry.dig("assets", "skills")

    assert_instance_of Hash, declared
    assert_equal ENTRY_SKILLS, declared.keys.sort
  end

  def test_registry_covers_actual_outgoing_operation_bound_skill_routes
    registry = JSON.parse(read("operation-capabilities.json"))
    declared = registry.dig("assets", "skills").keys.map { |name| name.tr("_", "-") }
    shared_skill_names = Dir.glob(File.join(ROOT, "skills/*/SKILL.md")).map do |path|
      File.basename(File.dirname(path))
    end
    routed = ENTRY_SKILLS.flat_map do |name|
      text = read("skills/#{name.tr('_', '-')}/SKILL.md")
      text.scan(/\$([a-z][a-z0-9-]+)/).flatten +
        text.scan(%r{`/([a-z][a-z0-9-]+)`}).flatten
    end.uniq & shared_skill_names

    assert_empty routed - declared, "unbound outgoing routes: #{(routed - declared).sort.join(', ')}"
    assert_includes routed, "run-ci"
  end

  def test_every_operation_bound_entry_skill_carries_the_bootstrap_contract
    failures = ENTRY_SKILLS.flat_map do |name|
      path = "skills/#{name.tr('_', '-')}/SKILL.md"
      text = read(path)
      required_fragments = [
        "## Bound Provider Operation",
        "current invocation",
        "active host home",
        "absolute `bin/agent-workflows-resolve begin`",
        "Never bootstrap through `PATH`",
        "inherited operation",
        "`assets.skills.#{name}`",
        "`assets.workflow`",
        "`assets.root`",
        "Consumer `AGENTS.md`",
        "stop"
      ]
      required_fragments.filter_map do |fragment|
        "#{path}: missing #{fragment.inspect}" unless text.include?(fragment)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_every_entry_documents_provider_profile_fail_closed_semantics
    failures = ENTRY_SKILLS.flat_map do |name|
      path = "skills/#{name.tr('_', '-')}/SKILL.md"
      text = read(path)
      %w[provider_profile managed pinned].filter_map do |fragment|
        "#{path}: missing #{fragment}" unless text.include?(fragment)
      end + [
        ("#{path}: missing legacy pinned default" unless text.include?("missing legacy field is `pinned`")),
        ("#{path}: pinned profile may fetch" unless text.include?("never fetch")),
        ("#{path}: unknown profile does not stop" unless text.include?("unknown profile") && text.include?("stop")),
        ("#{path}: managed asset scope is implicit" unless text.include?("Managed profile only:")),
        ("#{path}: pinned branch is not concrete" unless text.include?("Pinned profile:"))
      ].compact
    end

    assert_empty failures, failures.join("\n")
  end

  def test_restart_surfaces_fence_provider_revision_changes
    %w[
      skills/pause/SKILL.md
      workflows/pr-processing.md
      docs/agent-runner-restarts.md
      skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
    ].each do |path|
      text = read(path)
      assert_includes text, "originating_provider_revision", path
      assert_includes text, "On mismatch, stop normal resume", path
      assert_includes text, "cancellation/relaunch or state reconciliation", path
    end
  end

  def test_copy_paste_surfaces_require_recipient_local_binding
    %w[
      workflows/address-review.md
      workflows/adversarial-pr-review.md
      workflows/post-merge-audit.md
    ].each do |path|
      text = read(path)
      assert_includes text, "Every recipient of a copied prompt must bind locally", path
      assert_includes text, "absolute `bin/agent-workflows-resolve begin`", path
      assert_includes text, "Never inherit a sender's handle or paths", path
    end
    triage = read("skills/plan-issue-triage/SKILL.md")
    assert_includes triage, "This receiving invocation must bind its own provider"
    assert_includes triage, "Never inherit operation handles"
  end

  def test_every_asset_consuming_copy_paste_prompt_binds_inside_the_received_body
    paths = %w[
      workflows/address-review.md
      workflows/adversarial-pr-review.md
      workflows/post-merge-audit.md
    ]
    failures = paths.flat_map do |path|
      fenced_text_blocks(read(path)).filter_map.with_index do |body, index|
        next unless body.include?("assets.")
        next if body.include?("This receiving invocation must bind its own provider")

        "#{path}: fenced prompt #{index + 1} consumes assets without recipient-local binding"
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_every_restart_or_replacement_prompt_contains_revision_fencing
    paths = %w[skills/pause/SKILL.md docs/agent-runner-restarts.md workflows/pr-processing.md]
    failures = paths.flat_map do |path|
      fenced_text_blocks(read(path)).filter_map.with_index do |body, index|
        next unless body.lstrip.start_with?("Resume", "Restart")
        next if body.include?("originating_provider_revision") &&
                body.include?("On mismatch, stop normal resume")

        "#{path}: restart prompt #{index + 1} lacks provider-revision fencing"
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_public_provider_docs_use_neutral_profile_terminology
    paths = %w[
      docs/installation-and-upgrades.md
      docs/host-adapter/contract.md
      docs/plans/2026-07-25-bound-provider-snapshot-design.md
    ]
    failures = paths.filter_map do |path|
      "#{path}: contains organization-specific rolling terminology" if read(path).match?(/ShakaCode (?:rolling-main|rolling channel)/i)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_operation_bound_surfaces_do_not_offer_mixed_provider_fallbacks
    failures = OPERATION_BOUND_SURFACES.flat_map do |path|
      text = read(path)
      FORBIDDEN_PROVIDER_FALLBACKS.filter_map do |label, pattern|
        "#{path}: contains #{label}" if text.match?(pattern)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_transitive_registered_docs_and_references_use_named_assets
    registry = JSON.parse(read("operation-capabilities.json"))
    skill_paths = registry.dig("assets", "skills").values.flat_map do |entry|
      Dir.glob(File.join(ROOT, File.dirname(entry), "**/*.{md,txt}")).map do |path|
        path.delete_prefix("#{ROOT}/")
      end
    end
    paths = skill_paths +
            registry.dig("assets", "related_workflows").values +
            registry.dig("assets", "docs").values
    failures = paths.flat_map do |path|
      text = read(path)
      FORBIDDEN_PROVIDER_FALLBACKS.filter_map do |label, pattern|
        "#{path}: contains #{label}" if text.match?(pattern)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_consumer_policy_and_command_seams_remain_local
    workflow = read("workflows/pr-processing.md")

    assert_includes workflow, "Consumer `AGENTS.md`"
    assert_includes workflow, "`.agents/agent-workflow.yml`"
    assert_match(%r{\.agents/bin}, workflow)
  end

  def test_public_contract_documents_the_generic_bound_snapshot_model
    contract = read("docs/host-adapter/contract.md")
    design_path = "docs/plans/2026-07-25-bound-provider-snapshot-design.md"
    assert_path_exists File.join(ROOT, design_path)
    design = read(design_path)

    [contract, design].each do |text|
      assert_includes text, "managed provider"
      assert_includes text, "explicit pinned or offline snapshot"
      assert_includes text, "`assets.root`"
      assert_includes text, "`assets.skills`"
      assert_includes text, "current invocation"
    end
    refute_match(/professional consumer/i, contract)
    refute_match(/professional consumer/i, design)
  end

  private

  def fenced_text_blocks(text)
    text.scan(/^(`{3,4})text\s*$\n(.*?)^\1\s*$/m).map(&:last)
  end

  def read(relative)
    File.binread(File.join(ROOT, relative))
  end
end
