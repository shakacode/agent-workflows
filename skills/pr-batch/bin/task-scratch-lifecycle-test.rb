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
GIT_PROBE_ENV = File.expand_path("../lib/git_probe_env.rb", __dir__)
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
    assert_includes host_contract, "accepts that exact `created` decision directly"
    assert_includes host_contract, "unchanged nested raw receipt for compatibility"
    assert_includes host_contract, "cap-adjudicated completion never authorizes scratch deletion"
    assert_includes host_contract, "exclusive lock on the durable receipt"
    assert_includes host_contract, "open directory descriptor"
    assert_includes host_contract, "one component at a time with no-follow descriptor-relative operations"
    assert_includes host_contract, "random private name before descriptor-relative removal"
    assert_includes host_contract, "immediately before each destructive unlink or rollback rename"
    assert_includes host_contract, "cooperative cleanup boundary"
    assert_includes host_contract,
                    "Hostile same-UID mutation inside the unavoidable final check/syscall interval is outside " \
                    "the supported cooperative contract and can redirect deletion"
    assert_includes host_contract, "documented limitation, not a host prerequisite"
    assert_includes host_contract, "Codex and Claude semantics do not depend on host-provided same-UID isolation"
    refute_includes host_contract, "host must isolate the scratch parent"
    assert_includes workflow, "task-review-loop\" --repository-root \"$REVIEW_WORKTREE_ROOT\""
    assert_includes workflow, "task-scratch-lifecycle\" create"
    assert_includes workflow, "task-scratch-lifecycle\" cleanup"
    assert_includes workflow, "## Owned Scratch Lifecycle"
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

  def test_documented_create_output_round_trips_directly_into_cleanup
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      receipt_path = File.join(durable_root, "scratch-receipt.json")

      create_stdout, create_stderr, create_status = Open3.capture3(
        HELPER,
        "create",
        "--repository-root", repository,
        "--scratch-parent", scratch_parent,
        "--identity-file", identity_path,
        "--allow-relative", "evidence.json"
      )
      File.binwrite(receipt_path, create_stdout)
      assert create_status.success?, create_stderr
      created = JSON.parse(create_stdout)
      scratch_root = created.dig("receipt", "scratch_root")
      File.write(File.join(scratch_root, "evidence.json"), "{}\n")
      review_input_path, = write_clean_review_input(durable_root, repository, base_sha, head_sha)

      cleaned, cleanup_stderr, cleanup_status = run_cleanup(receipt_path, review_input_path)

      assert cleanup_status.success?, cleanup_stderr
      assert_equal "cleaned", cleaned.fetch("status")
      assert_equal scratch_root, cleaned.fetch("removed_root")
      refute_path_exists scratch_root
      assert_equal create_stdout, File.binread(receipt_path)
    end
  end

  def test_cleanup_blocks_without_deleting_when_adjacent_review_helper_is_missing
    assert_cleanup_blocks_when_review_helper_cannot_launch(:missing)
  end

  def test_unavailable_platform_cleanup_rename_does_not_disable_create_and_blocks_cleanup_structurally
    instrumentations = {
      "unsupported platform" => lambda do |source|
        source.sub('    if RUBY_PLATFORM.include?("darwin")', "    if false")
              .sub('    elsif RUBY_PLATFORM.include?("linux")', "    elsif false")
      end,
      "missing Linux symbol" => lambda do |source|
        source.sub('    if RUBY_PLATFORM.include?("darwin")', "    if false")
              .sub('    elsif RUBY_PLATFORM.include?("linux")', "    elsif true")
              .sub(
                '        extern "int renameat2(int, const char *, int, const char *, unsigned int)"',
                '        extern "int task_scratch_missing_renameat2(int, const char *, int, const char *, unsigned int)"'
              )
              .sub(
                "        renameat2(source_directory_fd, source, destination_directory_fd, destination, 0x1)",
                "        task_scratch_missing_renameat2(source_directory_fd, source, destination_directory_fd, destination, 0x1)"
              )
      end
    }

    instrumentations.each do |label, instrument|
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
        instrumented_helper = instrument.call(File.read(HELPER))
        refute_equal File.read(HELPER), instrumented_helper, label
        File.write(lifecycle_helper, instrumented_helper)
        File.chmod(0o755, lifecycle_helper)
        write_clean_review_helper(review_helper)

        created, create_stderr, create_status = run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper
        )

        assert create_status.success?, "#{label}: #{create_stderr}"
        assert_empty create_stderr, label
        assert_equal "created", created.fetch("status"), label
        receipt = created.fetch("receipt")
        scratch_root = receipt.fetch("scratch_root")
        evidence_path = File.join(scratch_root, "evidence.json")
        File.write(evidence_path, "preserve me\n")
        receipt_path = File.join(durable_root, "scratch-receipt.json")
        review_input_path = File.join(durable_root, "task-review-input.json")
        File.write(receipt_path, JSON.generate(receipt))
        File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))

        blocked, cleanup_stderr, cleanup_status = run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper
        )

        refute cleanup_status.success?, label
        assert_empty cleanup_stderr, label
        assert_equal "blocked", blocked.fetch("status"), label
        assert_equal "cleanup-syscall-unavailable", blocked.fetch("reason"), label
        assert_path_exists scratch_root, label
        assert_equal "preserve me\n", File.binread(evidence_path), label
        assert_equal JSON.generate(receipt), File.binread(receipt_path), label
      end
    end
  end

  def test_cleanup_blocks_without_deleting_when_adjacent_review_helper_is_not_executable
    assert_cleanup_blocks_when_review_helper_cannot_launch(:not_executable)
  end

  def test_cleanup_rejects_noncanonical_create_wrappers_before_touching_scratch
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
      scratch_root = created.dig("receipt", "scratch_root")
      File.write(File.join(scratch_root, "evidence.json"), "{}\n")
      review_input_path, = write_clean_review_input(durable_root, repository, base_sha, head_sha)
      variants = {
        "extra field" => created.merge("unexpected" => true),
        "wrong contract" => created.merge("contract" => "other-decision"),
        "wrong version" => created.merge("version" => 2),
        "numeric lookalike version" => created.merge("version" => 1.0),
        "string version" => created.merge("version" => "1"),
        "boolean version" => created.merge("version" => true),
        "null version" => created.merge("version" => nil),
        "wrong status" => created.merge("status" => "cleaned"),
        "missing receipt" => created.reject { |key, _value| key == "receipt" },
        "non-object receipt" => created.merge("receipt" => [])
      }

      variants.each do |label, wrapper|
        receipt_path = File.join(durable_root, "#{label.tr(' ', '-')}.json")
        File.write(receipt_path, JSON.generate(wrapper))

        blocked, stderr, status = run_cleanup(receipt_path, review_input_path)

        refute status.success?, label
        assert_empty stderr, label
        assert_equal "blocked", blocked.fetch("status"), label
        assert_equal "receipt-invalid", blocked.fetch("reason"), label
        assert_path_exists scratch_root, label
      end
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

  def test_cleanup_rechecks_head_after_clean_review_before_removing_scratch
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, reviewed_head = build_repository(directory)
      source_path = File.join(repository, "work.txt")
      File.write(source_path, "moved after review\n")
      system("git", "-C", repository, "commit", "--quiet", "-am", "moved after review") ||
        raise("git commit failed")
      moved_head = git_output(repository, "rev-parse", "HEAD")
      system("git", "-C", repository, "update-ref", "HEAD", reviewed_head) || raise("git update-ref failed")

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
      instrumented_helper = File.read(HELPER).sub(
        "  def remove_allowlisted_root(receipt, reviewed_head)\n",
        <<~'RUBY'
          def remove_allowlisted_root(receipt, reviewed_head)
            moved = system(
              ENV.fetch("REAL_GIT"), "-C", receipt.fetch("worktree_root"),
              "update-ref", "HEAD", ENV.fetch("MOVE_HEAD_TO")
            )
            fail!("test-head-move-failed") unless moved
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      write_clean_review_helper(review_helper)
      created, create_stderr, create_status = run_create(
        repository, scratch_parent, identity_path, ["evidence.json"], helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      File.write(evidence_path, "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root, repository, base_sha, reviewed_head
      )
      root_stat = File.stat(scratch_root)
      preserved_paths = [
        receipt_path,
        evidence_path,
        File.join(scratch_root, ".task-scratch-owner.json"),
        review_input_path,
        *review_artifacts
      ]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper,
        env: { "REAL_GIT" => executable_on_path("git"), "MOVE_HEAD_TO" => moved_head }
      )

      refute cleanup_status.success?, cleanup_stderr
      assert_empty cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-head-changed", blocked.fetch("reason")
      assert_equal moved_head, git_output(repository, "rev-parse", "HEAD")
      assert_equal [root_stat.dev, root_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_create_and_cleanup_ignore_inherited_repository_selectors
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, reviewed_head = build_repository(directory)
      alternate_git_dir = File.join(directory, "alternate.git")
      FileUtils.cp_r(File.join(repository, ".git"), alternate_git_dir)
      poisoned_git_env = {
        "GIT_DIR" => alternate_git_dir,
        "GIT_WORK_TREE" => repository
      }
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
        ["evidence.json"],
        env: poisoned_git_env
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      assert_equal File.realpath(File.join(repository, ".git")), receipt.fetch("repository_common_dir")
      scratch_root = receipt.fetch("scratch_root")
      File.write(File.join(scratch_root, "evidence.json"), "{}\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        reviewed_head
      )

      File.write(File.join(repository, "work.txt"), "moved\n")
      system("git", "-C", repository, "commit", "--quiet", "-am", "move head") ||
        raise("git commit failed")

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        env: poisoned_git_env
      )

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-clean-required", blocked.fetch("reason")
      assert_path_exists scratch_root
      assert_equal "{}\n", File.read(File.join(scratch_root, "evidence.json"))
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

  def test_create_bounds_repository_git_probe_timeouts
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      fake_bin = File.join(directory, "bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(fake_bin)
      fake_git = File.join(fake_bin, "git")
      File.write(
        fake_git,
        <<~'SH'
          #!/bin/sh
          if [ "$1" = "rev-parse" ] && [ "$2" = "--local-env-vars" ]; then
            exec "$REAL_GIT" "$@"
          fi
          sleep 3
        SH
      )
      File.chmod(0o755, fake_git)
      real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |path|
        candidate = File.expand_path(File.join(path, "git"))
        candidate if File.file?(candidate) && File.executable?(candidate)
      end.first
      raise "git executable not found on PATH" unless real_git

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      blocked, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        env: {
          "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
          "REAL_GIT" => real_git,
          "PR_BATCH_GIT_PROBE_TIMEOUT_SECONDS" => "1"
        }
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "repository-invalid", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
      assert_operator elapsed, :<, 2.5
    end
  end

  def test_cleanup_validates_ownership_against_the_effective_uid
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
      instrumented_helper = File.read(HELPER).sub(
        "module TaskScratchLifecycle\n",
        <<~'RUBY'
          module Process
            class << self
              def uid
                ENV["TASK_SCRATCH_INJECT_DISTINCT_REAL_UID"] ? euid + 1 : euid
              end
            end
          end
          module TaskScratchLifecycle
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      write_clean_review_helper(review_helper)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper
      )
      assert create_status.success?, "#{create_stderr}\n#{created.inspect}"
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      File.write(File.join(scratch_root, "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))

      cleaned, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_INJECT_DISTINCT_REAL_UID" => "1" }
      )

      assert cleanup_status.success?, cleanup_stderr
      assert_empty cleanup_stderr
      assert_equal "cleaned", cleaned.fetch("status")
      refute_path_exists scratch_root
    end
  end

  def test_create_retries_descriptor_open_after_successful_directory_creation
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      failure_marker = File.join(directory, "root-open-failed-once")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "  def open_at(directory, name)\n",
        <<~'RUBY'
          def open_at(directory, name)
            marker = ENV["TASK_SCRATCH_FAIL_ROOT_OPEN_ONCE"]
            if marker && name.start_with?("task-scratch-") && !File.exist?(marker)
              File.write(marker, "failed")
              raise Errno::EMFILE, "injected root open failure"
            end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      created, stderr, status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_ROOT_OPEN_ONCE" => failure_marker }
      )

      assert status.success?, stderr
      assert_empty stderr
      assert_path_exists failure_marker
      assert_equal [File.basename(created.fetch("receipt").fetch("scratch_root"))], Dir.children(scratch_parent)
    end
  end

  def test_create_removes_unreceipted_root_after_persistent_descriptor_open_failure
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "  def open_at(directory, name)\n",
        <<~'RUBY'
          def open_at(directory, name)
            if ENV["TASK_SCRATCH_FAIL_ROOT_OPEN"] && name.start_with?("task-scratch-")
              raise Errno::ENFILE, "injected persistent root open failure"
            end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, stderr, status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_ROOT_OPEN" => "1" }
      )

      refute status.success?
      assert_empty stderr
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_create_removes_unreceipted_root_when_cleanup_rename_is_unsupported
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER)
                                .sub('    if RUBY_PLATFORM.include?("darwin")', "    if false")
                                .sub('    elsif RUBY_PLATFORM.include?("linux")', "    elsif false")
                                .sub(
                                  "  def open_at(directory, name)\n",
                                  <<~'RUBY'
                                    def open_at(directory, name)
                                      if ENV["TASK_SCRATCH_FAIL_ROOT_OPEN"] && name.start_with?("task-scratch-")
                                        raise Errno::ENFILE, "injected persistent root open failure"
                                      end
                                  RUBY
                                )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, stderr, status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_ROOT_OPEN" => "1" }
      )

      refute status.success?
      assert_empty stderr
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_create_blocks_before_mutation_when_directory_removal_flag_is_unknown
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "REMOVE_DIRECTORY = case RUBY_PLATFORM",
        'REMOVE_DIRECTORY = case "unsupported-platform"'
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, stderr, status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper
      )

      refute status.success?
      assert_empty stderr
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_create_blocks_before_mutation_when_descriptor_reservation_is_unavailable
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "      File.open(File::NULL, File::RDONLY)\n",
        <<~'RUBY'.gsub(/^/, "      ")
          raise Errno::ENFILE, "injected reservation failure" if ENV["TASK_SCRATCH_FAIL_RESERVATION"]
          File.open(File::NULL, File::RDONLY)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, stderr, status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_RESERVATION" => "1" }
      )

      refute status.success?
      assert_empty stderr
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_cleanup_retries_descriptor_open_after_successful_holder_creation
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      failure_marker = File.join(directory, "holder-open-failed-once")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(durable_root)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        "  def open_at(directory, name)\n",
        <<~'RUBY'
          def open_at(directory, name)
            marker = ENV["TASK_SCRATCH_FAIL_HOLDER_OPEN_ONCE"]
            if marker && name.start_with?(".task-scratch-cleanup-") && !File.exist?(marker)
              File.write(marker, "failed")
              raise Errno::ENFILE, "injected holder open failure"
            end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      write_clean_review_helper(review_helper)
      created, create_stderr, create_status = run_create(
        repository, scratch_parent, identity_path, ["evidence.json"], helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      File.write(File.join(receipt.fetch("scratch_root"), "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, = write_clean_review_input(durable_root, repository, base_sha, head_sha)

      cleaned, stderr, status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_HOLDER_OPEN_ONCE" => failure_marker }
      )

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "cleaned", cleaned.fetch("status")
      assert_path_exists failure_marker
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_cleanup_removes_unbound_holder_after_persistent_descriptor_open_failure
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
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
      File.write(lifecycle_helper, File.read(HELPER))
      File.chmod(0o755, lifecycle_helper)
      write_clean_review_helper(review_helper)

      created, create_stderr, create_status = run_create(
        repository, scratch_parent, identity_path, ["evidence.json"], helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      File.write(File.join(receipt.fetch("scratch_root"), "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, = write_clean_review_input(durable_root, repository, base_sha, head_sha)

      instrumented_helper = File.read(HELPER).sub(
        "  def open_at(directory, name)\n",
        <<~'RUBY'
          def open_at(directory, name)
            if ENV["TASK_SCRATCH_FAIL_HOLDER_OPEN"] && name.start_with?(".task-scratch-cleanup-")
              raise Errno::ENFILE, "injected persistent holder open failure"
            end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, stderr, status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_FAIL_HOLDER_OPEN" => "1" }
      )

      refute status.success?
      assert_empty stderr
      assert_equal "cleanup-holder-unavailable", blocked.fetch("reason")
      assert_equal [File.basename(receipt.fetch("scratch_root"))], Dir.children(scratch_parent)
    end
  end

  def test_cleanup_bounds_review_helper_runtime_and_releases_receipt_claim
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
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
      File.chmod(0o755, lifecycle_helper)
      File.write(review_helper, "#!/usr/bin/env ruby\nsleep 3\n")
      File.chmod(0o755, review_helper)
      created, create_stderr, create_status = run_create(
        repository, scratch_parent, identity_path, ["evidence.json"], helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      evidence_path = File.join(scratch_root, "evidence.json")
      File.write(evidence_path, "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, review_artifacts = write_clean_review_input(durable_root, repository, base_sha, head_sha)
      root_stat = File.stat(scratch_root)
      root_children = Dir.children(scratch_root).sort
      preserved_paths = [
        receipt_path,
        evidence_path,
        File.join(scratch_root, ".task-scratch-owner.json"),
        review_input_path,
        *review_artifacts
      ]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      blocked, stderr, status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper,
        env: { "PR_BATCH_GIT_PROBE_TIMEOUT_SECONDS" => "1" }
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      refute status.success?
      assert_empty stderr
      assert_equal "review-validation-unavailable", blocked.fetch("reason")
      assert_operator elapsed, :<, 2.5
      assert_path_exists scratch_root
      assert_equal [root_stat.dev, root_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal root_children, Dir.children(scratch_root).sort
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
      File.open(receipt_path, File::RDONLY) do |receipt|
        assert receipt.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end
  end

  def test_cleanup_rejects_digest_consistent_malformed_receipt_fields_with_structured_decisions
    malformed_fields = {
      "contract" => %w[other-receipt receipt-invalid],
      "version" => %w[1 receipt-invalid],
      "identity" => [[], "receipt-identity-invalid"],
      "worktree_root" => [7, "receipt-worktree-root-invalid"],
      "repository_common_dir" => [[], "receipt-repository-common-dir-invalid"],
      "scratch_parent" => %w[relative-parent receipt-scratch-parent-invalid],
      "scratch_root" => [{}, "receipt-scratch-root-invalid"],
      "run_token" => [[], "receipt-run-token-invalid"],
      "root_device" => %w[1 receipt-root-device-invalid],
      "root_inode" => [[], "receipt-root-inode-invalid"],
      "root_owner" => [-1, "receipt-root-owner-invalid"],
      "root_mode" => [0o1000, "receipt-root-mode-invalid"],
      "allowlist" => [{}, "allowlist-required"],
      "created_at" => [7, "receipt-created-at-invalid"],
      "digest" => [7, "receipt-digest-invalid"]
    }

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
      scratch_root = receipt.fetch("scratch_root")

      malformed_fields.each do |field, (value, expected_reason)|
        malformed_receipt = receipt.merge(field => value)
        malformed_receipt["digest"] = lifecycle_digest(malformed_receipt) unless field == "digest"
        receipt_path = File.join(durable_root, "#{field}.json")
        File.write(receipt_path, JSON.generate(malformed_receipt))

        blocked, stderr, status = run_cleanup(receipt_path, identity_path)

        refute status.success?, field
        assert_empty stderr, field
        assert_equal "blocked", blocked.fetch("status"), field
        assert_equal expected_reason, blocked.fetch("reason"), field
        assert_path_exists scratch_root, field
      end
    end
  end

  def test_create_rejects_missing_options_before_creating_scratch
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      Dir.mkdir(scratch_parent)
      cases = {
        "repository root" => [
          [HELPER, "create", "--scratch-parent", scratch_parent, "--identity-file", identity_path,
           "--allow-relative", "evidence.json"],
          "repository-root-invalid"
        ],
        "scratch parent" => [
          [HELPER, "create", "--repository-root", repository, "--identity-file", identity_path,
           "--allow-relative", "evidence.json"],
          "scratch-parent-invalid"
        ],
        "identity file" => [
          [HELPER, "create", "--repository-root", repository, "--scratch-parent", scratch_parent,
           "--allow-relative", "evidence.json"],
          "identity-source-path-invalid"
        ],
        "allowlist" => [
          [HELPER, "create", "--repository-root", repository, "--scratch-parent", scratch_parent,
           "--identity-file", identity_path],
          "allowlist-required"
        ]
      }

      cases.each do |label, (arguments, expected_reason)|
        stdout, stderr, status = Open3.capture3(*arguments)

        refute status.success?, label
        assert_empty stderr, label
        decision = JSON.parse(stdout)
        assert_equal "blocked", decision.fetch("status"), label
        assert_equal expected_reason, decision.fetch("reason"), label
        assert_empty Dir.children(scratch_parent), label
      end
    end
  end

  def test_create_rejects_invalid_encoding_in_path_options_without_a_backtrace
    invalid_identity_path = "identity-\xFF.json".b
    stdout, stderr, status = Open3.capture3(
      HELPER,
      "create",
      "--identity-file", invalid_identity_path,
      "--repository-root", "/unused",
      "--scratch-parent", "/unused",
      "--allow-relative", "evidence.json"
    )

    refute status.success?
    assert_empty stderr
    assert_equal "blocked", JSON.parse(stdout).fetch("status")
    assert_equal "options-invalid", JSON.parse(stdout).fetch("reason")
  end

  def test_create_rejects_invalid_encoding_in_identity_without_a_backtrace
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      identity_json = JSON.generate("identity" => TASK_IDENTITY).b.sub(
        TASK_IDENTITY.fetch("plan_id").b,
        "plan-\xFF".b
      )
      File.binwrite(identity_path, identity_json)
      scratch_parent = File.join(directory, "scratch-parent")
      Dir.mkdir(scratch_parent)

      blocked, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"]
      )

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "task-identity-invalid", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_create_returns_structured_block_when_scratch_parent_disappears_during_realpath
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "    worktree_root, common_dir = repository_identity(options[:repository_root])\n",
        <<~RUBY.gsub(/^/, "    ")
          worktree_root, common_dir = repository_identity(options[:repository_root])
          if ENV["TASK_SCRATCH_BEFORE_PARENT_REALPATH_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_BEFORE_PARENT_REALPATH_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_BEFORE_PARENT_REALPATH_RELEASE"))
          end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      signal_path = File.join(directory, "before-parent-realpath.signal")
      release_path = File.join(directory, "before-parent-realpath.release")
      creation = Thread.new do
        run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_BEFORE_PARENT_REALPATH_SIGNAL" => signal_path,
            "TASK_SCRATCH_BEFORE_PARENT_REALPATH_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      Dir.rmdir(scratch_parent)
      File.write(release_path, "continue")

      blocked, create_stderr, create_status = creation.value

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-parent-invalid", blocked.fetch("reason")
      refute_path_exists scratch_parent
    end
  end

  def test_create_returns_structured_block_when_mkdirat_reports_permission_denied
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "  class LifecycleError < StandardError; end\n",
        <<~RUBY.gsub(/^/, "  ")
          if ENV["TASK_SCRATCH_INJECT_MKDIRAT_EACCES"]
            module CleanupSyscalls
              def self.mkdirat(*)
                raise Errno::EACCES, "injected mkdirat permission failure"
              end
            end
          end
          class LifecycleError < StandardError; end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_INJECT_MKDIRAT_EACCES" => "1" }
      )

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-parent-invalid", blocked.fetch("reason")
      assert_empty Dir.children(scratch_parent)
    end
  end

  def test_create_blocks_after_ten_mkdirat_collisions_without_touching_collision_entries
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      collision_names = 10.times.map { |index| "task-scratch-#{format('%032x', index)}" }
      collision_names.each do |name|
        collision_path = File.join(scratch_parent, name)
        Dir.mkdir(collision_path)
        File.write(File.join(collision_path, "sentinel.txt"), "#{name}\n")
      end
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "module TaskScratchLifecycle\n",
        <<~RUBY
          if ENV["TASK_SCRATCH_DETERMINISTIC_COLLISIONS"]
            module SecureRandom
              class << self
                alias task_scratch_original_hex hex

                def hex(length = nil)
                  return task_scratch_original_hex(length) unless length == 16

                  @task_scratch_collision_index ||= -1
                  @task_scratch_collision_index += 1
                  format("%032x", @task_scratch_collision_index)
                end
              end
            end
          end
          module TaskScratchLifecycle
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      blocked, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: { "TASK_SCRATCH_DETERMINISTIC_COLLISIONS" => "1" }
      )

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-parent-invalid", blocked.fetch("reason")
      assert_equal collision_names, Dir.children(scratch_parent).sort
      collision_names.each do |name|
        collision_path = File.join(scratch_parent, name)
        assert_equal ["sentinel.txt"], Dir.children(collision_path)
        assert_equal "#{name}\n", File.read(File.join(collision_path, "sentinel.txt"))
      end
    end
  end

  def test_create_succeeds_on_tenth_mkdirat_attempt_after_nine_collisions
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      candidate_names = 10.times.map { |index| "task-scratch-#{format('%032x', index)}" }
      candidate_names.first(9).each do |name|
        collision_path = File.join(scratch_parent, name)
        Dir.mkdir(collision_path)
        File.write(File.join(collision_path, "sentinel.txt"), "#{name}\n")
      end
      attempt_log = File.join(directory, "mkdirat-attempts.txt")
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "module TaskScratchLifecycle\n",
        <<~RUBY
          if ENV["TASK_SCRATCH_DETERMINISTIC_COLLISIONS"]
            module SecureRandom
              class << self
                alias task_scratch_original_hex hex

                def hex(length = nil)
                  return task_scratch_original_hex(length) unless length == 16

                  @task_scratch_collision_index ||= -1
                  @task_scratch_collision_index += 1
                  format("%032x", @task_scratch_collision_index)
                end
              end
            end
          end
          module TaskScratchLifecycle
        RUBY
      ).sub(
        "  class LifecycleError < StandardError; end\n",
        <<~RUBY.gsub(/^/, "  ")
          if ENV["TASK_SCRATCH_MKDIRAT_ATTEMPT_LOG"]
            module CleanupSyscalls
              class << self
                alias task_scratch_original_mkdirat mkdirat

                def mkdirat(*arguments)
                  File.open(ENV.fetch("TASK_SCRATCH_MKDIRAT_ATTEMPT_LOG"), "a") do |log|
                    log.puts(arguments.fetch(1))
                  end
                  task_scratch_original_mkdirat(*arguments)
                end
              end
            end
          end
          class LifecycleError < StandardError; end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)

      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json"],
        helper: lifecycle_helper,
        env: {
          "TASK_SCRATCH_DETERMINISTIC_COLLISIONS" => "1",
          "TASK_SCRATCH_MKDIRAT_ATTEMPT_LOG" => attempt_log
        }
      )

      assert create_status.success?, create_stderr
      assert_empty create_stderr
      assert_equal "created", created.fetch("status")
      assert_equal candidate_names.fetch(9), File.basename(created.dig("receipt", "scratch_root"))
      assert_equal candidate_names, File.readlines(attempt_log, chomp: true)
      candidate_names.first(9).each do |name|
        collision_path = File.join(scratch_parent, name)
        assert_equal ["sentinel.txt"], Dir.children(collision_path)
        assert_equal "#{name}\n", File.read(File.join(collision_path, "sentinel.txt"))
      end
    end
  end

  def test_create_returns_structured_block_when_scratch_parent_disappears_after_directory_check
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "      root_name, root_file, created_root_stat = create_private_directory(\n",
        <<~RUBY.gsub(/^/, "      ")
          if ENV["TASK_SCRATCH_AFTER_PARENT_DIRECTORY_CHECK_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_AFTER_PARENT_DIRECTORY_CHECK_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_AFTER_PARENT_DIRECTORY_CHECK_RELEASE"))
          end
          root_name, root_file, created_root_stat = create_private_directory(
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      signal_path = File.join(directory, "after-parent-directory-check.signal")
      release_path = File.join(directory, "after-parent-directory-check.release")
      creation = Thread.new do
        run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_AFTER_PARENT_DIRECTORY_CHECK_SIGNAL" => signal_path,
            "TASK_SCRATCH_AFTER_PARENT_DIRECTORY_CHECK_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      Dir.rmdir(scratch_parent)
      File.write(release_path, "continue")

      blocked, create_stderr, create_status = creation.value

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-parent-invalid", blocked.fetch("reason")
      refute_path_exists scratch_parent
    end
  end

  def test_create_rejects_parent_rebound_without_orphaning_its_descriptor_relative_root
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "      root_name, root_file, created_root_stat = create_private_directory(\n",
        <<~RUBY.gsub(/^/, "      ")
          if ENV["TASK_SCRATCH_AFTER_PARENT_OPEN_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_AFTER_PARENT_OPEN_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_AFTER_PARENT_OPEN_RELEASE"))
          end
          root_name, root_file, created_root_stat = create_private_directory(
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      signal_path = File.join(directory, "after-parent-open.signal")
      release_path = File.join(directory, "after-parent-open.release")
      creation = Thread.new do
        run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_AFTER_PARENT_OPEN_SIGNAL" => signal_path,
            "TASK_SCRATCH_AFTER_PARENT_OPEN_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      parked_parent = File.join(directory, "parked-parent")
      File.rename(scratch_parent, parked_parent)
      Dir.mkdir(scratch_parent)
      foreign_path = File.join(scratch_parent, "foreign.txt")
      File.write(foreign_path, "foreign parent\n")
      File.write(release_path, "continue")

      blocked, create_stderr, create_status = creation.value

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      refute blocked.key?("receipt")
      assert_empty Dir.children(parked_parent)
      assert_equal ["foreign.txt"], Dir.children(scratch_parent)
      assert_equal "foreign parent\n", File.read(foreign_path)
    end
  end

  def test_create_rejects_root_rebound_and_removes_only_its_renamed_owned_root
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(
        "      )\n      scratch_root = File.join(scratch_parent, root_name)\n",
        <<~RUBY.gsub(/^/, "      ")
          )
          if ENV["TASK_SCRATCH_AFTER_CREATED_ROOT_STAT_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_AFTER_CREATED_ROOT_STAT_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_AFTER_CREATED_ROOT_STAT_RELEASE"))
          end
          scratch_root = File.join(scratch_parent, root_name)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      signal_path = File.join(directory, "after-created-root-stat.signal")
      release_path = File.join(directory, "after-created-root-stat.release")
      creation = Thread.new do
        run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_AFTER_CREATED_ROOT_STAT_SIGNAL" => signal_path,
            "TASK_SCRATCH_AFTER_CREATED_ROOT_STAT_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      scratch_root = Dir.glob(File.join(scratch_parent, "task-scratch-*")).fetch(0)
      parked_root = File.join(scratch_parent, "parked-created-root")
      File.rename(scratch_root, parked_root)
      Dir.mkdir(scratch_root, 0o755)
      foreign_path = File.join(scratch_root, "foreign.txt")
      File.write(foreign_path, "foreign root\n")
      foreign_stat = File.stat(scratch_root)
      File.write(release_path, "continue")

      blocked, create_stderr, create_status = creation.value

      refute create_status.success?
      assert_empty create_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      refute blocked.key?("receipt")
      refute_path_exists parked_root
      assert_equal [foreign_stat.dev, foreign_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal 0o755, File.stat(scratch_root).mode & 0o777
      assert_equal "foreign root\n", File.read(foreign_path)
      refute_path_exists File.join(scratch_root, ".task-scratch-owner.json")
    end
  end

  def test_create_cleans_its_partial_root_after_initialization_faults
    {
      "chmod" => "TASK_SCRATCH_INJECT_CHMOD_FAILURE",
      "owner marker write" => "TASK_SCRATCH_INJECT_OWNER_WRITE_FAILURE"
    }.each do |label, fault_env|
      Dir.mktmpdir("task-scratch-lifecycle") do |directory|
        repository, = build_repository(directory)
        identity_path = File.join(directory, "task-identity.json")
        File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
        scratch_parent = File.join(directory, "scratch-parent")
        helper_root = File.join(directory, "helper-bin")
        Dir.mkdir(scratch_parent)
        Dir.mkdir(helper_root)
        lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
        instrumented_helper = File.read(HELPER).sub(
          "module TaskScratchLifecycle\n",
          <<~'RUBY'
            if ENV["TASK_SCRATCH_INJECT_CHMOD_FAILURE"]
              module InjectedScratchChmodFailure
                def chmod(*)
                  raise Errno::EIO, "injected scratch chmod failure"
                end
              end
              File.singleton_class.prepend(InjectedScratchChmodFailure)
              File.prepend(InjectedScratchChmodFailure)
            end
            if ENV["TASK_SCRATCH_INJECT_OWNER_WRITE_FAILURE"]
              module InjectedOwnerMarkerWriteFailure
                def for_fd(...)
                  file = super
                  original_write = file.method(:write)
                  file.define_singleton_method(:write) do |*arguments, **keywords|
                    result = original_write.call(*arguments, **keywords)
                    raise Errno::EIO, "injected owner marker storage failure"
                  end
                  file
                end
              end
              File.singleton_class.prepend(InjectedOwnerMarkerWriteFailure)
            end
            module TaskScratchLifecycle
          RUBY
        )
        refute_equal File.read(HELPER), instrumented_helper
        File.write(lifecycle_helper, instrumented_helper)
        File.chmod(0o755, lifecycle_helper)

        blocked, create_stderr, create_status = run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: { fault_env => "1" }
        )

        refute create_status.success?, label
        assert_empty create_stderr, label
        assert_kind_of Hash, blocked, label
        assert_equal "blocked", blocked.fetch("status"), label
        assert_equal "scratch-initialization-failure", blocked.fetch("reason"), label
        assert_empty Dir.children(scratch_parent), label
      end
    end
  end

  def test_create_preserves_rebound_root_when_initialization_fails
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      helper_root = File.join(directory, "helper-bin")
      Dir.mkdir(scratch_parent)
      Dir.mkdir(helper_root)
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      instrumented_helper = File.read(HELPER).sub(/^        root_stat = .*$/) do |line|
        <<~RUBY.chomp
          #{line}
                  if ENV["TASK_SCRATCH_AFTER_ROOT_IDENTITY_SIGNAL"]
                    File.write(ENV.fetch("TASK_SCRATCH_AFTER_ROOT_IDENTITY_SIGNAL"), "ready")
                    sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_AFTER_ROOT_IDENTITY_RELEASE"))
                    raise Errno::EIO, "injected post-identity initialization failure"
                  end
        RUBY
      end
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      File.chmod(0o755, lifecycle_helper)
      signal_path = File.join(directory, "after-root-identity.signal")
      release_path = File.join(directory, "after-root-identity.release")
      creation = Thread.new do
        run_create(
          repository,
          scratch_parent,
          identity_path,
          ["evidence.json"],
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_AFTER_ROOT_IDENTITY_SIGNAL" => signal_path,
            "TASK_SCRATCH_AFTER_ROOT_IDENTITY_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      scratch_root = Dir.glob(File.join(scratch_parent, "task-scratch-*")).fetch(0)
      parked_root = File.join(directory, "parked-created-root")
      File.rename(scratch_root, parked_root)
      Dir.mkdir(scratch_root, 0o755)
      foreign_path = File.join(scratch_root, "foreign.txt")
      File.write(foreign_path, "foreign content\n")
      foreign_stat = File.stat(scratch_root)
      File.write(release_path, "continue")

      blocked, create_stderr, create_status = creation.value

      refute create_status.success?
      assert_empty create_stderr
      assert_kind_of Hash, blocked
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-initialization-failure", blocked.fetch("reason")
      assert_path_exists parked_root
      assert_equal [foreign_stat.dev, foreign_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal 0o755, File.stat(scratch_root).mode & 0o777
      assert_equal "foreign content\n", File.read(foreign_path)
      refute_path_exists File.join(scratch_root, ".task-scratch-owner.json")
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

  def test_concurrent_cleanup_has_one_exclusive_owner_and_leaves_no_lock_or_quarantine
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
          sleep 0.5
          puts JSON.generate(
            "contract" => "task-review-loop-decision",
            "version" => 1,
            "status" => "task_complete",
            "dependent_task_permitted" => true,
            "reasons" => ["review-clean"]
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
      File.write(File.join(scratch_root, "evidence.json"), "disposable\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))

      results = 2.times.map do
        Thread.new { run_cleanup(receipt_path, review_input_path, helper: lifecycle_helper) }
      end.map(&:value)
      successful, blocked = results.partition { |_decision, _stderr, status| status.success? }

      assert_equal 1, successful.length
      assert_equal "cleaned", successful.first.first.fetch("status")
      assert_equal 1, blocked.length
      assert_equal "cleanup-already-running", blocked.first.first.fetch("reason")
      refute_path_exists scratch_root
      assert_equal JSON.generate(receipt), File.binread(receipt_path)
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-lock-*"))
    end
  end

  def test_cleanup_holder_replacement_is_rejected_without_moving_or_deleting_the_replacement
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
      instrumented_helper = File.read(HELPER).sub(
        "    moved_by_invocation = true\n",
        <<~RUBY.gsub(/^/, "    ")
          moved_by_invocation = true
          if ENV["TASK_SCRATCH_AFTER_MOVE_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_AFTER_MOVE_SIGNAL"), "moved")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_AFTER_MOVE_RELEASE"))
          end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
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
            "reasons" => ["review-clean"]
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
      File.write(evidence_path, "owned scratch\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "after-move.signal")
      release_path = File.join(directory, "after-move.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_AFTER_MOVE_SIGNAL" => signal_path,
            "TASK_SCRATCH_AFTER_MOVE_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      payload = File.join(holder, "payload")
      parked_root = File.join(scratch_parent, "parked-owned-root")
      File.rename(payload, parked_root)
      Dir.mkdir(payload, 0o700)
      FileUtils.cp(File.join(parked_root, ".task-scratch-owner.json"), payload)
      foreign_path = File.join(payload, "evidence.json")
      File.write(foreign_path, "must survive\n")
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-root-rebound", blocked.fetch("reason")
      refute_path_exists scratch_root
      assert_equal "owned scratch\n", File.read(File.join(parked_root, "evidence.json"))
      assert_path_exists File.join(parked_root, ".task-scratch-owner.json")
      assert_equal "must survive\n", File.read(foreign_path)
    end
  end

  def test_scratch_root_replacement_immediately_before_move_is_rejected_without_moving_the_replacement
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        "    root_name = File.basename(root)\n",
        <<~RUBY.gsub(/^/, "    ")
          root_name = File.basename(root)
          if ENV["TASK_SCRATCH_BEFORE_ROOT_MOVE_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_BEFORE_ROOT_MOVE_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_BEFORE_ROOT_MOVE_RELEASE"))
          end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(File.join(scratch_root, "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "before-root-move.signal")
      release_path = File.join(directory, "before-root-move.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_BEFORE_ROOT_MOVE_SIGNAL" => signal_path,
            "TASK_SCRATCH_BEFORE_ROOT_MOVE_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      parked_owned_root = File.join(directory, "parked-owned-root")
      File.rename(scratch_root, parked_owned_root)
      Dir.mkdir(scratch_root, 0o700)
      replacement_stat = File.stat(scratch_root)
      foreign_path = File.join(scratch_root, "foreign.txt")
      File.write(foreign_path, "must remain in place\n")
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-root-rebound", blocked.fetch("reason")
      assert_equal [replacement_stat.dev, replacement_stat.ino],
                   [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal "must remain in place\n", File.read(foreign_path)
      assert_equal "owned evidence\n", File.read(File.join(parked_owned_root, "evidence.json"))
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_filesystem_failure_after_owned_move_restores_the_complete_intact_root
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
      instrumented_helper = File.read(HELPER).sub(
        '    fail!("scratch-entry-rebound") unless tree_bindings_current?(files, directories)',
        "    raise Errno::EIO, \"injected failure after owned move\""
      )
      File.write(lifecycle_helper, instrumented_helper)
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
            "reasons" => ["review-clean"]
          )
        RUBY
      )
      File.chmod(0o755, lifecycle_helper)
      File.chmod(0o755, review_helper)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["evidence.json", "nested/notes.txt"],
        helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      File.write(File.join(scratch_root, "evidence.json"), "owned evidence\n")
      FileUtils.mkdir_p(File.join(scratch_root, "nested"))
      File.write(File.join(scratch_root, "nested/notes.txt"), "owned notes\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      preserved = Dir.glob(File.join(scratch_root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path.delete_prefix("#{scratch_root}/"), File.directory?(path) ? :directory : File.binread(path)]
      end

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper
      )

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "cleanup-filesystem-failure", blocked.fetch("reason")
      assert_path_exists scratch_root
      restored = Dir.glob(File.join(scratch_root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path.delete_prefix("#{scratch_root}/"), File.directory?(path) ? :directory : File.binread(path)]
      end
      assert_equal preserved, restored
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_cleanup_rejects_an_intermediate_symlink_swap_without_deleting_external_files
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      external_root = File.join(directory, "external")
      [scratch_parent, durable_root, helper_root, external_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        '    fail!("scratch-entry-rebound") unless tree_bindings_current?(files, directories)',
        <<~RUBY.gsub(/^/, "    ").strip
          if ENV["TASK_SCRATCH_TREE_VALIDATED_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_TREE_VALIDATED_SIGNAL"), "validated")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_TREE_VALIDATED_RELEASE"))
          end
          fail!("scratch-entry-rebound") unless tree_bindings_current?(files, directories)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
      created, create_stderr, create_status = run_create(
        repository,
        scratch_parent,
        identity_path,
        ["nested/notes.txt"],
        helper: lifecycle_helper
      )
      assert create_status.success?, create_stderr
      receipt = created.fetch("receipt")
      scratch_root = receipt.fetch("scratch_root")
      nested = File.join(scratch_root, "nested")
      Dir.mkdir(nested)
      File.write(File.join(nested, "notes.txt"), "owned notes\n")
      external_file = File.join(external_root, "notes.txt")
      File.write(external_file, "external notes\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "tree-validated.signal")
      release_path = File.join(directory, "tree-validated.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_TREE_VALIDATED_SIGNAL" => signal_path,
            "TASK_SCRATCH_TREE_VALIDATED_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      parked_nested = File.join(directory, "parked-nested")
      payload = File.join(holder, "payload")
      File.rename(File.join(payload, "nested"), parked_nested)
      File.symlink(external_root, File.join(payload, "nested"))
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-entry-rebound", blocked.fetch("reason")
      assert_equal "external notes\n", File.read(external_file)
      assert_equal "owned notes\n", File.read(File.join(parked_nested, "notes.txt"))
    end
  end

  def test_pre_detach_path_replacement_is_restored_after_identity_rejection
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        "      result = CleanupSyscalls.rename_no_replace(directory.fileno, name, directory.fileno, candidate)",
        <<~RUBY.gsub(/^/, "      ").strip
          if name == "evidence.json" && ENV["TASK_SCRATCH_BEFORE_ENTRY_DETACH_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_BEFORE_ENTRY_DETACH_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_BEFORE_ENTRY_DETACH_RELEASE"))
          end
          result = CleanupSyscalls.rename_no_replace(directory.fileno, name, directory.fileno, candidate)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(File.join(scratch_root, "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "before-entry-detach.signal")
      release_path = File.join(directory, "before-entry-detach.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_BEFORE_ENTRY_DETACH_SIGNAL" => signal_path,
            "TASK_SCRATCH_BEFORE_ENTRY_DETACH_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      payload = File.join(holder, "payload")
      evidence_path = File.join(payload, "evidence.json")
      parked_evidence = File.join(directory, "parked-evidence.json")
      File.rename(evidence_path, parked_evidence)
      File.write(evidence_path, "replacement evidence\n")
      replacement_stat = File.stat(evidence_path)
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-entry-rebound", blocked.fetch("reason")
      assert_equal "owned evidence\n", File.read(parked_evidence)
      assert_equal [replacement_stat.dev, replacement_stat.ino], [File.stat(evidence_path).dev, File.stat(evidence_path).ino]
      assert_empty Dir.glob(File.join(payload, ".task-scratch-delete-*"))
    end
  end

  def test_final_root_removal_detaches_and_rejects_a_replacement_directory
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        '    detach_and_remove(holder, "payload", owned_root.stat, directory_entry: true)',
        <<~RUBY.gsub(/^/, "    ").strip
          if ENV["TASK_SCRATCH_BEFORE_ROOT_REMOVE_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_BEFORE_ROOT_REMOVE_SIGNAL"), "ready")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_BEFORE_ROOT_REMOVE_RELEASE"))
          end
          detach_and_remove(holder, "payload", owned_root.stat, directory_entry: true)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(File.join(scratch_root, "evidence.json"), "disposable\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "before-root-remove.signal")
      release_path = File.join(directory, "before-root-remove.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_BEFORE_ROOT_REMOVE_SIGNAL" => signal_path,
            "TASK_SCRATCH_BEFORE_ROOT_REMOVE_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      payload = File.join(holder, "payload")
      parked_owned_root = File.join(directory, "parked-owned-root")
      File.rename(payload, parked_owned_root)
      Dir.mkdir(payload, 0o700)
      replacement_stat = File.stat(payload)
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-entry-rebound", blocked.fetch("reason")
      assert_path_exists parked_owned_root
      assert_equal [replacement_stat.dev, replacement_stat.ino], [File.stat(payload).dev, File.stat(payload).ino]
      assert_empty Dir.glob(File.join(holder, ".task-scratch-delete-*"))
    end
  end

  def test_missing_scanned_owner_marker_blocks_structurally_and_rolls_back_the_complete_root
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        '    files, directories = scan_allowlisted_tree(owned_root, receipt.fetch("allowlist"))',
        <<~RUBY.gsub(/^/, "    ").strip
          marker = File.join(parent, holder_name, "payload", OWNER_BASENAME)
          parked_marker = File.join(parent, holder_name, "parked-owner-marker")
          File.rename(marker, parked_marker)
          files, directories = scan_allowlisted_tree(owned_root, receipt.fetch("allowlist"))
          File.rename(parked_marker, marker)
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(evidence_path, "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      root_stat = File.stat(scratch_root)
      marker_bytes = File.binread(File.join(scratch_root, ".task-scratch-owner.json"))

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper
      )

      refute cleanup_status.success?
      assert_kind_of Hash, blocked, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "owner-marker-mismatch", blocked.fetch("reason")
      assert_equal [root_stat.dev, root_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal "owned evidence\n", File.read(evidence_path)
      assert_equal marker_bytes, File.binread(File.join(scratch_root, ".task-scratch-owner.json"))
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def test_post_verification_private_name_rebinding_preserves_the_replacement
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        '    fail!("scratch-entry-rebound") unless same_identity?(captured.stat, expected_stat)',
        <<~RUBY.gsub(/^/, "    ").strip
          fail!("scratch-entry-rebound") unless same_identity?(captured.stat, expected_stat)
          if name == "payload" && ENV["TASK_SCRATCH_PRIVATE_VERIFIED_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_PRIVATE_VERIFIED_SIGNAL"), private_name)
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_PRIVATE_VERIFIED_RELEASE"))
          end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(File.join(scratch_root, "evidence.json"), "disposable\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "private-verified.signal")
      release_path = File.join(directory, "private-verified.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_PRIVATE_VERIFIED_SIGNAL" => signal_path,
            "TASK_SCRATCH_PRIVATE_VERIFIED_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      private_path = File.join(holder, File.read(signal_path))
      parked_owned_root = File.join(directory, "parked-owned-root")
      File.rename(private_path, parked_owned_root)
      Dir.mkdir(private_path, 0o700)
      replacement_stat = File.stat(private_path)
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "scratch-entry-rebound", blocked.fetch("reason")
      assert_path_exists parked_owned_root
      assert_equal [replacement_stat.dev, replacement_stat.ino], [File.stat(private_path).dev, File.stat(private_path).ino]
    end
  end

  def test_post_verification_rollback_source_rebinding_preserves_both_directories
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, = build_repository(directory)
      identity_path = File.join(directory, "task-identity.json")
      File.write(identity_path, JSON.generate("identity" => TASK_IDENTITY))
      scratch_parent = File.join(directory, "scratch-parent")
      durable_root = File.join(directory, "durable")
      helper_root = File.join(directory, "helper-bin")
      [scratch_parent, durable_root, helper_root].each { |path| Dir.mkdir(path) }
      lifecycle_helper = File.join(helper_root, "task-scratch-lifecycle")
      review_helper = File.join(helper_root, "task-review-loop")
      instrumented_helper = File.read(HELPER).sub(
        '    fail!("scratch-entry-rebound") unless tree_bindings_current?(files, directories)',
        '    raise Errno::EIO, "injected failure before deletion"'
      ).sub(
        "    return false unless root_identity_matches?(payload.stat, receipt)",
        <<~RUBY.gsub(/^/, "    ").strip
          return false unless root_identity_matches?(payload.stat, receipt)
          if ENV["TASK_SCRATCH_ROLLBACK_SOURCE_VERIFIED_SIGNAL"]
            File.write(ENV.fetch("TASK_SCRATCH_ROLLBACK_SOURCE_VERIFIED_SIGNAL"), "verified")
            sleep 0.01 until File.exist?(ENV.fetch("TASK_SCRATCH_ROLLBACK_SOURCE_VERIFIED_RELEASE"))
          end
        RUBY
      )
      refute_equal File.read(HELPER), instrumented_helper
      File.write(lifecycle_helper, instrumented_helper)
      write_clean_review_helper(review_helper)
      File.chmod(0o755, lifecycle_helper)
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
      File.write(File.join(scratch_root, "evidence.json"), "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      review_input_path = File.join(durable_root, "task-review-input.json")
      File.write(receipt_path, JSON.generate(receipt))
      File.write(review_input_path, JSON.generate("identity" => TASK_IDENTITY))
      signal_path = File.join(directory, "rollback-source-verified.signal")
      release_path = File.join(directory, "rollback-source-verified.release")
      cleanup = Thread.new do
        run_cleanup(
          receipt_path,
          review_input_path,
          helper: lifecycle_helper,
          env: {
            "TASK_SCRATCH_ROLLBACK_SOURCE_VERIFIED_SIGNAL" => signal_path,
            "TASK_SCRATCH_ROLLBACK_SOURCE_VERIFIED_RELEASE" => release_path
          }
        )
      end
      sleep 0.01 until File.exist?(signal_path)
      holder = Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*")).fetch(0)
      payload = File.join(holder, "payload")
      parked_owned_root = File.join(directory, "parked-owned-root")
      File.rename(payload, parked_owned_root)
      Dir.mkdir(payload, 0o700)
      foreign_path = File.join(payload, "foreign.txt")
      File.write(foreign_path, "foreign evidence\n")
      replacement_stat = File.stat(payload)
      File.write(release_path, "continue")

      blocked, cleanup_stderr, cleanup_status = cleanup.value

      refute cleanup_status.success?, cleanup_stderr
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "cleanup-filesystem-failure", blocked.fetch("reason")
      refute_path_exists scratch_root
      assert_equal "owned evidence\n", File.read(File.join(parked_owned_root, "evidence.json"))
      assert_path_exists File.join(parked_owned_root, ".task-scratch-owner.json")
      assert_equal [replacement_stat.dev, replacement_stat.ino], [File.stat(payload).dev, File.stat(payload).ino]
      assert_equal "foreign evidence\n", File.read(foreign_path)
    end
  end

  private

  def executable_on_path(name)
    executable = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |path|
      candidate = File.expand_path(File.join(path, name))
      candidate if File.file?(candidate) && File.executable?(candidate)
    end.first
    executable || raise("#{name} executable not found on PATH")
  end

  def assert_cleanup_blocks_when_review_helper_cannot_launch(mode)
    Dir.mktmpdir("task-scratch-lifecycle") do |directory|
      repository, base_sha, head_sha = build_repository(directory)
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
      File.chmod(0o755, lifecycle_helper)
      if mode == :not_executable
        write_clean_review_helper(review_helper)
        File.chmod(0o644, review_helper)
      end

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
      File.write(evidence_path, "owned evidence\n")
      receipt_path = File.join(durable_root, "scratch-receipt.json")
      File.write(receipt_path, JSON.generate(receipt))
      review_input_path, review_artifacts = write_clean_review_input(
        durable_root,
        repository,
        base_sha,
        head_sha
      )
      root_stat = File.stat(scratch_root)
      root_children = Dir.children(scratch_root).sort
      preserved_paths = [
        receipt_path,
        evidence_path,
        File.join(scratch_root, ".task-scratch-owner.json"),
        review_input_path,
        *review_artifacts
      ]
      preserved_bytes = preserved_paths.to_h { |path| [path, File.binread(path)] }

      blocked, cleanup_stderr, cleanup_status = run_cleanup(
        receipt_path,
        review_input_path,
        helper: lifecycle_helper
      )

      refute cleanup_status.success?
      assert_empty cleanup_stderr
      assert_kind_of Hash, blocked
      assert_equal "blocked", blocked.fetch("status")
      assert_equal "review-validation-unavailable", blocked.fetch("reason")
      assert_equal [root_stat.dev, root_stat.ino], [File.stat(scratch_root).dev, File.stat(scratch_root).ino]
      assert_equal root_children, Dir.children(scratch_root).sort
      preserved_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
      assert_empty Dir.glob(File.join(scratch_parent, ".task-scratch-cleanup-*"))
    end
  end

  def write_clean_review_helper(path)
    File.write(
      path,
      <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        $stdin.read
        puts JSON.generate(
          "contract" => "task-review-loop-decision",
          "version" => 1,
          "status" => "task_complete",
          "dependent_task_permitted" => true,
          "reasons" => ["review-clean"]
        )
      RUBY
    )
    File.chmod(0o755, path)
  end

  def run_create(repository, scratch_parent, identity_path, allowlist, helper: HELPER, env: {})
    install_helper_dependencies(helper) unless helper == HELPER
    arguments = [
      helper,
      "create",
      "--repository-root", repository,
      "--scratch-parent", scratch_parent,
      "--identity-file", identity_path
    ]
    allowlist.each { |path| arguments.concat(["--allow-relative", path]) }
    stdout, stderr, status = Open3.capture3(env, *arguments)
    [stdout.empty? ? nil : JSON.parse(stdout), stderr, status]
  end

  def install_helper_dependencies(helper)
    library_root = File.expand_path("../lib", File.dirname(helper))
    FileUtils.mkdir_p(library_root)
    FileUtils.cp(GIT_PROBE_ENV, File.join(library_root, File.basename(GIT_PROBE_ENV)))
  end

  def run_cleanup(receipt_path, review_input_path, helper: HELPER, env: {})
    stdout, stderr, status = Open3.capture3(
      env,
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
