#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

PATH_EXPANSION_DEFAULT =
  "Necessary in-repository path expansion defaults to allowed when repository evidence shows an added path " \
  "is reasonably necessary to complete the already-authorized goal or its required validation. Treat owned " \
  "paths and the execution envelope as coordination and collision controls, not as a user-permission boundary. " \
  "Before changing the added path, record the path and reason in the lane envelope, refresh active-lane claim " \
  "and collision checks, and continue without user approval when they are clear. A missing path alone is not " \
  "material scope growth and must not produce `blocked-user-input`."

PATH_EXPANSION_EXAMPLES =
  "Necessary additions can include contract or type files, tests or fixtures, offline demo stubs, and build or " \
  "generated integration surfaces when repository evidence makes them necessary."

PATH_EXPANSION_STOPS =
  "Contradictory evidence remains an immediate stop. Stop and return control for path expansion that changes " \
  "the approved goal, accepted behavior, or acceptance criteria; adds unrelated work; crosses a repository or " \
  "trust boundary; requires a destructive or difficult-to-reverse action; introduces secrets, permissions, " \
  "deployments, billing, or other external effects; requires consequential architecture, performance, " \
  "compatibility, or product judgment; materially changes security, privacy, compliance, or release policy; " \
  "collides with another active lane and cannot be safely coordinated; exposes consequential ambiguity; or " \
  "weakens verification."

COMPACT_WORKER_CONTRACT =
  "Workers:paths=coord!=permission;path+log/check/go;contradiction/ambiguity/scope-risk/weakened " \
  "verify=>stop;Verify live GitHub before edits;unverifiable facts are UNKNOWN"

WORKER_SUBAGENT_RESTATEMENT =
  "With or without an envelope, contradictory evidence remains an immediate stop. Stop and return control when " \
  "path expansion changes the approved goal, accepted behavior, or acceptance criteria; adds unrelated " \
  "work; crosses a repository " \
  "or trust boundary; requires a destructive or difficult-to-reverse action; introduces secrets, permissions, " \
  "deployments, billing, or other external effects; requires consequential architecture, performance, " \
  "compatibility, or product judgment; materially changes security, privacy, compliance, or release policy; " \
  "collides with another active lane and cannot be safely coordinated; exposes consequential ambiguity; or " \
  "weakens verification. An omitted path alone is not such a condition."

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
    assert_includes COMPACT_WORKER_CONTRACT, "path+log/check/go"
    assert_includes COMPACT_WORKER_CONTRACT, "contradiction"
    assert_includes COMPACT_WORKER_CONTRACT, "unverifiable facts are UNKNOWN"
  end

  def test_worker_subagent_restatement_preserves_every_material_stop
    workflow = @full_contract_surfaces.fetch("workflows/pr-processing.md").gsub(/\s+/, " ")

    assert_includes workflow, WORKER_SUBAGENT_RESTATEMENT
  end
end
