#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
load File.expand_path("lint", __dir__)

class LintCommandTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/lint")
  WRAPPER = File.join(ROOT, ".agents/bin/lint")
  WORKFLOW = File.join(ROOT, ".github/workflows/lint.yml")
  VALIDATE = File.join(ROOT, "bin/validate")

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
      assert_includes by_tool.fetch("rubocop"), "_#{File.read(File.join(ROOT, '.rubocop-version')).strip}_"
      assert_includes by_tool.fetch("rubocop"), "bin/lint"
      refute_includes by_tool.fetch("rubocop"), "README.md"
      assert_includes by_tool.fetch("shellcheck"), ".agents/bin/lint"
      assert_includes by_tool.fetch("markdownlint-cli2"), "README.md"
      assert_includes by_tool.fetch("yamllint"), ".github/workflows/validate.yml"
      assert_includes by_tool.fetch("yamllint"), "--strict"
      assert_includes by_tool.fetch("actionlint"), ".github/workflows/validate.yml"
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
    assert_includes workflow, "persist-credentials: false"
    assert_includes workflow, "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"
    assert_includes workflow, "ruby/setup-ruby@95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
    assert_includes workflow, "actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38"
    assert_includes workflow, "actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1"
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

  def install_fake_linters(directory)
    source = <<~'RUBY'
      #!/usr/bin/env ruby
      require "json"

      tool = File.basename($PROGRAM_NAME)
      versions = {
        "rubocop" => "1.87.0",
        "shellcheck" => "0.11.0",
        "actionlint" => "1.7.12",
        "markdownlint-cli2" => "0.23.2",
        "yamllint" => "1.37.1"
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

      File.open(ENV.fetch("LINT_TEST_LOG"), "a") do |file|
        file.puts(JSON.generate([tool, *ARGV]))
      end
    RUBY
    %w[rubocop shellcheck actionlint markdownlint-cli2 yamllint].each do |tool|
      path = File.join(directory, tool)
      File.write(path, source)
      FileUtils.chmod(0o755, path)
    end
  end
end
