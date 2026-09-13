#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
REPLICATE_CI = File.join(ROOT, "skills/replicate-ci/SKILL.md")

class RunHistoryRecipeContractTest < Minitest::Test
  def setup
    @replicate_ci = File.read(REPLICATE_CI, encoding: "UTF-8")
    @recipe = @replicate_ci
              .split("## Hosted Run-History Recipe", 2).fetch(1)
              .split("## Preflight", 2).fetch(0)
  end

  def test_github_api_calls_are_bound_to_the_repository_host
    preamble = @recipe.split("```bash", 2).fetch(0)

    assert_equal 2, @recipe.scan(/gh api --hostname <HOST>/).length
    assert_includes preamble, "<HOST>"
  end

  def test_run_metadata_preserves_the_trigger_ref
    assert_match(/headBranch: \.head_branch/, @recipe)
    assert_match(/gh run view .* --json [^\n]*headBranch/, @recipe)
  end

  def test_attempt_jobs_expose_the_id_used_for_the_scoped_log_fetch
    assert_match(/\.jobs\[\] \| \{id: \.id,/, @recipe)
    assert_match(/gh run view <RUN_ID> .* --job <JOB_ID> --log/, @recipe)
  end
end
