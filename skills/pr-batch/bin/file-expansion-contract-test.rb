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
  "maps and lane lifecycle state, and reruns `batch-plan-preflight`. For every multi-editor request, acceptance " \
  "alone does not authorize resume: the requester must durably transition out of `blocked`, a fresh preflight " \
  "must accept, and the requester must be absent from `launch.held_lane_ids`; when launch or relaunch is needed, " \
  "it must also be present in `launch.eligible_lane_ids`. Under maximum-concurrency-one serialization, the current " \
  "holder must also release the slot before resume. The reservation persists until " \
  "the verified PR file-touch map contains the path or the request is cancelled, and it is removed once reflected " \
  "or cancelled. A collision or `UNKNOWN` collision state remains stopped until then. A missing path alone is not " \
  "material scope growth and must not produce `blocked-user-input`."

PATH_EXPANSION_EXAMPLES =
  "Necessary additions can include contract or type files, tests or fixtures, offline demo stubs, and build or " \
  "generated integration surfaces when repository evidence makes them necessary."

RENAME_RESERVATION_RULE =
  "Directory renames use a distinct `expansion-rename-reservation` v1 record with canonical, distinct `old` and " \
  "`new` endpoints; only this typed rename form adds ancestor/descendant collision checks, while scalar path " \
  "reservations remain exact-path collision controls."

PATH_EXPANSION_STOPS =
  "Contradictory evidence remains an immediate stop. Stop and return control when any of the following applies: " \
  "the approved goal, accepted behavior, or acceptance criteria changes; the work adds unrelated work; it crosses " \
  "a repository or trust boundary; it requires a destructive or difficult-to-reverse action; it introduces " \
  "secrets, permissions, deployments, billing, or other external effects; it requires consequential architecture, " \
  "performance, compatibility, or product judgment; it materially changes security, privacy, compliance, or " \
  "release policy; it collides with another active lane and cannot be safely coordinated; it exposes consequential " \
  "ambiguity; or it weakens verification. An omitted path alone is not such a condition."

COMPRESSED_WORKER_RESTATEMENT =
  "Workers:paths=coord!=perm;path+resv;multi=>coord;stop:contradiction/ambig/scope-risk/" \
  "verify-down;Verify live GitHub before edits;unverifiable=>UNKNOWN"

MATERIAL_SCOPE_GROWTH_STOP = "material semantic scope growth or material blast-radius growth"
NECESSARY_PATH_SCOPE_QUALIFIER =
  "Evidence-backed discovery of a necessary in-repository path alone is not such growth"

PLANNING_CONTRACT_SURFACES = {
  "skills/plan-pr-batch/SKILL.md" => File.join(ROOT, "skills/plan-pr-batch/SKILL.md"),
  "skills/triage/SKILL.md" => File.join(ROOT, "skills/triage/SKILL.md"),
  "docs/pr-batch-skills.md" => File.join(ROOT, "docs/pr-batch-skills.md")
}.freeze

PROMPT_AUTHORING_SURFACES = %w[
  skills/plan-pr-batch/SKILL.md
  skills/pr-batch/SKILL.md
  workflows/pr-processing.md
].to_h { |path| [path, File.join(ROOT, path)] }.freeze

WORKER_EXECUTION_PATH = File.join(ROOT, "workflows/pr-batch-worker-execution.md")

class FileExpansionContractTest < Minitest::Test
  def setup
    @planning_contract_surfaces = PLANNING_CONTRACT_SURFACES.transform_values do |path|
      File.read(path, encoding: "UTF-8")
    end
    @prompt_authoring_surfaces = PROMPT_AUTHORING_SURFACES.transform_values do |path|
      File.read(path, encoding: "UTF-8")
    end
    @worker_execution = File.read(WORKER_EXECUTION_PATH, encoding: "UTF-8")
  end

  def test_public_surfaces_allow_evidence_backed_in_repository_path_expansion
    @planning_contract_surfaces.each do |label, text|
      normalized = text.gsub(/\s+/, " ")

      assert_includes normalized, PATH_EXPANSION_DEFAULT, label
      assert_includes normalized, PATH_EXPANSION_EXAMPLES, label
      assert_includes normalized, RENAME_RESERVATION_RULE, label
      assert_includes normalized, PATH_EXPANSION_STOPS, label
    end
  end

  def test_human_prompt_surfaces_drop_the_compressed_worker_restatement
    @prompt_authoring_surfaces.each do |label, text|
      refute_includes text, COMPRESSED_WORKER_RESTATEMENT, label
    end
  end

  def test_worker_subagent_restatement_preserves_every_material_stop
    contract = @worker_execution.gsub(/\s+/, " ")

    assert_includes contract, "active typed `expansion-path-reservation`"
    assert_includes contract, "For a sole active editor"
    assert_includes contract, "In a multi-editor wave"
    assert_includes contract, "`launch.held_lane_ids`"
    assert_includes contract, "`expansion-rename-reservation`"
    assert_includes contract, "An omitted path alone is not material scope growth"
    assert_includes contract, "Stop at a safe checkpoint when contradictory evidence appears"
    assert_includes contract, "`Path expansion:` `<canonical path|none>`"
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
