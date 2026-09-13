#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"

# List user-visible Codex Desktop tasks from local Codex state, read-only.
module LocalChatInventory
  class DatabaseError < StandardError; end

  module_function

  def query(path, sql)
    stdout, stderr, status = Open3.capture3(
      "sqlite3", "-init", File::NULL, "-readonly", "-batch", "-json", File.expand_path(path),
      stdin_data: sql
    )
    [stdout, stderr].each { |output| output.force_encoding(Encoding::UTF_8) }
    unless stdout.valid_encoding? && stderr.valid_encoding?
      raise DatabaseError, "sqlite3 output is not valid UTF-8"
    end
    raise DatabaseError, stderr.strip unless status.success?

    stdout.strip.empty? ? [] : JSON.parse(stdout)
  rescue JSON::ParserError => e
    raise DatabaseError, e.message
  end

  def columns(path, table)
    query(path, "PRAGMA table_info(#{table});").map { |row| row.fetch("name") }
  end

  def catalog_rows(path)
    names = columns(path, "local_thread_catalog")
    required = %w[host_id thread_id display_title source_kind]
    unless (required - names).empty?
      raise DatabaseError, "local_thread_catalog has an unsupported schema"
    end

    optional = %w[cwd source_updated_at source_recency_at thread_source missing_candidate project_id]
    selected = required + (optional & names)
    query(path, "SELECT #{selected.join(', ')} FROM local_thread_catalog;").each_with_object({}) do |row, rows|
      next unless row["source_kind"] == "vscode" && [nil, "local"].include?(row["host_id"])

      rows[row.fetch("thread_id").to_s] = row
    end
  end

  def state_rows(path)
    names = columns(path, "threads")
    unless (%w[id archived source] - names).empty?
      raise DatabaseError, "threads has an unsupported schema"
    end

    selected = %w[id title name cwd rollout_path updated_at updated_at_ms recency_at recency_at_ms
                  archived source thread_source agent_path is_pinned project_id] & names
    query(path, "SELECT #{selected.join(', ')} FROM threads;").to_h { |row| [row.fetch("id").to_s, row] }
  end

  # SQLite flags are integers; Ruby treats zero as truthy.
  def flag?(value)
    !value.nil? && value != false && value != 0 && value != ""
  end

  def first_value(*values)
    values.find { |value| flag?(value) } || values.last
  end

  def state_timestamp(row, seconds_key, milliseconds_key)
    return row[seconds_key] unless row[seconds_key].nil?

    milliseconds = row[milliseconds_key]
    milliseconds.nil? ? nil : Float(milliseconds) / 1000
  end

  def build_inventory(codex_home, include_archived: false)
    codex_home = File.expand_path(codex_home)
    state_path = %w[state_5.sqlite sqlite/state_5.sqlite].map { |name| File.join(codex_home, name) }.find { |path| File.file?(path) }
    raise DatabaseError, "Codex state database not found" unless state_path

    state = state_rows(state_path)
    candidate_ids = state.filter_map { |id, row| id if row["source"] == "vscode" }
    catalog_path = File.join(codex_home, "sqlite/codex-dev.db")
    catalog = {}
    scope = "state-vscode-fallback"
    warning = "Desktop catalog unavailable; inventory may be incomplete"
    if File.file?(catalog_path)
      begin
        catalog = catalog_rows(catalog_path)
        if catalog.empty? && !candidate_ids.empty?
          warning = "Desktop catalog empty; using Codex state fallback"
        else
          scope = "desktop-catalog"
          warning = nil
          candidate_ids |= catalog.keys
        end
      rescue DatabaseError
        warning = "Desktop catalog unsupported; using Codex state fallback"
      end
    end

    tasks = candidate_ids.filter_map do |id|
      row = state.fetch(id, {})
      catalog_row = catalog.fetch(id, {})
      if flag?(catalog_row["missing_candidate"]) && !(include_archived && flag?(row["archived"]))
        next
      end
      next if !include_archived && flag?(row["archived"])
      next if flag?(row["agent_path"])
      next if %w[subagent guardian_review].include?(row["thread_source"])
      next if row["thread_source"] == "agent_created_thread" && catalog_row.empty?
      next if %w[subagent guardian_review].include?(catalog_row["thread_source"])

      title = first_value(catalog_row["display_title"], row["name"], row["title"])
      {
        "id" => id,
        "title" => title.to_s.split(/\r\n|[\n\r\v\f\u001c-\u001e\u0085\u2028\u2029]/, 2).first.to_s,
        "cwd" => first_value(catalog_row["cwd"], row["cwd"]),
        "updated_at" => catalog_row["source_updated_at"] || state_timestamp(row, "updated_at", "updated_at_ms"),
        "recency_at" => catalog_row["source_recency_at"] || state_timestamp(row, "recency_at", "recency_at_ms"),
        "archived" => row.empty? ? nil : flag?(row["archived"]),
        "pinned" => row.empty? ? nil : flag?(row["is_pinned"]),
        "project_id" => first_value(row["project_id"], catalog_row["project_id"]),
        "thread_source" => first_value(row["thread_source"], catalog_row["thread_source"]),
        "state_available" => !row.empty?
      }
    end
    tasks.sort_by! { |task| [task["recency_at"] || 0, task["id"]] }.reverse!
    { "schema_version" => 1, "scope" => scope, "warning" => warning, "count" => tasks.length, "tasks" => tasks }
  end

  def main(argv)
    options = { codex_home: ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex")), include_archived: false, format: "json" }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: local_chat_inventory.rb [options]\nList user-visible Codex Desktop tasks from local Codex state, read-only."
      opts.on("--codex-home PATH") { |value| options[:codex_home] = value }
      opts.on("--include-archived") { options[:include_archived] = true }
      opts.on("--format FORMAT", %w[json tsv]) { |value| options[:format] = value }
      opts.on("-h", "--help") do
        puts opts
        return 0
      end
    end
    parser.parse!(argv)
    raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?

    result = build_inventory(options[:codex_home], include_archived: options[:include_archived])
    if options[:format] == "json"
      puts JSON.pretty_generate(result)
    else
      fields = %w[id title recency_at updated_at archived pinned cwd]
      puts fields.join("\t")
      result.fetch("tasks").each do |task|
        puts fields.map { |field| tsv_value(task[field]) }.join("\t")
      end
    end
    0
  rescue OptionParser::ParseError => e
    warn "local_chat_inventory: #{e.message}"
    2
  rescue SystemCallError, DatabaseError => e
    warn "local_chat_inventory: #{e.message}"
    1
  end

  def tsv_value(value)
    case value
    when true then "True"
    when false then "False"
    else value.to_s
    end
  end
end

exit LocalChatInventory.main(ARGV) if $PROGRAM_NAME == __FILE__
