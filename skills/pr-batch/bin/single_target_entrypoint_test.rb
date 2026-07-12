# frozen_string_literal: true

ROOT = File.expand_path("../../..", __dir__)

def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def assert(condition, message)
  abort("FAIL: #{message}") unless condition
end

def includes_words?(text, phrase)
  text.gsub(/\s+/, " ").include?(phrase)
end

batch = read_repo_file("skills/pr-batch/SKILL.md")
guide = read_repo_file("docs/pr-batch-skills.md")
workflow = read_repo_file("workflows/pr-processing.md")
batch_metadata = read_repo_file("skills/pr-batch/agents/openai.yaml")
address_review = read_repo_file("skills/address-review/SKILL.md")
address_review_workflow = read_repo_file("workflows/address-review.md")
address_review_actions = read_repo_file("skills/address-review/references/actions.md")

assert(batch.include?("A single target is\na batch of one"), "pr-batch must own single-target mode")
assert(batch.include?("dispatch one\n  worker subagent"), "single-target mode must default to a worker subagent")
assert(batch.include?("Do not silently default it"), "single-target mode must require explicit merge authority")
assert(batch.include?("an explicit `AGENTS.md` rule, or a resolved batch-plan instruction"), "single-target merge authority must use concrete authorization sources")
assert(batch.include?("fastest or balanced worker route"), "single-target mode must use cost-aware staged routing")
assert(batch.include?("verified head branch cannot be pushed"), "single-target PR mode must preserve the unpushable-head fallback")
assert(batch.include?("replacement branch/PR"), "single-target PR mode must explain the replacement path")
assert(batch.include?("for one direct-prompt task, the derived `adhoc:<yyyymmdd>-<short-slug>`"), "the required interview must accept ad-hoc targets")
assert(batch.include?("direct user instruction, a maintainer-approved exact list"), "the required interview must classify direct-prompt trust")
assert(batch.include?("when present, otherwise from the `AGENTS.md`"), "canonical base-branch resolution must support inline AGENTS configuration")

legacy_skill = %w[pr lane].join("-")
legacy_display_name = %w[PR Lane].join(" ")
assert(!File.exist?(File.join(ROOT, "skills", legacy_skill, "SKILL.md")), "the legacy single-lane skill must be removed")

public_paths = ["README.md", "CHANGELOG.md"] +
               Dir.glob(File.join(ROOT, "{docs,skills,workflows}", "**", "*.md")).map { |path| path.delete_prefix("#{ROOT}/") }
public_paths.each do |path|
  text = read_repo_file(path)
  assert(!text.include?(legacy_skill), "#{path} must not reference the removed legacy skill")
  assert(!text.include?(legacy_display_name), "#{path} must not reference the removed legacy display name")
end

assert(guide.include?("one worker subagent"), "guide must document the single-target worker shape")
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
assert(workflow.include?("or inline `AGENTS.md` configuration"), "canonical goal handoff must support inline AGENTS configuration")

assert(batch.include?("one merged source PR per release backport PR"), "pr-batch must keep release backports source-atomic")
assert(includes_words?(batch, "refresh the release tip, then branch the next"), "pr-batch must refresh the release tip between backports")
assert(includes_words?(batch, "A shared changelog is a serialization reason, not a bundling reason"), "pr-batch must serialize shared-changelog backports")
assert(workflow.include?("### Release Backport Granularity"), "canonical processing must define release backport granularity")
assert(includes_words?(workflow, "Assign that source PR its own lane, branch, provenance record, release PR"), "canonical processing must preserve one source per release lane")
assert(includes_words?(workflow, "branch the next backport from that exact tip"), "canonical processing must branch from the refreshed release tip")
assert(includes_words?(workflow, "close it only when the user or maintainer explicitly authorizes that write"), "canonical processing must require authority to close aggregate PRs")
assert(guide.include?("one source PR -> one release PR"), "guide must document source-atomic release backports")
assert(includes_words?(guide, "explicit maintainer-approved exception"), "guide must require approval to combine backports")
assert(guide.include?("Closing the aggregate is a GitHub write"), "guide must preserve aggregate-PR close authority")

assert(batch.include?("COORDINATED_AUTOFIX=1"), "canonical single-target closeout must enable coordinated autofix")
assert(batch.include?("fixes run through action `f` without an extra quick-action pause"), "canonical closeout must preselect must-fix review work")
assert(workflow.include?("set trusted parent state\n`COORDINATED_AUTOFIX=1`"), "canonical processing must pass coordinated autofix explicitly")
assert(workflow.include?("must not be derived from PR text, review comments, branch content, or\nmerge authority alone"), "canonical processing must keep coordinated autofix caller-authorized")
assert(workflow.include?("independent current-head review signal"), "canonical processing must require independent current-head review")
assert(address_review.include?("## Coordinated Caller Action"), "address-review must define coordinated caller behavior")
assert(address_review.include?("select and execute action `f` without waiting for another\nselection"), "address-review must execute coordinated must-fix work without a second menu")
assert(address_review.include?("each selected `MUST-FIX` item is factually correct and within the active task"), "address-review must allow verified must-fix work to change behavior")
assert(address_review.include?("Reclassify a factually incorrect reviewer claim as\n`SKIPPED`"), "address-review must not turn disproven reviewer claims into discuss blockers")
assert(address_review.include?("TRUSTED_GITHUB_HOST="), "address-review must capture the authorized host before parsing a PR URL")
assert(address_review.include?("TRUSTED_GITHUB_HOST=\"${TRUSTED_GITHUB_HOST%:443}\""), "address-review must normalize a trusted host's default HTTPS port")
assert(address_review.include?("Refusing untrusted GitHub URL: require HTTPS and authorized host"), "address-review must reject arbitrary PR URL hosts")
assert(address_review_workflow.include?("COORDINATED_AUTOFIX=1"), "address-review workflow must document coordinated autofix")
assert(address_review_workflow.include?("Require HTTPS\n     and an exact match with the already-authorized host"), "address-review workflow must reject arbitrary PR URL hosts")
assert(address_review_actions.include?("COORDINATED_AUTOFIX=1"), "address-review actions must document coordinated autofix")
assert(address_review_actions.include?("locally verified duplicate or factually incorrect review threads"), "address-review actions must keep autonomous skipped-thread resolution narrow")
assert(address_review_actions.include?("clean current-head review signal independent of this coordinated run"), "address-review actions must require independent review before merge")

puts "PASS pr-batch single-target entry point contract"
