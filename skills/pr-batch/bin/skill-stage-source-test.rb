#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/skill_stage_source"

STAGE_ROOT = File.expand_path("../../..", __dir__)
load File.join(STAGE_ROOT, "bin/validate-doc-links")

class SkillStageSourceTest < Minitest::Test
  def stage_files
    SkillStageSource::STAGES.flat_map do |skill, stages|
      ["skills/#{skill}/SKILL.md", *stages.map { |stage| "skills/#{skill}/references/#{stage}.md" }]
    end
  end

  def graph_errors(root, files = stage_files)
    files.flat_map do |relative|
      text = File.read(File.join(root, relative))
      ValidateDocLinks.links(text).flat_map do |target, line|
        next [] if target.match?(ValidateDocLinks::ABSOLUTE_TARGET)

        ValidateDocLinks.check_link(root, relative, target, line, {})
      end
    end
  end

  def with_skill
    Dir.mktmpdir("skill-stage") do |root|
      FileUtils.mkdir_p(File.join(root, "skills"))
      FileUtils.cp_r(File.join(STAGE_ROOT, "skills/pr-batch"), File.join(root, "skills"))
      yield root, File.join(root, "skills/pr-batch/SKILL.md")
    end
  end

  def test_source_stages_are_reachable_and_all_relative_links_and_anchors_resolve
    assert_empty graph_errors(STAGE_ROOT)
    SkillStageSource::STAGES.each_key do |skill|
      source = SkillStageSource.read(File.join(STAGE_ROOT, "skills", skill, "SKILL.md"))
      refute_includes source, "<!-- stage-reference:"
    end
  end

  def test_missing_direct_link_fails_despite_equivalent_prose_elsewhere
    with_skill do |root, path|
      text = File.read(path).sub("[Planning](references/planning.md)", "Planning")
      File.write(path, text + File.read(File.join(root, "skills/pr-batch/references/planning.md")))
      assert_raises(ArgumentError) { SkillStageSource.read(path) }
    end
  end

  def test_code_fenced_link_does_not_count_as_navigation
    with_skill do |_root, path|
      text = File.read(path).sub("[Planning](references/planning.md)", "`[Planning](references/planning.md)`")
      File.write(path, text)
      assert_raises(ArgumentError) { SkillStageSource.read(path) }
    end
  end

  def test_removed_declaration_cannot_be_replaced_with_decoy_text
    with_skill do |_root, path|
      File.write(path, File.read(path).sub(SkillStageSource::BLOCK, "decoy policy"))
      assert_raises(ArgumentError) { SkillStageSource.read(path) }
    end
  end

  def test_wrong_stage_target_or_anchor_fails
    %w[references/launch.md references/planning.md#missing-anchor].each do |target|
      with_skill do |_root, path|
        File.write(path, File.read(path).sub("[Planning](references/planning.md)", "[Planning](#{target})"))
        assert_raises(ArgumentError) { SkillStageSource.read(path) }
      end
    end
  end

  def test_missing_stage_file_fails
    with_skill do |root, path|
      File.unlink(File.join(root, "skills/pr-batch/references/planning.md"))
      assert_raises(Errno::ENOENT) { SkillStageSource.read(path) }
    end
  end

  def test_stage_internal_anchor_is_checked_in_its_real_file
    with_skill do |root, _path|
      relative = "skills/pr-batch/references/planning.md"
      File.write(File.join(root, relative), "# Planning\n\n[Missing](#missing-anchor)\n")
      assert_match(/heading anchor not found/, graph_errors(root, [relative]).join)
    end
  end

  def test_goal_templates_come_from_the_exact_linked_stage
    %w[plan-pr-batch pr-batch].each do |skill|
      path = File.join(STAGE_ROOT, "skills", skill, "SKILL.md")
      assert_equal File.read(File.join(File.dirname(path), "references/prompt-template.md")),
                   SkillStageSource.stage(path, "prompt-template")
      refute_includes File.read(path), "/goal\n"
    end
  end

  def test_entrypoint_guards_remain_visible_without_expanding_stages
    guards = {
      "pr-batch" => ["pr-batch-intake.md", "pr-batch-security-floor.md", "pr-batch-task-review.md",
                     "Merge Assurance Gate", "Checker independence", "sole user-facing coordinator"],
      "address-review" => ["before triage or mutation", "ownership, authority", "current-head evidence"],
      "plan-pr-batch" => ["Do not implement items here", "before dispatch", "Planning alone does not dispatch"],
      "post-merge-audit" => ["independent checker", "current complete evidence", "coordinator publishes"]
    }
    guards.each do |skill, phrases|
      text = File.read(File.join(STAGE_ROOT, "skills", skill, "SKILL.md")).downcase
      assert_operator text.lines.length, :<, 400, "#{skill} must remain a stage entrypoint"
      phrases.each { |phrase| assert_includes text, phrase.downcase, skill }
    end
  end
end
