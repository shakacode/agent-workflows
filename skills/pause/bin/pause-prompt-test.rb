#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
TEXT_FENCE = "```text\n"

DOCS_PATH = File.join(ROOT, "docs/agent-runner-restarts.md")
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SKILL_PATH = File.join(ROOT, "skills/pause/SKILL.md")

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def extract_fenced_prompt(text, heading)
  heading_index = text.index(heading)
  raise "missing heading #{heading.inspect}" unless heading_index

  fence_start = text.index(TEXT_FENCE, heading_index)
  raise "missing text fence after #{heading.inspect}" unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  fence_end = text.index("\n```", body_start)
  raise "missing closing fence after #{heading.inspect}" unless fence_end

  text[body_start...fence_end]
end

def extract_restart_prompts(text)
  text.scan(/^```text\s*$\n(.*?)^```\s*$/m)
      .map(&:first)
      .select { |body| body.lstrip.start_with?("Resume", "Restart") }
end

class PausePromptTest < Minitest::Test
  def setup
    @docs = read_repo_file(DOCS_PATH)
    @workflow = read_repo_file(WORKFLOW_PATH)
    @skill = read_repo_file(SKILL_PATH)
  end

  def test_non_batch_pause_prompt_matches_docs
    docs_prompt = extract_fenced_prompt(@docs, "## Non-Batch Pause Prompt")
    skill_prompt = extract_fenced_prompt(@skill, "## Non-Batch Pause Prompt")

    assert_equal docs_prompt, skill_prompt
  end

  def test_non_batch_same_thread_resume_prompt_matches_docs
    docs_prompt = extract_fenced_prompt(@docs, "After restart, reopen the thread")
    skill_prompt = extract_fenced_prompt(@skill, "## Non-Batch Same-Thread Resume Prompt")

    assert_equal docs_prompt, skill_prompt
  end

  def test_non_batch_new_chat_restart_prompt_matches_docs
    docs_prompt = extract_fenced_prompt(@docs, "If the original thread cannot be reopened")
    skill_prompt = extract_fenced_prompt(@skill, "## Non-Batch New-Chat Restart Prompt")

    assert_equal docs_prompt, skill_prompt
  end

  def test_pr_batch_pause_prompt_matches_canonical_workflow
    workflow_prompt = extract_fenced_prompt(@workflow, "Before quitting the agent runner")
    skill_prompt = extract_fenced_prompt(@skill, "## PR-Batch Pause Prompt")

    assert_equal workflow_prompt, skill_prompt
  end

  def test_pr_batch_same_thread_resume_prompt_matches_docs
    docs_prompt = extract_fenced_prompt(@docs, "into every paused persistent batch thread")
    skill_prompt = extract_fenced_prompt(@skill, "## PR-Batch Same-Thread Resume Prompt")

    assert_equal docs_prompt, skill_prompt
  end

  def test_pr_batch_new_chat_restart_prompt_matches_docs
    docs_prompt = extract_fenced_prompt(@docs, "If a replacement worker must start in a new chat")
    skill_prompt = extract_fenced_prompt(@skill, "## PR-Batch New-Chat Restart Prompt")

    assert_equal docs_prompt, skill_prompt
  end

  def test_pause_skill_prints_copy_paste_restart_prompts
    assert_includes @skill, "new chat"
    assert_includes @skill, "<PASTE_RESTART_HANDOFF_HERE>"
    assert_includes @skill, "not inspect the repo"
    assert_includes @skill, "pause current work"
  end

  def test_every_restart_prompt_has_structural_managed_and_pinned_branches
    surfaces = {
      "skills/pause/SKILL.md" => [@skill, 4],
      "docs/agent-runner-restarts.md" => [@docs, 4],
      "workflows/pr-processing.md" => [@workflow, 1]
    }

    surfaces.each do |path, (text, expected_count)|
      prompts = extract_restart_prompts(text)
      assert_equal expected_count, prompts.length, path

      prompts.each.with_index(1) do |prompt, index|
        managed, pinned = extract_provider_branches(prompt, "#{path} prompt #{index}")

        assert_equal 1, managed.scan("agent-workflows-resolve begin").length
        assert_includes managed, "`resume_operation.revision`"
        assert_includes managed, "`originating_provider_revision`"
        assert_includes managed, "`resume_operation.assets.skills.pause`"
        refute_match(/(?<!resume_operation\.)\bassets\./, managed)
        assert_operator managed.index("`resume_operation.revision`"), :<,
                        managed.index("`resume_operation.assets.skills.pause`")

        refute_includes pinned, "agent-workflows-resolve begin"
        refute_includes pinned, "resume_operation"
        refute_match(/\bassets\./, pinned)
        assert_match(/continue only|stop before/i, pinned)

        assert_operator prompt.scan("agent-workflows-resolve begin").length, :<=, 1
        refute_match(/(?<!resume_operation\.)\bassets\./, prompt)
      end
    end
  end

  private

  def extract_provider_branches(prompt, label)
    managed_marker = "Managed provider branch:"
    pinned_marker = "Pinned or offline provider branch:"
    after_marker = "After provider branch selection:"
    managed_start = prompt.index(managed_marker)
    pinned_start = prompt.index(pinned_marker)
    after_start = prompt.index(after_marker)

    refute_nil managed_start, "#{label}: missing managed branch"
    refute_nil pinned_start, "#{label}: missing pinned branch"
    refute_nil after_start, "#{label}: missing post-selection boundary"
    assert_operator managed_start, :<, pinned_start, label
    assert_operator pinned_start, :<, after_start, label
    assert_match(%r{If metadata\s+is unavailable,\s+use\s+the\s+pinned/offline branch},
                 prompt[0...managed_start], label)

    managed = prompt[(managed_start + managed_marker.length)...pinned_start]
    pinned = prompt[(pinned_start + pinned_marker.length)...after_start]
    [managed, pinned]
  end
end
