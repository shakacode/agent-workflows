#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

HELPER = File.expand_path("task-scratch-lifecycle", __dir__)
TASK_REVIEW_HELPER = File.expand_path("task-review-loop", __dir__)
REPO_ROOT = File.expand_path("../../..", __dir__)
VALIDATE = File.join(REPO_ROOT, "bin/validate")
HOST_CONTRACT = File.join(REPO_ROOT, "docs/host-adapter/contract.md")
TASK_REVIEW_WORKFLOW = File.join(REPO_ROOT, "workflows/pr-batch-task-review.md")
TASK_IDENTITY = {
  "batch_id" => "aw-c-391-plan-bound-state",
  "lane_id" => "aw391-implementation",
  "plan_id" => "aw-c-391-plan-bound-state-deps-v1",
  "plan_digest" => "sha256:#{'1' * 64}",
  "task_id" => "shakacode/agent-workflows:issue:391"
}.freeze

class TaskScratchLifecycleTest < Minitest::Test
  def test_repository_validation_runs_the_lifecycle_suite_once
    validation = File.read(VALIDATE, encoding: "UTF-8")

    assert_equal 1, validation.scan("ruby skills/pr-batch/bin/task-scratch-lifecycle-test.rb").length
  end

  def test_portable_contract_documents_read_only_review_and_exclusive_scratch_ownership
    host_contract = File.read(HOST_CONTRACT, encoding: "UTF-8").gsub(/\s+/, " ")
    workflow = File.read(TASK_REVIEW_WORKFLOW, encoding: "UTF-8").gsub(/\s+/, " ")

    assert_includes host_contract, "task-review-loop --repository-root"
    assert_includes host_contract, "task-scratch-lifecycle create"
    assert_includes host_contract, "task-scratch-lifecycle cleanup"
    assert_includes host_contract, "cap-adjudicated completion never authorizes scratch deletion"
    assert_includes workflow, "task-review-loop\" --repository-root \"$REVIEW_WORKTREE_ROOT\""
    assert_includes workflow, "task-scratch-lifecycle\" create"
    assert_includes workflow, "task-scratch-lifecycle\" cleanup"
    assert_includes workflow, "The lifecycle helper is the only owner allowed to delete that root"
  end

  def test_clean_review_cleanup_removes_only_the_created_allowlisted_root
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      Dir.mkdir(scratch_parent)

      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["notes.txt", "nested/evidence.json"]
      )
      assert create_status.success?, create_stderr
      assert_equal "created", created.fetch("status")
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      assert_equal 0o700, File.stat(scratch_root).mode & 0o777
      File.write(File.join(scratch_root, "notes.txt"), "disposable\n")
      FileUtils.mkdir_p(File.join(scratch_root, "nested"))
      File.write(File.join(scratch_root, "nested/evidence.json"), "{}\n")

      durable_root = File.join(directory, "durable")
      Dir.mkdir(durable_root)
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        head_sha
      )
      review_stdout, review_stderr, review_status = Open3.capture3(
        TASK_REVIEW_HELPER,
        "--repository-root",
        repository,
        stdin_data: File.binread(review_input_path)
      )
      assert review_status.success?, review_stderr
      assert_equal "task_complete", JSON.parse(review_stdout).fetch("status")

      coordination_path = File.join(durable_root, "coordination-receipt.json")
      wake_path = File.join(durable_root, "pending-wake.json")
      File.write(coordination_path, JSON.generate("batch_id" => TASK_IDENTITY.fetch("batch_id"), "generation" => 7))
      File.write(wake_path, JSON.generate("pending_wake" => true))
      preserved_paths = [receipt_path, review_input_path, coordination_path, wake_path, *review_artifacts]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      external_worktree = File.join(directory, "external-worktree")
      system("git", "-C", repository, "worktree", "add", "--quiet", "--detach", external_worktree, head_sha) ||
        raise("git worktree add failed")
      external_sentinel = File.join(external_worktree, "external-sentinel.txt")
      File.write(external_sentinel, "owned elsewhere\n")
      repository_head_before = git_output(repository, "rev-parse", "HEAD")
      repository_log_before = git_output(repository, "log", "--format=%H")
      worktrees_before = git_output(repository, "worktree", "list", "--porcelain")

      cleaned, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, review_input_path)

      assert cleanup_status.success?, cleanup_stderr
      assert_equal "cleaned", cleaned.fetch("status")
      assert_equal scratch_root, cleaned.fetch("removed_root")
      refute_path_exists scratch_root
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_equal "owned elsewhere\n", File.read(external_sentinel)
      assert_equal repository_head_before, git_output(repository, "rev-parse", "HEAD")
      assert_equal repository_log_before, git_output(repository, "log", "--format=%H")
      assert_equal worktrees_before, git_output(repository, "worktree", "list", "--porcelain")
      assert_empty git_output(repository, "status", "--porcelain")
    end
  end

  def test_cleanup_revalidates_the_review_input_and_preserves_scratch_after_head_moves
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, reviewed_head = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"]
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      File.write(evidence_path, "{}\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        reviewed_head
      )
      scratch_before = Dir.children(scratch_root).sort.to_h do |entry|
        path = File.join(scratch_root, entry)
        [entry, File.file?(path) ? File.binread(path) : :directory]
      end
      preserved_paths = [receipt_path, review_input_path, *review_artifacts]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      File.write(File.join(repository, "work.txt"), "moved\n")
      system("git", "-C", repository, "commit", "--quiet", "-am", "move head") || raise("git commit failed")

      blocked, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, review_input_path)

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-clean-required", blocked.fetch("reason")
      assert_path_exists scratch_root
      assert_equal(scratch_before, Dir.children(scratch_root).sort.to_h do |entry|
        path = File.join(scratch_root, entry)
        [entry, File.file?(path) ? File.binread(path) : :directory]
      end)
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_creation_rejects_incomplete_or_ambiguous_task_identity
    invalid_identities = {
      "missing plan" => TASK_IDENTITY.reject { |key, _value| key == "plan_id" },
      "blank plan" => TASK_IDENTITY.merge("plan_id" => ""),
      "unknown plan" => TASK_IDENTITY.merge("plan_id" => "uNkNoWn"),
      "ambiguous whitespace" => TASK_IDENTITY.merge("plan_id" => " plan-a "),
      "malformed digest" => TASK_IDENTITY.merge("plan_digest" => "not-a-digest")
    }

    invalid_identities.each do |label, identity|
      Dir.mktmpdir("task-scratch-lifecycle") do |directory|
        repository, = build_repository(directory)
        identity_path = File.join(directory, "task-identity.json")
        File.write(identity_path, JSON.generate("identity" => identity))
        scratch_parent = File.join(directory, "scratch-parent")
        Dir.mkdir(scratch_parent)

        blocked, stderr, status = run_create(repository, scratch_parent, identity_path, ["evidence.json"])

        refute status.success?, "#{label}: #{stderr}"
        assert_equal "blocked", blocked.fetch("status"), label
        assert_equal "task-identity-invalid", blocked.fetch("reason"), label
        assert_empty Dir.children(scratch_parent), label
      end
    end
  end

  def test_plan_b_rejects_plan_a_scratch_even_with_the_same_task_numbering
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"]
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      File.write(evidence_path, "plan A\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      plan_b_identity = TASK_IDENTITY.merge(
        "plan_id" => "aw-c-391-plan-bound-state-deps-v2",
        "plan_digest" => "sha256:#{'2' * 64}"
      )
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        head_sha,
        identity: plan_b_identity
      )
      preserved_paths = [receipt_path, evidence_path, review_input_path, *review_artifacts]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      blocked, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, review_input_path)

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-identity-mismatch", blocked.fetch("reason")
      assert_path_exists scratch_root
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_cleanup_rejects_a_copied_root_even_with_a_digest_consistent_receipt
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"]
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      original_root = receipt.fetch("scratch_root")
      File.write(File.join(original_root, "evidence.json"), "original\n")
      copied_root = File.join(receipt.fetch("scratch_parent"), "copied-root")
      FileUtils.cp_r(original_root, copied_root)
      File.chmod(0o700, copied_root)
      copied_stat = File.stat(copied_root)
      forged_receipt = receipt.merge(
        "scratch_root" => copied_root,
        "root_device" => copied_stat.dev,
        "root_inode" => copied_stat.ino,
        "root_owner" => copied_stat.uid,
        "root_mode" => copied_stat.mode & 0o777
      )
      forged_receipt["digest"] = lifecycle_digest(forged_receipt)
      receipt_path = File.join(durable_root, "copied-receipt.json")
      File.write(receipt_path, JSON.generate(forged_receipt))
      preserved_paths = [
        receipt_path,
        File.join(original_root, "evidence.json"),
        File.join(copied_root, "evidence.json")
      ]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      blocked, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, identity_path)

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "owner-marker-mismatch", blocked.fetch("reason")
      assert_path_exists original_root
      assert_path_exists copied_root
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_cleanup_rejects_legacy_receipts_and_unallowlisted_entries_without_deleting_anything
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)

      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"]
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      unexpected_path = File.join(scratch_root, "pending-wake.json")
      File.write(evidence_path, "owned scratch\n")
      File.write(unexpected_path, "must survive\n")
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        head_sha
      )
      legacy_receipt_path = File.join(durable_root, "legacy-receipt.json")
      File.write(legacy_receipt_path, JSON.generate(receipt.reject { |key, _value| key == "run_token" }))

      legacy, legacy_stderr, legacy_status = run_cleanup(legacy_receipt_path, review_input_path)

      refute legacy_status.success?, legacy_stderr
      assert_equal "receipt-invalid", legacy.fetch("reason")
      assert_path_exists scratch_root

      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      preserved_paths = [receipt_path, legacy_receipt_path, evidence_path, unexpected_path, review_input_path,
                         *review_artifacts]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      blocked, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, review_input_path)

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-entry-not-allowlisted", blocked.fetch("reason")
      assert_path_exists scratch_root
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_cap_adjudicated_completion_does_not_authorize_cleanup
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      FileUtils.cp(HELPER, lifecycle_helper)
      File.write(
        review_helper,
        <<~RUBY
          #!/usr/bin/env ruby
          require "json"
          $stdin.read
          puts JSON.generate(
            "contract" => "task-review-loop-decision",
            "version" => 1,
            "status" => "task_complete",
            "dependent_task_permitted" => true,
            "reasons" => ["cap-adjudicated"]
          )
        RUBY
      )
      File.chmod(0o755, lifecycle_helper)
      File.chmod(0o755, review_helper)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      File.write(evidence_path, "preserve after cap\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      preserved_bytes = [receipt_path, review_input_path, evidence_path].to_h do |path|
        [path, File.binread(path)]
      end

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper
      )

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-clean-required", blocked.fetch("reason")
      assert_path_exists scratch_root
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  private

  def run_create(repository, scratch_parent, identity_path, allowlist, helper: HELPER)
    arguments = [
      helper,
      "create",
      "--repository-root", repository,
      "--scratch-parent", scratch_parent,
      "--identity-file", identity_path
    ]
    allowlist.each { |path| arguments.concat(["--allow-relative", path]) }
    stdout, stderr, status = Open3.capture3(*arguments)
    [stdout.empty? ? nil : JSON.parse(stdout), stderr, status]
  end

  def run_cleanup(receipt_path, review_input_path, helper: HELPER)
    stdout, stderr, status = Open3.capture3(
      helper,
      "cleanup",
      "--receipt", receipt_path,
      "--review-input", review_input_path
    )
    [stdout.empty? ? nil : JSON.parse(stdout), stderr, status]
  end

  def build_repository(directory)
    repository = File.join(directory, "repository")
    Dir.mkdir(repository)
    system("git", "init", "--quiet", repository) || raise("git init failed")
    system("git", "-C", repository, "config", "user.name", "Test") || raise("git config failed")
    system("git", "-C", repository, "config", "user.email", "test@example.com") || raise("git config failed")
    source_path = File.join(repository, "work.txt")
    File.write(source_path, "base\n")
    system("git", "-C", repository, "add", "work.txt") || raise("git add failed")
    system("git", "-C", repository, "commit", "--quiet", "-m", "base") || raise("git commit failed")
    base_sha = git_output(repository, "rev-parse", "HEAD")
    File.write(source_path, "reviewed\n")
    system("git", "-C", repository, "commit", "--quiet", "-am", "reviewed") || raise("git commit failed")
    [repository, base_sha, git_output(repository, "rev-parse", "HEAD")]
  end

  def write_clean_review_input(directory, repository, base_sha, head_sha, identity: TASK_IDENTITY)
    brief = with_digest(
      "identity" => identity,
      "requirements" => ["Clean only proven-owned scratch."],
      "global_constraints" => [],
      "interfaces" => ["task-scratch-lifecycle"],
      "resolved_ambiguities" => []
    )
    report = with_digest(
      "identity" => identity,
      "brief_digest" => brief.fetch("digest"),
      "initial_implementer_id" => "implementer-a",
      "current_implementer_id" => "implementer-a",
      "status" => "done",
      "base_sha" => base_sha,
      "head_sha" => head_sha,
      "commits" => [head_sha],
      "changed_paths" => ["work.txt"],
      "verification" => [{ "command" => "ruby test.rb", "status" => "passed", "outcome" => "green" }],
      "concerns" => [],
      "open_context_needs" => []
    )
    diff_path = File.join(directory, "review.diff")
    File.binwrite(diff_path, canonical_git_diff(repository, base_sha, head_sha))
    findings_path = File.join(directory, "findings.json")
    File.write(
      findings_path,
      JSON.generate(
        "schema" => "review-finding-v0",
        "reviewer_id" => "reviewer-b",
        "review_receipt" => {
          "source" => "adversarial-pr-review",
          "target" => {
            "kind" => "committed",
            "base_ref" => "base",
            "base_sha" => base_sha,
            "head_sha" => head_sha
          },
          "provenance" => { "engine" => "test", "invocation" => "real repository fixture" },
          "risk_lenses" => [{ "name" => "correctness", "status" => "applied", "reason" => "fixture" }],
          "coverage" => {
            "status" => "complete",
            "included_paths" => ["work.txt"],
            "excluded_paths" => [],
            "limitations" => []
          }
        },
        "review_findings" => []
      )
    )
    package = with_digest(
      "identity" => identity,
      "brief_digest" => brief.fetch("digest"),
      "worker_report_digest" => report.fetch("digest"),
      "scope" => "task",
      "base_sha" => base_sha,
      "head_sha" => head_sha,
      "expected_current_head_sha" => head_sha,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "commit_list" => [head_sha],
      "diff_stat" => "1 file changed",
      "exact_diff" => artifact(diff_path).merge("truncated" => false),
      "prior_round_digest" => nil
    )
    findings = artifact(findings_path)
    round = with_digest(
      "number" => 0,
      "kind" => "initial_review",
      "package_digest" => package.fetch("digest"),
      "review_package" => package,
      "worker_report" => report,
      "base_sha" => base_sha,
      "head_sha" => head_sha,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "prior_round_digest" => nil,
      "review_findings" => findings,
      "addressed_finding_ids" => [],
      "open_finding_ids" => [],
      "new_consequential_finding_ids" => []
    )
    input = {
      "contract" => "task-review-loop",
      "version" => 1,
      "identity" => identity,
      "expected_current_head_sha" => head_sha,
      "task_brief" => brief,
      "worker_report" => report,
      "review_package" => package,
      "review_state" => "complete",
      "rounds" => [round],
      "open_findings" => findings.merge("ids" => []),
      "finding_controls" => [],
      "replacement_evidence" => [],
      "cap_adjudication" => nil
    }
    input_path = File.join(directory, "task-review-input.json")
    File.write(input_path, JSON.generate(input))
    [input_path, [diff_path, findings_path]]
  end

  def artifact(path)
    bytes = File.binread(path)
    {
      "path" => path,
      "digest" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
      "byte_count" => bytes.bytesize
    }
  end

  def with_digest(record)
    record.merge("digest" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(record)))}")
  end

  def lifecycle_digest(receipt)
    payload = receipt.reject { |key, _value| key == "digest" }
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))}"
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
    when Array
      value.map { |entry| canonicalize(entry) }
    else
      value
    end
  end

  def canonical_git_diff(repository, base_sha, head_sha)
    stdout, stderr, status = Open3.capture3(
      "git", "-C", repository, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative",
      "--binary", "--src-prefix=a/", "--dst-prefix=b/", "--ignore-submodules=none", "--submodule=short",
      base_sha, head_sha, "--"
    )
    raise stderr unless status.success?

    stdout
  end

  def git_output(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise stderr unless status.success?

    stdout.strip
  end
end
