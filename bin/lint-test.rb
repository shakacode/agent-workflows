#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
load File.expand_path("lint", __dir__)

module LintCommandTestSupport
  FAKE_LINTER_SOURCE = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"

    tool = File.basename($PROGRAM_NAME)
    versions = {
      "rubocop" => "1.87.0", "shellcheck" => "0.11.0", "actionlint" => "1.7.12",
      "markdownlint-cli2" => "0.23.2", "yamllint" => "1.37.1"
    }
    if ARGV.include?("--version") || ARGV.include?("-version")
      version = versions.fetch(tool)
      case tool
      when "shellcheck"
        puts "ShellCheck - shell script analysis tool"
        puts "version: #{version}"
      when "markdownlint-cli2"
        puts "markdownlint-cli2 v#{version}"
      when "yamllint"
        puts "yamllint #{version}"
      else
        puts version
      end
      exit
    end

    File.open(ENV.fetch("LINT_TEST_LOG"), "a") { |file| file.puts(JSON.generate([tool, *ARGV])) }
    if tool == "rubocop" && ARGV.include?("--format")
      empty_result = { "metadata" => { "rubocop_version" => versions.fetch(tool) }, "files" => [] }
      puts ENV.fetch("LINT_TEST_RUBOCOP_RESULT", JSON.generate(empty_result))
    end
  RUBY

  def install_fake_linters(directory)
    %w[rubocop shellcheck actionlint markdownlint-cli2 yamllint].each do |tool|
      path = File.join(directory, tool)
      File.write(path, FAKE_LINTER_SOURCE)
      FileUtils.chmod(0o755, path)
    end
  end

  def rubocop_commands(commands)
    commands.select { |command| command.first == "rubocop" }.map { |command| command.drop(1) }
  end

  def increased_metrics_result
    { "metadata" => { "rubocop_version" => "1.87.0" }, "files" => [{
      "path" => "new.rb", "offenses" => [{
        "cop_name" => "Metrics/MethodLength", "message" => "Method has too many lines. [12/10]"
      }]
    }] }
  end
end

class LintCommandTest < Minitest::Test
  include LintCommandTestSupport

  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/lint")
  WRAPPER = File.join(ROOT, ".agents/bin/lint")
  WORKFLOW = File.join(ROOT, ".github/workflows/lint.yml")
  VALIDATE = File.join(ROOT, "bin/validate")
  YAML_TIMESTAMP_CLASSES = [Date, Time].freeze

  def test_missing_tool_message_points_to_lint_setup_guidance
    message = LintRunner.new.send(:missing_tool_message, "yamllint")

    assert_includes message, "Install yamllint 1.37.1"
    assert_includes message, "CONTRIBUTING.md#lint-toolchain-setup"
  end

  def test_repository_lint_command_is_the_portable_wrapper_target
    assert File.executable?(SCRIPT), "expected executable bin/lint"
    assert_includes File.read(WRAPPER), 'exec "$root/bin/lint" "$@"'
  end

  def test_reports_every_pinned_linter_version
    expected = {
      "rubocop" => File.read(File.join(ROOT, ".rubocop-version")).strip,
      "shellcheck" => "0.11.0",
      "actionlint" => "1.7.12",
      "markdownlint-cli2" => "0.23.2",
      "yamllint" => "1.37.1"
    }

    expected.each do |tool, version|
      stdout, stderr, status = Open3.capture3(SCRIPT, "--version", tool)

      assert status.success?, "#{tool}: #{stderr}"
      assert_equal "#{version}\n", stdout
    end
  end

  def test_runs_each_linter_over_its_tracked_surface
    Dir.mktmpdir("lint-command-test") do |directory|
      log = File.join(directory, "commands.jsonl")
      install_fake_linters(directory)
      environment = {
        "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
        "LINT_TEST_LOG" => log
      }

      stdout, stderr, status = Open3.capture3(environment, SCRIPT)

      assert status.success?, "#{stdout}\n#{stderr}"
      commands = File.readlines(log, chomp: true).map { |line| JSON.parse(line) }
      by_tool = commands.to_h { |command| [command.first, command.drop(1)] }
      assert_equal %w[actionlint markdownlint-cli2 rubocop shellcheck yamllint], by_tool.keys.sort
      rubocop_commands = rubocop_commands(commands)
      assert_equal 2, rubocop_commands.length
      metrics_command = rubocop_commands.find { |command| command.include?("--only") }
      regular_command = rubocop_commands.find { |command| !command.include?("--only") }
      refute_nil metrics_command
      assert(metrics_command.any? { |argument| argument.include?("Metrics/MethodLength") })
      assert_includes regular_command, "_#{File.read(File.join(ROOT, '.rubocop-version')).strip}_"
      assert_includes regular_command, "bin/lint"
      refute_includes regular_command, "README.md"
      assert_includes by_tool.fetch("shellcheck"), ".agents/bin/lint"
      assert_includes by_tool.fetch("markdownlint-cli2"), "README.md"
      assert_includes by_tool.fetch("yamllint"), ".github/workflows/validate.yml"
      assert_includes by_tool.fetch("yamllint"), "--strict"
      assert_includes by_tool.fetch("actionlint"), ".github/workflows/validate.yml"
    end
  end

  def test_stops_when_the_metrics_baseline_increases
    Dir.mktmpdir("lint-command-test") do |directory|
      log = File.join(directory, "commands.jsonl")
      install_fake_linters(directory)
      environment = { "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
                      "LINT_TEST_LOG" => log,
                      "LINT_TEST_RUBOCOP_RESULT" => JSON.generate(increased_metrics_result) }

      stdout, stderr, status = Open3.capture3(environment, SCRIPT)

      refute status.success?, stdout
      assert_includes stderr, "new.rb Metrics/MethodLength value #1: 0 -> 12"
      assert_equal 1, File.readlines(log).length
    end
  end

  def test_shell_surface_recognizes_env_and_absolute_interpreters
    runner = LintRunner.new

    Dir.mktmpdir("lint-shell-files") do |directory|
      ksh_file = File.join(directory, "tool.ksh")
      {
        "env" => "#!/usr/bin/env bash\n",
        "bin" => "#!/bin/bash\n",
        "usr-bin" => "#!/usr/bin/sh\n",
        "dash-bin" => "#!/bin/dash\n",
        "dash-env" => "#!/usr/bin/env dash\n",
        "ruby" => "#!/usr/bin/env ruby\n"
      }.each do |name, shebang|
        File.write(File.join(directory, name), shebang)
      end
      File.write(ksh_file, "print -r -- ksh\n")

      assert runner.send(:shell_file?, File.join(directory, "env"))
      assert runner.send(:shell_file?, File.join(directory, "bin"))
      assert runner.send(:shell_file?, File.join(directory, "usr-bin"))
      assert runner.send(:shell_file?, File.join(directory, "dash-bin"))
      assert runner.send(:shell_file?, File.join(directory, "dash-env"))
      assert runner.send(:shell_file?, ksh_file)
      refute runner.send(:shell_file?, File.join(directory, "ruby"))
    end
  end

  def test_shell_surface_excludes_zsh
    runner = LintRunner.new

    Dir.mktmpdir("lint-zsh-files") do |directory|
      extension = File.join(directory, "tool.zsh")
      shebang = File.join(directory, "tool")
      File.write(extension, "print -r -- zsh\n")
      File.write(shebang, "#!/usr/bin/env zsh\n")

      refute runner.send(:shell_file?, extension)
      refute runner.send(:shell_file?, shebang)
    end
  end

  def test_ruby_surface_recognizes_extensions_entrypoints_and_shebangs
    runner = LintRunner.new

    Dir.mktmpdir("lint-ruby-files") do |directory|
      ruby_file = File.join(directory, "tool.rb")
      rake_file = File.join(directory, "tasks.rake")
      gemspec_file = File.join(directory, "example.gemspec")
      rackup_file = File.join(directory, "config.ru")
      gemfile = File.join(directory, "Gemfile")
      script = File.join(directory, "script")
      markdown = File.join(directory, "README.md")
      File.write(ruby_file, "puts :ruby\n")
      File.write(rake_file, "task :default\n")
      File.write(gemspec_file, "Gem::Specification.new\n")
      File.write(rackup_file, "run ->(_env) { [200, {}, []] }\n")
      File.write(gemfile, "source 'https://rubygems.org'\n")
      File.write(script, "#!/usr/bin/env ruby\n")
      File.write(markdown, "# Not Ruby\n")

      assert runner.send(:ruby_file?, ruby_file)
      assert runner.send(:ruby_file?, rake_file)
      assert runner.send(:ruby_file?, gemspec_file)
      assert runner.send(:ruby_file?, rackup_file)
      assert runner.send(:ruby_file?, gemfile)
      assert runner.send(:ruby_file?, script)
      refute runner.send(:ruby_file?, markdown)
    end
  end

  def test_skips_linters_without_matching_tracked_files
    commands = LintRunner.new.send(:commands, ["notes.md"])

    assert_equal [["markdownlint-cli2", ["notes.md"]]], commands
  end

  def test_ci_installs_pinned_linters_and_runs_the_canonical_command
    assert File.file?(WORKFLOW), "expected a dedicated lint workflow"

    workflow = File.read(WORKFLOW)
    assert_lint_workflow_checkout_contract(workflow)
    assert_includes workflow, "name: Lint"
    assert_includes workflow, "pull_request:"
    assert_includes workflow, "push:"
    assert_includes workflow, "contents: read"
    assert_includes workflow, "bin/lint"
    assert_includes workflow, "bin/lint --version shellcheck"
    assert_includes workflow, "bin/lint --version actionlint"
    assert_includes workflow, "bin/lint --version markdownlint-cli2"
    assert_includes workflow, "bin/lint --version yamllint"
    assert_includes workflow, "sha256sum --check"
    assert_includes workflow, "ruby/setup-ruby@95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
    assert_includes workflow, "actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38"
    assert_includes workflow, "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97"
  end

  def test_ci_checkout_contract_does_not_pin_one_historical_revision
    workflow = File.read(WORKFLOW).sub(
      %r{actions/checkout@[0-9a-f]{40}},
      "actions/checkout@#{'a' * 40}"
    )

    assert_lint_workflow_checkout_contract(workflow)
    assert_includes File.read(VALIDATE), "ruby bin/repository-security-policy-test.rb"
  end

  def test_ci_checkout_contract_matches_policy_aliases_and_yaml_features
    case_variant = File.read(WORKFLOW).sub("actions/checkout@", "Actions/Checkout@")
    assert_lint_workflow_checkout_contract(case_variant)

    anchored = File.read(WORKFLOW).sub(
      "      - name: Checkout repository",
      "      - &checkout\n        name: Checkout repository"
    ).sub("      - name: Set up Ruby", "      - *checkout\n      - name: Set up Ruby")
    assert_lint_workflow_checkout_contract(anchored)
  end

  def test_ci_checkout_precedes_the_first_repository_dependent_lint_command
    workflow = File.read(WORKFLOW)
    checkout = workflow.match(
      /^      - name: Checkout repository\n(?:        .*\n)+?          persist-credentials: false\n/
    ).to_s
    refute_empty checkout
    misplaced = workflow.sub(checkout, "").sub(
      "      - name: Install binary linters",
      "#{checkout}\n      - name: Install binary linters"
    )

    assert_raises(Minitest::Assertion) do
      assert_lint_workflow_checkout_contract(misplaced)
    end
  end

  def test_validation_and_contributor_docs_expose_the_lint_command
    contributing = File.read(File.join(ROOT, "CONTRIBUTING.md"))
    assert_includes File.read(VALIDATE), "ruby bin/lint-test.rb"
    # The backticked form pins the contributor instruction: "`.agents/bin/lint`"
    # contains the substring "bin/lint" but not "`bin/lint`".
    assert_includes contributing, "`bin/lint`"
    assert_includes contributing, ".agents/bin/lint"
    assert_includes File.read(File.join(ROOT, ".agents/bin/README.md")), "`bin/lint`"
  end

  def test_contributor_docs_cover_every_pinned_linter
    contributing = File.read(File.join(ROOT, "CONTRIBUTING.md"))

    assert_includes contributing, "## Lint Toolchain Setup"
    %w[rubocop shellcheck actionlint markdownlint-cli2 yamllint].each do |tool|
      assert_includes contributing, "bin/lint --version #{tool}"
    end
    assert_includes contributing, 'go_bin="$(go env GOBIN)"'
    assert_includes contributing, 'export PATH="${go_bin:-$(go env GOPATH)/bin}:$PATH"'
    assert_includes contributing, "pipx install --force"
  end

  private

  def assert_lint_workflow_checkout_contract(workflow)
    steps = YAML.safe_load(
      workflow,
      permitted_classes: YAML_TIMESTAMP_CLASSES,
      aliases: true
    ).dig("jobs", "lint", "steps")
    # RepositorySecurityPolicyTest owns immutable action-reference validation;
    # this contract owns checkout ordering and credential persistence.
    checkout_index = steps.index do |step|
      checkout_action_reference?(step["uses"])
    end
    lint_index = steps.index do |step|
      step["run"].is_a?(String) && step["run"].match?(%r{\bbin/lint\b})
    end

    refute_nil checkout_index, "expected the lint workflow to check out the repository"
    refute_nil lint_index, "expected the lint workflow to run the canonical lint command"
    assert_operator checkout_index, :<, lint_index
    assert_equal false, steps.fetch(checkout_index).dig("with", "persist-credentials")
  end

  def checkout_action_reference?(reference)
    return false unless reference.is_a?(String)

    identity, separator, action_ref = reference.partition("@")
    separator == "@" && !action_ref.empty? && identity.casecmp?("actions/checkout")
  end
end
