#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class SecureGitHubActionsContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PROJECT_ROOT = File.expand_path("../..", ROOT)
  UPSTREAM_COMMIT = "59213af0a2db9321ef10355ff24e9bd619151b6b"

  def test_skill_carries_portable_boundaries_and_pinned_mit_attribution
    skill = File.read(File.join(ROOT, "SKILL.md"), encoding: "UTF-8")
    license = File.read(File.join(ROOT, "LICENSE.intercom"), encoding: "UTF-8")

    assert_includes skill, "name: secure-github-actions"
    assert_includes skill, "## When NOT to Use"
    assert_includes skill, UPSTREAM_COMMIT
    assert_includes skill, "[MIT License](LICENSE.intercom)"
    assert_includes license, "MIT License"
    assert_includes license, "Copyright (c) 2026 Intercom"
    refute_path_exists File.join(ROOT, "README.md")
  end

  def test_references_separate_mechanical_and_judgment_checks
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")
    public_rules = File.read(File.join(ROOT, "references/public-repo-rules.md"), encoding: "UTF-8")

    assert_includes audit, "secure-github-actions-scan"
    assert_includes audit, "trusted_actions"
    assert_includes audit, "aliases at security-sensitive"
    assert_includes audit, "non-scalar mapping keys everywhere"
    assert_includes audit, ".tmp"
    assert_includes public_rules, "persist-credentials: false"
    assert_includes public_rules, "necessary but not sufficient"
    assert_includes public_rules, "nonblocking observation"
  end

  def test_repository_validation_runs_all_focused_security_suites
    validate = File.read(File.join(PROJECT_ROOT, "bin/validate"), encoding: "UTF-8")

    %w[
      secure-github-actions-scan-test.rb
      secure-github-actions-review-lens-test.rb
      secure-github-actions-contract-test.rb
    ].each { |test| assert_includes validate, test }
  end

  def test_user_docs_define_the_gate_and_targeted_rollout_boundary
    readme = read_project("README.md")
    adoption = read_project("docs/adoption.md")
    downstream = read_project("docs/downstream-sync.md")
    supply_chain = read_project("docs/repository-supply-chain.md")
    changelog = read_project("CHANGELOG.md")

    assert_includes readme, "secure-github-actions"
    assert_includes adoption, "trusted_actions"
    assert_includes downstream, "--security-audit-fleet secure-github-actions"
    assert_includes downstream, "read-only"
    assert_includes downstream, "Shakapacker"
    assert_includes supply_chain, "necessary but not sufficient"
    assert_includes supply_chain, "trusted_actions"
    assert_includes supply_chain, "YAML aliases"
    assert_includes downstream, "same-named tag"
    assert_includes changelog, "issue 273"
  end

  private

  def read_project(relative)
    File.read(File.join(PROJECT_ROOT, relative), encoding: "UTF-8")
  end
end
