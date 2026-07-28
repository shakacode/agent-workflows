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

  def test_every_operation_bound_surface_carries_the_explicit_closeout_contract
    failures = OPERATION_BOUND_SURFACES.flat_map do |path|
      text = read(path)
      [
        "final shared-instruction read",
        "final helper/capability use",
        "invalidates every returned `assets.*` path",
        "begin a new operation",
        "release the old operation",
        "`list --json`",
        "named `release`",
        "never TTL or PID inference"
      ].filter_map { |fragment| "#{path}: missing #{fragment.inspect}" unless text.include?(fragment) }
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

  def test_generated_restart_fixture_uses_the_structural_provider_contract
    source = read("skills/plan-pr-batch/scripts/check_goal_prompt_size.rb")
    fixture = source.match(/CANONICAL_RESUME_SNIPPET = <<~TEXT\.chomp\n(.*?)^TEXT$/m)&.captures&.first

    refute_nil fixture
    assert_restart_provider_contract(fixture, "generated canonical resume fixture")
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

  def test_plan_issue_triage_copied_prompt_has_safe_provider_branches
    prompt = fenced_prompt_after(
      read("skills/plan-issue-triage/SKILL.md"),
      "## Prompt Template"
    )
    managed, pinned = provider_branches(prompt)

    assert_equal 1, managed.scan("agent-workflows-resolve begin").length
    assert_includes managed, "`triage_operation.assets.skills.evaluate_issue`"
    assert_includes managed, "`triage_operation.assets.skills.plan_pr_batch`"
    refute_match(/(?<!triage_operation\.)\bassets\./, managed)
    assert_equal ["triage_operation"], prompt.scan(/\b([a-z_]+_operation)\.assets\./).flatten.uniq
    refute_match(/(?<!triage_operation\.)\bassets\./, prompt)

    refute_includes pinned, "agent-workflows-resolve begin"
    refute_includes pinned, "triage_operation"
    refute_match(/\bassets\./, pinned)
    assert_includes pinned, "stop without running the issue triage"
  end

  def test_every_asset_consuming_copy_paste_prompt_binds_inside_the_received_body
    paths = %w[
      workflows/address-review.md
      workflows/adversarial-pr-review.md
      workflows/post-merge-audit.md
    ]
    failures = paths.flat_map do |path|
      fenced_text_blocks(read(path)).flat_map.with_index do |body, index|
        next [] unless body.include?("assets.")

        required = [
          "This receiving invocation must bind its own provider",
          "final shared-instruction read",
          "final helper/capability use",
          "invalidates every returned `assets.*` path",
          "release the old operation",
          "`list --json`",
          "named\n`release`",
          "never TTL or PID inference"
        ]
        required.filter_map do |fragment|
          "#{path}: fenced prompt #{index + 1} missing #{fragment.inspect}" unless body.include?(fragment)
        end
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_every_restart_or_replacement_prompt_has_structural_provider_fencing
    paths = %w[skills/pause/SKILL.md docs/agent-runner-restarts.md workflows/pr-processing.md]
    paths.each do |path|
      prompts = fenced_text_blocks(read(path)).select do |body|
        body.lstrip.start_with?("Resume", "Restart")
      end
      refute_empty prompts, path
      prompts.each.with_index(1) do |body, index|
        assert_restart_provider_contract(body, "#{path}: restart prompt #{index}")
        assert_includes body, "release the old operation", "#{path}: restart prompt #{index}"
        assert_includes body, "`list --json`", "#{path}: restart prompt #{index}"
      end
    end
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

  def test_public_contract_documents_bounded_explicit_lifecycle
    paths = %w[
      docs/host-adapter/contract.md
      docs/installation-and-upgrades.md
      docs/plans/2026-07-25-bound-provider-snapshot-design.md
    ]
    failures = paths.flat_map do |path|
      text = read(path)
      [
        "`release --host HOST --target TARGET --operation HANDLE --json`",
        "`list --host HOST --target TARGET --json`",
        "32",
        "8",
        "healthy quiescent state",
        "never evicts a live operation",
        "lifecycle lease"
      ].filter_map { |fragment| "#{path}: missing #{fragment}" unless text.include?(fragment) }
    end

    assert_empty failures, failures.join("\n")
  end

  def test_entry_scripts_embed_the_same_self_contained_lease_before_loading_mutable_runtime
    entries = %w[bin/agent-workflows-resolve bin/agent-workflows-run].to_h do |path|
      text = read(path)
      module_source = text.match(/module AgentWorkflowsEntryLease\n.*?^end\n/m)&.to_s

      refute_empty module_source, path
      assert_operator text.index(module_source), :<, text.index("AgentWorkflowsEntryLease.with"), path
      assert_operator text.index("AgentWorkflowsEntryLease.with"), :<,
                      text.index("require_relative \"agent_workflows_operation/"), path
      refute_includes text[0...text.index("AgentWorkflowsEntryLease.with")], "require_relative", path
      [path, module_source]
    end

    assert_equal entries.fetch("bin/agent-workflows-resolve"), entries.fetch("bin/agent-workflows-run")
  end

  def test_lifecycle_entry_is_self_contained
    lifecycle = read("bin/agent-workflows-lifecycle")

    refute_includes lifecycle, "require_relative"
    assert_includes lifecycle, "with_exclusive_lease(target)"
    assert_includes lifecycle, "validate_reentry!(target)"
  end

  def test_installer_atomically_publishes_complete_entries_before_mutable_runtime
    installer = read("bin/install-agent-workflows")

    assert_includes installer, "install -m 0755 \"$source\" \"$temporary\""
    assert_includes installer, "ln -s \"$source\" \"$temporary\""
    assert_operator installer.index("publish_entry_copy \"$repo_root/bin/$helper\" \"$destination\""), :<,
                    installer.index("rsync -a --delete \"$repo_root/bin/agent_workflows_operation/\"")
    assert_operator installer.index("publish_entry_symlink \"$repo_root/bin/$helper\" \"$destination\""), :<,
                    installer.index("ln -sfn \"$repo_root/bin/agent_workflows_operation\"")
    %w[
      agent-workflows-lifecycle
      agent-workflows-resolve
      agent-workflows-run
      install-agent-workflows
      upgrade-agent-workflows
    ].each do |entry|
      assert_match(/atomic_entry_helpers=\(.*?^\s+#{Regexp.escape(entry)}$/m, installer)
    end
  end

  def test_public_contract_explains_bootstrap_and_stale_reentry_proofs
    paths = %w[
      docs/host-adapter/contract.md
      docs/installation-and-upgrades.md
      docs/plans/2026-07-25-bound-provider-snapshot-design.md
    ]
    failures = paths.flat_map do |path|
      text = read(path)
      %w[atomic wrapper-only independent inherited inactive EOF].filter_map do |fragment|
        "#{path}: missing #{fragment.inspect}" unless text.include?(fragment)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  private

  def assert_restart_provider_contract(prompt, label)
    managed, pinned = provider_branches(prompt)

    assert_equal 1, managed.scan("agent-workflows-resolve begin").length, label
    assert_equal 1, prompt.scan("agent-workflows-resolve begin").length, label
    assert_equal ["resume_operation"], managed.scan(/\b([a-z_]+_operation)\.revision\b/).flatten.uniq, label
    assert_equal ["resume_operation"], prompt.scan(/\b([a-z_]+_operation)\.assets\./).flatten.uniq, label
    refute_match(/(?<!resume_operation\.)\bassets\./, prompt, label)
    assert_operator managed.index("resume_operation.revision"), :<,
                    managed.index("resume_operation.assets"), label

    refute_includes pinned, "agent-workflows-resolve begin", label
    refute_match(/\b[a-z_]+_operation\b/, pinned, label)
    refute_match(/\bassets\./, pinned, label)
    assert_match(/continue only|stop before/i, pinned, label)
  end

  def fenced_prompt_after(text, heading)
    heading_start = text.index(heading)
    raise "missing heading #{heading.inspect}" unless heading_start

    fenced_text_blocks(text[heading_start..]).fetch(0)
  end

  def provider_branches(prompt)
    managed_marker = "Managed provider branch:"
    pinned_marker = "Pinned or offline provider branch:"
    after_marker = "After provider branch selection:"
    managed_start = prompt.index(managed_marker)
    pinned_start = prompt.index(pinned_marker)
    after_start = prompt.index(after_marker)

    refute_nil managed_start, "missing managed branch"
    refute_nil pinned_start, "missing pinned branch"
    refute_nil after_start, "missing post-selection boundary"
    assert_operator managed_start, :<, pinned_start
    assert_operator pinned_start, :<, after_start
    assert_match(%r{If metadata\s+is unavailable,\s+use\s+the\s+pinned/offline branch},
                 prompt[0...managed_start])

    managed = prompt[(managed_start + managed_marker.length)...pinned_start]
    pinned = prompt[(pinned_start + pinned_marker.length)...after_start]
    [managed, pinned]
  end

  def fenced_text_blocks(text)
    text.scan(/^(`{3,4})text\s*$\n(.*?)^\1\s*$/m).map(&:last)
  end

  def read(relative)
    File.binread(File.join(ROOT, relative))
  end
end
