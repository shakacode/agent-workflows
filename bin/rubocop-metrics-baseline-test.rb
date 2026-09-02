#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class RubocopMetricsBaselineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/rubocop-metrics-baseline")
  BASELINE = File.join("test", "fixtures", "rubocop-metrics-baseline.json")
  METRICS_COPS = %w[
    Metrics/AbcSize
    Metrics/BlockLength
    Metrics/ClassLength
    Metrics/CyclomaticComplexity
    Metrics/MethodLength
    Metrics/ModuleLength
    Metrics/ParameterLists
    Metrics/PerceivedComplexity
  ].freeze

  def test_refresh_writes_a_deterministic_profile_with_observed_metric_values
    with_repository do |root, environment, log|
      stdout, stderr, status = run_helper(root, environment, "refresh")

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "Refreshed #{BASELINE}\n", stdout
      baseline_path = File.join(root, BASELINE)
      first_refresh = File.binread(baseline_path)
      assert_equal(
        {
          "schema_version" => 1,
          "rubocop_version" => "1.87.0",
          "cops" => METRICS_COPS,
          "files" => {
            "example.rb" => {
              "Metrics/AbcSize" => [18.1],
              "Metrics/MethodLength" => [14, 11]
            }
          }
        },
        JSON.parse(first_refresh)
      )

      stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal first_refresh, File.binread(baseline_path)

      arguments = JSON.parse(File.readlines(log, chomp: true).first)
      assert_equal "_1.87.0_", arguments.first
      only_index = arguments.index("--only")
      refute_nil only_index
      assert_equal METRICS_COPS.join(","), arguments.fetch(only_index + 1)
      assert_includes arguments, "example.rb"
    end
  end

  def test_check_accepts_metric_reductions_without_requiring_a_refresh
    with_repository do |root, environment, _log|
      _stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, stderr
      environment["RUBOCOP_RESULT"] = JSON.generate(
        rubocop_result(method_lengths: [13], abc_sizes: [18.1])
      )

      stdout, stderr, status = run_helper(root, environment, "check")

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "PASS RuboCop metrics baseline\n", stdout
      assert_empty stderr
    end
  end

  def test_check_rejects_larger_values_and_new_offenses_with_actionable_output
    with_repository do |root, environment, _log|
      _stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, stderr
      File.write(File.join(root, "new.rb"), "def added = :ok\n")
      git(root, "add", "new.rb")
      current = rubocop_result(method_lengths: [10, 15])
      current.fetch("files") << {
        "path" => "new.rb",
        "offenses" => [
          metric_offense("Metrics/MethodLength", "Method has too many lines. [12/10]")
        ]
      }
      environment["RUBOCOP_RESULT"] = JSON.generate(current)

      stdout, stderr, status = run_helper(root, environment, "check")

      refute status.success?
      assert_empty stdout
      assert_equal <<~ERROR, stderr
        RuboCop metrics baseline increased:
          example.rb Metrics/MethodLength value #1: 14 -> 15
          new.rb Metrics/MethodLength value #1: 0 -> 12
        Reduce the metrics or deliberately refresh with bin/rubocop-metrics-baseline refresh.
      ERROR
    end
  end

  def test_check_rejects_a_baseline_from_another_rubocop_version
    with_repository do |root, environment, _log|
      _stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, stderr
      baseline_path = File.join(root, BASELINE)
      baseline = JSON.parse(File.read(baseline_path))
      baseline["rubocop_version"] = "1.86.0"
      File.write(baseline_path, "#{JSON.pretty_generate(baseline)}\n")

      stdout, stderr, status = run_helper(root, environment, "check")

      refute status.success?
      assert_empty stdout
      assert_equal(
        "RuboCop metrics baseline check failed: baseline uses RuboCop 1.86.0; expected 1.87.0; refresh it\n",
        stderr
      )
    end
  end

  private

  def run_helper(root, environment, command)
    Open3.capture3(environment, RbConfig.ruby, File.join(root, "bin/rubocop-metrics-baseline"), command)
  end

  def with_repository
    Dir.mktmpdir("rubocop-metrics-baseline-test") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      FileUtils.cp(SCRIPT, File.join(root, "bin")) if File.file?(SCRIPT)
      File.write(File.join(root, ".rubocop-version"), "1.87.0\n")
      File.write(File.join(root, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")
      File.write(File.join(root, "example.rb"), "def example = :ok\n")
      git(root, "init", "--quiet")
      git(root, "add", ".rubocop-version", ".rubocop.yml", "example.rb")

      tools = File.join(root, "tools")
      FileUtils.mkdir_p(tools)
      log = File.join(root, "rubocop-arguments.jsonl")
      write_fake_rubocop(File.join(tools, "rubocop"))
      environment = {
        "PATH" => "#{tools}:#{ENV.fetch('PATH')}",
        "RUBOCOP_ARGUMENT_LOG" => log,
        "RUBOCOP_RESULT" => JSON.generate(rubocop_result)
      }
      yield root, environment, log
    end
  end

  def git(root, *arguments)
    _stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise stderr unless status.success?
  end

  def write_fake_rubocop(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      File.open(ENV.fetch("RUBOCOP_ARGUMENT_LOG"), "a") do |file|
        file.puts(JSON.generate(ARGV))
      end
      puts ENV.fetch("RUBOCOP_RESULT")
      exit 1
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def rubocop_result(method_lengths: [11, 14], abc_sizes: [18.1])
    offenses = method_lengths.map do |value|
      metric_offense("Metrics/MethodLength", "Method has too many lines. [#{value}/10]")
    end
    offenses.concat(abc_sizes.map do |value|
      metric_offense(
        "Metrics/AbcSize",
        "Assignment Branch Condition size for example is too high. [<2, 18, 1> #{value}/17]"
      )
    end)
    {
      "metadata" => { "rubocop_version" => "1.87.0" },
      "files" => [
        {
          "path" => "example.rb",
          "offenses" => offenses
        }
      ]
    }
  end

  def metric_offense(cop, message)
    {
      "severity" => "convention",
      "message" => message,
      "cop_name" => cop,
      "corrected" => false,
      "correctable" => false,
      "location" => {
        "start_line" => 1,
        "start_column" => 1,
        "last_line" => 1,
        "last_column" => 3,
        "length" => 3,
        "line" => 1,
        "column" => 1
      }
    }
  end
end
