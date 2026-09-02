#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

HELPER = File.expand_path("pr-route-provenance", __dir__)
FIXTURES = File.expand_path("../../../test/fixtures/execution-provenance", __dir__)

load HELPER

class PrRouteProvenanceTest < Minitest::Test
  class FakeGitHub
    attr_reader :updates, :reads

    def initialize(body, readback: nil)
      @body = body
      @readback = readback
      @updates = []
      @reads = 0
    end

    def read_pr_body
      @reads += 1
      return @readback if @reads > 1 && @readback

      @body
    end

    def update_pr_body(body)
      @updates << body
      @body = body
    end
  end

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))
  end

  def same_scope(receipts)
    batch, target = receipts.first.fetch("execution_provenance").values_at("batch", "target")
    receipts.each do |document|
      document.fetch("execution_provenance").merge!("batch" => batch, "target" => target)
    end
  end

  def test_renders_validated_receipts_as_deterministic_requested_versus_observed_waves
    receipts = same_scope(%w[
      authorized-fallback-valid
      unbound-exact-route-valid
      bound-exact-match-valid
      silent-substitution-valid
      coordinator-pair-inheritance-valid
    ].map { |name| fixture(name) })

    section = PrRouteProvenance.render(receipts.reverse)

    assert_equal 1, section.scan(PrRouteProvenance::START_MARKER).length
    assert_equal 1, section.scan(PrRouteProvenance::END_MARKER).length
    assert_includes section, "Generated from 5 validated `execution-provenance-v0` receipts"
    assert_match(%r{Wave 1.*`lane-unbound`.*`gpt-5\.6-sol/high`.*`UNKNOWN/UNKNOWN`.*`unbound-exact-route`.*`proceed-unmeasured`}, section)
    assert_match(%r{Wave 2.*`lane-substituted`.*`claude-opus/high`.*`gpt-5\.6-sol/high`.*`silent-substitution`.*`proceed-unmeasured`}, section)
    assert_match(/Wave 3.*`lane-inherited`.*`coordinator-pair-inheritance`.*`proceed-unmeasured`/, section)
    assert_match(/Wave 4.*`lane-fallback`.*`authorized-fallback`.*`proceed-as-fallback`/, section)
    assert_match(%r{Wave 5.*`aw-i333`.*`gpt-5\.6-sol/high`.*`gpt-5\.6-sol/high`.*`bound-exact-match`.*`proceed`}, section)
    assert_includes section, "Host route metadata was unavailable before editing."
    assert_includes section, "authority: `release-manager approval 2026-08-11`"
    assert_match(%r{`0123456789abcdef0123456789abcdef01234567`.*Wave 5.*`gpt-5\.6-sol/high`.*`exact`}, section)
    assert_operator section.index("Wave 1"), :<, section.index("Wave 5")
    assert_equal section, PrRouteProvenance.render(receipts)
  end

  def test_refuses_to_render_a_satisfied_route_without_observed_receipt_evidence
    document = fixture("bound-exact-match-valid")
    document.dig("execution_provenance", "observed").replace("model" => "UNKNOWN", "effort" => "UNKNOWN")
    document["execution_provenance"]["binding_source"] = "UNKNOWN"

    error = assert_raises(PrRouteProvenance::Error) { PrRouteProvenance.render([document]) }

    assert_includes error.message, "bound-exact-match requires a known observed tuple"
  end

  def test_keeps_large_commit_ledgers_outside_the_pr_prose_block
    document = fixture("bound-exact-match-valid")
    document["execution_provenance"]["influenced_commits"] = (1..22).map { |number| format("%040x", number) }

    section = PrRouteProvenance.render([document])

    assert_equal PrRouteProvenance::MAX_COMMIT_ROWS, section.scan(/^\| `[0-9a-f]{40}` \|/).length
    assert_includes section, "2 additional commit mappings remain in the validated receipts outside this PR prose block."
  end

  def test_managed_section_update_preserves_surrounding_prose_and_never_duplicates_markers
    old_section = PrRouteProvenance.render([fixture("unbound-exact-route-valid")])
    new_section = PrRouteProvenance.render([fixture("bound-exact-match-valid")])
    body = "Human introduction.\n\n#{old_section}\n\nHuman conclusion."

    updated = PrRouteProvenance.apply_to_body(body, new_section)

    assert_equal "Human introduction.\n\n#{new_section}\n\nHuman conclusion.", updated
    assert_equal 1, updated.scan(PrRouteProvenance::START_MARKER).length
    assert_equal 1, updated.scan(PrRouteProvenance::END_MARKER).length

    appended = PrRouteProvenance.apply_to_body("Human-only body.", new_section)
    assert_equal "Human-only body.\n\n#{new_section}", appended

    trailing = PrRouteProvenance.apply_to_body("Human-only body.\n \n", new_section)
    assert_equal "Human-only body.\n \n\n#{new_section}", trailing

    agent_details = <<~MARKDOWN
      Human summary.

      <details>
      <summary>Agent details</summary>

      Existing telemetry.

      </details>
    MARKDOWN
    inside_details = PrRouteProvenance.apply_to_body(agent_details, new_section)
    assert_match(
      %r{Existing telemetry\.\n\n#{Regexp.escape(new_section)}\n</details>},
      inside_details
    )
    assert_equal agent_details.delete_suffix("</details>\n"), inside_details.split(new_section).first

    duplicate = "#{old_section}\n#{old_section}"
    error = assert_raises(PrRouteProvenance::Error) do
      PrRouteProvenance.apply_to_body(duplicate, new_section)
    end
    assert_includes error.message, "exactly one ordered managed section"
  end

  def test_apply_reads_fresh_body_updates_it_and_verifies_exact_readback
    github = FakeGitHub.new("Human prose.")

    result = PrRouteProvenance.apply(
      [fixture("bound-exact-match-valid")],
      github: github
    )

    assert result.fetch("changed")
    assert_equal 2, github.reads
    assert_equal 1, github.updates.length
    assert_equal github.updates.first, result.fetch("body")
    assert_equal 1, result.fetch("body").scan(PrRouteProvenance::START_MARKER).length

    mismatch = FakeGitHub.new("Human prose.", readback: "Concurrent replacement")
    error = assert_raises(PrRouteProvenance::Error) do
      PrRouteProvenance.apply([fixture("bound-exact-match-valid")], github: mismatch)
    end
    assert_includes error.message, "readback did not match"
  end

  def test_apply_is_idempotent_and_still_verifies_readback
    section = PrRouteProvenance.render([fixture("bound-exact-match-valid")])
    github = FakeGitHub.new("Human prose.\n\n#{section}")

    result = PrRouteProvenance.apply(
      [fixture("bound-exact-match-valid")],
      github: github
    )

    refute result.fetch("changed")
    assert_equal 2, github.reads
    assert_empty github.updates
  end

  def test_github_client_uses_get_patch_get_and_persists_the_generated_body
    Dir.mktmpdir("pr-route-provenance-gh") do |directory|
      state_path = File.join(directory, "state.json")
      log_path = File.join(directory, "calls.log")
      gh_path = File.join(directory, "gh")
      File.write(state_path, JSON.generate("body" => "Human prose."))
      File.write(gh_path, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        state_path = ENV.fetch("FAKE_GH_STATE")
        log_path = ENV.fetch("FAKE_GH_LOG")
        state = JSON.parse(File.read(state_path))
        method = ARGV.include?("PATCH") ? "PATCH" : "GET"
        File.open(log_path, "a") { |file| file.puts(method) }
        if method == "PATCH"
          state = JSON.parse($stdin.read)
          File.write(state_path, JSON.generate(state))
        end
        puts JSON.generate(state)
      RUBY
      File.chmod(0o755, gh_path)

      with_environment(
        "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
        "FAKE_GH_STATE" => state_path,
        "FAKE_GH_LOG" => log_path
      ) do
        client = PrRouteProvenance::GitHubClient.new(repo: "acme/widgets", pr_number: 42)
        result = PrRouteProvenance.apply([fixture("bound-exact-match-valid")], github: client)

        assert result.fetch("changed")
      end

      assert_equal %w[GET PATCH GET], File.readlines(log_path, chomp: true)
      applied = JSON.parse(File.read(state_path, encoding: "UTF-8")).fetch("body")
      assert_equal 1, applied.scan(PrRouteProvenance::START_MARKER).length
      assert_includes applied, "Human prose."
    end
  end

  def test_wave_order_uses_utc_instants_instead_of_timestamp_text
    earlier = fixture("unbound-exact-route-valid")
    earlier["execution_provenance"]["started_at"] = "2026-08-11T19:00:00Z"
    earlier["execution_provenance"]["ended_at"] = "2026-08-11T19:00:01Z"
    later = fixture("bound-exact-match-valid") # 10:00 -10:00 is 20:00 UTC.
    same_scope([earlier, later])

    section = PrRouteProvenance.render([later, earlier])

    assert_match(%r{Wave 1 \| `implementation` / `lane-unbound`}, section)
    assert_match(%r{Wave 2 \| `implementation` / `aw-i333`}, section)
  end

  def test_refuses_to_combine_receipts_from_different_batches_or_targets
    first = fixture("bound-exact-match-valid")
    second = fixture("unbound-exact-route-valid")
    second["execution_provenance"]["target"] = first.dig("execution_provenance", "target")

    error = assert_raises(PrRouteProvenance::Error) do
      PrRouteProvenance.render([first, second])
    end
    assert_includes error.message, "one batch and target"

    second["execution_provenance"]["batch"] = first.dig("execution_provenance", "batch")
    second["execution_provenance"]["target"] = "https://github.com/acme/widgets/issues/999"
    error = assert_raises(PrRouteProvenance::Error) do
      PrRouteProvenance.render([first, second])
    end
    assert_includes error.message, "one batch and target"
  end

  def test_keeps_large_wave_ledgers_outside_the_pr_prose_block
    receipts = (0...22).map do |index|
      document = fixture("unbound-exact-route-valid")
      receipt = document.fetch("execution_provenance")
      receipt["lane"] = format("lane-%02d", index)
      receipt["started_at"] = format("2026-08-11T10:00:%02dZ", index)
      receipt["ended_at"] = format("2026-08-11T10:00:%02dZ", index + 1)
      document
    end

    section = PrRouteProvenance.render(receipts)

    assert_equal PrRouteProvenance::MAX_WAVE_ROWS, section.scan(/^\| Wave \d+/).length
    assert_includes section, "2 intermediate receipt waves remain in the validated receipts outside this PR prose block."
    assert_includes section, "Wave 22"
  end

  private

  def with_environment(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
