#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

PATH_EXPANSION_DEFAULT =
  "Necessary in-repository path expansion defaults to allowed when repository evidence shows an added path " \
  "is reasonably necessary to complete the already-authorized goal or its required validation. Treat owned " \
  "paths and the execution envelope as coordination and collision controls, not as a user-permission boundary. " \
  "Before editing, record each added path and reason in the lane envelope when one is present; otherwise use a " \
  "durable coordinator-owned lane record or Lane Card that the coordinator can read. Every added path not yet " \
  "reflected in its verified file-touch map must have an active typed `expansion-path-reservation` before edit. " \
  "When a lane is the sole active editor, the coordinator durably records the reservation, refreshes authoritative " \
  "file-touch maps, lane lifecycle state, and active-lane claim and collision checks, and reruns " \
  "`batch-plan-preflight`; the worker continues without user approval or a blocked lifecycle only after the " \
  "preflight accepts. Before a worker in a multi-editor wave changes an added path, it persists a typed expansion " \
  "request, marks its durable lane lifecycle blocked, refreshes its heartbeat, emits a Lane Card with the path, " \
  "reason, and request evidence reference, and pauses at a safe checkpoint. The coordinator processes expansion " \
  "requests serially, records an active `expansion_path_reservations` entry, refreshes authoritative file-touch " \
  "maps and lane lifecycle state, reruns `batch-plan-preflight`, and resumes the worker only after the preflight " \
  "accepts the path as disjoint or under maximum-concurrency-one serialization. The reservation persists until " \
  "the verified PR file-touch map contains the path or the request is cancelled, and it is removed once reflected " \
  "or cancelled. A collision or `UNKNOWN` collision state remains stopped until then. A missing path alone is not " \
  "material scope growth and must not produce `blocked-user-input`."

PATH_EXPANSION_EXAMPLES =
  "Necessary additions can include contract or type files, tests or fixtures, offline demo stubs, and build or " \
  "generated integration surfaces when repository evidence makes them necessary."

PATH_EXPANSION_STOPS =
  "Contradictory evidence remains an immediate stop. Stop and return control when any of the following applies: " \
  "the approved goal, accepted behavior, or acceptance criteria changes; the work adds unrelated work; it crosses " \
  "a repository or trust boundary; it requires a destructive or difficult-to-reverse action; it introduces " \
  "secrets, permissions, deployments, billing, or other external effects; it requires consequential architecture, " \
  "performance, compatibility, or product judgment; it materially changes security, privacy, compliance, or " \
  "release policy; it collides with another active lane and cannot be safely coordinated; it exposes consequential " \
  "ambiguity; or it weakens verification. An omitted path alone is not such a condition."

COMPACT_WORKER_CONTRACT =
  "Workers:paths=coord!=permission;path+resv;multi=>coord;contradiction/ambiguity/scope-risk/weak " \
  "verify=>stop;Verify live GitHub before edits;unverifiable facts are UNKNOWN"

WORKER_SUBAGENT_COORDINATION =
  "A sole active editor records the path and reason in the envelope or durable coordinator-owned lane record, " \
  "then the coordinator records the active reservation, refreshes authoritative file-touch maps, lane lifecycle " \
  "state, and active claims and collision checks, and reruns `batch-plan-preflight`; the worker continues without " \
  "user approval or a blocked lifecycle only after the preflight accepts. In a multi-editor wave, the worker " \
  "persists a typed expansion request, marks its durable lifecycle blocked, refreshes its heartbeat, emits a Lane " \
  "Card with path, reason, and request evidence reference, and pauses before changing the path. The coordinator " \
  "processes requests serially, records the active reservation, refreshes authoritative file-touch maps and lane " \
  "lifecycle state, reruns `batch-plan-preflight`, and resumes only after an accepted disjoint or " \
  "maximum-concurrency-one result. The reservation remains active until the verified file-touch map reflects the " \
  "path or the request is cancelled. A collision or `UNKNOWN` collision state remains stopped."

WORKER_SUBAGENT_RESTATEMENT =
  "With or without an envelope, contradictory evidence remains an immediate stop. Stop and return control when " \
  "any of the following applies: the approved goal, accepted behavior, or acceptance criteria changes; the work " \
  "adds unrelated work; it crosses a repository or trust boundary; it requires a destructive or " \
  "difficult-to-reverse action; it introduces secrets, permissions, deployments, billing, or other external " \
  "effects; it requires consequential architecture, performance, compatibility, or product judgment; it " \
  "materially changes security, privacy, compliance, or release policy; it collides with another active lane and " \
  "cannot be safely coordinated; it exposes consequential ambiguity; or it weakens verification. An omitted path " \
  "alone is not such a condition."

LANE_CARD_EXPANSION_SIGNAL =
  "`Path expansion:` `<canonical path|none>`; `reason:` `<known reason|n/a>`; `request_ref:` " \
  "`<durable evidence ref|n/a>`"

MATERIAL_SCOPE_GROWTH_STOP = "material semantic scope growth or material blast-radius growth"
NECESSARY_PATH_SCOPE_QUALIFIER =
  "Evidence-backed discovery of a necessary in-repository path alone is not such growth"

FULL_CONTRACT_SURFACES = {
  "skills/plan-pr-batch/SKILL.md" => File.join(ROOT, "skills/plan-pr-batch/SKILL.md"),
  "skills/pr-batch/SKILL.md" => File.join(ROOT, "skills/pr-batch/SKILL.md"),
  "workflows/pr-processing.md" => File.join(ROOT, "workflows/pr-processing.md"),
  "skills/triage/SKILL.md" => File.join(ROOT, "skills/triage/SKILL.md"),
  "docs/pr-batch-skills.md" => File.join(ROOT, "docs/pr-batch-skills.md")
}.freeze

COMPACT_SURFACES = FULL_CONTRACT_SURFACES.slice(
  "skills/plan-pr-batch/SKILL.md",
  "skills/pr-batch/SKILL.md",
  "workflows/pr-processing.md"
).freeze

class FileExpansionContractTest < Minitest::Test
  def setup
    @full_contract_surfaces = FULL_CONTRACT_SURFACES.transform_values { |path| File.read(path, encoding: "UTF-8") }
    @compact_surfaces = COMPACT_SURFACES.transform_values { |path| File.read(path, encoding: "UTF-8") }
  end

  def test_public_surfaces_allow_evidence_backed_in_repository_path_expansion
    @full_contract_surfaces.each do |label, text|
      normalized = text.gsub(/\s+/, " ")

      assert_includes normalized, PATH_EXPANSION_DEFAULT, label
      assert_includes normalized, PATH_EXPANSION_EXAMPLES, label
      assert_includes normalized, PATH_EXPANSION_STOPS, label
    end
  end

  def test_compact_worker_contracts_are_mirrored_and_do_not_block_on_a_missing_path
    contracts = @compact_surfaces.transform_values do |text|
      text.lines.grep(/^Workers:/).map(&:strip).uniq
    end

    contracts.each do |label, lines|
      assert_equal [COMPACT_WORKER_CONTRACT], lines, label
    end
    assert_includes COMPACT_WORKER_CONTRACT, "path+resv;multi=>coord"
    assert_includes COMPACT_WORKER_CONTRACT, "contradiction"
    assert_includes COMPACT_WORKER_CONTRACT, "unverifiable facts are UNKNOWN"
  end

  def test_worker_subagent_restatement_preserves_every_material_stop
    workflow = @full_contract_surfaces.fetch("workflows/pr-processing.md").gsub(/\s+/, " ")

    assert_includes workflow, WORKER_SUBAGENT_COORDINATION
    assert_includes workflow, WORKER_SUBAGENT_RESTATEMENT
    assert_includes workflow, LANE_CARD_EXPANSION_SIGNAL
  end

  def test_scope_summaries_distinguish_semantic_growth_from_necessary_path_discovery
    routing = File.read(File.join(ROOT, "docs/agent-workflows-model-routing.md"), encoding: "UTF-8").gsub(/\s+/, " ")
    context = File.read(File.join(ROOT, "CONTEXT.md"), encoding: "UTF-8").gsub(/\s+/, " ")

    assert_equal 2, routing.scan(MATERIAL_SCOPE_GROWTH_STOP).length
    assert_equal 2, routing.scan(NECESSARY_PATH_SCOPE_QUALIFIER).length
    assert_equal 2, routing.scan("(pr-batch-skills.md#implementation-batch-planning-flow)").length
    assert_includes context, "material semantic scope growth"
    assert_includes context, NECESSARY_PATH_SCOPE_QUALIFIER
    assert_includes context, "(docs/pr-batch-skills.md#implementation-batch-planning-flow)"
  end
end
