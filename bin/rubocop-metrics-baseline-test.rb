#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
load File.expand_path("rubocop-metrics-baseline", __dir__)

module RubocopMetricsFixtures
  COPS = RubocopMetrics::COPS
  LOCATION = {
    "start_line" => 1, "start_column" => 1, "last_line" => 1,
    "last_column" => 3, "length" => 3, "line" => 1, "column" => 1
  }.freeze

  def expected_profile
    {
      "schema_version" => 1, "rubocop_version" => "1.87.0", "cops" => COPS,
      "files" => { "example.rb" => {
        "Metrics/AbcSize" => [18.1], "Metrics/MethodLength" => [14, 11]
      } }
    }
  end

  def rubocop_result(method_lengths: [11, 14], abc_sizes: [18.1])
    {
      "metadata" => { "rubocop_version" => "1.87.0" },
      "files" => [{ "path" => "example.rb", "offenses" => metric_offenses(method_lengths, abc_sizes) }]
    }
  end

  def metric_offenses(method_lengths, abc_sizes)
    lengths = method_lengths.map do |value|
      metric_offense("Metrics/MethodLength", "Method has too many lines. [#{value}/10]")
    end
    lengths + abc_sizes.map do |value|
      metric_offense("Metrics/AbcSize", abc_message(value))
    end
  end

  def abc_message(value)
    "Assignment Branch Condition size for example is too high. [<2, 18, 1> #{value}/17]"
  end

  def metric_offense(cop, message)
    {
      "severity" => "convention", "message" => message, "cop_name" => cop,
      "corrected" => false, "correctable" => false, "location" => LOCATION
    }
  end
end

module RubocopMetricsTestRepository
  include RubocopMetricsFixtures

  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/rubocop-metrics-baseline")
  RUBY_FILE_SURFACE = File.join(ROOT, "bin/ruby_file_surface.rb")
  BASELINE = File.join("test", "fixtures", "rubocop-metrics-baseline.json")

  def run_helper(root, environment, command)
    Open3.capture3(environment, RbConfig.ruby, File.join(root, "bin/rubocop-metrics-baseline"), command)
  end

  def with_repository
    Dir.mktmpdir("rubocop-metrics-baseline-test") do |root|
      prepare_repository(root)
      environment, log = fake_rubocop_environment(root)
      yield root, environment, log
    end
  end

  def prepare_repository(root)
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.cp(SCRIPT, File.join(root, "bin"))
    FileUtils.cp(RUBY_FILE_SURFACE, File.join(root, "bin"))
    File.write(File.join(root, ".rubocop-version"), "1.87.0\n")
    File.write(File.join(root, ".rubocop.yml"), "AllCops:\n  NewCops: disable\n")
    File.write(File.join(root, "example.rb"), "def example = :ok\n")
    File.write(File.join(root, "README.md"), "# Not Ruby\n")
    git(root, "init", "--quiet")
    git(root, "add", ".rubocop-version", ".rubocop.yml", "README.md", "example.rb")
  end

  def fake_rubocop_environment(root)
    tools = File.join(root, "tools")
    FileUtils.mkdir_p(tools)
    write_fake_rubocop(File.join(tools, "rubocop"))
    log = File.join(root, "rubocop-arguments.jsonl")
    environment = { "PATH" => "#{tools}:#{ENV.fetch('PATH')}",
                    "RUBOCOP_ARGUMENT_LOG" => log,
                    "RUBOCOP_RESULT" => JSON.generate(rubocop_result) }
    [environment, log]
  end

  def git(root, *arguments)
    _stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise stderr unless status.success?
  end

  def write_fake_rubocop(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      File.open(ENV.fetch("RUBOCOP_ARGUMENT_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      puts ENV.fetch("RUBOCOP_RESULT")
      exit 1
    RUBY
    FileUtils.chmod(0o755, path)
  end
end

class RubocopMetricsRefreshTest < Minitest::Test
  include RubocopMetricsTestRepository

  def test_refresh_writes_observed_metric_values
    with_repository do |root, environment, _log|
      stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "Refreshed #{BASELINE}\n", stdout
      assert_equal expected_profile, JSON.parse(File.read(File.join(root, BASELINE)))
    end
  end

  def test_refresh_is_deterministic
    with_repository do |root, environment, _log|
      run_helper(root, environment, "refresh")
      first_refresh = File.binread(File.join(root, BASELINE))
      _stdout, stderr, status = run_helper(root, environment, "refresh")
      assert status.success?, stderr
      assert_equal first_refresh, File.binread(File.join(root, BASELINE))
    end
  end

  def test_refresh_selects_the_pinned_metrics_cops_and_tracked_ruby_files
    with_repository do |root, environment, log|
      run_helper(root, environment, "refresh")
      arguments = JSON.parse(File.readlines(log, chomp: true).first)
      assert_equal "_1.87.0_", arguments.first
      assert_equal COPS.join(","), arguments.fetch(arguments.index("--only") + 1)
      assert_includes arguments, "--ignore-disable-comments"
      assert_includes arguments, "example.rb"
      refute_includes arguments, "README.md"
    end
  end

  def test_refresh_does_not_invoke_rubocop_without_tracked_ruby_files
    with_repository do |root, environment, log|
      FileUtils.rm(File.join(root, "example.rb"))

      stdout, stderr, status = run_helper(root, environment, "refresh")

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal({}, JSON.parse(File.read(File.join(root, BASELINE))).fetch("files"))
      refute_path_exists log
    end
  end
end

class RubocopMetricsCheckTest < Minitest::Test
  include RubocopMetricsTestRepository

  INCREASE_ERROR = <<~ERROR
    RuboCop metrics baseline increased:
      example.rb Metrics/MethodLength value #1: 14 -> 15
      new.rb Metrics/MethodLength value #1: 0 -> 12
    Reduce the metrics or deliberately refresh with bin/rubocop-metrics-baseline refresh.
  ERROR

  def test_check_accepts_reductions_without_a_refresh
    with_repository do |root, environment, _log|
      run_helper(root, environment, "refresh")
      environment["RUBOCOP_RESULT"] = JSON.generate(rubocop_result(method_lengths: [13]))
      stdout, stderr, status = run_helper(root, environment, "check")
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "PASS RuboCop metrics baseline\n", stdout
      assert_empty stderr
    end
  end

  def test_check_rejects_larger_values_and_new_offenses
    with_repository do |root, environment, _log|
      run_helper(root, environment, "refresh")
      configure_increased_result(root, environment)
      stdout, stderr, status = run_helper(root, environment, "check")
      refute status.success?
      assert_empty stdout
      assert_equal INCREASE_ERROR, stderr
    end
  end

  def test_check_rejects_a_different_rubocop_version
    with_repository do |root, environment, _log|
      run_helper(root, environment, "refresh")
      write_baseline_version(root, "1.86.0")
      stdout, stderr, status = run_helper(root, environment, "check")
      refute status.success?
      assert_empty stdout
      assert_includes stderr, "baseline uses RuboCop 1.86.0; expected 1.87.0; refresh it"
    end
  end

  def test_check_rejects_a_different_metrics_cop_set
    with_repository do |root, environment, _log|
      run_helper(root, environment, "refresh")
      write_baseline_field(root, "cops", COPS.drop(1))
      stdout, stderr, status = run_helper(root, environment, "check")
      refute status.success?
      assert_empty stdout
      assert_includes stderr, "baseline cop set differs from the current Metrics cop set; refresh it"
    end
  end

  private

  def configure_increased_result(root, environment)
    File.write(File.join(root, "new.rb"), "def added = :ok\n")
    git(root, "add", "new.rb")
    current = rubocop_result(method_lengths: [10, 15])
    current.fetch("files") << new_file_result
    environment["RUBOCOP_RESULT"] = JSON.generate(current)
  end

  def new_file_result
    { "path" => "new.rb", "offenses" => [
      metric_offense("Metrics/MethodLength", "Method has too many lines. [12/10]")
    ] }
  end

  def write_baseline_version(root, version)
    write_baseline_field(root, "rubocop_version", version)
  end

  def write_baseline_field(root, field, value)
    path = File.join(root, BASELINE)
    baseline = JSON.parse(File.read(path))
    baseline[field] = value
    File.write(path, "#{JSON.pretty_generate(baseline)}\n")
  end
end
