#!/usr/bin/env ruby
# frozen_string_literal: true

GOAL_PROMPT_CHAR_LIMIT = 4_000
TEXT_FENCE = "```text\n"
REPO_ROOT = File.expand_path("../../..", __dir__)

CANONICAL_RESUME_SNIPPET = <<~TEXT.chomp
  Resume batch processing now.

  Re-read your restart handoff and run the bounded status recovery steps described under "Pausing For An Agent-Runner Restart" in the installed `pr-processing.md` workflow before editing, pushing, polling, or starting any new target.
TEXT

CANONICAL_CONTINUATION_SNIPPET_PHRASES = [
  "Use $pr-batch to continue PR-batch closeout, not to start a new implementation batch.",
  "determine the exact targets from the visible request, pasted handoff, PR URLs, GitHub shorthand refs, or final-bucket table",
  "Extract only explicit PR/issue refs such as OWNER/REPO#123, PR #123, issue #123, or GitHub URLs.",
  "Exclude anything explicitly marked excluded, deferred, next-major, out of scope, or not part of this batch.",
  "Do not broaden to all open PRs, labels, milestones, or inferred related work unless I explicitly ask for discovery.",
  "If extracted targets have mixed states, split internally by action type: checks/review polling, conflict recovery, draft/product-decision blockers, and excluded/deferred items.",
  "Mode: continue from live GitHub state; previous handoffs are stale hints only.",
  "Re-fetch every target's current head SHA, branch, draft status, merge state, conflicts/behind state, review decision, unresolved current-head review threads, configured review-agent state, and current-head checks.",
  "Do not mark the overall goal complete while any target is `waiting-on-checks-or-review`, has pending/missing/untriaged current-head checks or configured review agents, unresolved current-head review threads, fixable failures, or `UNKNOWN`.",
  "Terminal states allowed: `merged`, `ready-no-merge-authority`, `blocked-user-input` with exact question/thread URL, `external-gate-failing` with evidence and no local fix, or `no-pr-evidence` where applicable.",
  "Final handoff must include detected target list, links, tests, blockers, next action, confidence/UNKNOWN, QA evidence, merge_authority, and per-target terminal state."
].freeze

PRESSURE_SCENARIOS = [
  "A handoff containing final buckets for PRs #4259, #4260, #4277, #4278, and #4282 extracts exactly those five targets and excludes explicitly deferred/excluded PRs.",
  "A mixed-state handoff containing #4283, #4281, #4268, #4266, and #4264 splits checks/review polling from draft/product-decision blockers and conflict recovery.",
  "A pasted handoff with no exact PR/issue refs stops and asks for targets instead of broadening to all open PRs.",
  "A normal resume prompt routes to bounded status recovery, not cancellation/relaunch."
].freeze

def abort_with_failure(message)
  abort "FAIL: #{message}"
end

def read_repo_file(path)
  File.read(File.join(REPO_ROOT, path), encoding: "UTF-8")
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

skill_path = File.expand_path("../SKILL.md", __dir__)
abort_with_failure("SKILL.md not found at #{skill_path}") unless File.exist?(skill_path)

skill_text = File.read(skill_path, encoding: "UTF-8")
prompt_template = extract_goal_prompt_template(skill_text)
workflow_text = read_repo_file("workflows/pr-processing.md")

required_skill_rule_phrases = [
  "Goal prompt character count:",
  "If the measured prompt is 4000 characters or more",
  "output only the first ready goal",
  "bulky detail stays in the Batch Plan",
  "Keep bulky evidence",
  "outside the prompt"
]

required_prompt_phrases = [
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

required_prompt_phrases.each do |phrase|
  unless prompt_template.include?(phrase)
    abort_with_failure("Goal prompt template is missing required phrase: #{phrase}")
  end
end

unless workflow_text.include?(CANONICAL_RESUME_SNIPPET)
  abort_with_failure("canonical workflow is missing the exact restart resume snippet")
end

CANONICAL_CONTINUATION_SNIPPET_PHRASES.each do |phrase|
  unless workflow_text.include?(phrase)
    abort_with_failure("canonical workflow continuation snippet is missing phrase: #{phrase}")
  end
end

PRESSURE_SCENARIOS.each do |scenario|
  unless workflow_text.include?(scenario)
    abort_with_failure("canonical workflow is missing pressure scenario: #{scenario}")
  end
end

if prompt_template.match?(/Batch Plan/i)
  abort_with_failure("goal prompt template must be self-contained and not depend on Batch Plan context")
end

template_chars = prompt_template.length
if template_chars >= GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure("goal prompt template is #{template_chars} chars, must stay under #{GOAL_PROMPT_CHAR_LIMIT}")
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

oversized_candidate = with_items(prompt_template, bulky_items)
abort_with_failure("oversized fixture did not exceed 4000 chars") unless oversized_candidate.length >= 4_000

fallback_prompt = with_items(prompt_template, first_ready_item)
# Keep this defense-in-depth check near the substitution so future changes to
# with_items cannot accidentally reintroduce a Batch Plan dependency.
if fallback_prompt.match?(/Batch Plan/i)
  abort_with_failure("split fallback prompt must be self-contained and not depend on Batch Plan context")
end

fallback_chars = fallback_prompt.length
if fallback_chars >= GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure("split fallback prompt is #{fallback_chars} chars, must stay under #{GOAL_PROMPT_CHAR_LIMIT}")
end

puts "All checks passed."
puts "goal_prompt_template_chars=#{template_chars}"
puts "oversized_candidate_chars=#{oversized_candidate.length}"
puts "split_fallback_goal_prompt_chars=#{fallback_chars}"
