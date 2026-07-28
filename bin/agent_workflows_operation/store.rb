# frozen_string_literal: true

require "fileutils"
require "find"
require "securerandom"

require_relative "errors"
require_relative "secure_git"
require_relative "secure_paths"
require_relative "tree"

module AgentWorkflowsOperation
  StoreSnapshot = Data.define(:revision, :root, :repository, :tree)

  class Store
    attr_reader :state_root, :git

    def initialize(state_root:)
      @state_root = state_root
      @git = SecureGit.new
    end

    def fetch_current!
      fetch_url!(SecureGit::CANONICAL_URL)
    end

    def import_local!(source, revision)
      stage_snapshot!(revision, repair_existing: true) do |repository, private_home|
        git.import_local_revision!(repository, source, revision, private_home: private_home)
      end
    end

    def open!(revision)
      unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)
        raise StoreError, "canonical content store revision must be a full SHA-1"
      end

      root = File.join(state_root, "store", revision)
      verify_store!(root, revision)
    end

    private

    def fetch_url!(url, cleanup_probe: nil)
      stage_snapshot!(nil, cleanup_probe:) do |repository, private_home|
        git.send(:fetch_url!, repository, url, private_home: private_home)
      end
    end

    def stage_snapshot!(expected_revision, cleanup_probe: nil, repair_existing: false)
      quarantine = File.join(state_root, "quarantine")
      SecurePaths.verify_private_directory!(quarantine)
      stage = File.join(quarantine, SecureRandom.hex(24))
      Dir.mkdir(stage, 0o700)
      identity = SecurePaths.owned_identity(stage)
      cleanup_path = stage
      published = false
      begin
        private_home = File.join(stage, "home")
        repository = File.join(stage, "repo.git")
        tree = File.join(stage, "tree")
        Dir.mkdir(private_home, 0o700)
        git.init_bare!(repository, private_home: private_home)
        FileUtils.chmod(0o700, repository)
        yield repository, private_home
        revision = git.resolve_private_revision!(repository, private_home: private_home)
        if expected_revision && revision != expected_revision
          raise StoreError, "imported provider revision does not match #{expected_revision}"
        end

        Dir.mkdir(tree, 0o700)
        git.archive!(repository, revision, tree, private_home: private_home)
        Tree.verify_against_git!(
          git: git,
          repository: repository,
          revision: revision,
          root: tree,
          private_home: private_home
        )
        harden_state_tree!(stage)
        cleanup_probe&.call(stage)
        destination = File.join(state_root, "store", revision)
        if File.exist?(destination) || File.symlink?(destination)
          begin
            snapshot = verify_store!(destination, revision)
            SecurePaths.cleanup_owned_directory!(stage, identity)
            published = true
            return snapshot
          rescue StoreError
            raise unless repair_existing

            remove_repairable_store!(destination)
          end
        end
        begin
          File.rename(stage, destination)
        rescue Errno::EEXIST, Errno::ENOTEMPTY
          snapshot = verify_store!(destination, revision)
          SecurePaths.cleanup_owned_directory!(stage, identity)
          published = true
          return snapshot
        end
        cleanup_path = destination
        snapshot = verify_store!(destination, revision)
        published = true
        snapshot
      rescue SystemCallError => e
        raise StoreError, "unable to stage canonical provider: #{e.message}"
      ensure
        SecurePaths.cleanup_owned_directory!(cleanup_path, identity) unless published
      end
    end

    def remove_repairable_store!(root)
      stat = File.lstat(root)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        raise StoreError, "existing canonical content store is not safely repairable"
      end

      Find.find(root) do |path|
        entry = File.lstat(path)
        unless entry.uid == Process.uid && (entry.symlink? || entry.directory? || entry.file?)
          raise StoreError, "existing canonical content store contains an unsafe entry: #{path}"
        end
      end
      SecurePaths.cleanup_owned_directory!(root, SecurePaths.owned_identity(root))
    rescue Errno::ENOENT
      nil
    end

    def verify_store!(root, revision)
      SecurePaths.verify_private_directory!(root)
      repository = File.join(root, "repo.git")
      tree = File.join(root, "tree")
      private_home = File.join(root, "home")
      [repository, private_home].each { |path| SecurePaths.verify_private_directory!(path) }
      tree_stat = File.lstat(tree)
      unless tree_stat.directory? && !tree_stat.symlink? && tree_stat.uid == Process.uid &&
             (tree_stat.mode & 0o777) == 0o500
        raise StoreError, "canonical instruction snapshot root must have mode 0500"
      end

      verify_state_tree_permissions!(root)
      alternates = File.join(repository, "objects/info/alternates")
      raise StoreError, "canonical content store must not use Git alternates" if File.exist?(alternates) || File.symlink?(alternates)

      resolved = git.resolve_private_revision!(repository, private_home: private_home)
      raise StoreError, "canonical content store ref does not match #{revision}" unless resolved == revision

      Tree.verify_against_git!(
        git: git,
        repository: repository,
        revision: revision,
        root: tree,
        private_home: private_home
      )
      StoreSnapshot.new(revision: revision, root: root, repository: repository, tree: tree)
    rescue PathError, GitError, StoreError => e
      raise StoreError, "canonical content store verification failed: #{e.message}"
    end

    def harden_state_tree!(root)
      Find.find(root) do |path|
        stat = File.lstat(path)
        next if stat.symlink?

        in_instruction_tree = path == File.join(root, "tree") ||
                              path.start_with?("#{File.join(root, 'tree')}/")
        mode = if stat.directory?
                 in_instruction_tree ? 0o500 : 0o700
               elsif in_instruction_tree
                 (stat.mode & 0o111).positive? ? 0o500 : 0o400
               else
                 stat.mode & 0o755
               end
        File.chmod(mode, path)
      end
    end

    def verify_state_tree_permissions!(root)
      Find.find(root) do |path|
        stat = File.lstat(path)
        raise StoreError, "canonical content store path has wrong owner: #{path}" unless stat.uid == Process.uid

        in_instruction_tree = path == File.join(root, "tree") ||
                              path.start_with?("#{File.join(root, 'tree')}/")
        expected_directory_mode = in_instruction_tree ? 0o500 : 0o700
        if stat.directory? && (stat.mode & 0o777) != expected_directory_mode
          raise StoreError, "canonical content store directory has unsafe mode: #{path}"
        end
        if in_instruction_tree && stat.file? && (stat.mode & 0o200).positive?
          raise StoreError, "canonical instruction snapshot is owner-writable: #{path}"
        end
        if !stat.symlink? && (stat.mode & 0o022).positive?
          raise StoreError, "canonical content store path is group/world writable: #{path}"
        end
      end
    end
  end
end
