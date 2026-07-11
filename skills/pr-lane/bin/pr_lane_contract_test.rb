# frozen_string_literal: true

require "minitest/autorun"

class PrLaneContractTest < Minitest::Test
  SKILL_PATH = File.expand_path("../SKILL.md", __dir__)
  ADDRESS_REVIEW_SKILL_PATH = File.expand_path("../../address-review/SKILL.md", __dir__)
  ADDRESS_REVIEW_WORKFLOW_PATH = File.expand_path("../../../workflows/address-review.md", __dir__)

  def setup
    @skill = File.read(SKILL_PATH, encoding: "UTF-8")
    @normalized_skill = @skill.gsub(/\s+/, " ")
    @address_review_skill = File.read(ADDRESS_REVIEW_SKILL_PATH, encoding: "UTF-8").gsub(/\s+/, " ")
    @address_review_workflow = File.read(ADDRESS_REVIEW_WORKFLOW_PATH, encoding: "UTF-8").gsub(/\s+/, " ")
  end

  def test_explicit_pr_url_wins_over_checkout_repository_detection
    assert_includes @normalized_skill, "A full GitHub PR URL is authoritative for repository selection"
    assert_includes @normalized_skill, "hostname into `TARGET_HOST`"
    assert_includes @normalized_skill, "Do not replace the URL-derived host or repository with `gh repo view` output"
    assert_includes @normalized_skill, "final numeric path component into `TARGET_NUMBER`"
    assert_includes @skill, 'export GH_HOST="${TARGET_HOST}"'
    assert_includes @skill, 'CHECKOUT_HOST="${CHECKOUT_URL#*://}"'
    assert_includes @skill, 'CHECKOUT_HOST="${CHECKOUT_HOST%%/*}"'
    assert_includes @skill, 'COORD_REPO="github-host/$(ruby -rdigest'
    assert_includes @skill, 'REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"'
    assert_includes @skill, "if ! git rev-parse --show-toplevel >/dev/null 2>&1; then"
    assert_operator @skill.index("git rev-parse --show-toplevel"), :<, @skill.index('REPO="${REPO:-')
    assert_includes @skill, ': "${TARGET_NUMBER:?TARGET_NUMBER must be set before preflight}"'
    assert_includes @skill,
                    'if [ "${CHECKOUT_HOST}" != "${TARGET_HOST}" ] || [ "${CHECKOUT_REPO}" != "${REPO}" ]; then'
    assert_includes @skill, "enter a trusted base checkout before preflight"
    assert_includes @normalized_skill, "For a fork PR, run preflight from a separate trusted checkout"
    assert_includes @normalized_skill, "then return to or create the verified fork-head checkout"
    assert_includes @normalized_skill, "`COORD_REPO` is a coordination identity only"
    assert_includes @normalized_skill, "Public fallback uses the real `GH_HOST`, `REPO`, and target surface"
    assert_includes @skill, "github_host: <target-host>"
    assert_includes @skill,
                    'pr-security-preflight" --repo "${REPO}" "${TARGET_NUMBER}"'
  end

  def test_authorized_auto_merge_lane_does_not_pause_for_review_quick_actions
    authority_index = @normalized_skill.index("Determine `merge_authority` before review triage")
    address_review_index = @normalized_skill.index("Use `verify`, `pr-monitoring`, and `address-review`")
    assert_operator authority_index, :<, address_review_index
    assert_includes @normalized_skill, "select the `f` action without presenting the quick-action menu"
    assert_includes @normalized_skill, "Do not classify routine verified review fixes as `blocked-user-input`"
    assert_includes @normalized_skill,
                    "every behavior-preserving optional fix or recorded outcome is within the active task"
    assert_includes @normalized_skill,
                    "set trusted parent state `COORDINATED_AUTOFIX=1` for the `address-review` invocation"
    [@address_review_skill, @address_review_workflow].each do |text|
      assert_includes text, "COORDINATED_AUTOFIX"
      assert_includes text, "execute action `f` without waiting for another selection"
      assert_includes text, "autonomous optional fix or recorded outcome"
      assert_includes text, "without prompting"
      assert_includes text, "Do not auto-resolve other substantive skipped threads"
      assert_includes text, "skipped review-summary bodies that contain a reviewer claim"
      assert_includes text, "explicit no-action outcome in the cutoff-safe summary"
      assert_includes text, "Re-present any other skipped item for an explicit decision"
      assert_includes text, "boilerplate skipped items without an actionable thread"
    end
  end

  def test_merge_authority_does_not_expand_task_scope
    assert_includes @normalized_skill, "Merge authority authorizes the final merge, not unrelated scope expansion"
    assert_includes @normalized_skill, "Stop only for a genuinely blocking question"
  end
end
