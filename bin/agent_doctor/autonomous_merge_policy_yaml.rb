# frozen_string_literal: true

# All three autonomous_merge_policy*.rb files reopen one module; the split
# exists only to keep each file inside the 180-line focused-module cap asserted
# by test/agent_doctor/architecture_test.rb, not to draw an API boundary. The
# portable policy pattern constants live here because this is the file with
# room for them.
module AutonomousMergePolicy
  # Built-in autonomous-merge policy surface. Every source path also has an
  # installed `.agents/` twin, so the twins are derived rather than listed and
  # a new source path cannot forget its installed form. Consumer `policy_paths`
  # add repository-specific policy documents and helpers; they can never remove
  # a built-in entry.
  SOURCE_POLICY_PATTERNS = %w[
    workflows/pr-processing.md
    workflows/pr-batch-security-floor.md
    workflows/pr-batch-worker-execution.md
    workflows/pr-batch-integration-closeout.md
    workflows/pr-batch-coordination-observability.md
    workflows/pr-production-release.md
    skills/pr-batch/SKILL.md skills/pr-monitoring/SKILL.md
    skills/plan-pr-batch/SKILL.md skills/triage/SKILL.md
    bin/agent_doctor/autonomous_merge_policy.rb bin/agent_doctor/autonomous_merge_policy_globs.rb
    bin/agent_doctor/autonomous_merge_policy_yaml.rb
    skills/pr-batch/bin/autonomous-merge-eligibility skills/pr-batch/bin/autonomous-merge-calibrate
    skills/pr-batch/bin/autonomous-merge-closeout skills/pr-batch/bin/*contract-test.rb
    skills/pr-batch/lib/autonomous_merge_*.rb
    skills/pr-batch/lib/current_integration_*.rb
    skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json
    skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
  ].freeze
  BUILTIN_POLICY_PATTERNS = (
    %w[AGENTS.md **/AGENTS.md .agents/agent-workflow.yml docs/adr/0003-smarter-autonomous-merge-gates.md] +
    SOURCE_POLICY_PATTERNS + SOURCE_POLICY_PATTERNS.map { |pattern| ".agents/#{pattern}" }
  ).freeze

  # Portable safe-path-group excludes. Every portable safe group carries them,
  # and together they cover every BUILTIN_POLICY_PATTERNS path in both layouts,
  # so no safe classification can contradict the built-in policy surface -
  # including when a consumer adds includes, because a consumer can only add to
  # these excludes and never remove one.
  PORTABLE_POLICY_EXCLUDES = %w[
    AGENTS.md **/AGENTS.md CLAUDE.md **/CLAUDE.md **/SKILL.md
    **/autonomous_merge_*.rb **/current_integration_*.rb
    **/autonomous-merge-* **/check_goal_prompt_size.rb
    **/*contract-test.rb workflows/** .agents/** docs/adr/**
  ].freeze

  # Portable safe path groups. Absent, empty, or partial consumer configuration
  # inherits these; consumer patterns are added to them.
  PORTABLE_SAFE_PATH_GROUPS = {
    "documentation" => {
      "include" => %w[**/*.md **/*.mdx docs/** **/*.txt].freeze,
      "exclude" => (
        PORTABLE_POLICY_EXCLUDES + %w[**/CHANGELOG.md SECURITY.md **/SECURITY.md **/README.md]
      ).freeze
    }.freeze,
    "tests" => {
      "include" => %w[test/** spec/** **/*_test.rb **/*_spec.rb **/*.test.ts **/*.test.js **/__tests__/**].freeze,
      "exclude" => (
        PORTABLE_POLICY_EXCLUDES + %w[**/fixtures/** **/*fixture* spec/dummy/** test/dummy/** **/*.snap]
      ).freeze
    }.freeze
  }.freeze

  module_function

  # Mutable deep copy of the portable safe path groups, so callers can merge
  # consumer patterns into it without mutating the frozen defaults.
  def portable_safe_path_groups
    PORTABLE_SAFE_PATH_GROUPS.transform_values do |group|
      { "include" => group.fetch("include").dup, "exclude" => group.fetch("exclude").dup }
    end
  end

  def duplicate_key_errors(yaml)
    stream = Psych.parse_stream(yaml)
    errors = []
    walk_for_duplicate_keys(stream, "$", errors)
    errors
  rescue Psych::Exception => e
    ["malformed trusted-base YAML: #{e.message.lines.first.to_s.strip}"]
  end

  def walk_for_duplicate_keys(node, path, errors)
    return unless node.respond_to?(:children) && node.children.is_a?(Array)

    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key_node, value_node|
        key = key_node.respond_to?(:value) ? key_node.value : nil
        if key.nil?
          errors << "#{path} contains a non-scalar mapping key"
        elsif seen.key?(key)
          errors << "#{path} contains duplicate key #{key.inspect}"
        else
          seen[key] = true
        end
        walk_for_duplicate_keys(value_node, "#{path}.#{key}", errors)
      end
    else
      node.children.each { |child| walk_for_duplicate_keys(child, path, errors) }
    end
  end
end
