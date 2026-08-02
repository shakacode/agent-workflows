#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"

ROOT = File.expand_path("../../..", __dir__)
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
COORDINATION_DOC_PATH = File.join(ROOT, "docs/coordination-backend.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PR_MONITORING_SKILL_PATH = File.join(ROOT, "skills/pr-monitoring/SKILL.md")
PAUSE_SKILL_PATH = File.join(ROOT, "skills/pause/SKILL.md")
CONTINUE_SKILL_PATH = File.join(ROOT, "skills/continue/SKILL.md")
TRIAGE_SKILL_PATH = File.join(ROOT, "skills/triage/SKILL.md")
MANIFEST_PROMPT_LINE = "Manifest:pack_sha=<rev|UNKNOWN>;" \
                       "coordinator_route=<model/effort@binding|UNKNOWN>;" \
                       "lanes=<lane-id:host+model/effort@binding>,...;" \
                       "UNKNOWN=field;no guesses"
MANIFEST_MISSING_REPETITION_LINE = MANIFEST_PROMPT_LINE.sub(">,...", ">")
MANIFEST_WHOLE_ENTRY_UNKNOWN_LINE =
  MANIFEST_PROMPT_LINE.sub("model/effort@binding>,...", "model/effort@binding|UNKNOWN>,...")
HELP_REQUESTED_REASON_PRECEDENCE =
  "Choose exactly one `help_requested.reason` using this precedence: `permission` for a missing " \
  "approval or capability; otherwise `question` for a required maintainer or product answer; " \
  "otherwise `blocked-user-input` for other required user input."
AUDIT_COMPATIBLE_CAPABILITY = "`agent-coord`-compatible telemetry-completeness audit capability"
AUDIT_ARGV_REQUIRED_CONCEPTS = {
  "executable" => "Executable: `agent-coord`.",
  "ordered separate arguments" =>
    "Arguments, in order and as separate values: `batch-audit`, `--batch-id`, `<opaque batch id>`, `--json`.",
  "single opaque ID argument" =>
    "Pass the opaque batch ID as exactly one argument value through a process/argument-vector API.",
  "shell-evaluation prohibition" =>
    "Shell interpolation, `eval`, `sh -c`, and equivalent shell-evaluation paths are forbidden."
}.freeze
AUDIT_UNSUPPORTED_CAPABILITY = "does not advertise that compatible capability"
AUDIT_UNKNOWN_ADVERTISEMENT = "its advertisement is `UNKNOWN`"
AUDIT_UNAVAILABLE = "telemetry audit: unavailable"
AUDIT_REQUIRED_CONTINUATION = "durable handoff and continue"
AUDIT_SECTION_REQUIRED_CONCEPTS = {
  "compatible capability" => AUDIT_COMPATIBLE_CAPABILITY,
  "unsupported capability condition" => AUDIT_UNSUPPORTED_CAPABILITY,
  "UNKNOWN advertisement condition" => AUDIT_UNKNOWN_ADVERTISEMENT,
  "unavailable outcome" => "`#{AUDIT_UNAVAILABLE}`",
  "required continuation" => AUDIT_REQUIRED_CONTINUATION
}.freeze
AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS = {
  "hard deadline and process-group termination" =>
    "Run that exact child contract through the resolved pr-batch `bin/agent-coord-bounded` process-control seam " \
    "with a positive hard deadline; the helper must preserve the exact child executable and separate argument " \
    "vector, launch it in its own process group, and terminate the whole process group when the deadline expires.",
  "timeout failure evidence and closeout continuation" =>
    "A timeout or forced termination is a command failure: record best-effort `UNKNOWN` telemetry-audit evidence " \
    "and continue closeout through steps 13-14 with that blocker; the audit subprocess must never wedge merge " \
    "closeout."
}.freeze
REMEDIATION_AUTHORITY_REQUIRED_CONCEPTS = {
  "outcome-bound authority" =>
    "Coordinated review-remediation authority is outcome-bound across convergence cycles, not pass-count-bound.",
  "bounded regression repair" =>
    "A verified correctness/security/contract regression caused by the authorized lane may be repaired without a fresh " \
    "maintainer prompt if and only if the repair stays within the already-authorized path envelope, preserves the " \
    "accepted outcome, and changes no unrelated semantics.",
  "fresh-authority boundary" =>
    "Fresh authority is mandatory for a new path, unrelated behavior or product semantics, a material tradeoff or " \
    "judgment, a new security, release, or merge-policy expansion, destructive or risky publication not already " \
    "authorized, or a new actor, replacement, or resource.",
  "bounded-pass meaning" =>
    "`Bounded pass` binds paths/semantics/risk; pass count alone does not expire authority."
}.freeze
EVENT_TRANSPORT_REQUIRED_CONCEPTS = {
  "optional transport" => "Typed-event transport is optional",
  "unadvertised transport" => "does not advertise it",
  "unsupported transport" => "reports it unsupported",
  "distinct unavailable outcome" => "`typed event transport: unavailable`",
  "nonblocking skip and continuation" =>
    "skip the emission, and continue without marking the event emission `UNKNOWN`",
  "advertised attempted-write failure" =>
    "Only after the transport is advertised does an attempted write that fails, degrades, or is rejected " \
    "become `UNKNOWN` handoff evidence"
}.freeze
COOPERATIVE_DRAIN_EMISSION_REQUIREMENT =
  "When a worker first observes cancellation at its cooperative drain checkpoint, that worker emits one " \
  "lane-scoped typed `human_intervention` event with `kind: drain` when the active private coordination backend " \
  "advertises typed-event support."
COOPERATIVE_DRAIN_DEDUPLICATION_REQUIREMENT =
  "The coordinator/operator must not emit a duplicate for that cooperative path."
HARD_ESCAPE_DRAIN_EMISSION_REQUIREMENT =
  "Immediately before terminating a worker that cannot reach that checkpoint, the coordinator/operator instead " \
  "emits one lane-scoped typed `human_intervention` event with `kind: drain` when the active private coordination " \
  "backend advertises typed-event support."
DRAIN_TRANSPORT_FALLBACK_REQUIREMENT =
  "For either drain path, backend `n/a` skips the emission; unadvertised or unsupported typed-event capability " \
  "records `typed event transport: unavailable` and remains nonblocking."
DRAIN_EMISSION_FAILURE_REQUIREMENT =
  "After advertised support, an emission failure, degradation, or rejection records best-effort `UNKNOWN` evidence " \
  "and never blocks safe termination or claim release."

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

def registered_batch_manifest
  docs = read_repo_file(COORDINATION_DOC_PATH)
  extract_json_fence(docs, "## Batch Provenance Manifest")
end

def assert_nonblank_string(value, label)
  assert_instance_of String, value, "#{label} must be a string"
  refute_empty value.strip, "#{label} must not be blank"
end

def assert_manifest_route_provenance(manifest)
  coordinator_route = manifest.fetch("coordinator_route")
  assert_equal %w[binding_source effort model], coordinator_route.keys.sort
  coordinator_route.each do |key, value|
    assert_nonblank_string(value, "coordinator_route.#{key}")
  end

  lanes = manifest.fetch("lanes")
  refute_empty lanes
  lanes.each_with_index do |lane, lane_index|
    assert_nonblank_string(lane.fetch("host"), "lanes[#{lane_index}].host")

    worker_route = lane.fetch("worker_route")
    assert_equal %w[binding_source effort model], worker_route.keys.sort
    worker_route.each do |key, value|
      assert_nonblank_string(value, "lanes[#{lane_index}].worker_route.#{key}")
    end
  end
end

def assert_batch_audit_section_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  AUDIT_SECTION_REQUIRED_CONCEPTS.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
  end
  assert_batch_audit_argv_contract(normalized_section, location)
end

def assert_batch_audit_argv_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  AUDIT_ARGV_REQUIRED_CONCEPTS.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
  end
  refute_includes normalized_section, "agent-coord batch-audit",
                  "#{location} must not present the audit as shell command text"
end

def assert_batch_audit_bounded_execution_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
  end

  hard_deadline_offset = normalized_section.index(AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS.values.fetch(0))
  continuation_offset = normalized_section.index(AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS.values.fetch(1))
  assert_operator hard_deadline_offset, :<, continuation_offset,
                  "#{location} must bind timeout handling after the bounded child execution requirement"
end

def assert_typed_event_transport_section_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  EVENT_TRANSPORT_REQUIRED_CONCEPTS.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
  end
end

def assert_hard_escape_drain_emission_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  {
    "cooperative worker emission" => COOPERATIVE_DRAIN_EMISSION_REQUIREMENT,
    "cooperative-path deduplication" => COOPERATIVE_DRAIN_DEDUPLICATION_REQUIREMENT,
    "coordinator/operator hard-escape emission" => HARD_ESCAPE_DRAIN_EMISSION_REQUIREMENT,
    "transport fallback" => DRAIN_TRANSPORT_FALLBACK_REQUIREMENT,
    "advertised-support write failure" => DRAIN_EMISSION_FAILURE_REQUIREMENT
  }.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
  end

  cooperative_offset = normalized_section.index(COOPERATIVE_DRAIN_EMISSION_REQUIREMENT)
  hard_escape_offset = normalized_section.index(HARD_ESCAPE_DRAIN_EMISSION_REQUIREMENT)
  assert_operator cooperative_offset, :<, hard_escape_offset,
                  "#{location} must assign cooperative emission before the hard-escape fallback"
end

def assert_manifest_prompt_contract(text, location)
  normalized_text = text.gsub(/\s+/, " ")
  assert_includes normalized_text, MANIFEST_PROMPT_LINE,
                  "#{location} must use the exact manifest provenance grammar"
  assert_includes normalized_text, "lanes=<lane-id:host+model/effort@binding>,...",
                  "#{location} must require repeated lane entries"
  assert_includes normalized_text, ";UNKNOWN=field;",
                  "#{location} must keep UNKNOWN at field granularity"
  refute_match(/lanes=<lane-id:[^>]*\|UNKNOWN>/, normalized_text,
               "#{location} must reject whole-entry UNKNOWN")
end

def assert_remediation_authority_section_contract(section, location)
  normalized_section = section.gsub(/\s+/, " ")
  REMEDIATION_AUTHORITY_REQUIRED_CONCEPTS.each do |concept, phrase|
    assert_includes normalized_section, phrase, "#{location} must include the #{concept}"
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
    assert_includes telemetry, "preserve the missing fact as `UNKNOWN`"
  end

  def test_typed_event_transport_fallback_is_section_local_and_nonblocking
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance"],
      COORDINATION_DOC_PATH => ["## Operational Signal Events"],
      PR_BATCH_SKILL_PATH => ["## Question And Decision Handling"],
      PR_MONITORING_SKILL_PATH => ["## Monitoring Loop"],
      PAUSE_SKILL_PATH => ["## Output Rules"],
      CONTINUE_SKILL_PATH => ["# Continue"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading)
        assert_typed_event_transport_section_contract(section, "#{path} #{heading}")
      end
    end
  end

  def test_typed_event_transport_contract_rejects_each_missing_required_concept
    transport_unavailable = EVENT_TRANSPORT_REQUIRED_CONCEPTS.fetch("distinct unavailable outcome")
    assert_equal "`typed event transport: unavailable`", transport_unavailable
    refute_equal "`#{AUDIT_UNAVAILABLE}`", transport_unavailable

    expected_concepts = [
      "optional transport",
      "unadvertised transport",
      "unsupported transport",
      "distinct unavailable outcome",
      "nonblocking skip and continuation",
      "advertised attempted-write failure"
    ]
    assert_equal expected_concepts, EVENT_TRANSPORT_REQUIRED_CONCEPTS.keys

    complete_fixture = EVENT_TRANSPORT_REQUIRED_CONCEPTS.values.join(" | ")
    EVENT_TRANSPORT_REQUIRED_CONCEPTS.each do |concept, phrase|
      incomplete_fixture = complete_fixture.sub(phrase, "")

      error = assert_raises(Minitest::Assertion) do
        assert_typed_event_transport_section_contract(incomplete_fixture, "negative fixture")
      end
      assert_includes error.message, "must include the #{concept}"
    end
  end

  def test_wedged_worker_hard_escape_assigns_one_drain_event_to_the_coordinator
    {
      WORKFLOW_PATH => "### Cancelling Or Stopping A Batch",
      PR_BATCH_SKILL_PATH => "### Cancellation Or Relaunch"
    }.each do |path, heading|
      section = extract_section(read_repo_file(path), heading)
      assert_hard_escape_drain_emission_contract(section, "#{path} #{heading}")
    end
  end

  def test_wedged_worker_hard_escape_rejects_removed_coordinator_emission
    {
      WORKFLOW_PATH => "### Cancelling Or Stopping A Batch",
      PR_BATCH_SKILL_PATH => "### Cancellation Or Relaunch"
    }.each do |path, heading|
      section = extract_section(read_repo_file(path), heading).gsub(/\s+/, " ")
      mutated_section = section.sub(HARD_ESCAPE_DRAIN_EMISSION_REQUIREMENT, "")
      refute_equal section, mutated_section, "#{path} must expose the hard-escape emission to mutation"

      error = assert_raises(Minitest::Assertion) do
        assert_hard_escape_drain_emission_contract(mutated_section, "#{path} hard-escape mutation")
      end
      assert_includes error.message, "must include the coordinator/operator hard-escape emission"
    end
  end

  def test_registered_batch_manifest_dry_run_carries_pack_and_route_provenance
    manifest = registered_batch_manifest

    assert_match(/\A[0-9a-f]{40}\z|\AUNKNOWN\z/, manifest.fetch("pack_sha"))
    assert_manifest_route_provenance(manifest)

    [WORKFLOW_PATH, File.join(ROOT, "skills/plan-pr-batch/SKILL.md"), PR_BATCH_SKILL_PATH, TRIAGE_SKILL_PATH].each do |path|
      assert_manifest_prompt_contract(read_repo_file(path), path)
    end
  end

  def test_manifest_prompt_rejects_missing_repetition_and_whole_entry_unknown
    {
      "missing repetition" => MANIFEST_MISSING_REPETITION_LINE,
      "whole-entry UNKNOWN" => MANIFEST_WHOLE_ENTRY_UNKNOWN_LINE
    }.each do |mutation, invalid_line|
      [WORKFLOW_PATH, File.join(ROOT, "skills/plan-pr-batch/SKILL.md"), PR_BATCH_SKILL_PATH, TRIAGE_SKILL_PATH].each do |path|
        text = read_repo_file(path)
        mutated_text = text.sub(MANIFEST_PROMPT_LINE, invalid_line)
        refute_equal text, mutated_text, "#{path} must expose the manifest grammar to mutation"

        error = assert_raises(Minitest::Assertion) do
          assert_manifest_prompt_contract(mutated_text, "#{path} #{mutation} mutation")
        end
        assert_includes error.message, "must use the exact manifest provenance grammar"
      end
    end
  end

  def test_registered_batch_manifest_route_provenance_accepts_literal_unknown
    manifest = registered_batch_manifest
    manifest.fetch("coordinator_route")["model"] = "UNKNOWN"
    manifest.fetch("lanes").each do |lane|
      lane["host"] = "UNKNOWN"
      lane.fetch("worker_route")["binding_source"] = "UNKNOWN"
    end

    assert_manifest_route_provenance(manifest)
  end

  def test_registered_batch_manifest_route_provenance_rejects_whitespace_only_values
    mutations = {
      "coordinator_route.model" => lambda do |manifest|
        manifest.fetch("coordinator_route")["model"] = " \t\n"
      end,
      "lanes[0].host" => lambda do |manifest|
        manifest.fetch("lanes").first["host"] = " \t\n"
      end,
      "lanes[0].worker_route.binding_source" => lambda do |manifest|
        manifest.fetch("lanes").first.fetch("worker_route")["binding_source"] = " \t\n"
      end
    }

    mutations.each do |label, mutate|
      manifest = registered_batch_manifest
      mutate.call(manifest)

      error = assert_raises(Minitest::Assertion) { assert_manifest_route_provenance(manifest) }
      assert_includes error.message, "#{label} must not be blank"
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

  def test_batch_audit_fails_closed_only_for_an_advertised_capability
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance", "### Coordinator Closeout Lane"],
      COORDINATION_DOC_PATH => ["## Operational Signal Events"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading)
        assert_batch_audit_section_contract(section, "#{path} #{heading}")
      end
    end
  end

  def test_batch_audit_section_contract_rejects_each_missing_required_concept
    expected_concepts = [
      "compatible capability",
      "unsupported capability condition",
      "UNKNOWN advertisement condition",
      "unavailable outcome",
      "required continuation"
    ]
    assert_equal expected_concepts, AUDIT_SECTION_REQUIRED_CONCEPTS.keys

    complete_fixture = AUDIT_SECTION_REQUIRED_CONCEPTS.values.join(" | ")
    AUDIT_SECTION_REQUIRED_CONCEPTS.each do |concept, phrase|
      incomplete_fixture = complete_fixture.sub(phrase, "")

      error = assert_raises(Minitest::Assertion) do
        assert_batch_audit_section_contract(incomplete_fixture, "negative fixture")
      end
      assert_includes error.message, "must include the #{concept}"
    end
  end

  def test_batch_audit_argv_contract_rejects_each_authoritative_section_mutation
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance", "### Coordinator Closeout Lane"],
      COORDINATION_DOC_PATH => ["## Operational Signal Events"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading).gsub(/\s+/, " ")
        AUDIT_ARGV_REQUIRED_CONCEPTS.each do |concept, phrase|
          mutated_section = section.sub(phrase, "mutated #{concept}")
          refute_equal section, mutated_section, "#{path} #{heading} must expose #{concept} to mutation"

          error = assert_raises(Minitest::Assertion) do
            assert_batch_audit_section_contract(mutated_section, "#{path} #{heading} mutation")
          end
          assert_includes error.message, "must include the #{concept}"
        end
      end
    end
  end

  def test_batch_audit_argv_contract_rejects_each_missing_required_concept
    complete_fixture = AUDIT_ARGV_REQUIRED_CONCEPTS.values.join(" | ")
    AUDIT_ARGV_REQUIRED_CONCEPTS.each do |concept, phrase|
      incomplete_fixture = complete_fixture.sub(phrase, "")

      error = assert_raises(Minitest::Assertion) do
        assert_batch_audit_argv_contract(incomplete_fixture, "negative argv fixture")
      end
      assert_includes error.message, "must include the #{concept}"
    end
  end

  def test_batch_audit_execution_is_bounded_and_closeout_continues
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance", "### Coordinator Closeout Lane"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading)
        assert_batch_audit_bounded_execution_contract(section, "#{path} #{heading}")
      end
    end
  end

  def test_batch_audit_bounded_execution_rejects_each_authoritative_section_mutation
    {
      WORKFLOW_PATH => ["### Coordination Telemetry And Provenance", "### Coordinator Closeout Lane"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading).gsub(/\s+/, " ")
        AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS.each do |concept, phrase|
          mutated_section = section.sub(phrase, "")
          refute_equal section, mutated_section, "#{path} #{heading} must expose #{concept} to mutation"
          (AUDIT_BOUNDED_EXECUTION_REQUIRED_CONCEPTS.values - [phrase]).each do |preserved_phrase|
            assert_includes mutated_section, preserved_phrase,
                            "#{path} #{heading} mutant must remove only the #{concept}"
          end

          error = assert_raises(Minitest::Assertion) do
            assert_batch_audit_bounded_execution_contract(mutated_section, "#{path} #{heading} mutation")
          end
          assert_includes error.message, "must include the #{concept}"
        end
      end
    end
  end

  def test_review_remediation_authority_is_section_local_and_outcome_bound
    {
      WORKFLOW_PATH => ["## Review Comment Handling"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading)
        assert_remediation_authority_section_contract(section, "#{path} #{heading}")
      end
    end
  end

  def test_review_remediation_authority_rejects_each_authoritative_section_mutation
    {
      WORKFLOW_PATH => ["## Review Comment Handling"],
      PR_BATCH_SKILL_PATH => ["## Coordinator Closeout Lane"]
    }.each do |path, headings|
      text = read_repo_file(path)
      headings.each do |heading|
        section = extract_section(text, heading).gsub(/\s+/, " ")
        REMEDIATION_AUTHORITY_REQUIRED_CONCEPTS.each do |concept, phrase|
          mutated_section = section.sub(phrase, "mutated #{concept}")
          refute_equal section, mutated_section, "#{path} #{heading} must expose #{concept} to mutation"

          error = assert_raises(Minitest::Assertion) do
            assert_remediation_authority_section_contract(mutated_section, "#{path} #{heading} mutation")
          end
          assert_includes error.message, "must include the #{concept}"
        end
      end
    end
  end

  def test_review_remediation_authority_rejects_each_missing_required_concept
    complete_fixture = REMEDIATION_AUTHORITY_REQUIRED_CONCEPTS.values.join(" | ")
    REMEDIATION_AUTHORITY_REQUIRED_CONCEPTS.each do |concept, phrase|
      incomplete_fixture = complete_fixture.sub(phrase, "")

      error = assert_raises(Minitest::Assertion) do
        assert_remediation_authority_section_contract(incomplete_fixture, "negative authority fixture")
      end
      assert_includes error.message, "must include the #{concept}"
    end
  end
end
