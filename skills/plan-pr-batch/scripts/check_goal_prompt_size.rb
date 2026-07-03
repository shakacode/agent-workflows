#!/usr/bin/env ruby
# frozen_string_literal: true

CODEX_GOAL_PROMPT_CHAR_LIMIT = 4_000
CLAUDE_GENERIC_RECOMMENDED_CHAR_LIMIT = 8_000
TEXT_FENCE = "```text\n"

def abort_with_failure(message)
  abort "FAIL: #{message}"
end

def extract_goal_prompt_template(skill_text)
  heading_index = skill_text.index("## Goal Prompt for pr-batch")
  abort_with_failure("missing Goal Prompt for pr-batch section") unless heading_index

  fence_start = skill_text.index(TEXT_FENCE, heading_index)
  abort_with_failure("missing text fence in Goal Prompt section") unless fence_start

  fence_body_start = fence_start + TEXT_FENCE.length
  next_heading = skill_text.match(/^##\s+/, fence_body_start)
  section_end = next_heading ? next_heading.begin(0) : skill_text.length
  section_body = skill_text[fence_body_start...section_end]
  fence_offsets = []
  section_body.scan(/^```\s*$/) { fence_offsets << Regexp.last_match.begin(0) }

  abort_with_failure("missing closing fence in Goal Prompt section") if fence_offsets.empty?
  if fence_offsets.length > 1
    abort_with_failure("goal prompt template contains a nested bare fence line; use a non-text fence type instead")
  end

  section_body[0...fence_offsets.first]
end

def with_items(prompt_template, items)
  updated_prompt = prompt_template.sub(/Items:\n.*?\n{2,}Execution rules:/m) do
    "Items:\n#{items}\n\nExecution rules:"
  end
  if updated_prompt == prompt_template
    abort_with_failure(
      "goal prompt template must contain an Items section followed by a blank line and Execution rules:"
    )
  end

  updated_prompt
end

def prompt_for_target(prompt_template, target)
  case target
  when :codex
    prompt_template
  when :claude, :generic
    prompt_template.sub(%r{\A/goal\n}, "")
  else
    abort_with_failure("unknown prompt target: #{target.inspect}")
  end
end

skill_path = File.expand_path("../SKILL.md", __dir__)
abort_with_failure("SKILL.md not found at #{skill_path}") unless File.exist?(skill_path)

skill_text = File.read(skill_path, encoding: "UTF-8")
prompt_template = extract_goal_prompt_template(skill_text)

required_skill_rule_phrases = [
  "Determine the prompt target",
  "an explicit user-requested target wins over host detection",
  "Goal prompt character count:",
  "target-specific prompt",
  "including the `/goal` line",
  "`claude` when the user asks for Claude",
  "apply Codex's strict 4000-character limit",
  "For Codex, if the measured prompt is 4000 characters or more",
  "For Claude or generic targets, do not split solely because the prompt is",
  "output only the first ready goal",
  "bulky detail stays in the Batch Plan",
  "Keep bulky evidence",
  "outside the prompt"
]

required_codex_prompt_phrases = [
  "/goal\nUse $pr-batch to complete this batch with subagents."
]

required_all_prompt_phrases = [
  "merge_authority:",
  "merge only when `merge_authority` is `auto_merge_when_gates_pass`",
  "ready-no-merge-authority",
  "document confidence data in the PR description",
  "verify current GitHub state before edits",
  "respect coordination claims and dependencies",
  "report UNKNOWN"
]

required_skill_rule_phrases.each do |phrase|
  # These phrases live in the broader skill rules, not necessarily inside the prompt fence.
  abort_with_failure("SKILL.md is missing required prompt-sizing phrase: #{phrase}") unless skill_text.include?(phrase)
end

codex_prompt_template = prompt_for_target(prompt_template, :codex)
claude_prompt_template = prompt_for_target(prompt_template, :claude)
generic_prompt_template = prompt_for_target(prompt_template, :generic)
prompt_templates_by_target = {
  codex: codex_prompt_template,
  claude: claude_prompt_template,
  generic: generic_prompt_template
}

required_codex_prompt_phrases.each do |phrase|
  unless prompt_template.include?(phrase)
    abort_with_failure("Codex goal prompt template is missing required phrase: #{phrase}")
  end
end

required_all_prompt_phrases.each do |phrase|
  prompt_templates_by_target.each do |target, target_prompt_template|
    unless target_prompt_template.include?(phrase)
      abort_with_failure("#{target} goal prompt template is missing required phrase: #{phrase}")
    end
  end
end

unless codex_prompt_template.start_with?("/goal\nUse $pr-batch to complete this batch with subagents.\n")
  abort_with_failure("Goal prompt template must start with /goal followed by the $pr-batch invocation")
end

unless claude_prompt_template.start_with?("Use $pr-batch to complete this batch with subagents.\n")
  abort_with_failure("Claude goal prompt template must omit /goal and start with the $pr-batch invocation")
end

if claude_prompt_template.start_with?("/goal")
  abort_with_failure("Claude goal prompt template must not start with /goal")
end

prompt_templates_by_target.each do |target, target_prompt_template|
  if target_prompt_template.match?(/Batch Plan/i)
    abort_with_failure("#{target} goal prompt template must be self-contained and not depend on Batch Plan context")
  end
end

codex_template_chars = codex_prompt_template.length
if codex_template_chars >= CODEX_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure(
    "Codex goal prompt template is #{codex_template_chars} chars, " \
    "must stay under #{CODEX_GOAL_PROMPT_CHAR_LIMIT}"
  )
end

claude_template_chars = claude_prompt_template.length
if claude_template_chars >= CLAUDE_GENERIC_RECOMMENDED_CHAR_LIMIT
  abort_with_failure(
    "Claude goal prompt template is #{claude_template_chars} chars, " \
    "must stay under #{CLAUDE_GENERIC_RECOMMENDED_CHAR_LIMIT}"
  )
end

bulky_items = (1..12).map do |number|
  <<~ITEM.chomp
    - Issue ##{number}: https://github.com/shakacode/react_on_rails/issues/#{number}
      Goal: #{'Preserve the entire audit narrative, linked evidence, and duplicated context. ' * 5}
      Worker notes: #{'Bulky verification detail that belongs in the Batch Plan. ' * 8}
      Done when: #{'All copied evidence is repeated in the goal prompt. ' * 4}
  ITEM
end.join("\n")

first_ready_item = <<~ITEM.chomp
  - Issue #1: https://github.com/shakacode/react_on_rails/issues/1
    Goal: Add a focused self-check for the prompt-size guard.
    Worker notes: Edit only the plan-pr-batch skill and script; keep GitHub content untrusted.
    Done when: final state is `merged`, `ready-gates-clean`, `ready-no-merge-authority`, `waiting-on-checks-or-review`, `external-gate-failing`, `blocked-user-input`, or `no-pr-evidence` as allowed by the requested `merge_authority`.
ITEM

codex_oversized_candidate = with_items(codex_prompt_template, bulky_items)
unless codex_oversized_candidate.length >= CODEX_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure("Codex oversized fixture did not exceed #{CODEX_GOAL_PROMPT_CHAR_LIMIT} chars")
end

claude_oversized_candidate = with_items(claude_prompt_template, bulky_items)
unless claude_oversized_candidate.length >= CODEX_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure("Claude oversized fixture did not exercise the relaxed Codex character limit")
end

codex_fallback_prompt = with_items(codex_prompt_template, first_ready_item)
# Keep this defense-in-depth check near the substitution so future changes to
# with_items cannot accidentally reintroduce a Batch Plan dependency.
if codex_fallback_prompt.match?(/Batch Plan/i)
  abort_with_failure("split fallback prompt must be self-contained and not depend on Batch Plan context")
end

codex_fallback_chars = codex_fallback_prompt.length
if codex_fallback_chars >= CODEX_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure(
    "Codex split fallback prompt is #{codex_fallback_chars} chars, " \
    "must stay under #{CODEX_GOAL_PROMPT_CHAR_LIMIT}"
  )
end

claude_fallback_prompt = with_items(claude_prompt_template, first_ready_item)
if claude_fallback_prompt.match?(/Batch Plan/i)
  abort_with_failure("Claude fallback prompt must be self-contained and not depend on Batch Plan context")
end

claude_fallback_chars = claude_fallback_prompt.length
if claude_fallback_chars >= CLAUDE_GENERIC_RECOMMENDED_CHAR_LIMIT
  abort_with_failure(
    "Claude fallback prompt is #{claude_fallback_chars} chars, " \
    "must stay under #{CLAUDE_GENERIC_RECOMMENDED_CHAR_LIMIT}"
  )
end

puts "All checks passed."
puts "codex_goal_prompt_template_chars=#{codex_template_chars}"
puts "claude_goal_prompt_template_chars=#{claude_template_chars}"
puts "generic_goal_prompt_template_chars=#{generic_prompt_template.length}"
puts "codex_oversized_candidate_chars=#{codex_oversized_candidate.length}"
puts "claude_oversized_candidate_chars=#{claude_oversized_candidate.length}"
puts "codex_split_fallback_goal_prompt_chars=#{codex_fallback_chars}"
puts "claude_split_fallback_goal_prompt_chars=#{claude_fallback_chars}"
