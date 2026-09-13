#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"

load File.expand_path("validate-docs", __dir__)

class PrValidationScopeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOC = "docs/problems-solved.md"

  def setup
    @root = Dir.mktmpdir("pr-validation-scope")
    git("init", "-q")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Validation Test")
    write(DOC, "# Problems\n")
    write("README.md", "# Readme\n")
    write("bin/validate", "echo \"== routing doc links ==\"\necho \"== installer ==\"\n")
    write("bin/pr-validation-scope", File.read(File.join(ROOT, "bin/pr-validation-scope")))
    @base = commit
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    PrValidationScope.git(@root, *args).strip
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), text)
  end

  def commit
    git("add", "-A")
    git("commit", "-qm", "fixture")
    git("rev-parse", "HEAD")
  end

  def selection(base: @base, head: git("rev-parse", "HEAD"), target: head, draft: "true", event: "pull_request")
    PrValidationScope.select(@root, event: event, base: base, head: head, target: target, draft: draft).first
  end

  def test_ordinary_docs_modify_and_add_select_docs
    write(DOC, "# Updated\n")
    write(PrValidationScope::DOCUMENTS.last, "# Case study\n")
    commit
    assert_equal "docs", selection
  end

  def test_instruction_markdown_and_every_unclassified_kind_select_full
    %w[AGENTS.md CLAUDE.md CONTEXT.md SECURITY.md skills/example/SKILL.md workflows/guide.md
       docs/README.md docs/installation-and-upgrades.md docs/unknown.md bin/tool
       .github/workflows/validate.yml .agents/agent-workflow.yml new.json].each do |path|
      git("reset", "--hard", @base)
      write(path, "changed\n")
      commit
      assert_equal "full", selection, path
    end
  end

  def test_readme_prose_is_fast_but_embedded_command_changes_select_full
    ["```bash\ninstall safe\n```", "~~~sh\ninstall safe\n~~~",
     "Run `install safe` now.", "Run ``install safe`` now.", "    install safe", " \tinstall safe", "```bash\ninstall safe",
     "```sh\n    ```\ninstall safe\n```", "<script>\ninstall safe\n</script>"].each do |code|
      git("reset", "--hard", @base)
      write("README.md", "# Readme\n\nOriginal prose.\n\n#{code}\n")
      code_base = commit
      write("README.md", "# Readme\n\nUpdated prose.\n\n#{code}\n")
      commit
      # HTML code blocks deliberately make the entire document conservative.
      expected = code.start_with?("<script>") ? "full" : "docs"
      assert_equal expected, selection(base: code_base), code
      write("README.md", "# Readme\n\nUpdated prose.\n\n#{code.sub('install safe', 'install changed')}\n")
      commit
      assert_equal "full", selection(base: code_base), code
    end
  end

  def test_renames_deletions_executable_and_symlink_docs_select_full
    FileUtils.mkdir_p(File.join(@root, "docs/postmortems"))
    git("mv", DOC, PrValidationScope::DOCUMENTS.last)
    commit
    assert_equal "full", selection
    git("reset", "--hard", @base)
    git("rm", DOC)
    commit
    assert_equal "full", selection
    git("reset", "--hard", @base)
    File.chmod(0o755, File.join(@root, DOC))
    commit
    assert_equal "full", selection
    git("reset", "--hard", @base)
    File.unlink(File.join(@root, DOC))
    File.symlink("../README.md", File.join(@root, DOC))
    commit
    assert_equal "full", selection
  end

  def test_moving_unchanged_commands_between_sections_selects_full
    ["```bash\ninstall safe\n```", "Run `install safe` now.", "    install safe"].each do |code|
      git("checkout", "--detach", @base)
      write("README.md", "# Readme\n\n## First\n\n#{code}\n\n## Second\n\nMore prose.\n")
      code_base = commit
      write("README.md", "# Readme\n\n## First\n\n## Second\n\nMore prose.\n\n#{code}\n")
      head = commit
      assert_equal "full", selection(base: code_base), code
      git("checkout", "--detach", code_base)
      git("merge", "--no-ff", "-m", "integration", head)
      assert_equal "full", selection(base: code_base, head: head, target: git("rev-parse", "HEAD"), draft: "false"), code
    end
  end

  def test_multiline_and_mismatched_inline_code_use_full_coverage
    ["`sh\ninstall safe\n`", "``sh\ninstall safe\n``", "`install safe``",
     "Run \\` before `sh\ninstall safe\nargument` after \\`.",
     "Run `a `` b` ``sh\ninstall safe\nargument`` after `a `` b`.",
     "```inline```\n<!-- markdownlint-disable MD040 -->\n```\ninstall safe\n```",
     "Run ```inline``` now.\n<!-- markdownlint-disable MD040 -->\n```\ninstall safe\n```"].each do |code|
      git("reset", "--hard", @base)
      write("README.md", "# Readme\n\nOriginal prose.\n\n#{code}\n")
      code_base = commit
      write("README.md", "# Readme\n\nUpdated prose.\n\n#{code}\n")
      commit
      assert_equal "full", selection(base: code_base), code
      write("README.md", "# Readme\n\nOriginal prose.\n\n#{code.sub('install safe', 'install changed')}\n")
      commit
      assert_equal "full", selection(base: code_base), code
    end
  end

  def test_container_code_and_raw_html_cannot_use_docs_coverage
    [">     install safe", "  >     install safe", "-     install safe",
     "1.     install safe", "> -     install safe", "<code>\ninstall safe\n</code>"].each do |code|
      git("reset", "--hard", @base)
      write("README.md", "# Readme\n\n#{code}\n")
      code_base = commit
      write("README.md", "# Readme\n\n#{code.sub('install safe', 'install changed')}\n")
      commit
      assert_equal "full", selection(base: code_base), code
    end
  end

  def test_real_readme_plain_prose_change_remains_eligible
    readme = File.read(File.join(ROOT, "README.md"))
    write("README.md", readme)
    readme_base = commit
    write("README.md", "#{readme}\nA plain documentation note.\n")
    commit
    assert_equal "docs", selection(base: readme_base)
  end

  def test_empty_missing_and_malformed_evidence_select_full
    assert_equal "full", selection
    assert_equal "full", selection(base: "f" * 40)
    assert_equal "full", selection(base: nil)
    assert_equal "full", selection(base: "HEAD")
    ["", "incomplete", ":100644 100644 #{'a' * 40} #{'b' * 40} M\0",
     ":100644 100644 #{'a' * 40} #{'b' * 40} M\0#{DOC}",
     ":100644 100644 #{'a' * 40} #{'b' * 40} R100\0README.md\0#{DOC}\0"].each do |raw|
      assert_equal "full", PrValidationScope.classify(raw).first
    end
  end

  def test_main_and_mismatched_checkout_never_select_docs
    write(DOC, "# Updated\n")
    commit
    assert_equal "full", selection(event: "push")
    assert_equal "full", selection(target: @base)
    assert_equal "full", selection(head: @base)
    assert_equal "full", selection(draft: "false")
  end

  def test_ready_pr_requires_exact_integration_parents
    git("checkout", "-qb", "topic")
    write(DOC, "# Updated\n")
    head = commit
    git("checkout", "--detach", @base)
    git("merge", "--no-ff", "-m", "integration", head)
    target = git("rev-parse", "HEAD")
    assert_equal "docs", selection(head: head, target: target, draft: "false")
    assert_equal "full", selection(head: @base, target: target, draft: "false")
  end

  def test_draft_behind_changed_code_on_base_selects_full
    write("bin/runtime", "base changed\n")
    newer_base = commit
    git("checkout", "--detach", @base)
    write(DOC, "# Updated\n")
    commit
    assert_equal "full", selection(base: newer_base)
  end

  def test_trusted_base_selector_rejects_pr_that_relaxes_its_own_policy
    write("bin/pr-validation-scope", "puts 'scope=docs'\n")
    head = commit
    trusted = File.join(@root, "trusted-selector.rb")
    File.write(trusted, git("show", "#{@base}:bin/pr-validation-scope"))
    output = File.join(@root, "output")
    summary = File.join(@root, "summary")
    env = { "GITHUB_EVENT_NAME" => "pull_request", "PR_BASE_SHA" => @base,
            "PR_HEAD_SHA" => head, "PR_DRAFT" => "true", "GITHUB_OUTPUT" => output,
            "GITHUB_STEP_SUMMARY" => summary }
    _stdout, stderr, status = Open3.capture3(env, "ruby", trusted, chdir: @root)
    assert status.success?, stderr
    assert_equal "scope=full\n", File.read(output)
    assert_includes File.read(summary), head
    assert_includes File.read(summary), @base
  end

  def test_docs_summary_reports_selection_and_omissions_without_claiming_full_success
    write(DOC, "# Updated\n")
    head = commit
    env = { "GITHUB_EVENT_NAME" => "pull_request", "PR_BASE_SHA" => @base,
            "PR_HEAD_SHA" => head, "PR_DRAFT" => "true" }
    output, = capture_io { assert_equal 0, PrValidationScope.run(@root, env) }
    assert_includes output, "Validation coverage: docs"
    assert_includes output, "Selected suites: Markdown lint"
    assert_includes output, "Omitted suites: installer"
    assert_includes output, head
    assert_includes output, @base
  end

  def test_applicable_broken_link_and_failed_markdown_lint_fail_selected_validation
    (PrValidationScope::DOCUMENTS + ValidateDocLinks::CHECKED_DOCUMENTS).uniq.each do |path|
      write(path, "# Heading\n\n[Self](#heading)\n")
    end
    assert_empty ValidateOrdinaryDocs.validate(@root)
    write(DOC, "# Heading\n\n[Broken](missing.md)\n")
    %w[validate-docs pr-validation-scope validate-doc-links].each do |script|
      write("bin/#{script}", File.read(File.join(ROOT, "bin", script)))
    end
    write("tools/markdownlint-cli2", "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(@root, "tools/markdownlint-cli2"))
    env = { "PATH" => "#{@root}/tools:#{ENV.fetch('PATH')}" }
    _stdout, stderr, status = Open3.capture3(env, "ruby", File.join(@root, "bin/validate-docs"))
    assert_equal 1, status.exitstatus
    assert_includes stderr, "link target not found"
    write("tools/markdownlint-cli2", "#!/bin/sh\nexit 1\n")
    stdout, _stderr, status = Open3.capture3(env, "ruby", File.join(@root, "bin/validate-docs"))
    assert_equal 1, status.exitstatus
    refute_includes stdout, "PASS"
  end

  def test_workflow_loads_base_policy_and_keeps_fail_closed_aggregate
    workflow = YAML.load_file(File.join(ROOT, ".github/workflows/validate.yml"))
    job = workflow.fetch("jobs").fetch("validate")
    steps = job.fetch("steps")
    selector = steps.find { |step| step["id"] == "scope" }
    assert_includes selector.fetch("run"), 'git show "${PR_BASE_SHA}:bin/pr-validation-scope"'
    assert_includes selector.fetch("run"), 'echo "scope=full"'
    assert_equal "${{ github.event.pull_request.base.sha }}", selector.fetch("env").fetch("PR_BASE_SHA")
    full = steps.find { |step| step["run"] == "bin/validate" }
    docs = steps.find { |step| step["run"] == "bin/validate-docs" }
    assert_equal "steps.scope.outputs.scope != 'docs'", full.fetch("if")
    assert_equal "steps.scope.outputs.scope == 'docs'", docs.fetch("if")
    refute docs.key?("continue-on-error")
    assert_equal "${{ github.event.pull_request.draft == true && 'validate (draft head)' || 'validate' }}", job.fetch("name")
  end

  def test_removing_readme_skill_navigation_fails_actual_selected_contracts
    files = PrValidationScope.git(ROOT, "ls-files", "-z").split("\0")
    files |= %w[bin/pr-validation-scope bin/pr-validation-scope-test.rb bin/validate-docs]
    files.each do |path|
      source = File.join(ROOT, path)
      next unless File.exist?(source) || File.symlink?(source)

      destination = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.copy_entry(source, destination, true, false)
    end
    readme = File.read(File.join(@root, "README.md"))
    broken = readme.sub("[Skill Guide](docs/skills.md)", "Skill Guide")
    refute_equal readme, broken
    assert_equal PrValidationScope.code_lines(readme), PrValidationScope.code_lines(broken)
    write("README.md", broken)
    write("tools/markdownlint-cli2", "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(@root, "tools/markdownlint-cli2"))
    env = { "PATH" => "#{@root}/tools:#{ENV.fetch('PATH')}", "BASH_ENV" => nil, "ENV" => nil }
    stdout, stderr, status = Open3.capture3(env, "ruby", File.join(@root, "bin/validate-docs"))
    assert_equal 1, status.exitstatus, "#{stdout}\n#{stderr}"
    assert_includes stdout, "test_public_skill_inventory_links_to_close_session_guide"
    refute_includes stdout, "PASS selected ordinary-documentation validation"
  end
end
