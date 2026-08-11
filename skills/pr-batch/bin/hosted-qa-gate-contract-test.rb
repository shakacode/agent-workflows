#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "../lib/hosted_qa_runtime_trust"

ROOT = File.expand_path("../../..", __dir__)
DELEGATION = "Use the trusted-base `hosted-qa-readiness` helper and the canonical hosted QA contract " \
             "in `workflows/pr-processing.md`; do not reproduce or reinterpret that contract here."

class HostedQaGateContractTest < Minitest::Test
  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def test_first_phase_seam_is_optional_and_example_is_n_a
    doctor = read("bin/agent-workflow-seam-doctor")
    required_keys = doctor[/REQUIRED_POLICY_KEYS = %w\[(.*?)\]\.freeze/m, 1]
    example = YAML.safe_load(read("examples/agent-workflow.yml"), aliases: false)

    refute_includes required_keys, "hosted_qa_gate"
    assert_equal "n/a", example.fetch("hosted_qa_gate")
    assert_includes read("docs/seam-design.md"), "optional closed mapping"
  end

  def test_canonical_workflow_owns_the_executable_contract
    workflow = read("workflows/pr-processing.md")

    assert_includes workflow, "hosted-qa-evidence v1"
    assert_includes workflow, "Generic `qa-evidence v2` never proves a hosted deployment"
    assert_includes workflow, "hosted-qa-readiness"
    assert_includes workflow, "BOOTSTRAP_ALLOWED"
    assert_includes workflow, "hosted-qa-maintainer-waiver v1"
    assert_includes workflow, "qa-maintainer-waiver v1"
    assert_includes workflow, "cannot satisfy a hosted QA waiver"
    assert_includes workflow, "The closed v1 interpreter families are Ruby and POSIX `sh`"
    assert_includes workflow, "Arbitrary executable identities such as `/usr/bin/false` block"
    assert_includes workflow, "After full-SHA validation, replay canonicalizes both SHA fields to lowercase"
  end

  def test_canonical_workflow_requires_pre_execution_runtime_trust_and_criteria_authentication
    workflow = read("workflows/pr-processing.md")
    section = workflow[/### Hosted Runtime QA Gate\n(.*?)\n### QA Evidence/m, 1]&.gsub(/\s+/, " ")

    refute_nil section
    assert_includes section, "trusted-base materialization"
    assert_includes section, "verified installed Agent Workflows pack"
    assert_includes section, "--trusted-helper-provenance"
    assert_includes section, '"${TRUSTED_PR_BATCH_SKILL_DIR}/bin/hosted-qa-readiness"'
    refute_includes section, '"${PR_BATCH_SKILL_DIR}/bin/hosted-qa-readiness"'
    assert_includes section, 'trusted_git -C "${REPO_ROOT}" ls-tree'
    assert_includes section, 'trusted_git -C "${REPO_ROOT}" archive'
    assert_includes section, "stat.file? && stat.nlink == 1"
    assert_includes section, "trap cleanup_trusted_runtime EXIT"
    refute_includes section, ["rm", ["-", "r", "f"].join].join(" ")
    assert_includes section, "--criterion <configured-id>"
    assert_includes section, '"criteria"'
    assert_includes section, "exact ordered rows"
  end

  def test_canonical_materialization_uses_only_coordinator_verified_outer_tools
    workflow = read("workflows/pr-processing.md")
    section = workflow[/### Hosted Runtime QA Gate\n(.*?)\n### QA Evidence/m, 1]
    normalized = section&.gsub(/\s+/, " ")

    refute_nil section
    %w[GIT TAR MKTEMP RM ENV RUBY].each do |name|
      assert_includes normalized, "`TRUSTED_#{name}`", name
    end
    assert_includes normalized, "Before executing any repository content"
    assert_includes normalized, "requested path and realpath"
    assert_includes normalized, "executable regular file outside `REPO_ROOT`"
    assert_includes normalized, 'trusted_host_tool "${TRUSTED_MKTEMP}"'
    assert_includes normalized, 'trusted_git -C "${REPO_ROOT}" ls-tree'
    assert_includes normalized, 'trusted_git -C "${REPO_ROOT}" archive'
    assert_includes normalized, 'trusted_host_tool "${TRUSTED_TAR}"'
    assert_includes normalized, 'trusted_host_tool "${TRUSTED_RM}"'
    refute_match(/^TRUSTED_RUNTIME_ROOT="\$\(mktemp /, section)
    refute_includes normalized, 'cat-file -e "${TRUSTED_BASE_SHA}:${path}"'
    refute_match(/^\s*tar -x /, section)
    refute_match(/trap ['"]rm /, section)
  end

  def test_canonical_materialization_rejects_symlink_runtime_entries_before_extraction
    Dir.mktmpdir("hosted-qa-materialization-contract") do |root|
      repository = File.join(root, "repository")
      FileUtils.mkdir_p(repository)
      HostedQaRuntimeTrust::RUNTIME_SOURCES.each_value do |source|
        destination = File.join(repository, source.fetch(:tree_paths).first)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source.fetch(:path), destination)
      end
      helper_path = File.join(repository, "skills/pr-batch/bin/hosted-qa-readiness")
      FileUtils.rm_f(helper_path)
      File.symlink("../../../../outside-hosted-helper", helper_path)

      git = File.realpath("/usr/bin/git")
      run_git!(git, repository, "init", "-q")
      run_git!(git, repository, "config", "user.name", "Test User")
      run_git!(git, repository, "config", "user.email", "test@example.test")
      run_git!(git, repository, "add", "--all")
      run_git!(git, repository, "commit", "-q", "-m", "trusted base with runtime symlink")
      base_sha = run_git!(git, repository, "rev-parse", "HEAD").strip

      script = read("workflows/pr-processing.md").match(
        /```bash\n(?<script>set -o pipefail.*?HOSTED_HELPER_PROVENANCE="trusted-base:\$\{TRUSTED_BASE_SHA\}"\n)```/m
      )&.[](:script)
      refute_nil script

      tool_home = File.join(root, "tool-home")
      temporary_root = File.join(root, "temporary")
      FileUtils.mkdir_p([tool_home, temporary_root], mode: 0o700)
      tools = {
        "TRUSTED_GIT" => git,
        "TRUSTED_TAR" => File.realpath("/usr/bin/tar"),
        "TRUSTED_MKTEMP" => File.realpath("/usr/bin/mktemp"),
        "TRUSTED_RM" => File.realpath("/bin/rm"),
        "TRUSTED_ENV" => File.realpath("/usr/bin/env"),
        "TRUSTED_RUBY" => File.realpath(RbConfig.ruby)
      }
      account = Etc.getpwuid
      environment = tools.merge(
        "REPO_ROOT" => repository,
        "TRUSTED_BASE_SHA" => base_sha,
        "TRUSTED_SYSTEM_PATH" => (tools.values.map { |path| File.dirname(path) } + %w[/usr/bin /bin]).uniq.join(":"),
        "TRUSTED_USER" => account.name,
        "TRUSTED_LOGNAME" => account.name,
        "TRUSTED_TOOL_HOME" => tool_home,
        "TRUSTED_TEMP_ROOT" => temporary_root
      )

      _stdout, stderr, status = Open3.capture3(
        environment,
        "/bin/bash", "--noprofile", "--norc", "-c", script,
        unsetenv_others: true
      )

      refute status.success?
      assert_includes stderr, "UNKNOWN: trusted base lacks the complete hosted QA runtime"
    end
  end

  def test_canonical_helper_launcher_uses_sanitized_absolute_ruby_from_a_trusted_cwd
    workflow = read("workflows/pr-processing.md")
    section = workflow[/### Hosted Runtime QA Gate\n(.*?)\n### QA Evidence/m, 1]
    normalized = section&.gsub(/\s+/, " ")

    refute_nil section
    assert_includes normalized, "run_hosted_qa_readiness()"
    assert_includes normalized, 'builtin cd -- "${TRUSTED_HELPER_CWD}"'
    assert_includes normalized, '"${TRUSTED_ENV}" -i'
    assert_includes normalized, 'HOME="${TRUSTED_HELPER_HOME}"'
    assert_includes normalized, 'USER="${TRUSTED_USER}"'
    assert_includes normalized, 'LOGNAME="${TRUSTED_LOGNAME}"'
    assert_includes normalized, 'PATH="${TRUSTED_SYSTEM_PATH}"'
    assert_includes normalized, '"${TRUSTED_RUBY}"'
    assert_includes normalized, '"${TRUSTED_PR_BATCH_SKILL_DIR}/bin/hosted-qa-readiness" "$@"'
    assert_includes normalized, "RUBYOPT"
    assert_includes normalized, "RUBYLIB"
    assert_equal 2, section.scan(/^run_hosted_qa_readiness \\$/).length
    refute_match(%r{^"\$\{TRUSTED_PR_BATCH_SKILL_DIR\}/bin/hosted-qa-readiness"}, section)
  end

  def test_runtime_trust_manifest_covers_the_exact_loaded_eight_file_closure
    expected_tree_paths = {
      "helper" => %w[skills/pr-batch/bin/hosted-qa-readiness .agents/skills/pr-batch/bin/hosted-qa-readiness],
      "runtime-trust-library" => %w[skills/pr-batch/lib/hosted_qa_runtime_trust.rb .agents/skills/pr-batch/lib/hosted_qa_runtime_trust.rb],
      "hosted-policy-library" => %w[bin/agent_doctor/hosted_qa_policy.rb .agents/bin/agent_doctor/hosted_qa_policy.rb],
      "autonomous-policy-library" => %w[bin/agent_doctor/autonomous_merge_policy.rb .agents/bin/agent_doctor/autonomous_merge_policy.rb],
      "autonomous-policy-glob-library" => %w[bin/agent_doctor/autonomous_merge_policy_globs.rb .agents/bin/agent_doctor/autonomous_merge_policy_globs.rb],
      "autonomous-policy-yaml-library" => %w[bin/agent_doctor/autonomous_merge_policy_yaml.rb .agents/bin/agent_doctor/autonomous_merge_policy_yaml.rb],
      "closeout-replay-helper" => %w[skills/post-merge-audit/bin/closeout-evidence-replay .agents/skills/post-merge-audit/bin/closeout-evidence-replay],
      "completed-publication-preflight-helper" => %w[skills/post-merge-audit/bin/completed-batch-publication-preflight .agents/skills/post-merge-audit/bin/completed-batch-publication-preflight]
    }
    actual_tree_paths = HostedQaRuntimeTrust::RUNTIME_SOURCES.transform_values do |source|
      source.fetch(:tree_paths)
    end

    assert_equal expected_tree_paths, actual_tree_paths
  end

  def test_entry_point_skills_delegate_without_copying_the_contract
    %w[
      skills/pr-batch/SKILL.md
      skills/pr-monitoring/SKILL.md
      skills/manual-testing/SKILL.md
    ].each do |path|
      text = read(path).gsub(/\s+/, " ")

      assert_includes text, DELEGATION, path
      refute_includes text, "criterion: id=", path
    end
  end

  private

  def run_git!(git, repository, *arguments)
    output, status = Open3.capture2e(
      { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL },
      git, "-C", repository, *arguments
    )
    raise "git fixture failed: #{output}" unless status.success?

    output
  end
end
