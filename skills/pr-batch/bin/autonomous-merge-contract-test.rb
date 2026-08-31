#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"
require_relative "../lib/autonomous_merge_runtime_trust"

ROOT = File.expand_path("../../..", __dir__)
PARITY_PATHS = %w[
  workflows/pr-batch-integration-closeout.md
  skills/pr-monitoring/SKILL.md
  skills/plan-pr-batch/SKILL.md
  skills/triage/SKILL.md
].freeze
ROUTE_PATHS = %w[
  workflows/pr-processing.md
  skills/pr-batch/SKILL.md
].freeze
NECESSARY_NOT_SUFFICIENT = "Ordinary readiness is necessary but not sufficient for autonomous merge; " \
                           "evaluate exact-head autonomous-merge eligibility after every ordinary gate passes."
UNKNOWN_IS_NOT_APPROVAL = "`UNKNOWN` is not `human-approval-required` and cannot be cleared by risk approval."
HUMAN_STATE = "`ready-human-review-required` carries the exact current head SHA, every triggered gate, " \
              "rollback status, and the exact durable human decision needed."
UNKNOWN_STATE = "`autonomous-merge-evidence-unknown` carries the exact current head SHA, evidence failure, " \
                "trusted-base policy provenance, and repair action."
GMCC_HUMAN_DECISION_BINDING = "auto=>exact verdict/head/sorted-gates/rollback; merge iff " \
                              "autonomous-merge-eligible OR human-approved-for-current-head+" \
                              "durable-decision(proven-human+merge-authority)"
THRESHOLD_DOCUMENTATION_PARITY = "ADR 0003 is the source of truth for these copied portable defaults. " \
                                 "File, line, and commit maxima are enforced; max_reviewed_heads is " \
                                 "shadow-only until a checked calibration artifact explicitly graduates " \
                                 "it to enforcement."
SAFE_PATH_GROUP_DOCUMENTATION_PARITY = "Portable safe_path_groups defaults ship for documentation and tests. " \
                                       "Consumer include and exclude patterns are added to the portable sets; " \
                                       "a consumer can never remove a portable exclude."

class AutonomousMergeContractTest < Minitest::Test
  def test_runtime_records_are_keyword_structs_compatible_with_ruby_three_one
    records = [
      AutonomousMergePolicy::Result,
      AutonomousMergeRuntimeTrust::Result
    ]

    records.each do |record|
      assert_operator record, :<, Struct
      assert_equal true, record.keyword_init?
    end

    assert_equal(
      { accepted: true, provenance: "test", errors: [], manifest: {} },
      AutonomousMergeRuntimeTrust::Result.new(
        accepted: true,
        provenance: "test",
        errors: [],
        manifest: {}
      ).to_h
    )
  end

  def test_all_entry_points_preserve_eligibility_and_distinct_terminal_states
    PARITY_PATHS.each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8").gsub(/\s+/, " ")

      assert_includes text, NECESSARY_NOT_SUFFICIENT, path
      assert_includes text, UNKNOWN_IS_NOT_APPROVAL, path
      assert_includes text, HUMAN_STATE, path
      assert_includes text, UNKNOWN_STATE, path
    end

    ROUTE_PATHS.each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8")
      assert_includes text, "pr-batch-integration-closeout.md#autonomous-merge-eligibility-gate", path
    end
  end

  def test_canonical_workflow_binds_helper_to_trusted_base_and_exact_current_head
    workflow = File.read(File.join(ROOT, "workflows/pr-batch-integration-closeout.md"), encoding: "UTF-8")

    assert_includes workflow, "autonomous-merge-eligibility"
    assert_includes workflow, "--trusted-base"
    assert_includes workflow, "human-approved-for-current-head"
    assert_includes workflow, "shadow_triggered_gates"
    assert_includes workflow, "trusted-base materialization"
    assert_includes workflow, "verified installed Agent Workflows pack"
    assert_includes workflow, "--trusted-helper-provenance"
    assert_includes workflow, "autonomous_merge_runtime_trust.rb"
    assert_match(/stdin\s+evaluation JSON is diagnostic-only/, workflow)
    assert_includes workflow, "mechanically recomputes a length-framed manifest"
    assert_includes workflow, "remain coordinator procedures"
    assert_match(/`merge_authority`\s+remains separate from\s+eligibility/, workflow)
  end

  def test_goal_generation_surfaces_carry_both_autonomous_stop_states
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8")

      assert_includes text, "GMCC-v4:"
      assert_includes text, "ready-human-review-required"
      assert_includes text, "autonomous-merge-evidence-unknown"
      assert_includes text, GMCC_HUMAN_DECISION_BINDING
    end
  end

  def test_copied_threshold_defaults_document_reviewed_heads_as_shadow_only
    %w[docs/seam-design.md examples/agent-workflow.yml].each do |path|
      assert_includes normalized_policy_prose(path), THRESHOLD_DOCUMENTATION_PARITY, path
    end
  end

  def test_portable_safe_path_group_defaults_and_additive_merge_are_documented
    %w[
      docs/adr/0003-smarter-autonomous-merge-gates.md
      docs/seam-design.md
      examples/agent-workflow.yml
    ].each do |path|
      assert_includes normalized_policy_prose(path), SAFE_PATH_GROUP_DOCUMENTATION_PARITY, path
    end
  end

  # The acceptance invariant for the portable safe path groups: no path that a
  # built-in policy pattern can match may survive a portable safe group's
  # exclude set. Because a consumer can only add excludes, this holds for every
  # consumer configuration and for every include set, so a positive
  # documentation or tests classification can never contradict the built-in
  # policy surface that autonomous-merge-eligibility gates on.
  def test_portable_safe_path_groups_exclude_every_builtin_policy_path
    segments, fragments = safe_group_vocabulary
    refute_empty segments
    refute_empty fragments

    generated = 0
    include_matches = 0
    uncovered = []
    AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS.each do |pattern|
      representative_paths(pattern, segments, fragments).each do |path|
        generated += 1

        assert AutonomousMergePolicy.match?(pattern, path),
               "generated representative #{path.inspect} does not match #{pattern.inspect}"
        AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.each do |name, group|
          include_matches += 1 if match_any?(group.fetch("include"), path)
          uncovered << "#{name}: #{pattern} -> #{path}" unless match_any?(group.fetch("exclude"), path)
        end
      end
    end

    assert_operator generated, :>=, AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS.length
    assert_empty uncovered, "built-in policy paths reachable from a portable safe group:\n#{uncovered.join("\n")}"
    refute_equal 0, include_matches,
                 "no built-in policy representative is include-matched; the exclude assertions are vacuous"
  end

  def test_portable_safe_path_groups_apply_when_configuration_is_absent_empty_or_partial
    portable = AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS
    absent = AutonomousMergePolicy.parse("{}")
    empty = AutonomousMergePolicy.parse("autonomous_merge:\n  safe_path_groups: {}\n")
    partial = AutonomousMergePolicy.parse(<<~YAML)
      autonomous_merge:
        safe_path_groups:
          tests:
            include:
              - "**/*-test.rb"
    YAML

    [absent, empty, partial].each { |policy| assert_empty policy.errors }
    [absent, empty].each do |policy|
      %w[documentation tests].each do |name|
        assert_equal portable.fetch(name).fetch("include"), policy.safe_path_groups.fetch(name).fetch("include"), name
        assert_equal portable.fetch(name).fetch("exclude"), policy.safe_path_groups.fetch(name).fetch("exclude"), name
      end
    end
    assert_equal portable.fetch("documentation").fetch("include"),
                 partial.safe_path_groups.fetch("documentation").fetch("include")
    assert_equal portable.fetch("tests").fetch("include") + ["**/*-test.rb"],
                 partial.safe_path_groups.fetch("tests").fetch("include")
  end

  def test_consumer_safe_path_groups_add_patterns_and_cannot_remove_a_portable_exclude
    policy = AutonomousMergePolicy.parse(<<~YAML)
      autonomous_merge:
        safe_path_groups:
          documentation:
            include:
              - "workflows/**"
              - "handbook/**"
            exclude:
              - "handbook/runbooks/**"
    YAML

    assert_empty policy.errors
    documentation = policy.safe_path_groups.fetch("documentation")

    assert_equal AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.fetch("documentation").fetch("include") +
                 ["workflows/**", "handbook/**"],
                 documentation.fetch("include")
    assert_includes documentation.fetch("exclude"), "handbook/runbooks/**"
    AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.fetch("documentation").fetch("exclude").each do |pattern|
      assert_includes documentation.fetch("exclude"), pattern
    end
    assert match_any?(documentation.fetch("include"), "workflows/pr-processing.md")
    assert match_any?(documentation.fetch("exclude"), "workflows/pr-processing.md"),
           "a consumer include must not be able to reach a portable-excluded policy path"
  end

  def test_malformed_policy_falls_back_to_portable_thresholds_and_safe_path_groups
    policy = AutonomousMergePolicy.parse("- not a mapping\n")

    refute_empty policy.errors
    assert_equal AutonomousMergePolicy::PORTABLE_THRESHOLDS, policy.thresholds
    assert_equal AutonomousMergePolicy.portable_safe_path_groups, policy.safe_path_groups
  end

  # A consumer that only wants to tighten the portable set writes a group with
  # `exclude` and no `include`. That must parse clean: any nonempty
  # policy.errors makes autonomous-merge-eligibility emit UNKNOWN for the whole
  # PR, so rejecting this shape would fail every PR in that repository closed
  # rather than declining one group.
  def test_exclude_only_consumer_group_is_valid_and_inherits_the_portable_includes
    policy = AutonomousMergePolicy.parse(<<~YAML)
      autonomous_merge:
        safe_path_groups:
          documentation:
            exclude:
              - "handbook/runbooks/**"
    YAML
    portable = AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.fetch("documentation")
    documentation = policy.safe_path_groups.fetch("documentation")

    assert_equal [], policy.errors
    assert_equal portable.fetch("include"), documentation.fetch("include")
    assert_equal portable.fetch("exclude") + ["handbook/runbooks/**"], documentation.fetch("exclude")
    assert_equal AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.fetch("tests").fetch("include"),
                 policy.safe_path_groups.fetch("tests").fetch("include")
  end

  def test_a_consumer_group_whose_declared_includes_are_all_invalid_globs_still_fails
    policy = AutonomousMergePolicy.parse(<<~YAML)
      autonomous_merge:
        safe_path_groups:
          tests:
            include:
              - "../escape/**"
    YAML

    assert_includes policy.errors.join("; "), "autonomous_merge.safe_path_groups.tests.include[0] invalid glob"
    refute_empty policy.errors
  end

  def test_builtin_policy_patterns_carry_both_source_and_installed_layouts
    builtin = AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS

    refute_empty AutonomousMergePolicy::SOURCE_POLICY_PATTERNS
    assert_includes AutonomousMergePolicy::SOURCE_POLICY_PATTERNS, "workflows/pr-batch-security-floor.md"
    assert_includes builtin, ".agents/workflows/pr-batch-security-floor.md"
    AutonomousMergePolicy::SOURCE_POLICY_PATTERNS.each do |pattern|
      assert_includes builtin, pattern
      assert_includes builtin, ".agents/#{pattern}"
    end
    %w[
      AGENTS.md
      **/AGENTS.md
      .agents/agent-workflow.yml
      docs/adr/0003-smarter-autonomous-merge-gates.md
    ].each { |pattern| assert_includes builtin, pattern }
    assert_equal builtin.uniq, builtin
  end

  def test_release_policy_component_is_an_unconditional_policy_surface
    source_path = "workflows/pr-production-release.md"

    assert_includes AutonomousMergePolicy::SOURCE_POLICY_PATTERNS, source_path
    assert_includes AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS, source_path
    assert_includes AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS, ".agents/#{source_path}"
  end

  def test_coordination_observability_component_is_an_unconditional_policy_surface
    source_path = "workflows/pr-batch-coordination-observability.md"

    assert_includes AutonomousMergePolicy::SOURCE_POLICY_PATTERNS, source_path
    assert_includes AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS, source_path
    assert_includes AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS, ".agents/#{source_path}"
  end

  def test_portable_safe_path_group_constants_are_frozen_and_not_mutated_by_callers
    groups = AutonomousMergePolicy.portable_safe_path_groups
    groups.fetch("documentation").fetch("include") << "mutated/**"

    assert_predicate AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS, :frozen?
    assert_predicate AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS, :frozen?
    refute_includes AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.fetch("documentation").fetch("include"),
                    "mutated/**"
  end

  private

  def normalized_policy_prose(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
        .lines
        .map { |line| line.sub(/\A# ?/, "") }
        .join
        .delete("`")
        .gsub(/\s+/, " ")
  end

  def match_any?(patterns, path)
    patterns.any? { |pattern| AutonomousMergePolicy.match?(pattern, path) }
  end

  # Adversarial vocabulary mined from the portable safe-group include patterns
  # themselves, so the invariant test cannot drift away from the include sets it
  # is asserting against. Literal components become candidate `**` expansions and
  # literal wildcard tails become candidate `*` fillers.
  def safe_group_vocabulary
    segments = []
    fragments = []
    AutonomousMergePolicy::PORTABLE_SAFE_PATH_GROUPS.each_value do |group|
      group.fetch("include").each do |pattern|
        pattern.split("/", -1).each do |component|
          next if component == "**"

          if wildcard?(component)
            tail = literal_tail(component)
            fragments << tail unless tail.empty?
          else
            segments << component
          end
        end
      end
    end
    [segments.uniq, fragments.uniq]
  end

  def wildcard?(component)
    component.match?(/[*?\[]/)
  end

  def literal_tail(component)
    component[(component.rindex(/[*?\]]/) + 1)..].to_s
  end

  def representative_paths(pattern, segments, fragments)
    choices = pattern.split("/", -1).map do |component|
      if component == "**"
        [[], %w[x], %w[x y]] + segments.map { |segment| [segment] }
      else
        component_variants(component, fragments).map { |variant| [variant] }
      end
    end
    expanded = choices.reduce([[]]) do |paths, options|
      paths.flat_map { |prefix| options.map { |option| prefix + option } }
    end
    expanded.map { |components| components.join("/") }.uniq
  end

  def component_variants(component, fragments)
    return [component] unless wildcard?(component)

    tail = literal_tail(component)
    fillers = ["x"]
    fragments.each do |fragment|
      trimmed = !tail.empty? && fragment.end_with?(tail) ? fragment.delete_suffix(tail) : fragment
      fillers << "x#{trimmed}"
    end
    fillers.uniq.map { |filler| expand_component(component, filler) }
  end

  def expand_component(component, filler)
    expanded = +""
    index = 0
    while index < component.length
      case component[index]
      when "*"
        expanded << filler
      when "?"
        expanded << "x"
      when "["
        closing = component.index("]", index + 1)
        raise "unterminated bracket class in #{component.inspect}" unless closing

        content = component[(index + 1)...closing]
        content = content[1..] if content.start_with?("!", "^")
        expanded << content[0]
        index = closing
      else
        expanded << component[index]
      end
      index += 1
    end
    expanded
  end
end
