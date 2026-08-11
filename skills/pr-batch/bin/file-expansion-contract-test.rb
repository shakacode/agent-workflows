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
  "Workers:paths=coord!=permission;path+log/check/go;contradiction/material risk/ambiguity/weakened " \
  "verify=>stop;Verify live GitHub before edits;unverified facts are UNKNOWN"

SURFACES = {
  "skills/plan-pr-batch/SKILL.md" => File.join(ROOT, "skills/plan-pr-batch/SKILL.md"),
  "skills/pr-batch/SKILL.md" => File.join(ROOT, "skills/pr-batch/SKILL.md"),
  "workflows/pr-processing.md" => File.join(ROOT, "workflows/pr-processing.md")
}.freeze

class FileExpansionContractTest < Minitest::Test
  def setup
    @surfaces = SURFACES.transform_values { |path| File.read(path, encoding: "UTF-8") }
  end

  def test_public_surfaces_allow_evidence_backed_in_repository_path_expansion
    @surfaces.each do |label, text|
      normalized = text.gsub(/\s+/, " ")

      assert_includes normalized, PATH_EXPANSION_DEFAULT, label
      assert_includes normalized, PATH_EXPANSION_EXAMPLES, label
      assert_includes normalized, PATH_EXPANSION_STOPS, label
    end
  end

  def test_compact_worker_contracts_are_mirrored_and_do_not_block_on_a_missing_path
    contracts = @surfaces.transform_values do |text|
      text.lines.grep(/^Workers:/).map(&:strip).uniq
    end

    contracts.each do |label, lines|
      assert_equal [COMPACT_WORKER_CONTRACT], lines, label
    end
    assert_includes COMPACT_WORKER_CONTRACT, "path+log/check/go"
    assert_includes COMPACT_WORKER_CONTRACT, "contradiction"
    assert_includes COMPACT_WORKER_CONTRACT, "unverified facts are UNKNOWN"
  end
end
