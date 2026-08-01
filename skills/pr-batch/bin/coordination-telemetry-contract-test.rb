#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"

ROOT = File.expand_path("../../..", __dir__)
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
COORDINATION_DOC_PATH = File.join(ROOT, "docs/coordination-backend.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
MANIFEST_PROMPT_LINE = "Manifest:pack_sha=<rev|UNKNOWN>;" \
                       "coordinator_route=<model/effort@binding|UNKNOWN>;" \
                       "lanes=<lane-id:host+worker-route,...>;no guesses"
HELP_REQUESTED_REASON_PRECEDENCE =
  "Choose exactly one `help_requested.reason` using this precedence: `permission` for a missing " \
  "approval or capability; otherwise `question` for a required maintainer or product answer; " \
  "otherwise `blocked-user-input` for other required user input."
BATCH_AUDIT_EXECUTABLE = "agent-coord"
BATCH_AUDIT_ARGUMENTS = "batch-audit --batch-id <id> --json"
BATCH_AUDIT_COMMAND = "#{BATCH_AUDIT_EXECUTABLE} #{BATCH_AUDIT_ARGUMENTS}".freeze
AUDIT_COMPATIBLE_CAPABILITY = "`agent-coord`-compatible telemetry-completeness audit capability"
AUDIT_COMMAND_BINDING = "bound to the exact command `#{BATCH_AUDIT_COMMAND}`".freeze
AUDIT_UNAVAILABLE = "telemetry audit: unavailable"

EXPECTED_OPERATIONAL_SIGNALS = {
  "help-needed pause" => {
    "type" => "help_requested",
    "required_fields" => %w[reason]
  },
  "model escalation request" => {
    "type" => "escalation_requested",
    "required_fields" => %w[from_route to_route evidence]
  },
  "human intervention" => {
    "type" => "human_intervention",
    "required_fields" => %w[kind]
  },
  "serious error" => {
    "type" => "error",
    "required_fields" => %w[severity category message]
  }
}.freeze

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def extract_section(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[ \t]*$/)
  raise "missing heading #{heading.inspect}" unless heading_match

  heading_level = heading[/\A#+/].length
  body_start = heading_match.end(0)
  cursor = body_start
  next_heading = nil
  while (candidate = text.match(/^(#+)\s+/, cursor))
    if candidate[1].length <= heading_level
      next_heading = candidate
      break
    end

    cursor = candidate.end(0)
  end
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def parse_operational_signal_rows(section)
  section.each_line.filter_map do |line|
    next unless line.start_with?("|")

    cells = line.split("|").map(&:strip).reject(&:empty?)
    next unless cells.length == 3
    next if cells.first == "Checkpoint" || cells.first.match?(/\A-+\z/)

    checkpoint = cells.fetch(0).delete("`")
    type = cells.fetch(1).delete("`")
    fields = cells.fetch(2).scan(/`([a-z_]+)`/).flatten
    [checkpoint, { "type" => type, "required_fields" => fields }]
  end.to_h
end

def extract_json_fence(text, heading)
  heading_index = text.index(heading)
  raise "missing heading #{heading.inspect}" unless heading_index

  fence_start = text.index("```json\n", heading_index)
  raise "missing JSON fence after #{heading.inspect}" unless fence_start

  body_start = fence_start + "```json\n".length
  body_end = text.index(/^```\s*$/, body_start)
  raise "missing closing JSON fence after #{heading.inspect}" unless body_end

  JSON.parse(text[body_start...body_end])
end

def batch_audit_invocation_executables(text)
  text.to_enum(:scan, /#{Regexp.escape(BATCH_AUDIT_ARGUMENTS)}/).map do
    invocation = Regexp.last_match
    prefix = text[0...invocation.begin(0)]
    prefix[/(\S+)[ \t]+\z/, 1]&.delete_prefix("`")
  end
end

class CoordinationTelemetryContractTest < Minitest::Test
  def test_extract_section_stops_at_a_parent_heading
    fixture = <<~MARKDOWN
      ### Target
      target body
      #### Nested
      nested body
      ## Parent
      parent body
    MARKDOWN

    section = extract_section(fixture, "### Target")

    assert_includes section, "target body"
    assert_includes section, "#### Nested"
    assert_includes section, "nested body"
    refute_includes section, "## Parent"
    refute_includes section, "parent body"
  end

  def test_extract_section_stops_at_an_equal_level_sibling_heading
    fixture = <<~MARKDOWN
      ### Target
      target body
      #### Nested
      nested body
      ### Sibling
      sibling body
    MARKDOWN

    section = extract_section(fixture, "### Target")

    assert_includes section, "target body"
    assert_includes section, "#### Nested"
    assert_includes section, "nested body"
    refute_includes section, "### Sibling"
    refute_includes section, "sibling body"
  end

  def test_operational_signal_dry_run_maps_each_checkpoint_to_the_typed_contract
    workflow = read_repo_file(WORKFLOW_PATH)
    telemetry = extract_section(workflow, "### Coordination Telemetry And Provenance")
    rows = parse_operational_signal_rows(telemetry)

    assert_equal EXPECTED_OPERATIONAL_SIGNALS, rows
    assert_equal %w[error escalation_requested help_requested human_intervention],
                 rows.values.map { |row| row.fetch("type") }.sort

    assert_includes telemetry, "`claim.acquired`"
    assert_includes telemetry, "`claim.released`"
    assert_includes telemetry, "`phase.changed`"
    assert_includes telemetry, "best-effort"
    assert_includes telemetry, "No coordination backend (`n/a`): skip the event silently."
    assert_includes telemetry, "preserve `UNKNOWN`"
  end

  def test_registered_batch_manifest_dry_run_carries_pack_and_route_provenance
    docs = read_repo_file(COORDINATION_DOC_PATH)
    manifest = extract_json_fence(docs, "## Batch Provenance Manifest")

    assert_match(/\A[0-9a-f]{40}\z|\AUNKNOWN\z/, manifest.fetch("pack_sha"))
    coordinator_route = manifest.fetch("coordinator_route")
    assert_equal %w[binding_source effort model], coordinator_route.keys.sort
    coordinator_route.each do |key, value|
      assert_instance_of String, value, "coordinator_route.#{key} must be a string"
      refute_empty value, "coordinator_route.#{key} must not be empty"
    end
    refute_empty manifest.fetch("lanes")
    manifest.fetch("lanes").each do |lane|
      host = lane.fetch("host")
      assert_instance_of String, host, "lane host must be a string"
      refute_empty host, "lane host must not be empty"

      worker_route = lane.fetch("worker_route")
      assert_equal %w[binding_source effort model], worker_route.keys.sort
      worker_route.each do |key, value|
        assert_instance_of String, value, "worker_route.#{key} must be a string"
        refute_empty value, "worker_route.#{key} must not be empty"
      end
    end

    [
      "workflows/pr-processing.md",
      "skills/plan-pr-batch/SKILL.md",
      "skills/pr-batch/SKILL.md"
    ].each do |path|
      assert_includes read_repo_file(File.join(ROOT, path)), MANIFEST_PROMPT_LINE
    end
  end

  def test_existing_checkpoint_guidance_carries_typed_events_and_closeout_audit
    workflow = read_repo_file(WORKFLOW_PATH)

    {
      "### Question And Decision Handling" => %w[help_requested blocked-user-input question permission],
      "### Worker Model Replacement And Escalation" => %w[escalation_requested human_intervention supersede],
      "### Cancelling Or Stopping A Batch" => %w[human_intervention drain],
      "## Review Comment Handling" => %w[error P0 P1 regression revert],
      "### Coordinator Closeout Lane" => %w[telemetry-completeness]
    }.each do |heading, phrases|
      section = extract_section(workflow, heading)
      phrases.each { |phrase| assert_includes section, phrase, "#{heading} is missing #{phrase}" }
    end

    {
      "skills/plan-pr-batch/SKILL.md" => %w[pack_sha coordinator_route worker_route host],
      "skills/pr-batch/SKILL.md" => %w[help_requested escalation_requested error human_intervention],
      "skills/pr-monitoring/SKILL.md" => %w[help_requested error],
      "skills/pause/SKILL.md" => %w[help_requested blocked-user-input],
      "skills/continue/SKILL.md" => %w[human_intervention takeover supersede]
    }.each do |path, phrases|
      text = read_repo_file(File.join(ROOT, path))
      phrases.each { |phrase| assert_includes text, phrase, "#{path} is missing #{phrase}" }
    end
  end

  def test_help_requested_reason_precedence_is_mutually_exclusive_everywhere
    workflow = read_repo_file(WORKFLOW_PATH)
    [
      "### Question And Decision Handling",
      "### Coordination Telemetry And Provenance"
    ].each do |heading|
      section = extract_section(workflow, heading).gsub(/\s+/, " ")
      assert_includes section, HELP_REQUESTED_REASON_PRECEDENCE, "#{heading} has a stale reason mapping"
    end

    %w[
      docs/coordination-backend.md
      skills/pr-batch/SKILL.md
      skills/pr-monitoring/SKILL.md
      skills/pause/SKILL.md
    ].each do |path|
      text = read_repo_file(File.join(ROOT, path)).gsub(/\s+/, " ")
      assert_includes text, HELP_REQUESTED_REASON_PRECEDENCE, "#{path} has a stale reason mapping"
    end
  end

  def test_authoritative_closeout_surfaces_use_exact_batch_audit_command
    {
      WORKFLOW_PATH => 2,
      COORDINATION_DOC_PATH => 1,
      PR_BATCH_SKILL_PATH => 1
    }.each do |path, expected_count|
      text = read_repo_file(path).gsub(/\s+/, " ")
      executables = batch_audit_invocation_executables(text)

      assert_equal expected_count, executables.length,
                   "#{path} must expose every batch-audit invocation to executable-token validation"
      assert_equal Array.new(expected_count, BATCH_AUDIT_EXECUTABLE), executables,
                   "#{path} must use only the exact agent-coord executable token"
      assert_equal expected_count, text.scan("`#{BATCH_AUDIT_COMMAND}`").length,
                   "#{path} must use the exact executable and batch-audit subcommand"
    end
  end

  def test_batch_audit_fails_closed_only_for_an_advertised_capability
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance", "### Coordinator Closeout Lane"],
      COORDINATION_DOC_PATH => ["## Operational Signal Events"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading).gsub(/\s+/, " ")
        assert_includes section, AUDIT_COMPATIBLE_CAPABILITY,
                        "#{path} #{heading} must gate blocking on an agent-coord-compatible audit"
        assert_includes section, AUDIT_COMMAND_BINDING,
                        "#{path} #{heading} must bind compatibility to the exact audit command"
        assert_includes section, "`#{AUDIT_UNAVAILABLE}`",
                        "#{path} #{heading} must record the unavailable outcome locally"
      end
    end
  end
end
