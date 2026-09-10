#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

class HumanAttentionContractTest < Minitest::Test
  def test_closeout_routes_human_attention_and_attribution_helpers
    closeout = File.read(File.join(ROOT, "workflows/pr-batch-integration-closeout.md"))
    human_attention = closeout[/\n## GitHub Human Attention\n.*?\n## /m]

    refute_nil human_attention
    assert_includes human_attention, "`walkthrough`"
    assert_includes human_attention, "`merge`"
    refute_includes human_attention, "`human-attention:walkthrough`"
    refute_includes human_attention, "`human-attention:merge`"
    assert_includes closeout, "${PR_BATCH_SKILL_DIR}/bin/human-attention"
    assert_includes closeout, "--repo-root"
    assert_includes closeout, "github-comment-envelope"
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

  def test_address_review_filters_primary_checkpoints_through_unwrapped_payloads
    workflow = File.read(File.join(ROOT, "workflows/address-review.md"))
    filter_step = workflow[/\n5\. Filter comments:\n.*?\n6\./m]

    refute_nil filter_step
    assert_includes filter_step, ".payload_body // .body // \"\""
  end

  def test_other_shared_comment_producers_use_the_envelope
    stale_sweep = File.read(File.join(ROOT, "skills/pr-batch/bin/stale-assignment-sweep"))
    audit_receipt = File.read(File.join(ROOT, "skills/post-merge-audit/bin/completed-batch-audit-receipt"))
    verify_fix = File.read(File.join(ROOT, "skills/verify-pr-fix/SKILL.md"))

    assert_includes stale_sweep, "GitHubCommentEnvelope.render"
    assert_includes audit_receipt, "GitHubCommentEnvelope.render"
    assert_includes verify_fix, "github-comment-envelope post-issue"
    assert_includes verify_fix, "PR_BATCH_SKILL_DIR"
    assert_includes verify_fix, "${PR_BATCH_SKILL_DIR}/bin/github-comment-envelope"
    assert_equal 2, verify_fix.scan("${PR_BATCH_SKILL_DIR}/bin/github-comment-envelope").length
    refute_includes verify_fix, "gh pr comment"
    refute_includes verify_fix, "gh issue comment"
  end

  def test_post_merge_audit_documents_comment_attribution_context
    skill = File.read(File.join(ROOT, "skills/post-merge-audit/SKILL.md"))
    workflow = File.read(File.join(ROOT, "workflows/post-merge-audit.md"))

    %w[AGENT_COMMENT_RUNNER AGENT_COMMENT_HOST AGENT_COMMENT_TASK_OR_RUN].each do |variable|
      assert_includes skill, variable
      assert_includes workflow, variable
    end
  end

  def test_repository_validation_runs_the_new_helper_tests
    validate = File.read(File.join(ROOT, "bin/validate"))

    assert_includes validate, "ruby skills/pr-batch/bin/github-comment-envelope-test.rb"
    assert_includes validate, "ruby skills/pr-batch/bin/human-attention-test.rb"
    assert_includes validate, "ruby skills/pr-batch/bin/human-attention-contract-test.rb"
  end
end
