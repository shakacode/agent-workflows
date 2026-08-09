#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

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

  def test_audit_commands_require_an_absolute_trusted_pack_without_consumer_fallback
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")

    assert_includes audit, "already-resolved absolute trusted-pack skill directory"
    assert_includes audit, 'case "${SECURE_GITHUB_ACTIONS_SKILL_DIR}" in'
    assert_includes audit, '"${SECURE_GITHUB_ACTIONS_SKILL_DIR}/bin/secure-github-actions-scan"'
    refute_includes audit, "${SECURE_GITHUB_ACTIONS_SKILL_DIR:-.agents/skills/secure-github-actions}"
  end

  def test_audit_command_never_executes_a_consumer_checkout_scanner
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")
    command = audit.scan(/```bash\n(.*?)```/m).fetch(0).fetch(0)

    Dir.mktmpdir("secure-github-actions-command-contract") do |outer|
      consumer = File.join(outer, "consumer")
      trusted_skill = File.join(outer, "trusted-pack/secure-github-actions")
      trusted_marker = File.join(outer, "trusted-ran")
      malicious_marker = File.join(outer, "malicious-ran")
      write_scanner(File.join(trusted_skill, "bin/secure-github-actions-scan"), trusted_marker)
      write_scanner(
        File.join(consumer, ".agents/skills/secure-github-actions/bin/secure-github-actions-scan"),
        malicious_marker
      )

      _out, err, status = Open3.capture3(
        { "SECURE_GITHUB_ACTIONS_SKILL_DIR" => trusted_skill }, "bash", "-c", command, chdir: consumer
      )

      assert_predicate status, :success?, err
      assert_path_exists trusted_marker
      refute_path_exists malicious_marker

      _out, err, status = Open3.capture3(
        { "SECURE_GITHUB_ACTIONS_SKILL_DIR" => ".agents/skills/secure-github-actions" },
        "bash", "-c", command, chdir: consumer
      )

      refute_predicate status, :success?
      assert_includes err, "must be absolute"
      refute_path_exists malicious_marker
    end
  end

  def test_replayable_snapshot_refuses_dirty_state_and_binds_exact_head
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")

    assert_includes audit, "git rev-parse --verify 'HEAD^{commit}'"
    assert_includes audit, "git status --porcelain=v1 --untracked-files=all"
    assert_includes audit, "Refusing replayable snapshot: checkout is dirty"
    assert_operator audit.index("git status --porcelain=v1 --untracked-files=all"), :<,
                    audit.rindex("secure-github-actions-scan")
  end

  def test_replayable_snapshot_command_refuses_staged_unstaged_and_untracked_state
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")
    command = audit.scan(/```bash\n(.*?)```/m).fetch(1).fetch(0)

    %i[staged unstaged untracked].each do |dirty_state|
      Dir.mktmpdir("secure-github-actions-snapshot-contract") do |outer|
        root = File.join(outer, "consumer")
        trusted_skill = File.join(outer, "trusted-pack/secure-github-actions")
        scanner_marker = File.join(outer, "scanner-ran")
        FileUtils.mkdir_p(root)
        File.write(File.join(root, "tracked"), "clean\n")
        git!(root, "init", "-b", "main")
        git!(root, "add", "tracked")
        git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "commit", "-m", "fixture")
        case dirty_state
        when :staged
          File.write(File.join(root, "tracked"), "staged\n")
          git!(root, "add", "tracked")
        when :unstaged
          File.write(File.join(root, "tracked"), "unstaged\n")
        when :untracked
          File.write(File.join(root, "untracked"), "untracked\n")
        end
        write_scanner(File.join(trusted_skill, "bin/secure-github-actions-scan"), scanner_marker)

        _out, err, status = Open3.capture3(
          { "SECURE_GITHUB_ACTIONS_SKILL_DIR" => trusted_skill }, "bash", "-c", command, chdir: root
        )

        refute_predicate status, :success?, dirty_state
        assert_includes err, "Refusing replayable snapshot: checkout is dirty", dirty_state
        refute_path_exists scanner_marker, dirty_state
      end
    end

    Dir.mktmpdir("secure-github-actions-snapshot-contract") do |outer|
      root = File.join(outer, "consumer")
      trusted_skill = File.join(outer, "trusted-pack/secure-github-actions")
      scanner_marker = File.join(outer, "scanner-ran")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "tracked"), "clean\n")
      git!(root, "init", "-b", "main")
      git!(root, "add", "tracked")
      git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
           "commit", "-m", "fixture")
      head = git!(root, "rev-parse", "HEAD").strip
      write_scanner(File.join(trusted_skill, "bin/secure-github-actions-scan"), scanner_marker)

      out, err, status = Open3.capture3(
        { "SECURE_GITHUB_ACTIONS_SKILL_DIR" => trusted_skill }, "bash", "-c", command, chdir: root
      )

      assert_predicate status, :success?, err
      assert_includes out, "exact HEAD: #{head}"
      assert_path_exists scanner_marker
    end
  end

  def test_docs_describe_discovery_exclusions_and_ignored_reference_behavior
    skill = File.read(File.join(ROOT, "SKILL.md"), encoding: "UTF-8")
    audit = File.read(File.join(ROOT, "references/audit-commands.md"), encoding: "UTF-8")
    adoption = read_project("docs/adoption.md")

    assert_includes skill, "unreferenced Git-ignored descriptors"
    assert_includes skill, "explicitly referenced ignored local actions"
    assert_includes audit, "Excluded roots are not discovered"
    assert_includes adoption, "case-insensitive"
    refute_includes adoption, "lowercase-insensitive"
    refute_includes adoption, "every nested `action.yml` or `action.yaml`"
    assert_includes adoption, "eligible tracked or unignored `action.yml` / `action.yaml` descriptors"
    assert_includes adoption, "Unreferenced ignored descriptors and excluded roots are not discovered"
    assert_includes adoption, "explicitly referenced ignored local actions are resolved separately and scanned"
    assert_includes adoption,
                    "/path/to/trusted/agent-workflows/skills/secure-github-actions/bin/secure-github-actions-scan"
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

  def test_downstream_rollout_docs_keep_missing_trusted_actions_fail_closed
    downstream = read_project("docs/downstream-sync.md").gsub(/\s+/, " ")

    assert_includes downstream, "A missing `trusted_actions` key is the closed empty allowlist"
    assert_includes downstream,
                    "Generic sync and direct seam-doctor checks stop on an unremediated consumer before mutation"
    assert_includes downstream, "`gate_activation` describes the ordered adoption boundary"
    assert_includes downstream, "Omitting or deleting the key is not an opt-out"
  end

  def test_docs_define_digest_pinned_container_trust_boundary
    skill = File.read(File.join(ROOT, "SKILL.md"), encoding: "UTF-8").gsub(/\s+/, " ")
    public_rules = File.read(File.join(ROOT, "references/public-repo-rules.md"), encoding: "UTF-8").gsub(/\s+/, " ")

    assert_includes skill, "A digest establishes container-image immutability, not image trust"
    assert_includes skill,
                    "`docker://` references are intentionally outside the exact GitHub `owner/repository` `trusted_actions` seam"
    assert_includes skill,
                    "A mechanical `trusted_container_images` seam or a Docker ban is separate product-policy scope"
    assert_includes public_rules,
                    "manually review the exact registry, image, and digest for every `docker://` use"
  end

  private

  def write_scanner(path, marker)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n: > #{marker}\n")
    File.chmod(0o755, path)
  end

  def git!(root, *arguments)
    environment = {
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_PARAMETERS" => nil
    }
    out, status = Open3.capture2e(environment, "git", "-C", root, *arguments)
    raise "git fixture failed: #{out}" unless status.success?

    out
  end

  def read_project(relative)
    File.read(File.join(PROJECT_ROOT, relative), encoding: "UTF-8")
  end
end
