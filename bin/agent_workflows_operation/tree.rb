# frozen_string_literal: true

require "digest"
require "find"

require_relative "errors"

module AgentWorkflowsOperation
  module Tree
    module_function

    def verify_against_git!(git:, repository:, revision:, root:, private_home:, ignore_git: false)
      expected = git.ls_tree!(repository, revision, private_home: private_home)
      actual = filesystem_entries(root, ignore_git: ignore_git)
      unless actual.keys.sort == expected.keys.sort
        missing = expected.keys - actual.keys
        extra = actual.keys - expected.keys
        raise StoreError, "tree mismatch (missing: #{missing.first(5).join(', ')}; extra: #{extra.first(5).join(', ')})"
      end

      expected.each do |relative, entry|
        actual_entry = actual.fetch(relative)
        unless actual_entry.fetch("mode") == entry.fetch("mode") &&
               actual_entry.fetch("object") == entry.fetch("object")
          raise StoreError, "tree entry differs from canonical Git object: #{relative}"
        end
      end
      true
    end

    def verify_file_against_git!(git:, repository:, revision:, root:, relative:, private_home:, manifest: nil)
      expected = (manifest || git.ls_tree!(repository, revision, private_home: private_home))[relative]
      raise StoreError, "canonical tree is missing required file: #{relative}" unless expected

      path = File.join(root, relative)
      actual = filesystem_entry(path)
      unless actual && actual.fetch("mode") == expected.fetch("mode") &&
             actual.fetch("object") == expected.fetch("object")
        raise StoreError, "installed provider file differs from canonical tree: #{relative}"
      end

      true
    end

    def verify_path_against_git!(
      git:,
      repository:,
      revision:,
      path:,
      source_relative:,
      private_home:,
      manifest: nil
    )
      expected = (manifest || git.ls_tree!(repository, revision, private_home: private_home))[source_relative]
      raise StoreError, "canonical tree is missing required file: #{source_relative}" unless expected

      actual = filesystem_entry(path)
      unless actual && actual.fetch("mode") == expected.fetch("mode") &&
             actual.fetch("object") == expected.fetch("object")
        raise StoreError, "private executable differs from canonical Git object: #{source_relative}"
      end

      true
    end

    def filesystem_entries(root, ignore_git:)
      raise StoreError, "tree root is not a real directory: #{root}" unless File.directory?(root) && !File.symlink?(root)

      entries = {}
      Find.find(root) do |path|
        next if path == root

        relative = path.delete_prefix("#{root}/")
        if ignore_git && (relative == ".git" || relative.start_with?(".git/"))
          Find.prune if File.directory?(path)
          next
        end
        entry = filesystem_entry(path)
        entries[relative] = entry if entry
      end
      entries
    rescue SystemCallError => e
      raise StoreError, "unable to inspect tree #{root}: #{e.message}"
    end

    def filesystem_entry(path)
      stat = File.lstat(path)
      if stat.symlink?
        content = File.readlink(path).b
        { "mode" => "120000", "object" => git_blob_id(content) }
      elsif stat.file?
        content = File.binread(path)
        mode = (stat.mode & 0o111).positive? ? "100755" : "100644"
        { "mode" => mode, "object" => git_blob_id(content) }
      end
    rescue Errno::ENOENT
      nil
    end

    def git_blob_id(content)
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0".b + content)
    end
  end
end
