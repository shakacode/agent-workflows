#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "local_chat_inventory"

class LocalChatInventoryTest < Minitest::Test
  SCRIPT = File.expand_path("local_chat_inventory.rb", __dir__)

  def setup
    @home = Dir.mktmpdir("codex#home ?%-")
    FileUtils.mkdir_p(File.join(@home, "sqlite"))
    @state = File.join(@home, "state_5.sqlite")
    @catalog = File.join(@home, "sqlite/codex-dev.db")
    sql(@state, <<~SQL)
      CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT,
        cwd TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at INTEGER,
        recency_at_ms INTEGER, archived INTEGER, source TEXT, thread_source TEXT,
        agent_path TEXT, is_pinned INTEGER, project_id TEXT);
      INSERT INTO threads VALUES
        ('active', '', NULL, '/a', 20, 20000, 19, 19000, 0, 'vscode', 'user', NULL, 1, 'p'),
        ('state-only', 'State only', NULL, '/h', 17, 17000, 16, 16000, 0, 'vscode', 'user', NULL, 0, NULL),
        ('missing-active', 'Missing active', NULL, '/i', 28, 28000, 27, 27000, 0, 'vscode', 'user', NULL, 0, NULL),
        ('archived', 'old', NULL, '/b', 10, 10000, 9, 9000, 1, 'vscode', 'user', NULL, 0, NULL),
        ('aged-archived', 'aged', NULL, '/e', 8, 8000, 7, 7000, 1, 'vscode', 'user', NULL, 0, NULL),
        ('agent-created', 'worker', NULL, '/f', 18, 18000, 17, 17000, 0, 'vscode', 'agent_created_thread', NULL, 0, NULL),
        ('worker', 'worker', NULL, '/c', 30, 30000, 29, 29000, 0, 'vscode', 'subagent', '/root/w', 0, NULL),
        ('exec', 'command', NULL, '/d', 40, 40000, 39, 39000, 0, 'exec', 'user', NULL, 0, NULL);
    SQL
    sql(@catalog, <<~SQL)
      CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT,
        display_title TEXT, source_kind TEXT, cwd TEXT, source_updated_at REAL,
        source_recency_at REAL, missing_candidate INTEGER);
      INSERT INTO local_thread_catalog VALUES
        ('local', 'active', 'Visible task', 'vscode', '/a', 21, 19, 0),
        ('local', 'catalog-only', 'Catalog task', 'vscode', '/g', 20, 18, 0),
        ('local', 'missing-active', 'Missing task', 'vscode', '/i', 28, 27, 1),
        ('local', 'archived', 'Archived task', 'vscode', '/b', 99, 9, 1),
        ('local', 'worker', 'Internal worker', 'vscode', '/c', 31, 29, 0),
        ('local', 'exec', 'Command', 'exec', '/d', 41, 39, 0),
        ('remote', 'remote', 'Remote task', 'vscode', '/e', 51, 49, 0);
    SQL
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def sql(path, statements)
    _, stderr, status = Open3.capture3("sqlite3", "-init", File::NULL, "-batch", path, stdin_data: statements)
    assert status.success?, stderr
  end

  def run_script(*arguments, environment: {})
    stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, SCRIPT, "--codex-home", @home, *arguments)
    assert status.success?, stderr
    JSON.parse(stdout.force_encoding(Encoding::UTF_8))
  end

  def invalid_output_environment(database)
    directory = File.join(@home, "invalid-sqlite-output")
    FileUtils.mkdir_p(directory)
    sqlite = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "sqlite3") }.find { |file| File.executable?(file) }
    script = File.join(directory, "sqlite3")
    File.write(script, <<~RUBY)
      #!#{RbConfig.ruby}
      require "open3"
      sql = $stdin.read
      if ARGV.last == #{database.dump} && sql.start_with?("SELECT ")
        $stdout.write("\\xFF")
      else
        stdout, stderr, status = Open3.capture3(#{sqlite.dump}, *ARGV, stdin_data: sql)
        $stdout.write(stdout)
        $stderr.write(stderr)
        exit status.exitstatus
      end
    RUBY
    File.chmod(0o755, script)
    { "PATH" => [directory, ENV.fetch("PATH")].join(File::PATH_SEPARATOR) }
  end

  def test_lists_only_unarchived_user_visible_local_tasks
    result = run_script
    assert_equal 1, result["schema_version"]
    assert_equal "desktop-catalog", result["scope"]
    assert_nil result["warning"]
    assert_equal 3, result["count"]
    assert_equal(%w[active catalog-only state-only], result["tasks"].map { |task| task["id"] })
    assert_equal "Visible task", result["tasks"][0]["title"]
    assert_equal 19, result["tasks"][0]["recency_at"]
    assert result["tasks"][0]["pinned"]
    refute result["tasks"][0]["archived"]
    assert_equal "p", result["tasks"][0]["project_id"]
    assert_nil result["tasks"][1]["archived"]
    refute result["tasks"][1]["state_available"]
  end

  def test_catalog_tombstone_excludes_unarchived_state_but_not_known_archived
    refute_includes run_script["tasks"].map { |task| task["id"] }, "missing-active"
    result = run_script("--include-archived")
    refute_includes result["tasks"].map { |task| task["id"] }, "missing-active"
    assert_includes result["tasks"].map { |task| task["id"] }, "archived"
  end

  def test_can_include_archived_tasks_without_including_workers
    result = run_script("--include-archived")
    assert_equal(%w[active catalog-only state-only archived aged-archived], result["tasks"].map { |task| task["id"] })
  end

  def test_missing_catalog_preserves_seconds_over_milliseconds
    File.unlink(@catalog)
    result = run_script
    assert_equal "state-vscode-fallback", result["scope"]
    assert_includes result["warning"], "unavailable"
    active = result["tasks"].find { |task| task["id"] == "active" }
    assert_equal "", active["title"]
    assert_equal 19, active["recency_at"]
    assert_equal 20, active["updated_at"]
  end

  def test_fallback_normalizes_millisecond_timestamps_to_seconds
    File.unlink(@catalog)
    sql(@state, "UPDATE threads SET updated_at = NULL, recency_at = NULL, recency_at_ms = 19500 WHERE id = 'active';")
    active = run_script["tasks"].find { |task| task["id"] == "active" }
    assert_equal 19.5, active["recency_at"]
    assert_equal 20.0, active["updated_at"]
  end

  def test_unsupported_catalog_uses_state_fallback
    File.unlink(@catalog)
    sql(@catalog, "CREATE TABLE unrelated (value TEXT);")
    result = run_script
    assert_equal "state-vscode-fallback", result["scope"]
    assert_includes result["warning"], "unsupported"
    assert_equal(%w[missing-active active state-only], result["tasks"].map { |task| task["id"] })
  end

  def test_corrupt_catalog_uses_state_fallback
    File.write(@catalog, "not a sqlite database")
    assert_includes run_script["warning"], "unsupported"
  end

  def test_invalid_utf8_catalog_output_uses_state_fallback
    result = run_script(environment: invalid_output_environment(@catalog))
    assert_equal "state-vscode-fallback", result["scope"]
    assert_includes result["warning"], "unsupported"
    assert_equal(%w[missing-active active state-only], result["tasks"].map { |task| task["id"] })
  end

  def test_invalid_utf8_state_output_exits_with_a_database_error
    stdout, stderr, status = Open3.capture3(invalid_output_environment(@state), RbConfig.ruby, SCRIPT, "--codex-home", @home)
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_equal "local_chat_inventory: sqlite3 output is not valid UTF-8\n", stderr
  end

  def test_empty_catalog_falls_back_only_when_state_has_candidates
    sql(@catalog, "DELETE FROM local_thread_catalog;")
    assert_includes run_script["warning"], "empty"
    sql(@state, "DELETE FROM threads;")
    result = run_script
    assert_equal "desktop-catalog", result["scope"]
    assert_nil result["warning"]
    assert_empty result["tasks"]
  end

  def test_state_schema_requires_archive_and_source_columns
    File.unlink(@state)
    sql(@state, "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT);")
    _, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--codex-home", @home)
    assert_equal 1, status.exitstatus
    assert_includes stderr, "threads has an unsupported schema"
  end

  def test_catalog_thread_sources_and_unicode_state_names_under_c_locale
    sql(@catalog, <<~SQL)
      ALTER TABLE local_thread_catalog ADD COLUMN thread_source TEXT;
      UPDATE local_thread_catalog SET thread_source = 'guardian_review' WHERE thread_id = 'catalog-only';
      INSERT INTO local_thread_catalog (host_id, thread_id, display_title, source_kind)
        VALUES ('local', 'agent-created', 'Named task', 'vscode');
    SQL
    sql(@state, <<~SQL)
      UPDATE threads SET name = 'Résumé
      second line' WHERE id = 'state-only';
      UPDATE threads SET thread_source = 'guardian_review' WHERE id = 'missing-active';
    SQL
    tasks = run_script(environment: { "LC_ALL" => "C", "LANG" => "C" })["tasks"]
    assert_equal(%w[active agent-created state-only], tasks.map { |task| task["id"] })
    assert_equal "Résumé", tasks.last["title"]
  end

  def test_tsv_keeps_boolean_spelling_and_empty_unknown_values
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--codex-home", @home, "--format", "tsv")
    assert status.success?, stderr
    lines = stdout.lines.map(&:chomp)
    assert_equal "id\ttitle\trecency_at\tupdated_at\tarchived\tpinned\tcwd", lines[0]
    assert_equal ["active", "Visible task", "19.0", "21.0", "False", "True", "/a"], lines[1].split("\t", -1)
    assert_equal ["catalog-only", "Catalog task", "18.0", "20.0", "", "", "/g"], lines[2].split("\t", -1)
  end

  def test_secondary_state_location_and_codex_home_environment
    File.rename(@state, File.join(@home, "sqlite/state_5.sqlite"))
    stdout, stderr, status = Open3.capture3({ "CODEX_HOME" => @home }, RbConfig.ruby, SCRIPT)
    assert status.success?, stderr
    assert_equal 3, JSON.parse(stdout)["count"]
  end

  def test_missing_state_is_not_created
    File.unlink(@state)
    _, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--codex-home", @home)
    assert_equal 1, status.exitstatus
    assert_includes stderr, "Codex state database not found"
    refute File.exist?(@state)
  end

  def test_inventory_runs_without_python_or_sqlite_startup_commands
    path = File.join(@home, "only-ruby-and-sqlite")
    FileUtils.mkdir_p(path)
    sqlite = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "sqlite3") }.find { |file| File.executable?(file) }
    File.symlink(File.realpath(sqlite), File.join(path, "sqlite3"))
    File.symlink(RbConfig.ruby, File.join(path, "ruby"))
    File.write(File.join(@home, ".sqliterc"), ".print UNEXPECTED_STARTUP_COMMAND\n")
    stdout, stderr, status = Open3.capture3({ "PATH" => path, "HOME" => @home }, SCRIPT, "--codex-home", @home)
    assert status.success?, stderr
    assert_equal 3, JSON.parse(stdout)["count"]
    assert_equal %w[ruby sqlite3], Dir.children(path).sort
  end

  def test_database_reads_preserve_files_and_connection_rejects_writes
    before = [@state, @catalog].to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
    run_script
    error = assert_raises(LocalChatInventory::DatabaseError) do
      LocalChatInventory.query(@state, "DELETE FROM threads;")
    end
    assert_match(/readonly|read.only/i, error.message)
    assert_equal(before, [@state, @catalog].to_h { |path| [path, Digest::SHA256.file(path).hexdigest] })
  end
end
