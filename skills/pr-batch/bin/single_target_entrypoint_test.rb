# frozen_string_literal: true

ROOT = File.expand_path("../../..", __dir__)

def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def assert(condition, message)
  abort("FAIL: #{message}") unless condition
end

batch = read_repo_file("skills/pr-batch/SKILL.md")
lane = read_repo_file("skills/pr-lane/SKILL.md")
guide = read_repo_file("docs/pr-batch-skills.md")

assert(batch.include?("A single target is\na batch of one"), "pr-batch must own single-target mode")
assert(batch.include?("dispatch one\n  worker subagent"), "single-target mode must default to a worker subagent")
assert(batch.include?("Do not silently default it"), "single-target mode must require explicit merge authority")
assert(batch.include?("fastest or balanced worker route"), "single-target mode must use cost-aware staged routing")
assert(batch.include?("verified head branch cannot be pushed"), "single-target PR mode must preserve the unpushable-head fallback")
assert(batch.include?("replacement branch/PR"), "single-target PR mode must explain the replacement path")
assert(batch.include?("for one direct-prompt task, the derived `adhoc:<yyyymmdd>-<short-slug>`"), "the required interview must accept ad-hoc targets")

assert(lane.include?("backward-compatibility alias"), "pr-lane must identify itself as an alias")
assert(lane.include?("Immediately load and follow `$pr-batch`"), "pr-lane must route to pr-batch")
assert(lane.include?("from `PR_BATCH_SKILL_DIR`"), "pr-lane must honor the explicit canonical skill path")
assert(lane.index("from `PR_BATCH_SKILL_DIR`") < lane.index("Prefer the host's skill invocation"), "pr-lane must prefer an explicit canonical path before host invocation")
assert(lane.include?("from a sibling of the loaded `pr-lane` directory"), "pr-lane must support single-skill picker loading")
assert(lane.include?("repo-local `.agents/skills/pr-batch/SKILL.md`"), "pr-lane must support repo-local fallback loading")
assert(lane.index("repo-local `.agents/skills/pr-batch/SKILL.md`") < lane.index("from a sibling of the loaded `pr-lane` directory"), "pr-lane must prefer pinned canonical policy over the installed sibling")
assert(lane.include?("${CODEX_HOME:-$HOME/.codex}/skills/pr-batch/SKILL.md"), "pr-lane must support picker-only Codex installs")
assert(lane.include?("${CLAUDE_HOME:-$HOME/.claude}/skills/pr-batch/SKILL.md"), "pr-lane must support picker-only Claude installs")
assert(lane.include?("Do not guess between\nhosts"), "pr-lane must not guess an active host")
assert(lane.include?("This follows `docs/host-adapter/contract.md`"), "pr-lane must document the cross-file support boundary")
assert(lane.include?("Do not restore a standalone copy"), "pr-lane must reject policy duplication as a fallback")
assert(lane.lines.length < 60, "pr-lane must stay a thin compatibility entry point")
[
  "Claim Before Branch",
  "Work Loop",
  "Coordinator Closeout Lane"
].each do |heading|
  assert(!lane.include?("## #{heading}"), "pr-lane must not duplicate #{heading}")
end

assert(guide.include?("`$pr-lane` Compatibility Alias"), "guide must describe pr-lane as an alias")
assert(guide.include?("one worker subagent"), "guide must document the single-target worker shape")
assert(!File.exist?(File.join(ROOT, "skills/pr-lane/agents/openai.yaml")), "the compatibility alias must not be promoted in picker metadata")

puts "PASS pr-batch single-target entry point contract"
