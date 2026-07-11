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
workflow = read_repo_file("workflows/pr-processing.md")
batch_metadata = read_repo_file("skills/pr-batch/agents/openai.yaml")

assert(batch.include?("A single target is\na batch of one"), "pr-batch must own single-target mode")
assert(batch.include?("dispatch one\n  worker subagent"), "single-target mode must default to a worker subagent")
assert(batch.include?("Do not silently default it"), "single-target mode must require explicit merge authority")
assert(batch.include?("fastest or balanced worker route"), "single-target mode must use cost-aware staged routing")
assert(batch.include?("verified head branch cannot be pushed"), "single-target PR mode must preserve the unpushable-head fallback")
assert(batch.include?("replacement branch/PR"), "single-target PR mode must explain the replacement path")
assert(batch.include?("for one direct-prompt task, the derived `adhoc:<yyyymmdd>-<short-slug>`"), "the required interview must accept ad-hoc targets")
assert(batch.include?("direct user instruction, a maintainer-approved exact list"), "the required interview must classify direct-prompt trust")

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
assert(lane.include?("both installed host copies exist but active host identity is ambiguous"), "pr-lane must handle ambiguous dual-home installs")
assert(lane.include?("complete installed shared packs"), "ambiguous dual-home fallback must compare the complete shared packs")
assert(lane.include?("not only their `pr-batch/SKILL.md` files"), "ambiguous dual-home fallback must include adjacent workflows and helpers")
assert(lane.include?("byte-identical"), "ambiguous dual-home fallback must require identical shared packs")
assert(lane.include?("If they differ, stop"), "ambiguous dual-home fallback must reject divergent policy")
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
assert(batch_metadata.include?("one or more"), "canonical picker metadata must advertise single- and multi-target work")
assert(batch_metadata.include?("ad-hoc"), "canonical picker metadata must advertise direct ad-hoc tasks")

assert(workflow.include?("claim --help"), "canonical coordination must preserve claim capability detection")
assert(workflow.include?("heartbeat --help"), "canonical coordination must preserve heartbeat capability detection")
assert(workflow.include?("--thread-handle"), "canonical coordination must preserve extended lane metadata")
assert(workflow.include?("`coordination_backend: n/a`"), "canonical coordination must define no-backend single-target behavior")
assert(workflow.include?("single-operator assumption in the Lane Card and final handoff"), "no-backend mode must preserve its assumption in evidence")
assert(workflow.include?("a derived `adhoc:<yyyymmdd>-<short-slug>` target"), "canonical intake must accept direct-prompt task targets")
assert(workflow.include?("Do not pass `adhoc:` targets to `pr-security-preflight`"), "ad-hoc targets must not be sent to the GitHub preflight helper")
assert(workflow.include?("Ad-hoc task: `adhoc:<yyyymmdd>-<short-slug>`"), "canonical goal handoff must represent ad-hoc task items")
assert(workflow.include?("Target ids: PR/Issue #N or Ad-hoc `adhoc:<yyyymmdd>-<short-slug>`"), "canonical file-touch map must represent ad-hoc task lanes")
assert(workflow.include?("For an ad-hoc target, record the evidence and rationale directly in the final handoff"), "canonical final handoff must support ad-hoc no-PR evidence")
assert(workflow.include?("For an ad-hoc task, the final handoff is the evidence surface"), "canonical outcome classification must support ad-hoc no-PR evidence")
assert(workflow.include?("public claim fallback is unavailable because there is no issue or PR comment surface"), "canonical coordination must handle ad-hoc lanes without a public claim surface")
assert(workflow.include?("coordination target or explicit no-backend single-operator approval"), "ad-hoc degraded coordination must stop for a safe ownership decision")

puts "PASS pr-batch single-target entry point contract"
