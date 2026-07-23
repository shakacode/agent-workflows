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

    def open!(revision)
      unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)
        raise StoreError, "canonical content store revision must be a full SHA-1"
      end

      root = File.join(state_root, "store", revision)
      verify_store!(root, revision)
    end

    private

    def fetch_url!(url, cleanup_probe: nil)
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
        git.send(:fetch_url!, repository, url, private_home: private_home)
        revision = git.resolve_private_revision!(repository, private_home: private_home)
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
          snapshot = verify_store!(destination, revision)
          SecurePaths.cleanup_owned_directory!(stage, identity)
          published = true
          return snapshot
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

    def verify_store!(root, revision)
      SecurePaths.verify_private_directory!(root)
      repository = File.join(root, "repo.git")
      tree = File.join(root, "tree")
      private_home = File.join(root, "home")
      [repository, tree, private_home].each { |path| SecurePaths.verify_private_directory!(path) }
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

        File.chmod(stat.directory? ? 0o700 : stat.mode & 0o755, path)
      end
    end

    def verify_state_tree_permissions!(root)
      Find.find(root) do |path|
        stat = File.lstat(path)
        raise StoreError, "canonical content store path has wrong owner: #{path}" unless stat.uid == Process.uid
        if stat.directory? && (stat.mode & 0o777) != 0o700
          raise StoreError, "canonical content store directory must have mode 0700: #{path}"
        end
        if !stat.symlink? && (stat.mode & 0o022).positive?
          raise StoreError, "canonical content store path is group/world writable: #{path}"
        end
      end
    end
  end
end
