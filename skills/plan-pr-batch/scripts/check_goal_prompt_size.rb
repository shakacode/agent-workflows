#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "check_goal_prompt_drift"

# The readable launch prompt is deliberately host-neutral. This guard protects
# that small interface; machine-readable batch state has its own contract tests.

TEXT_FENCE = "```text\n"
REPO_ROOT = File.expand_path("../../..", __dir__)
SOURCE_CHECKOUT_ENV = "AGENT_WORKFLOWS_SOURCE_CHECKOUT"
CODEX_GOAL_PROMPT_CHAR_LIMIT = 4_000
CLAUDE_GENERIC_GOAL_PROMPT_CHAR_LIMIT = 8_000
GOAL_PROMPT_MIN_HEADROOM = 300

EXPECTED_PROMPT = <<~TEXT
  Repository: OWNER/REPO
  Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
  Task name: <repository, work item, and purpose>
  Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
  Merge authority: <auto|ask>
  Human available after: <optional time; omit this line when not supplied>
TEXT

FORBIDDEN_PROMPT_FRAGMENTS = [
  "Lane Card:",
  "Launch:<",
  "PF:",
  "Manifest:",
  "Dispatch ",
  "Stage deps:",
  "GMCC-v5:",
  "HST-v1",
  "Batch QA Lane:",
  "Scope:",
  "ft=",
  "Items:",
  "Objective:",
  "Notes:",
  "Done:",
  "Execution rules:",
  "Workers:",
  "Final:",
  "Digest",
  "digest",
  "Selected",
  "Timestamp",
  "timestamp",
  "Observed",
  "observed",
  "Workflow",
  "workflow",
  "Coordination",
  "coordination",
  "none"
].freeze

COMMON_GUIDANCE_PHRASES = [
  "Fix issue #123 using $pr-batch with merge authority ask.",
  "accepted canonical issue or pull-request body",
  "later trusted maintainer comment",
  "Do not synthesize",
  "same readable prompt vocabulary for every host",
  "outside the human-authored prompt"
].freeze

LAUNCHER_RECORD_FIELDS = [
  "Run ID: <immutable unique per-execution run_id>",
  "Record destination: <exact issue or pull-request work-item URL authorized for every lane, or existing durable plan/backend destination authorized for every lane>",
  "Batch Plan binding: <SHA-256 of exact delivered UTF-8 plan bytes, or immutable reference plus exact revision/content digest>",
  "Prompt created at: <timestamp>",
  "Model at prompt creation: <observed value or UNKNOWN>",
  "Workflow at prompt creation: <version or UNKNOWN>",
  "Later workflow observations: <timestamped append-only entries or none>",
  "Target lanes:",
  "Lane: <lane id; repeat this entry once per planned target>",
  "Target: <exact issue, pull-request, or durable override identity>",
  "Replay identity: <existing lane_id, dispatcher, instance_id, and launch token>",
  "Prompt source: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>",
  "Selected at: <timestamp>",
  "Prompt digest at selection: <SHA-256 of the canonical source bytes fetched when selected; or not applicable — trusted-ad-hoc-override>",
  "Launched at: <timestamp or pending>",
  "Prompt digest at launch: <SHA-256 of the canonical source bytes re-fetched at launch or pending; or not applicable — trusted-ad-hoc-override>",
  "Worker started at: <timestamp or pending>",
  "Prompt digest observed by worker: <SHA-256 of the canonical source bytes re-fetched by the worker or pending; or not applicable — trusted-ad-hoc-override>",
  "Model observed by worker: <observed value or UNKNOWN>",
  "Workflow observed at worker start: <version or UNKNOWN>"
].freeze

def abort_with_failure(message)
  abort "FAIL: #{message}"
end

def read_repo_file(path)
  full_path = File.join(REPO_ROOT, path)
  abort_with_failure("#{path} not found at #{full_path}") unless File.file?(full_path)

  File.read(full_path, encoding: "UTF-8")
end

def extract_heading_prompt(text, heading, label)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  abort_with_failure("#{label} is missing #{heading}") unless heading_match

  extract_first_prompt(text[heading_match.end(0)..], label)
end

def extract_first_prompt(text, label)
  fence_start = text.index(TEXT_FENCE)
  abort_with_failure("#{label} is missing a text fence") unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  body_end = text.index(/^```[[:blank:]]*$/, body_start)
  abort_with_failure("#{label} is missing a closing fence") unless body_end

  text[body_start...body_end]
end

def extract_markdown_section(text, heading, label)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  abort_with_failure("#{label} is missing #{heading}") unless heading_match

  body_start = heading_match.end(0)
  heading_level = heading[/\A#+/].length
  next_heading = text.match(/^#{Regexp.escape('#' * heading_level)}\s+/, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def normalized(text)
  text.gsub(/\s+/, " ")
end

def require_phrases(text, phrases, label)
  normalized_text = normalized(text)
  phrases.each do |phrase|
    abort_with_failure("#{label} is missing phrase: #{phrase}") unless normalized_text.include?(phrase)
  end
end

def reject_phrases(text, phrases, label)
  phrases.each do |phrase|
    abort_with_failure("#{label} contains forbidden phrase: #{phrase}") if text.include?(phrase)
  end
end

plan_skill = read_repo_file("skills/plan-pr-batch/SKILL.md")
pr_batch_skill = read_repo_file("skills/pr-batch/SKILL.md")
triage_skill = read_repo_file("skills/triage/SKILL.md")
prompt_intake = read_repo_file("workflows/pr-batch-intake.md")
source_checkout = ENV[SOURCE_CHECKOUT_ENV] == "1"

prompt_intake_handoff = extract_markdown_section(
  prompt_intake,
  "## Plan To Goal Handoff",
  "prompt intake"
)

prompts = {
  "plan-pr-batch" => extract_heading_prompt(plan_skill, "## Goal Prompt for pr-batch", "plan-pr-batch"),
  "pr-batch" => extract_heading_prompt(pr_batch_skill, "## Goal Prompt Template", "pr-batch"),
  "prompt intake" => extract_first_prompt(prompt_intake_handoff, "prompt intake Plan To Goal Handoff")
}

unless prompts.values.uniq.length == 1
  abort_with_failure("canonical readable prompt templates must match exactly")
end

prompts.each do |label, prompt|
  reject_phrases(prompt, FORBIDDEN_PROMPT_FRAGMENTS, "#{label} prompt")
  abort_with_failure("#{label} prompt does not match the minimal human prompt") unless prompt == EXPECTED_PROMPT
end

{
  "skills/plan-pr-batch/SKILL.md" => plan_skill,
  "skills/pr-batch/SKILL.md" => pr_batch_skill,
  "skills/triage/SKILL.md" => triage_skill,
  "workflows/pr-batch-intake.md" => prompt_intake
}.each do |path, text|
  require_phrases(text, COMMON_GUIDANCE_PHRASES, path)
end

# Keep this example of ad hoc coordination diagnosis out of human-facing
# prompt guidance; it was never a canonical prompt field.
reject_phrases(
  [plan_skill, pr_batch_skill, triage_skill, prompt_intake].join("\n"),
  ["split-brain"],
  "readable-prompt guidance"
)

launcher_record = extract_markdown_section(
  prompt_intake,
  "## Launcher Run Record",
  "prompt intake"
)
require_phrases(
  launcher_record,
  [
    "field by field",
    "does not block launch",
    "collapsed `<details>`",
    "one entry for every planned target lane",
    "without replacing earlier values",
    "Reruns append a new collapsed record",
    "coordinator directly appends the cheap lane launch timestamp and digest",
    "existing immutable replay identity",
    "exactly matching `run_id`, replay identity, and `batch_plan_binding`",
    "not the deterministic launch token",
    "Do not add these fields to the human-authored prompt",
    "successful `pr-security-preflight` snapshot",
    "do not put the digest inside the bytes it hashes",
    "sole writer for that record",
    "workers return bound observation payloads",
    "Never put a private `plan-state://` or `batch://` identity in a public run record",
    "do not invent another snapshot, byte encoding, or record schema",
    "not applicable — trusted-ad-hoc-override",
    "`auto` maps to machine `auto_merge_when_gates_pass`; `ask` maps to machine `ask`",
    "machine-only `merge_authority: none`"
  ],
  "launcher run record"
)
require_phrases(launcher_record, LAUNCHER_RECORD_FIELDS, "launcher run record")

if source_checkout
  launcher_record_contract = read_repo_file("docs/github-task-prompts-and-run-records.md")
  require_phrases(launcher_record_contract, LAUNCHER_RECORD_FIELDS, "canonical launcher run record")
  require_phrases(
    launcher_record_contract,
    [
      "one exact canonical `record_destination` in the durable Batch Plan",
      "Each execution publishes exactly one `agent-launcher-run-record:v1` comment or durable record at that destination",
      "one compact visible state, one collapsed details block, and one unique entry per planned lane",
      "Reruns append a new outer record instead of replacing history",
      "`lane_id`, dispatcher, `instance_id`, and launch token",
      "A deterministic launch token is not unique across reruns and never substitutes for `run_id`",
      "does not inject outer identity, destination, or replay values into the helper",
      "not applicable — trusted-ad-hoc-override",
      "That worker-start value is immutable for the remainder of the run",
      "append a directly timestamped object to `workflow_versions.later_observations`"
    ],
    "canonical launcher run record"
  )
end

codex_prompt = "/goal\n#{prompts.fetch('plan-pr-batch')}"

if codex_prompt.length >= CODEX_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure("Codex goal prompt is #{codex_prompt.length} chars, must stay under #{CODEX_GOAL_PROMPT_CHAR_LIMIT}")
end
codex_headroom = CODEX_GOAL_PROMPT_CHAR_LIMIT - codex_prompt.length
if codex_headroom < GOAL_PROMPT_MIN_HEADROOM
  abort_with_failure("Codex goal prompt has #{codex_headroom} chars of headroom, must keep at least #{GOAL_PROMPT_MIN_HEADROOM}")
end
if prompts.fetch("plan-pr-batch").length >= CLAUDE_GENERIC_GOAL_PROMPT_CHAR_LIMIT
  abort_with_failure(
    "Claude/generic goal prompt is #{prompts.fetch('plan-pr-batch').length} chars, " \
    "must stay under #{CLAUDE_GENERIC_GOAL_PROMPT_CHAR_LIMIT}"
  )
end

begin
  GoalPromptDriftContract.check!(
    repo_root: REPO_ROOT,
    source_checkout: source_checkout
  )
rescue RuntimeError => e
  abort_with_failure(e.message)
end

puts "All checks passed."
puts "readable_goal_prompt_chars=#{prompts.fetch('plan-pr-batch').length}"
puts "codex_goal_prompt_chars=#{codex_prompt.length}"
