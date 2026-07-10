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

  def test_init_rejects_one_explicit_command_before_writing
    Dir.mktmpdir("agent-workflow-seam-init") do |root|
      out, status = run_doctor(root, "--init", "--validate-command", "true")

      refute status.success?
      assert_includes out, "--validate-command and --test-command must be provided together"
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

  def test_init_detects_exact_javascript_scripts_with_one_package_manager_lockfile
    {
      "package-lock.json" => "npm run",
      "pnpm-lock.yaml" => "pnpm run",
      "yarn.lock" => "yarn run"
    }.each do |lockfile, runner|
      Dir.mktmpdir("agent-workflow-seam-init") do |root|
        File.write(File.join(root, "package.json"), JSON.generate("scripts" => { "validate" => "check", "test" => "spec" }))
        File.write(File.join(root, lockfile), "lock\n")

        out, status = run_doctor(root, "--init")

        assert status.success?, "#{lockfile}: #{out}"
        assert_includes File.read(File.join(root, ".agents/bin/validate")), "exec #{runner} validate"
        assert_includes File.read(File.join(root, ".agents/bin/test")), "exec #{runner} test"
      end
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
