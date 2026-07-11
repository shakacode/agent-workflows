#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for agent-workflow-seam-doctor.
# Run with: ruby .agents/bin/agent-workflow-seam-doctor-test.rb

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflow-seam-doctor", __dir__)
load SCRIPT

module AgentWorkflowSeamDoctorTestHelpers
  POLICY = {
    "base_branch" => "main",
    "follow_up_prefix" => "Follow-up:",
    "review_gate" => "AI reviewers are advisory; merge gate is green checks plus resolved threads.",
    "approval_exempt" => "docs and workflow text when portable.",
    "coordination_backend" => "public claim-comment fallback.",
    "changelog" => "CHANGELOG.md; user-visible changes only.",
    "benchmark_labels" => "n/a",
    "merge_ledger" => "n/a",
    "ci_parity_environment" => "n/a",
    "hosted_ci_trigger" => "n/a",
    "ci_change_detector" => "n/a"
  }.freeze

  def with_repo
    Dir.mktmpdir("agent-workflow-seam-doctor-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents/bin"))
      FileUtils.mkdir_p(File.join(dir, ".agents/skills/example"))
      FileUtils.mkdir_p(File.join(dir, ".agents/workflows"))
      yield dir
    end
  end

  def write_agents(root, section = AgentWorkflowSeamDoctor::POINTER_SECTION)
    File.write(File.join(root, "AGENTS.md"), "# AGENTS.md\n\n#{section}\n\n## Commands\n")
  end

  def write_policy(root, values = POLICY)
    File.write(File.join(root, ".agents/agent-workflow.yml"), "#{values.to_yaml}\n")
  end

  def write_bin_readme(root)
    File.write(File.join(root, ".agents/bin/README.md"), <<~MARKDOWN)
      # Agent Workflow Scripts

      | Script | Purpose | This repo runs |
      | --- | --- | --- |
      | `validate` | Pre-push gate | `bundle exec rake` |
      | `test` | Run tests | `bundle exec rspec` |
    MARKDOWN
  end

  def write_script(root, name, body = "exec bundle exec #{name}\n")
    path = File.join(root, ".agents/bin", name)
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      set -euo pipefail
      cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
      #{body}
    BASH
    File.chmod(0o755, path)
    path
  end

  def write_valid_binstub_contract(root)
    write_agents(root)
    write_policy(root)
    write_bin_readme(root)
    write_script(root, "validate", "exec bundle exec rake\n")
    write_script(root, "test", "exec bundle exec rspec \"$@\"\n")
  end

  def write_skill(root, content)
    File.write(File.join(root, ".agents/skills/example/SKILL.md"), content)
  end

  def write_workflow(root, content)
    File.write(File.join(root, ".agents/workflows/example.md"), content)
  end

  def run_doctor(root, *)
    Open3.capture2e("ruby", SCRIPT, "--root", root, *)
  end
end

class AgentWorkflowSeamDoctorBinstubContractTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_complete_binstub_contract_passes
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ---
        name: example
        ---

        Run `.agents/bin/validate` before pushing.
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
      assert_includes out, "PASS"
    end
  end

  def test_missing_pointer_section_fails
    with_repo do |root|
      write_policy(root)
      write_bin_readme(root)
      write_script(root, "validate")
      write_script(root, "test")
      File.write(File.join(root, "AGENTS.md"), "# AGENTS.md\n\n## Commands\n")
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "missing AGENTS.md section: Agent Workflow Configuration"
    end
  end

  def test_missing_core_script_fails
    with_repo do |root|
      write_agents(root)
      write_policy(root)
      write_bin_readme(root)
      write_script(root, "validate")
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "missing core script: .agents/bin/test"
    end
  end

  def test_non_executable_core_script_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      File.chmod(0o644, File.join(root, ".agents/bin/test"))
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "core script is not executable: .agents/bin/test"
    end
  end

  def test_non_executable_optional_script_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_script(root, "lint", "exec bundle exec rubocop\n")
      File.chmod(0o644, File.join(root, ".agents/bin/lint"))
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "script is not executable: .agents/bin/lint"
    end
  end

  def test_script_without_repo_root_cd_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      path = File.join(root, ".agents/bin/test")
      File.write(path, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        exec bundle exec rspec
      BASH
      File.chmod(0o755, path)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "script does not cd to repo root: .agents/bin/test"
    end
  end

  def test_composed_script_root_preamble_passes
    with_repo do |root|
      write_valid_binstub_contract(root)
      path = File.join(root, ".agents/bin/validate")
      File.write(path, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
        cd "$root"
        "$root/.agents/bin/test"
      BASH
      File.chmod(0o755, path)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      assert status.success?, out
      assert_includes out, "PASS"
    end
  end

  def test_bash_syntax_error_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      path = File.join(root, ".agents/bin/test")
      File.write(path, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
        if true
      BASH
      File.chmod(0o755, path)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "script has bash syntax error: .agents/bin/test"
    end
  end

  def test_composed_script_missing_sibling_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      path = File.join(root, ".agents/bin/validate")
      File.write(path, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
        cd "$root"
        "$root/.agents/bin/lint"
        "$root/.agents/bin/test"
      BASH
      File.chmod(0o755, path)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "script references missing sibling script: .agents/bin/validate -> .agents/bin/lint"
    end
  end

  def test_missing_policy_file_fails
    with_repo do |root|
      write_agents(root)
      write_bin_readme(root)
      write_script(root, "validate")
      write_script(root, "test")
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "missing policy config: .agents/agent-workflow.yml"
    end
  end

  def test_missing_required_policy_key_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      values = POLICY.dup
      values.delete("review_gate")
      write_policy(root, values)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "missing policy key: review_gate"
    end
  end

  def test_unresolved_policy_value_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_policy(root, POLICY.merge("ci_parity_environment" => "<runner image>"))
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "unresolved policy value for key: ci_parity_environment"
    end
  end

  def test_invalid_policy_yaml_fails
    with_repo do |root|
      write_agents(root)
      write_bin_readme(root)
      write_script(root, "validate")
      write_script(root, "test")
      File.write(File.join(root, ".agents/agent-workflow.yml"), "base_branch: [\n")
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "invalid policy config: .agents/agent-workflow.yml"
    end
  end

  def test_regular_check_accepts_scalar_trust_values_for_preflight_compatibility
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")
      File.write(File.join(root, ".agents/trusted-github-actors.yml"), "trusted_bots: deploy\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_regular_check_rejects_overlapping_trust_bot_roles
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")
      trust = {
        "trusted_bots" => ["@Deploy[bot]"],
        "trusted_metadata_bots" => ["deploy"]
      }
      File.write(File.join(root, ".agents/trusted-github-actors.yml"), trust.to_yaml)

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "bot(s) listed in both trusted_bots and trusted_metadata_bots: deploy"
    end
  end

  def test_json_output_format
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root, "--json")

      assert status.success?, out
      parsed = JSON.parse(out)
      assert_equal "PASS", parsed.fetch("status")
      assert_empty parsed.fetch("issues")
    end
  end

  def test_json_output_format_on_failure
    with_repo do |root|
      File.write(File.join(root, "AGENTS.md"), "# AGENTS.md\n\n## Commands\n")
      write_policy(root)
      write_bin_readme(root)
      write_script(root, "validate")
      write_script(root, "test")
      write_skill(root, "No commands here.\n")

      out, status = run_doctor(root, "--json")

      refute status.success?
      parsed = JSON.parse(out)
      assert_equal "FAIL", parsed.fetch("status")
      refute_empty parsed.fetch("issues")
    end
  end
end

class AgentWorkflowSeamDoctorPlaceholderTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_executable_angle_placeholder_in_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "unresolved executable placeholder"
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_executable_placeholder_for_broader_seam_key_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        <docs checks>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<docs checks>"
    end
  end

  def test_executable_placeholder_in_titled_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash title="copyable"
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end
end

class AgentWorkflowSeamDoctorFenceTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_executable_placeholder_in_tilde_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ~~~bash
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ~~~
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_executable_placeholder_in_long_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ````bash
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ````
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_mismatched_fence_delimiter_does_not_close_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        ~~~
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end
end

class AgentWorkflowSeamDoctorFenceLengthTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_shorter_closing_fence_does_not_close_long_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ````bash
        ```
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ````
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_shorter_closing_tilde_fence_does_not_close_long_tilde_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ~~~~bash
        ~~~
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ~~~~
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_longer_closing_fence_closes_long_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ````bash
        echo ok
        `````
        <follow-up prefix>
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_longer_closing_tilde_fence_closes_long_tilde_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ~~~~bash
        echo ok
        ~~~~~
        <follow-up prefix>
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_closing_fence_with_info_string_stays_inside_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ````bash
        ````bash
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ````
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end

  def test_crlf_closing_fence_closes_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "```bash\r\necho ok\r\n```\r\n<follow-up prefix>\r\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_spaced_info_string_on_long_non_executable_fence_is_not_executable
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```` markdown
        <follow-up prefix>
        ````
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_spaced_info_string_on_long_executable_fence_is_executable
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```` bash
        gh issue create --title "<follow-up prefix> Review feedback from PR #123"
        ````
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<follow-up prefix>"
    end
  end
end

class AgentWorkflowSeamDoctorFenceContentTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_four_space_indented_fence_does_not_open_executable_fence
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "    ```bash\n    gh issue create --title \"<follow-up prefix> Review feedback\"\n    ```\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_inline_code_in_executable_fence_is_not_reported_twice
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        `gh issue create --title "<follow-up prefix> Review"`
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_equal 1, out.scan("unresolved executable placeholder").length
    end
  end

  def test_executable_ci_parity_placeholder_in_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        act -P ubuntu-latest=<runner image>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<runner image>"
    end
  end

  def test_filled_ci_parity_runner_image_in_code_fence_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        act -P ubuntu-latest=<runner image: ghcr.io/catthehacker/ubuntu:act-22.04>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<runner image: ghcr.io/catthehacker/ubuntu:act-22.04>"
    end
  end

  def test_executable_filled_ci_parity_command_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        <CI parity command: bin/ci-parity>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<CI parity command: bin/ci-parity>"
    end
  end

  def test_inline_ci_parity_placeholder_command_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "Run `act -P ubuntu-latest=<reproduction guide URL>`.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<reproduction guide URL>"
    end
  end

  def test_executable_compound_placeholder_is_reported_once
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        echo <hosted CI runner image>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      refute status.success?
      assert_equal 1, out.scan("<hosted CI runner image>").length
    end
  end

  def test_inline_act_event_command_placeholder_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "Run `act pull_request -P ubuntu-latest=<runner image>`.\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, "<runner image>"
    end
  end

  def test_inline_act_prose_does_not_make_placeholder_executable
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "Use `act on this finding <runner image>` when documenting parity.\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_non_executable_fence_placeholder_is_allowed
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```text
        <follow-up prefix>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_task_input_placeholder_in_command_is_allowed
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, <<~MARKDOWN)
        ```bash
        bundle exec rspec <test_file>
        ```
      MARKDOWN

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end

  def test_workflow_placeholder_is_scanned
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")
      write_workflow(root, "`gh issue create --title \"<follow-up prefix> Review\"`\n")

      out, status = run_doctor(root)

      refute status.success?
      assert_includes out, ".agents/workflows/example.md"
    end
  end

  def test_invalid_utf8_markdown_does_not_crash_scanner
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")
      File.binwrite(File.join(root, ".agents/skills/example/invalid.md"), "Latin-1 byte: \xE9\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end
end

class AgentWorkflowSeamDoctorSharedRootTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_shared_root_placeholder_is_scanned
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      Dir.mktmpdir("agent-workflow-shared-root") do |shared_root|
        FileUtils.mkdir_p(File.join(shared_root, "skills/shared"))
        File.write(File.join(shared_root, "skills/shared/SKILL.md"), <<~MARKDOWN)
          ```bash
          gh issue create --title "<follow-up prefix> Review"
          ```
        MARKDOWN

        out, status = run_doctor(root, "--shared", shared_root)

        refute status.success?
        assert_includes out, "[shared]"
        assert_includes out, "skills/shared/SKILL.md"
      end
    end
  end

  def test_missing_shared_root_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")
      missing_root = File.join(root, "missing-shared-root")

      out, status = run_doctor(root, "--shared", missing_root)

      refute status.success?
      assert_includes out, "missing shared root: #{missing_root}"
    end
  end

  def test_shared_root_without_skill_or_workflow_markdown_fails
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      Dir.mktmpdir("agent-workflow-shared-root") do |shared_root|
        File.write(File.join(shared_root, "README.md"), "Shared pack docs.\n")

        out, status = run_doctor(root, "--shared", shared_root)

        refute status.success?
        assert_includes out, "shared root has no skill/workflow Markdown: #{shared_root}"
      end
    end
  end

  def test_shared_root_general_markdown_is_not_scanned
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      Dir.mktmpdir("agent-workflow-shared-root") do |shared_root|
        File.write(File.join(shared_root, "README.md"), "`gh issue create --title \"<follow-up prefix>\"`\n")
        FileUtils.mkdir_p(File.join(shared_root, "skills/clean"))
        File.write(File.join(shared_root, "skills/clean/SKILL.md"), "Clean shared skill.\n")

        out, status = run_doctor(root, "--shared", shared_root)

        assert status.success?, out
      end
    end
  end

  def test_installed_skill_root_is_scanned
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      Dir.mktmpdir("agent-workflow-installed-skills") do |shared_root|
        FileUtils.mkdir_p(File.join(shared_root, "shared"))
        File.write(File.join(shared_root, "shared/SKILL.md"), <<~MARKDOWN)
          ```bash
          gh issue create --title "<follow-up prefix> Review"
          ```
        MARKDOWN

        out, status = run_doctor(root, "--shared", shared_root)

        refute status.success?
        assert_includes out, "shared/SKILL.md"
      end
    end
  end

  def test_multiple_shared_roots_are_scanned
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "No commands here.\n")

      Dir.mktmpdir("agent-workflow-shared-root-a") do |shared_root_a|
        Dir.mktmpdir("agent-workflow-shared-root-b") do |shared_root_b|
          FileUtils.mkdir_p(File.join(shared_root_a, "skills/clean"))
          FileUtils.mkdir_p(File.join(shared_root_b, "skills/failing"))
          File.write(File.join(shared_root_a, "skills/clean/SKILL.md"), "Clean shared skill.\n")
          File.write(File.join(shared_root_b, "skills/failing/SKILL.md"), <<~MARKDOWN)
            ```bash
            gh issue create --title "<follow-up prefix> Review"
            ```
          MARKDOWN

          out, status = run_doctor(root, "--shared", shared_root_a, "--shared", shared_root_b)

          refute status.success?
          assert_includes out, "skills/failing/SKILL.md"
        end
      end
    end
  end

  def test_prose_angle_placeholder_is_allowed
    with_repo do |root|
      write_valid_binstub_contract(root)
      write_skill(root, "Use title `<follow-up prefix> Review feedback from PR #N` after resolving the seam.\n")

      out, status = run_doctor(root)

      assert status.success?, out
    end
  end
end

class AgentWorkflowSeamDoctorEncodingTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_non_ascii_agents_md_parses_under_ascii_locale
    with_repo do |root|
      write_valid_binstub_contract(root)
      agents_path = File.join(root, "AGENTS.md")
      body = File.read(agents_path)
      # A real AGENTS.md carries non-ASCII bytes (em dashes, arrows). Reading it
      # under a non-UTF-8 locale must not crash the config parser.
      body.sub!("# AGENTS.md\n", "# AGENTS.md\n\nReact on Rails → SSR overview.\n")
      File.write(agents_path, body)
      write_skill(root, "No commands here.\n")

      out, status = Open3.capture2e(
        { "LC_ALL" => "C", "LANG" => "C" }, "ruby", SCRIPT, "--root", root
      )

      assert status.success?, out
      assert_includes out, "PASS"
    end
  end
end

class AgentWorkflowSeamDoctorInitCliTest < Minitest::Test
  include AgentWorkflowSeamDoctorTestHelpers

  def test_help_advertises_init
    out, status = Open3.capture2e("ruby", SCRIPT, "--help")

    assert status.success?, out
    assert_includes out, "--init"
  end

  def test_init_only_options_require_init
    {
      "--base-branch" => "develop",
      "--validate-command" => "true",
      "--test-command" => "true"
    }.each do |option, value|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        out, status = run_doctor(root, option, value)

        refute status.success?
        assert_includes out, "#{option} requires --init"
      end
    end
  end

  def test_init_with_explicit_commands_creates_a_complete_seam
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      assert_includes out, "PASS agent workflow seam is complete"
      assert_includes File.read(File.join(root, "AGENTS.md")), AgentWorkflowSeamDoctor::POINTER_SECTION
      assert File.executable?(File.join(root, ".agents/bin/validate"))
      assert File.executable?(File.join(root, ".agents/bin/test"))
      assert_equal "main", YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml"))).fetch("base_branch")
      trust = YAML.safe_load(File.read(File.join(root, ".agents/trusted-github-actors.yml")))
      assert_equal [], trust.fetch("trusted_users")
      assert_equal [], trust.fetch("trusted_bots")
      assert_equal [], trust.fetch("trusted_metadata_bots")
      assert_equal [], trust.fetch("trusted_teams")
    end
  end

  def test_init_explicit_simple_commands_forward_wrapper_arguments
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      %w[validate test].each do |name|
        path = File.join(root, "bin", name)
        File.write(path, "#!/usr/bin/env bash\nprintf '#{name}:%s\\n' \"${1:-missing}\"\n")
        File.chmod(0o755, path)
      end

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "bin/validate",
        "--test-command", "bin/test"
      )
      assert status.success?, out

      validate_out, validate_status = Open3.capture2e(File.join(root, ".agents/bin/validate"), "--changed=src/a b.rb")
      test_out, test_status = Open3.capture2e(File.join(root, ".agents/bin/test"), "--watch=false")
      assert validate_status.success?, validate_out
      assert test_status.success?, test_out
      assert_equal "validate:--changed=src/a b.rb\n", validate_out
      assert_equal "test:--watch=false\n", test_out
    end
  end

  def test_init_preserves_shell_comment_commands_verbatim
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = "echo validate # caller owns forwarding"
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, "#{command}\n"
      refute_includes validate, "#{command} \"$@\""
    end
  end

  def test_init_preserves_compound_commands_verbatim
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'bin/validate "$@" && bin/test "$@"'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, "#{command}\n"
      refute_includes validate, "exec #{command}"
    end
  end

  def test_init_preserves_subshell_commands_verbatim
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = '(bin/validate "$@")'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, "#{command}\n"
      refute_includes validate, "exec #{command}"
    end
  end

  def test_init_forwards_arguments_when_shell_metacharacters_are_quoted_or_escaped
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'LABEL="issue #1" bin/validate',
        "--test-command", 'URL=https://example.test/a\&b bin/test'
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'LABEL="issue #1" bin/validate "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'URL=https://example.test/a\&b bin/test "$@"'
    end
  end

  def test_init_forwards_outer_arguments_when_inner_forwarding_is_single_quoted
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'bash -c \'exec bin/validate "$@"\' _'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), %(exec #{command} "$@")
    end
  end

  def test_init_rejects_inner_shell_forwarding_without_a_dollar_zero_placeholder
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'bash -c \'exec bin/validate "$@"\'',
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c forwarding requires an explicit \$0 placeholder after the command string"
      assert_includes out, "add _ before forwarded wrapper arguments"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_allows_literal_forwarding_text_in_an_inner_shell_payload
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'bash -c \'echo \\$@\''
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), %(exec #{command} "$@")
    end
  end

  def test_init_rejects_double_quoted_shell_forwarding_without_a_dollar_zero_placeholder
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c "exec bin/validate \"$@\"")
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c has active outer argument expansion inside its command string"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_rejects_active_outer_forwarding_in_a_double_quoted_shell_payload_even_with_placeholder
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c "exec bin/validate \"$@\"" _)
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c has active outer argument expansion inside its command string"
      assert_includes out, "use a single-quoted command string plus an explicit $0 placeholder"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_rejects_active_outer_forwarding_despite_inner_single_quote_characters
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c "echo '$@'" _)
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c has active outer argument expansion inside its command string"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_requires_placeholder_for_outer_escaped_forwarding_in_a_double_quoted_payload
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c "exec bin/validate \"\$@\"")
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c forwarding requires an explicit $0 placeholder"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_allows_outer_escaped_forwarding_in_a_double_quoted_payload_with_placeholder
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c "exec bin/validate \"\$@\"" _)
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), %(exec #{command} "$@")
    end
  end

  def test_init_requires_placeholder_for_forwarding_in_an_unquoted_escaped_shell_payload
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c exec\ bin/validate\ \"\$@\")
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c forwarding requires an explicit $0 placeholder"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_preserves_all_arguments_for_dequoted_shell_payloads_with_placeholder
    [
      %q(bash -c exec\ bin/validate\ \"\$@\" _),
      %q(bash -c $'exec bin/validate "$@"' _)
    ].each do |command|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        FileUtils.mkdir_p(File.join(root, "bin"))
        validate_path = File.join(root, "bin/validate")
        File.write(validate_path, <<~BASH)
          #!/usr/bin/env bash
          printf '%s\n' "$@"
        BASH
        File.chmod(0o755, validate_path)
        out, status = run_doctor(
          root,
          "--init",
          "--validate-command", command,
          "--test-command", "true"
        )
        assert status.success?, out

        marker = File.join(root, "injected")
        hostile_argument = "; touch #{marker}"
        validate_out, validate_status = Open3.capture2e(
          File.join(root, ".agents/bin/validate"), "first", hostile_argument
        )

        assert validate_status.success?, validate_out
        assert_equal "first\n#{hostile_argument}\n", validate_out
        refute File.exist?(marker), "forwarded argument executed as shell source"
      end
    end
  end

  def test_init_requires_placeholder_for_forwarding_in_an_ansi_c_quoted_shell_payload
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c $'exec bin/validate "$@"')
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c forwarding requires an explicit $0 placeholder"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_rejects_active_outer_forwarding_in_a_mixed_quoted_shell_payload
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = %q(bash -c 'printf SAFE; '"$@" _)
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bash -c has active outer argument expansion inside its command string"
      assert_includes out, "use a single-quoted command string plus an explicit $0 placeholder"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_handles_clustered_shell_command_options_with_placeholder_safety
    {
      "bash -lc" => "bash -lc",
      "zsh -cl" => "zsh -cl"
    }.each do |prefix, label|
      error = assert_raises(AgentWorkflowSeamDoctor::InitError) do
        AgentWorkflowSeamDoctor.init_command_line(%(#{prefix} 'exec bin/validate "$@"'))
      end
      assert_includes error.message, "#{prefix.split.first} -c forwarding requires an explicit \$0 placeholder"

      command = %(#{prefix} 'exec bin/validate "$@"' _)
      assert_equal %(exec #{command} "$@"), AgentWorkflowSeamDoctor.init_command_line(command), label
    end
  end

  def test_init_handles_wrapped_and_absolute_shell_commands_with_placeholder_safety
    [
      "env FOO=bar bash -c",
      "/usr/bin/env bash -c",
      "/bin/bash -c"
    ].each do |prefix|
      error = assert_raises(AgentWorkflowSeamDoctor::InitError) do
        AgentWorkflowSeamDoctor.init_command_line(%(#{prefix} 'exec bin/validate "$@"'))
      end
      assert_includes error.message, "bash -c forwarding requires an explicit \$0 placeholder"

      command = %(#{prefix} 'exec bin/validate "$@"' _)
      assert_equal %(exec #{command} "$@"), AgentWorkflowSeamDoctor.init_command_line(command), prefix
    end
  end

  def test_init_does_not_treat_a_relative_env_executable_as_the_env_utility
    command = %q(./bin/env bash -c 'echo "$@"')

    assert_equal %(exec #{command} "$@"), AgentWorkflowSeamDoctor.init_command_line(command)
  end

  def test_init_distinguishes_escaped_and_braced_outer_argument_forwarding
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'printf \\$@',
        "--test-command", 'bin/test "${@}"'
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec printf \\$@ "$@"'
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes test, 'exec bin/test "${@}"'
      refute_includes test, 'bin/test "${@}" "$@"'
    end
  end

  def test_init_rejects_an_assignment_only_command_with_quoted_forwarding_text
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "LABEL='\$@'",
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "assignment-only commands cannot safely forward wrapper arguments"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_rejects_argument_forwarding_text_inside_a_shell_comment
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'bin/validate # "$@" is documentation',
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "argument-forwarding text inside a shell comment is ambiguous"
      refute File.exist?(File.join(root, ".agents/bin/validate"))
    end
  end

  def test_init_allows_commented_forwarding_text_after_real_outer_forwarding
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'echo "$@" # caller forwards "$@"'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), "#{command}\n"
    end
  end

  def test_init_escapes_pipes_in_the_generated_readme_table
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'bin/validate "$@" | tee validate.log'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      readme = File.read(File.join(root, ".agents/bin/README.md"))
      assert_includes readme, '| `validate` | Pre-push gate | `bin/validate "$@" \| tee validate.log` |'
      refute_includes readme, '| `bin/validate "$@" | tee validate.log` |'
    end
  end

  def test_init_uses_a_safe_markdown_code_span_for_commands_with_backticks
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = "echo `date`"
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      readme = File.read(File.join(root, ".agents/bin/README.md"))
      assert_includes readme, "| `validate` | Pre-push gate | `` echo `date` `` |"
      refute_includes readme, "| `validate` | Pre-push gate | `echo `date`` |"
    end
  end

  def test_init_ignores_fenced_pointer_headings_and_preserves_the_example
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      example = <<~MARKDOWN
        # AGENTS.md

        ## Example

        ```markdown
        ## Agent Workflow Configuration

        Example content that must remain fenced.
        ```

        ## Existing Guidance

        Keep this guidance.
      MARKDOWN
      File.write(File.join(root, "AGENTS.md"), example)

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      agents = File.read(File.join(root, "AGENTS.md"))
      assert agents.start_with?(example)
      assert_includes agents, "Example content that must remain fenced.\n```"
      assert_equal 2, agents.scan("## Agent Workflow Configuration").length
      assert_includes agents, "Keep this guidance."
    end
  end

  def test_init_rejects_one_explicit_command_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(root, "--init", "--validate-command", "true")

      refute status.success?
      assert_includes out, "--validate-command and --test-command must be provided together"
      refute File.exist?(File.join(root, ".agents"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_reports_missing_root_before_an_incomplete_explicit_command_pair
    Dir.mktmpdir("agent-workflow-seam-init") do |parent|
      missing = File.join(parent, "missing")
      out, status = run_doctor(missing, "--init", "--validate-command", "true")

      refute status.success?
      assert_includes out, "missing directory: #{missing}"
      refute_includes out, "must be provided together"
    end
  end

  def test_init_rejects_explicit_commands_that_would_replace_repo_owned_wrappers
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin"))
      validate_path = write_script(root, "validate", "exec echo repo-validate \"$@\"\n")
      test_path = write_script(root, "test", "exec echo repo-test \"$@\"\n")
      before = { validate_path => File.binread(validate_path), test_path => File.binread(test_path) }

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "echo replacement-validate",
        "--test-command", "echo replacement-test"
      )

      refute status.success?
      assert_includes out, "explicit commands cannot replace repo-owned wrappers"
      assert_includes out, ".agents/bin/validate"
      assert_includes out, ".agents/bin/test"
      after = before.keys.to_h { |path| [path, File.binread(path)] }
      assert_equal before, after
      refute File.exist?(File.join(root, ".agents/bin/README.md"))
      refute File.exist?(File.join(root, ".agents/agent-workflow.yml"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_api_rejects_one_explicit_command_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      error = assert_raises(AgentWorkflowSeamDoctor::InitError) do
        AgentWorkflowSeamDoctor.init(
          root,
          base_branch: "main",
          validate_command: "true",
          test_command: nil
        )
      end

      assert_includes error.message, "--validate-command and --test-command must be provided together"
      refute File.exist?(File.join(root, ".agents"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_unknown_repo_writes_fail_closed_wrappers_and_precise_next_step
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "unconfigured init wrapper: .agents/bin/validate"
      assert_includes out, "rerun --init with both --validate-command CMD and --test-command CMD"
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, "# Agent workflow seam init: command not configured."

      checked_out, checked_status = run_doctor(root)
      refute checked_status.success?
      assert_includes checked_out, "unconfigured init wrapper: .agents/bin/validate"
    end
  end

  def test_init_detects_executable_root_validate_and_test_commands
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      %w[validate test].each do |name|
        path = File.join(root, "bin", name)
        File.write(path, "#!/usr/bin/env bash\nexit 0\n")
        File.chmod(0o755, path)
      end

      out, status = run_doctor(root, "--init")

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec bin/validate "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec bin/test "$@"'
    end
  end

  def test_init_detects_exact_javascript_scripts_with_runner_specific_argument_forwarding
    {
      "package-lock.json" => 'exec npm run validate -- "$@"',
      "pnpm-lock.yaml" => 'exec pnpm run validate "$@"',
      "yarn.lock" => 'exec yarn run validate "$@"'
    }.each do |lockfile, expected_validate|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        File.write(File.join(root, "package.json"), JSON.generate("scripts" => { "validate" => "check", "test" => "spec" }))
        File.write(File.join(root, lockfile), "lock\n")

        out, status = run_doctor(root, "--init")

        assert status.success?, "#{lockfile}: #{out}"
        assert_includes File.read(File.join(root, ".agents/bin/validate")), expected_validate
      end
    end
  end

  def test_init_explicit_javascript_runner_commands_use_runner_specific_argument_forwarding
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run validate",
        "--test-command", "pnpm run test"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, 'exec npm run validate -- "$@"'
      assert_includes test, 'exec pnpm run test "$@"'
      refute_includes test, 'pnpm run test -- "$@"'
    end
  end

  def test_init_does_not_duplicate_a_leading_exec
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "exec bundle exec rake validate",
        "--test-command", "exec npm run test"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, 'exec bundle exec rake validate "$@"'
      refute_includes validate, "exec exec"
      assert_includes test, 'exec npm run test -- "$@"'
      refute_includes test, "exec exec"
    end
  end

  def test_init_normalizes_outer_command_whitespace_before_classification
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "  exec true  ",
        "--test-command", "  CI=1 npm run test  "
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, 'exec true "$@"'
      refute_includes validate, "exec  exec"
      assert_includes test, 'CI=1 npm run test -- "$@"'
      refute_includes test, "exec  CI=1"
    end
  end

  def test_init_adds_npm_separator_after_leading_environment_assignments
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "CI=1 npm run validate",
        "--test-command", "CI=1 LABEL='test suite' exec npm run test"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, 'CI=1 npm run validate -- "$@"'
      assert_includes test, %(CI=1 LABEL='test suite' exec npm run test -- "$@")
    end
  end

  def test_init_adds_npm_separator_after_npm_options
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm --prefix app run validate",
        "--test-command", "CI=1 npm --workspace packages/core --silent run test"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, 'exec npm --prefix app run validate -- "$@"'
      assert_includes test, 'CI=1 npm --workspace packages/core --silent run test -- "$@"'
    end
  end

  def test_init_adds_npm_separator_for_run_script_alias
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run-script validate",
        "--test-command", "npm --prefix app run-script test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec npm run-script validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec npm --prefix app run-script test -- "$@"'
    end
  end

  def test_init_adds_npm_separator_for_run_aliases
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm rum validate",
        "--test-command", "npm urn test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec npm rum validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec npm urn test -- "$@"'
    end
  end

  def test_init_adds_npm_separator_for_test_lifecycle_command
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm --prefix app test",
        "--test-command", "npm test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec npm --prefix app test -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec npm test -- "$@"'
    end
  end

  def test_init_adds_npm_separator_for_test_aliases
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm --prefix app tst",
        "--test-command", "npm t"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec npm --prefix app tst -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec npm t -- "$@"'
    end
  end

  def test_init_adds_npm_separator_after_env_utility_assignments
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "env CI=1 npm run validate",
        "--test-command", "/usr/bin/env LABEL='test suite' npm run-script test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec env CI=1 npm run validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      %(exec /usr/bin/env LABEL='test suite' npm run-script test -- "$@")
    end
  end

  def test_init_adds_npm_separator_after_env_utility_options
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "env -u CI npm run validate",
        "--test-command", "env --chdir app --ignore-environment npm run-script test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec env -u CI npm run validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec env --chdir app --ignore-environment npm run-script test -- "$@"'
    end
  end

  def test_init_preserves_env_split_string_commands_verbatim
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      validate_command = "env -S 'npm run validate'"
      test_command = "env --split-string='npm run test'"
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", validate_command,
        "--test-command", test_command
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      assert_includes validate, "#{validate_command}\n"
      refute_includes validate, "#{validate_command} \"$@\""
      assert_includes test, "#{test_command}\n"
      refute_includes test, "#{test_command} \"$@\""
    end
  end

  def test_init_adds_npm_separator_after_env_option_terminator
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "env -- npm run validate",
        "--test-command", "env -- npm run-script test"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec env -- npm run validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), 'exec env -- npm run-script test -- "$@"'
    end
  end

  def test_init_adds_npm_separator_before_caller_supplied_argument_forwarding
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'npm run validate "$@"',
        "--test-command", "CI=1 npm run-script test \$@"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")), 'exec npm run validate -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")), "CI=1 npm run-script test -- \$@"
    end
  end

  def test_init_adds_npm_separator_immediately_after_script_operand_with_existing_arguments
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'npm run validate --grep smoke "$@"',
        "--test-command", "npm test --watch=false"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")),
                      'exec npm run validate -- --grep smoke "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      'exec npm test -- --watch=false "$@"'
    end
  end

  def test_init_repositions_a_late_npm_separator_without_duplicating_it
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", 'npm run validate --grep smoke -- "$@"',
        "--test-command", "true"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, 'exec npm run validate -- --grep smoke "$@"'
      refute_includes validate, '-- --grep smoke -- "$@"'
    end
  end

  def test_init_preserves_an_existing_npm_separator_after_the_option_prefix
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      command = 'npm run validate --omit=dev -- --grep smoke "$@"'
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", command,
        "--test-command", "true"
      )

      assert status.success?, out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      assert_includes validate, "exec #{command}"
      refute_includes validate, "npm run validate -- -- --grep"
    end
  end

  def test_init_preserves_npm_cli_options_after_the_script_operand
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run validate --workspace packages/core",
        "--test-command", "npm test --ignore-scripts"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")),
                      'exec npm run validate --workspace packages/core -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      'exec npm test --ignore-scripts -- "$@"'
    end
  end

  def test_init_preserves_generic_npm_cli_options_after_the_script_operand
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run validate --loglevel silent",
        "--test-command", "npm test --silent"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")),
                      'exec npm run validate --loglevel silent -- "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      'exec npm test --silent -- "$@"'
    end
  end

  def test_init_uses_exact_npm_config_key_and_arity_metadata_before_script_arguments
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run validate --omit=dev --color=false -w2 --grep smoke",
        "--test-command", "npm test --omit dev --silent intent"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")),
                      'exec npm run validate --omit=dev --color=false -w2 -- --grep smoke "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      'exec npm test --omit dev --silent -- intent "$@"'
    end
  end

  def test_init_preserves_dash_prefixed_values_for_required_npm_options
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "npm run validate --workspace --grep smoke",
        "--test-command", "npm test --node-options --max-old-space-size=4096 --watch=false"
      )

      assert status.success?, out
      assert_includes File.read(File.join(root, ".agents/bin/validate")),
                      'exec npm run validate --workspace --grep -- smoke "$@"'
      assert_includes File.read(File.join(root, ".agents/bin/test")),
                      'exec npm test --node-options --max-old-space-size=4096 -- --watch=false "$@"'
      assert_equal 'exec npm test --node-options=--max-old-space-size=4096 -- --watch=false "$@"',
                   AgentWorkflowSeamDoctor.init_command_line(
                     "npm test --node-options=--max-old-space-size=4096 --watch=false"
                   )
    end
  end

  def test_init_uses_vendored_npm_metadata_without_an_npm_executable
    original_path = ENV.fetch("PATH", nil)
    ENV["PATH"] = "/nonexistent"

    command = AgentWorkflowSeamDoctor.init_command_line(
      "npm test -ddd --quiet --yes --production --no-production --no-audit --npm-version 11.6.0 --watch=false"
    )

    assert_equal "exec npm test -ddd --quiet --yes --production --no-production --no-audit " \
                 '--npm-version 11.6.0 -- --watch=false "$@"',
                 command
  ensure
    ENV["PATH"] = original_path
  end

  def test_init_appends_missing_yaml_keys_without_losing_comments_or_formatting
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      trust_path = File.join(root, ".agents/trusted-github-actors.yml")
      policy_prefix = <<~YAML
        # Keep this policy guidance.
        base_branch: develop # deployment branch
        custom_policy: "keep quoted"
      YAML
      trust_prefix = <<~YAML
        # Keep this trust guidance.
        trusted_users:
          - maintainer # release owner
      YAML
      File.write(policy_path, policy_prefix)
      File.write(trust_path, trust_prefix)

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      assert File.read(policy_path).start_with?(policy_prefix)
      assert File.read(trust_path).start_with?(trust_prefix)
      policy = YAML.safe_load(File.read(policy_path))
      trust = YAML.safe_load(File.read(trust_path))
      assert_equal "develop", policy.fetch("base_branch")
      assert_equal "keep quoted", policy.fetch("custom_policy")
      assert_equal [], trust.fetch("trusted_bots")
      assert_equal [], trust.fetch("trusted_metadata_bots")
      assert_equal [], trust.fetch("trusted_teams")
    end
  end

  def test_init_fails_before_writing_when_existing_yaml_cannot_be_safely_appended
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      original = "{base_branch: develop} # keep flow style\n"
      File.write(policy_path, original)

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "cannot safely add missing policy config keys without rewriting"
      assert_equal original, File.read(policy_path)
      refute File.exist?(File.join(root, ".agents/bin"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_reports_filesystem_errors_without_a_backtrace
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin/validate"))

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "FAIL agent workflow seam has 1 issue(s)"
      refute_includes out, "agent-workflow-seam-doctor:"
      refute_includes out, "Errno::EISDIR"
    end
  end

  def test_init_treats_non_object_package_json_as_unknown
    [[], "package", 1, nil].each do |package|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        File.write(File.join(root, "package.json"), JSON.generate(package))
        File.write(File.join(root, "package-lock.json"), "lock\n")

        out, status = run_doctor(root, "--init")

        refute status.success?
        assert_includes out, "unconfigured init wrapper"
        refute_includes out, "TypeError"
        refute_includes out, "NoMethodError"
      end
    end
  end

  def test_init_treats_invalid_utf8_package_json_as_unknown
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      File.binwrite(File.join(root, "package.json"), "{\xFF}".b)
      File.write(File.join(root, "package-lock.json"), "lock\n")

      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "unconfigured init wrapper"
      refute_includes out, "invalid byte sequence"
      refute_includes out, "Encoding::"
    end
  end

  def test_init_does_not_detect_blank_javascript_scripts
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      File.write(File.join(root, "package.json"), JSON.generate("scripts" => { "validate" => " ", "test" => "spec" }))
      File.write(File.join(root, "package-lock.json"), "lock\n")

      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "unconfigured init wrapper"
    end
  end

  def test_init_json_reports_shared_root_validation_failures
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      missing_shared = File.join(root, "missing-shared")
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true",
        "--shared", missing_shared,
        "--json"
      )

      refute status.success?
      payload = JSON.parse(out)
      assert_equal "FAIL", payload.fetch("status")
      assert_includes payload.fetch("issues"), "missing shared root: #{missing_shared}"
    end
  end

  def test_init_preserves_an_existing_valid_seam_and_is_idempotent
    with_repo do |root|
      write_valid_binstub_contract(root)
      trust_path = File.join(root, ".agents/trusted-github-actors.yml")
      File.write(trust_path, {
        "trusted_users" => ["maintainer"],
        "trusted_bots" => [],
        "trusted_metadata_bots" => ["github-actions"],
        "trusted_teams" => []
      }.to_yaml)
      paths = [
        "AGENTS.md",
        ".agents/bin/README.md",
        ".agents/bin/validate",
        ".agents/bin/test",
        ".agents/agent-workflow.yml",
        ".agents/trusted-github-actors.yml"
      ]
      before = paths.to_h { |path| [path, File.binread(File.join(root, path))] }

      out, status = run_doctor(root, "--init")
      assert status.success?, out
      second_out, second_status = run_doctor(root, "--init")
      assert second_status.success?, second_out

      after = paths.to_h { |path| [path, File.binread(File.join(root, path))] }
      assert_equal before, after
    end
  end

  def test_init_readme_records_existing_optional_wrappers
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents/bin"))
      write_script(root, "lint", "exec echo lint \"$@\"\n")

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      readme = File.read(File.join(root, ".agents/bin/README.md"))
      assert_includes readme, "| `lint` | Lint / format | configured wrapper |"
      refute_includes readme, "| `lint` | Lint / format | n/a |"
    end
  end

  def test_bare_init_refreshes_managed_readme_for_new_optional_wrapper
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      first_out, first_status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )
      assert first_status.success?, first_out
      refute_includes File.read(File.join(root, ".agents/bin/README.md")), "| `lint` | Lint / format | configured wrapper |"
      write_script(root, "lint", "exec echo lint \"$@\"\n")

      second_out, second_status = run_doctor(root, "--init")

      assert second_status.success?, second_out
      assert_includes File.read(File.join(root, ".agents/bin/README.md")), "| `lint` | Lint / format | configured wrapper |"
    end
  end

  def test_init_preserves_scalar_trust_entries_accepted_by_preflight
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      trust_path = File.join(root, ".agents/trusted-github-actors.yml")
      File.write(trust_path, "trusted_bots: deploy\n")

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      trust = YAML.safe_load(File.read(trust_path))
      assert_equal "deploy", trust.fetch("trusted_bots")
      assert_equal [], trust.fetch("trusted_metadata_bots")
    end
  end

  def test_init_validates_existing_yaml_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      policy_path = File.join(root, ".agents/agent-workflow.yml")
      File.write(policy_path, "base_branch: [\n")

      out, status = run_doctor(root, "--init", "--validate-command", "true", "--test-command", "true")

      refute status.success?
      assert_includes out, "invalid policy config"
      assert_equal "base_branch: [\n", File.read(policy_path)
      refute File.exist?(File.join(root, "AGENTS.md"))
      refute File.exist?(File.join(root, ".agents/bin"))
    end
  end

  def test_init_rejects_overlapping_trusted_bot_roles_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      trust_path = File.join(root, ".agents/trusted-github-actors.yml")
      trust = {
        "trusted_users" => [],
        "trusted_bots" => ["@Deploy[bot]"],
        "trusted_metadata_bots" => ["deploy"],
        "trusted_teams" => []
      }
      File.write(trust_path, trust.to_yaml)
      before = File.binread(trust_path)

      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "bot(s) listed in both trusted_bots and trusted_metadata_bots: deploy"
      assert_equal before, File.binread(trust_path)
      refute File.exist?(File.join(root, ".agents/bin"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_does_not_guess_when_javascript_detection_is_ambiguous
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      File.write(File.join(root, "package.json"), JSON.generate("scripts" => { "validate" => "check", "test" => "spec" }))
      File.write(File.join(root, "package-lock.json"), "lock\n")
      File.write(File.join(root, "yarn.lock"), "lock\n")

      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "unconfigured init wrapper"
    end
  end

  def test_init_uses_explicit_base_branch_for_new_policy
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--base-branch", "develop",
        "--validate-command", "true",
        "--test-command", "true"
      )

      assert status.success?, out
      policy = YAML.safe_load(File.read(File.join(root, ".agents/agent-workflow.yml")))
      assert_equal "develop", policy.fetch("base_branch")
    end
  end

  def test_init_rejects_invalid_base_branch_before_writing
    ["", "feature\nbranch", "feature\0branch", "feature branch", "feature~branch", "release.lock", "-hidden", "@{-1}"].each do |base_branch|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        error = assert_raises(AgentWorkflowSeamDoctor::InitError) do
          AgentWorkflowSeamDoctor.init(
            root,
            base_branch: base_branch,
            validate_command: "true",
            test_command: "true"
          )
        end

        assert_includes error.message, "base branch must be a valid Git branch name"
        refute File.exist?(File.join(root, ".agents"))
        refute File.exist?(File.join(root, "AGENTS.md"))
      end
    end
  end

  def test_init_rejects_multiline_command_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(
        root,
        "--init",
        "--validate-command", "true\necho unexpected",
        "--test-command", "true"
      )

      refute status.success?
      assert_includes out, "commands must be non-empty single-line shell commands without NUL bytes"
      refute File.exist?(File.join(root, ".agents"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_rejects_nul_command_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      error = assert_raises(AgentWorkflowSeamDoctor::InitError) do
        AgentWorkflowSeamDoctor.init(
          root,
          base_branch: "main",
          validate_command: "true\0unexpected",
          test_command: "true"
        )
      end

      assert_includes error.message, "commands must be non-empty single-line shell commands without NUL bytes"
      refute File.exist?(File.join(root, ".agents"))
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_init_reports_missing_root_without_creating_it
    Dir.mktmpdir("agent-workflow-seam-init") do |parent|
      root = File.join(parent, "missing")

      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "missing directory: #{root}"
      refute File.exist?(root)
    end
  end

  def test_init_text_and_json_report_the_same_failures
    Dir.mktmpdir("agent-workflow-seam-init-text") do |text_root|
      text, text_status = run_doctor(text_root, "--init")
      refute text_status.success?

      Dir.mktmpdir("agent-workflow-seam-init-json") do |json_root|
        json, json_status = run_doctor(json_root, "--init", "--json")
        refute json_status.success?
        payload = JSON.parse(json)

        assert_equal "FAIL", payload.fetch("status")
        payload.fetch("issues").each do |issue|
          normalized = issue.sub(json_root, text_root)
          assert_includes text, normalized
        end
      end
    end
  end

  def test_bare_init_preserves_previously_generated_valid_wrappers
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      first_out, first_status = run_doctor(
        root,
        "--init",
        "--validate-command", "true",
        "--test-command", "true"
      )
      assert first_status.success?, first_out
      paths = %w[
        AGENTS.md
        .agents/bin/README.md
        .agents/bin/validate
        .agents/bin/test
        .agents/agent-workflow.yml
        .agents/trusted-github-actors.yml
      ]
      before = paths.to_h do |path|
        [path, File.binread(File.join(root, path))]
      end

      second_out, second_status = run_doctor(root, "--init")

      assert second_status.success?, second_out
      after = paths.to_h do |path|
        [path, File.binread(File.join(root, path))]
      end
      assert_equal before, after
    end
  end

  def test_bare_init_restores_managed_wrapper_mode_without_rewriting_content
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      first_out, first_status = run_doctor(
        root,
        "--init",
        "--validate-command", "echo explicit-validate",
        "--test-command", "echo explicit-test"
      )
      assert first_status.success?, first_out
      validate_path = File.join(root, ".agents/bin/validate")
      before = File.binread(validate_path)
      File.chmod(0o644, validate_path)

      second_out, second_status = run_doctor(root, "--init")

      assert second_status.success?, second_out
      assert File.executable?(validate_path)
      assert_equal before, File.binread(validate_path)
      assert_includes File.read(validate_path), "explicit-validate"
      refute_includes File.read(validate_path), AgentWorkflowSeamDoctor::INIT_PLACEHOLDER_MARKER
    end
  end

  def test_bare_init_preserves_explicit_wrappers_when_root_commands_are_detectable
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      %w[validate test].each do |name|
        path = File.join(root, "bin", name)
        File.write(path, "#!/usr/bin/env bash\necho root-#{name}\n")
        File.chmod(0o755, path)
      end
      first_out, first_status = run_doctor(
        root,
        "--init",
        "--validate-command", "echo explicit-validate",
        "--test-command", "echo explicit-test"
      )
      assert first_status.success?, first_out
      paths = %w[.agents/bin/README.md .agents/bin/validate .agents/bin/test]
      before = paths.to_h { |path| [path, File.binread(File.join(root, path))] }

      second_out, second_status = run_doctor(root, "--init")

      assert second_status.success?, second_out
      after = paths.to_h { |path| [path, File.binread(File.join(root, path))] }
      assert_equal before, after
      assert_includes File.read(File.join(root, ".agents/bin/validate")), "explicit-validate"
      refute_includes File.read(File.join(root, ".agents/bin/validate")), "bin/validate"
    end
  end

  def test_explicit_commands_replace_previously_generated_wrappers
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      first_out, first_status = run_doctor(
        root,
        "--init",
        "--validate-command", "echo first",
        "--test-command", "echo first-test"
      )
      assert first_status.success?, first_out

      second_out, second_status = run_doctor(
        root,
        "--init",
        "--validate-command", "echo second",
        "--test-command", "echo second-test"
      )

      assert second_status.success?, second_out
      validate = File.read(File.join(root, ".agents/bin/validate"))
      test = File.read(File.join(root, ".agents/bin/test"))
      readme = File.read(File.join(root, ".agents/bin/README.md"))
      assert_includes validate, "exec echo second"
      refute_includes validate, "exec echo first"
      assert_includes test, "exec echo second-test"
      refute_includes test, "exec echo first-test"
      assert_includes readme, "`echo second`"
      assert_includes readme, "`echo second-test`"
    end
  end

  def test_init_does_not_detect_root_command_directories
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      FileUtils.mkdir_p(File.join(root, "bin/validate"))
      FileUtils.mkdir_p(File.join(root, "bin/test"))

      out, status = run_doctor(root, "--init")

      refute status.success?
      assert_includes out, "unconfigured init wrapper"
    end
  end
end
