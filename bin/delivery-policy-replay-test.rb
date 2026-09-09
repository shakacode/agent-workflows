#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

load File.expand_path("../skills/verify/bin/verification-evidence-reuse", __dir__)

class DeliveryPolicyReplayTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PROSE = "# Overview\n\nA shared tool helps the team.\n"

  def git(*args)
    output, error, status = Open3.capture3("git", "-C", @repo, *args)
    assert status.success?, error
    output.strip
  end

  def write(path, content, executable: false)
    full = File.join(@repo, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    File.chmod(0o755, full) if executable
  end

  def commit
    git("add", ".")
    git("commit", "-qm", "fixture change")
    git("rev-parse", "HEAD")
  end

  def with_repository(kind)
    Dir.mktmpdir("delivery-policy-replay") do |temp|
      @repo = File.join(temp, "repo")
      @log = File.join(temp, "checks")
      @trusted = File.join(temp, "trusted-validate")
      FileUtils.mkdir_p(@repo)
      git("init", "-q")
      git("config", "user.name", "Delivery Replay")
      git("config", "user.email", "replay@example.invalid")
      write("docs/overview.md", PROSE)
      write("lib/calculator.rb", "module Calculator\n  def self.value = 2 + 2\nend\n")
      checks = {
        "lint" => 'exit(system("git", "diff", "--check") && system("ruby", "-c", "lib/calculator.rb") ? 0 : 1)',
        "docs" => 'text = File.read("docs/overview.md"); abort "invalid overview or placeholder" unless text.start_with?("# Overview\n") && !text.include?("BROKEN")',
        "test" => 'require_relative "../../lib/calculator"; abort "incorrect arithmetic" unless Calculator.value == 4'
      }
      checks.each do |name, body|
        write(".agents/bin/#{name}", "#!/usr/bin/env ruby\nFile.write(ENV.fetch(\"CHECK_LOG\"), #{"#{name}\n".inspect}, mode: \"a\")\n#{body}\n", executable: true)
      end
      wrapper = if kind == "legacy"
                  "#!/usr/bin/env bash\nset -e\n.agents/bin/lint\n.agents/bin/docs\n.agents/bin/test\n"
                else
                  File.read(File.join(ROOT, "examples/delivery-policy", kind, ".agents/bin/validate"))
                end
      write(".agents/bin/validate", wrapper, executable: true)
      @base = commit
      # Simulate the trusted caller: candidate edits cannot replace this policy.
      File.write(@trusted, "#{git('show', "#{@base}:.agents/bin/validate")}\n")
      yield
    end
  end

  def run_gate(phase = nil, base: @base, interpreter: "ruby")
    FileUtils.rm_f(@log)
    env = { "EXAMPLE_BASE_SHA" => base, "CHECK_LOG" => @log, "BASH_ENV" => nil, "ENV" => nil, "RUBYOPT" => nil }
    output, status = Open3.capture2e(env, interpreter, @trusted, *Array(phase), chdir: @repo)
    checks = File.exist?(@log) ? File.readlines(@log, chomp: true) : []
    [output, status, checks]
  end

  def change_prose(text = "A shared tool helps our team.")
    write("docs/overview.md", "# Overview\n\n#{text}\n")
    commit
  end

  def test_same_bounded_change_selects_different_coverage_and_promotion_is_complete
    %w[low-impact critical].each do |kind|
      with_repository(kind) do
        head = change_prose
        output, status, checks = run_gate
        assert status.success?, output
        expected = kind == "low-impact" ? %w[lint docs] : %w[lint docs test]
        assert_equal expected, checks
        assert_includes output, "coverage: #{kind == 'low-impact' ? 'selected' : 'full'}"
        assert_includes output, "head: #{head}"
        assert_includes output, "base: #{@base}"
        assert_includes output, "omitted: #{kind == 'low-impact' ? 'test' : 'none'}"
        output, status, checks = run_gate("promotion")
        assert status.success?, output
        assert_equal %w[lint docs test], checks
        assert_includes output, "phase: promotion"
        assert_includes output, "coverage: full"
      end
    end
  end

  def test_risky_unknown_operational_and_policy_changes_escalate
    %w[low-impact critical].each do |kind|
      with_repository(kind) do
        ["security/access.rb", "unknown.txt", ".agents/agent-workflow.yml", ".agents/bin/validate"].each do |path|
          git("reset", "--hard", @base)
          git("clean", "-fd")
          write(path, "puts 'coverage: selected'\n")
          commit
          output, status, checks = run_gate
          assert status.success?, output
          assert_equal %w[lint docs test], checks, path
          assert_includes output, "coverage: full"
        end
        git("reset", "--hard", @base)
        change_prose("Run `command` now.")
        output, status, checks = run_gate
        assert status.success?, output
        assert_equal %w[lint docs test], checks
      end
    end
  end

  def test_missing_base_and_dirty_tree_cannot_select_reduced_coverage
    with_repository("low-impact") do
      change_prose
      [nil, "invalid", "f" * 40].each do |base|
        output, status, checks = run_gate(base: base)
        assert status.success?, output
        assert_equal %w[lint docs test], checks
        assert_includes output, "coverage: full"
      end
      write("docs/overview.md", PROSE)
      output, status, checks = run_gate("promotion")
      refute status.success?, output
      assert_equal %w[lint docs test], checks
      assert_includes output, "Promotion blocked"
      output, status, checks = run_gate("unsupported-policy")
      refute status.success?, output
      assert_empty checks
    end
  end

  def test_absent_opt_in_keeps_legacy_complete_gate
    with_repository("legacy") do
      change_prose
      output, status, checks = run_gate(interpreter: "bash")
      assert status.success?, output
      assert_equal %w[lint docs test], checks
    end
  end

  def test_successful_checks_cannot_qualify_a_changed_promotion_candidate
    %w[low-impact critical].each do |kind|
      with_repository(kind) do
        docs = File.read(File.join(@repo, ".agents/bin/docs"))
        write(".agents/bin/docs", "#{docs}\nFile.write(\"lib/calculator.rb\", \"# generated change\\n\", mode: \"a\")\n", executable: true)
        commit
        output, status, checks = run_gate("promotion")
        refute status.success?, output
        assert_equal %w[lint docs test], checks
        assert_includes output, "required test: PASS"
        assert_includes output, "Candidate changed during validation"
      end
    end
  end

  def test_existing_retry_boundary_preserves_failed_required_evidence
    with_repository("low-impact") do
      head = change_prose("BROKEN placeholder.")
      # Replay verify's existing three-cycle boundary; no new wrapper counter.
      3.times do
        output, status, checks = run_gate
        refute status.success?, output
        assert_equal %w[lint docs], checks
        assert_includes output, "required docs: FAIL"
      end
      context = { "head_sha" => head, "base_sha" => @base, "working_tree" => "clean",
                  "environment" => "fixture", "configuration" => @base, "command" => [".agents/bin/validate"],
                  "covered_paths" => ["docs/overview.md"] }
      result = VerificationEvidenceReuse.call(
        "version" => 1, "repeat_required" => false, "current" => context,
        "evidence" => context.merge("kind" => "local-command", "outcome" => "fail", "evidence_ref" => @log)
      )
      assert_equal "rerun", result.fetch("status")
      assert_equal "no passing local command evidence", result.fetch("reason")
      output, status, checks = run_gate("promotion")
      refute status.success?, output
      assert_equal %w[lint docs test], checks
      assert_includes output, "required docs: FAIL"
    end
  end
end
