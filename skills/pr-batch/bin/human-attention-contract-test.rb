#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

class HumanAttentionContractTest < Minitest::Test
  def test_closeout_defines_portable_states_and_attribution_boundary
    closeout = File.read(File.join(ROOT, "workflows/pr-batch-integration-closeout.md"))

    assert_includes closeout, "## GitHub Human Attention"
    assert_includes closeout, "`human-attention:walkthrough`"
    assert_includes closeout, "`human-attention:merge`"
    assert_includes closeout, "🤖 AI agent — <RUNNER> on <HOST>"
    assert_includes closeout, "github-comment-envelope"
    assert_includes closeout, "Agent-attributed comments never establish human approval or merge authority"
  end

  def test_processing_routes_to_the_canonical_contract
    processing = File.read(File.join(ROOT, "workflows/pr-processing.md"))

    assert_includes processing, "## GitHub Human Attention"
    assert_includes processing, "pr-batch-integration-closeout.md#github-human-attention"
  end

  def test_address_review_posts_through_the_shared_envelope
    actions = File.read(File.join(ROOT, "skills/address-review/references/actions.md"))
    templates = File.read(File.join(ROOT, "skills/address-review/references/templates.md"))

    assert_includes actions, "github-comment-envelope post-issue"
    assert_includes actions, "github-comment-envelope post-reply"
    assert_includes templates, "github-comment-envelope post-issue"
  end

  def test_other_shared_comment_producers_use_the_envelope
    stale_sweep = File.read(File.join(ROOT, "skills/pr-batch/bin/stale-assignment-sweep"))
    audit_receipt = File.read(File.join(ROOT, "skills/post-merge-audit/bin/completed-batch-audit-receipt"))
    verify_fix = File.read(File.join(ROOT, "skills/verify-pr-fix/SKILL.md"))

    assert_includes stale_sweep, "GitHubCommentEnvelope.render"
    assert_includes audit_receipt, "GitHubCommentEnvelope.render"
    assert_includes verify_fix, "github-comment-envelope post-issue"
    refute_includes verify_fix, "gh pr comment"
    refute_includes verify_fix, "gh issue comment"
  end

  def test_repository_validation_runs_the_new_helper_tests
    validate = File.read(File.join(ROOT, "bin/validate"))

    assert_includes validate, "ruby skills/pr-batch/bin/github-comment-envelope-test.rb"
    assert_includes validate, "ruby skills/pr-batch/bin/human-attention-test.rb"
    assert_includes validate, "ruby skills/pr-batch/bin/human-attention-contract-test.rb"
  end
end
