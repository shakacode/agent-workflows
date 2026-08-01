# frozen_string_literal: true

require "digest"
require "find"
require "json"

require_relative "errors"
require_relative "lifecycle_lease"
require_relative "process_supervisor"
require_relative "provider"
require_relative "registry"
require_relative "secure_paths"
require_relative "state"
require_relative "store"
require_relative "tree"

module AgentWorkflowsOperation
  class Runner
    PASSTHROUGH_ENVIRONMENT = %w[
      HOME XDG_CONFIG_HOME GH_CONFIG_DIR
      GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
      GH_HOST GH_REPO
      LANG LC_ALL LC_CTYPE
      HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
      http_proxy https_proxy all_proxy no_proxy
      SSL_CERT_FILE SSL_CERT_DIR
    ].freeze

    attr_reader :target, :state, :store, :lease

    def initialize(target:, lease: nil)
      @target = File.expand_path(target)
      @state = State.new(target: @target)
      @store = Store.new(state_root: state.root)
      @lease = lease || LifecycleLease.new(target: @target, root: state.root)
    rescue PathError => e
      raise RunnerError, e.message
    end

    def launch!(handle:, capability:, arguments:)
      lease.with_shared do
        operation_root, metadata, snapshot, registry = validated_operation!(handle, capability)
        enforce_current_provider!(registry.capability!(capability), metadata, capability)
        verify_provider!(metadata, snapshot)
        launcher = File.join(operation_root, "launcher")
        verify_executable_identity!(launcher, metadata.fetch("launcher"), "operation launcher")
        verify_runtime!(operation_root, metadata, snapshot)
        verify_external_executable!(metadata.fetch("environment"), "bound environment launcher")
        command = [
          verify_bound_interpreter!(operation_root, metadata),
          "--disable=gems",
          launcher,
          "--target", target,
          "--operation", handle,
          capability,
          "--",
          *arguments
        ]
        verify_runtime!(operation_root, metadata, snapshot)
        verify_executable_identity!(launcher, metadata.fetch("launcher"), "operation launcher")
        wait_for_command!(sanitized_environment(metadata), command)
      end
    rescue KeyError => e
      raise RunnerError, "operation metadata is incomplete: #{e.message}"
    end

    def run!(handle:, capability:, arguments:)
      lease.with_shared do
        operation_root, metadata, snapshot, registry = validated_operation!(handle, capability)
        definition = registry.capability!(capability)
        enforce_current_provider!(definition, metadata, capability)

        verify_provider!(metadata, snapshot)

        recorded = metadata.fetch("capabilities").fetch(capability)
        bundle = File.join(operation_root, "capabilities", capability)
        verify_capability_bundle!(bundle, recorded, definition, snapshot)
        executable_record = recorded.fetch("runtime").fetch(recorded.fetch("executable_role"))
        executable = File.join(bundle, executable_record.fetch("path"))
        ruby = verify_bound_interpreter!(operation_root, metadata)
        verify_external_executable!(metadata.fetch("environment"), "bound environment launcher")
        verify_external_executable!(metadata.fetch("tools").fetch("git"), "bound Git executable")
        gh = metadata.fetch("tools")["gh"]
        verify_external_executable!(gh, "bound gh executable") if gh
        wait_for_command!(
          sanitized_environment(metadata, capability: recorded, bundle: bundle),
          [ruby, "--disable=gems", executable, *arguments]
        )
      end
    rescue KeyError, RegistryError => e
      raise RunnerError, "operation capability binding is invalid: #{e.message}"
    rescue StoreError => e
      raise RunnerError, "canonical executable verification failed: #{e.message}"
    end

    private

    def wait_for_command!(environment, command)
      ProcessSupervisor.wait!(environment:, command:)
    rescue SystemCallError => e
      raise RunnerError, "operation capability could not be started: #{e.message}"
    end

    def sanitized_environment(metadata, capability: nil, bundle: nil)
      environment = PASSTHROUGH_ENVIRONMENT.to_h do |name|
        [name, ENV[name]]
      end.compact.merge(
        "HOME" => ENV.fetch("HOME", Dir.home),
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin",
        "GH_PROMPT_DISABLED" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "AGENT_WORKFLOWS_GIT_EXECUTABLE" => metadata.fetch("tools").fetch("git").fetch("path"),
        "AGENT_WORKFLOWS_GH_EXECUTABLE" => metadata.dig("tools", "gh", "path")
      )
      if capability
        environment["AGENT_WORKFLOWS_PROVIDER_OPERATION_PROVENANCE"] = capability.fetch("provenance")
        environment["AGENT_WORKFLOWS_PROVIDER_OPERATION_MANIFEST"] = JSON.generate(
          capability.fetch("runtime").transform_values do |recorded|
            {
              "path" => File.join(bundle, recorded.fetch("path")),
              "source" => recorded.fetch("source"),
              "sha256" => recorded.fetch("sha256")
            }
          end
        )
      end
      environment.compact
    end

    def verify_capability_bundle!(bundle, binding, definition, snapshot)
      runtime = binding.fetch("runtime")
      raise RunnerError, "operation capability runtime must be a nonempty object" unless runtime.is_a?(Hash) && !runtime.empty?

      expected_runtime = definition.runtime
      actual_runtime = runtime.transform_values { |recorded| recorded.fetch("source") }
      expected_executable_role = expected_runtime.key(definition.executable)
      unless actual_runtime == expected_runtime && binding.fetch("executable_role") == expected_executable_role
        raise RunnerError, "operation capability does not match the registry runtime manifest"
      end

      installation_trust = binding.fetch("installation_trust")
      unless installation_trust.is_a?(Hash) &&
             (installation_trust.keys - definition.installation_trust).empty?
        raise RunnerError, "operation capability installation trust does not match the registry"
      end

      root_stat = File.lstat(bundle)
      unless root_stat.directory? && !root_stat.symlink? && root_stat.uid == Process.uid &&
             (root_stat.mode & 0o777) == 0o500
        raise RunnerError, "operation capability bundle root is unsafe"
      end

      expected = (runtime.values + installation_trust.values).map { |recorded| recorded.fetch("path") }.sort
      actual = []
      Find.find(bundle) do |path|
        next if path == bundle

        relative = path.delete_prefix("#{bundle}/")
        stat = File.lstat(path)
        raise RunnerError, "operation capability bundle contains a symlink" if stat.symlink?

        if stat.directory?
          unless stat.uid == Process.uid && (stat.mode & 0o777) == 0o500
            raise RunnerError, "operation capability bundle directory is unsafe"
          end
        elsif stat.file?
          actual << relative
        else
          raise RunnerError, "operation capability bundle contains an unsupported entry"
        end
      end
      unless actual.sort == expected
        raise RunnerError, "operation capability bundle contains unknown or missing entries"
      end

      runtime.each do |role, recorded|
        path = File.join(bundle, recorded.fetch("path"))
        source_executable = (File.stat(File.join(snapshot.tree, recorded.fetch("source"))).mode & 0o111).positive?
        expected_mode = source_executable ? "0500" : "0400"
        unless recorded.fetch("path") == recorded.fetch("source") && recorded.fetch("mode") == expected_mode
          raise RunnerError, "operation capability runtime path or mode differs from the registry"
        end

        mode = expected_mode == "0500" ? 0o500 : 0o400
        if mode == 0o500
          verify_executable_identity!(path, recorded, "capability #{role}")
        else
          verify_file_identity!(path, recorded, "capability #{role}")
        end
        Tree.verify_path_against_git!(
          git: store.git,
          repository: snapshot.repository,
          revision: snapshot.revision,
          path: path,
          source_relative: recorded.fetch("source"),
          private_home: File.join(snapshot.root, "home")
        )
      end
      verify_installation_trust!(bundle, installation_trust, definition.installation_trust)
      digest = capability_digest(runtime, installation_trust, bundle)
      expected_provenance = "provider-operation:#{snapshot.revision}:#{digest}"
      unless binding.fetch("digest") == digest && binding.fetch("provenance") == expected_provenance
        raise RunnerError, "operation capability provenance does not match its runtime bundle"
      end
    rescue SystemCallError, KeyError, StoreError, PathError => e
      raise RunnerError, "operation capability bundle is invalid: #{e.message}"
    end

    def verify_installation_trust!(bundle, recorded_trust, configured_paths)
      recorded_trust.each do |relative, recorded|
        unless relative == recorded.fetch("source") && relative == recorded.fetch("path") &&
               recorded.fetch("mode") == "0400"
          raise RunnerError, "operation installation trust binding is invalid"
        end

        bundled = File.join(bundle, relative)
        verify_file_identity!(bundled, recorded, "installation trust anchor #{relative}")
        current = File.join(target, relative)
        verify_current_trust_source!(current, recorded, relative)
      end

      (configured_paths - recorded_trust.keys).each do |relative|
        current = File.join(target, relative)
        next unless File.exist?(current) || File.symlink?(current)

        raise RunnerError, "installation trust anchor appeared after operation begin; start a new operation: #{relative}"
      end
    end

    def verify_current_trust_source!(path, recorded, relative)
      target_stat = File.lstat(target)
      trust_dir_stat = File.lstat(File.dirname(path))
      source_stat = File.lstat(path)
      safe = [target_stat, trust_dir_stat].all? do |stat|
        stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
      end
      safe &&= source_stat.file? && !source_stat.symlink? && source_stat.uid == Process.uid &&
               (source_stat.mode & 0o022).zero?
      safe &&= source_stat.size == recorded.fetch("size") &&
               Digest::SHA256.file(path).hexdigest == recorded.fetch("sha256")
      raise RunnerError, "installation trust anchor changed after operation begin: #{relative}" unless safe
    rescue SystemCallError
      raise RunnerError, "installation trust anchor changed after operation begin: #{relative}"
    end

    def enforce_current_provider!(definition, metadata, capability)
      return unless definition.requires_current_provider
      return if metadata["freshness"] == "current" && metadata.dig("provider", "profile") == "managed"

      raise RunnerError, "CURRENT_PROVIDER_REQUIRED: #{capability} is unavailable in pinned/degraded operations"
    end

    def verify_provider!(metadata, snapshot)
      Provider.new(
        host: metadata.dig("provider", "host"),
        target: target,
        snapshot: snapshot
      ).verify!(expected_revision: metadata.fetch("revision"))
    rescue ProviderError => e
      raise RunnerError, "provider moved after operation begin: #{e.message}"
    end

    def capability_digest(runtime, installation_trust, bundle)
      return legacy_runtime_digest(runtime, bundle) if installation_trust.empty?

      digest = Digest::SHA256.new
      { "runtime" => runtime, "installation_trust" => installation_trust }.each do |kind, records|
        digest << [kind.bytesize].pack("N") << kind
        records.sort.each do |role, recorded|
          bytes = File.binread(File.join(bundle, recorded.fetch("path")))
          digest << [role.bytesize].pack("N") << role
          digest << [bytes.bytesize].pack("Q>") << bytes
        end
      end
      digest.hexdigest
    end

    def legacy_runtime_digest(runtime, bundle)
      digest = Digest::SHA256.new
      runtime.sort.each do |role, recorded|
        bytes = File.binread(File.join(bundle, recorded.fetch("path")))
        digest << [role.bytesize].pack("N") << role
        digest << [bytes.bytesize].pack("Q>") << bytes
      end
      digest.hexdigest
    end

    def verify_external_executable!(recorded, label)
      path = recorded.fetch("path")
      stat = File.stat(path)
      unless stat.file? && (stat.uid == Process.uid || stat.uid.zero?) && (stat.mode & 0o022).zero? &&
             (stat.mode & 0o111).positive?
        raise RunnerError, "#{label} is no longer a trusted executable"
      end

      identity = [stat.dev, stat.ino, stat.size, Digest::SHA256.file(path).hexdigest]
      expected = [recorded["device"], recorded["inode"], recorded["size"], recorded["sha256"]]
      raise RunnerError, "#{label} inode or hash changed after operation begin" unless identity == expected

      path
    rescue SystemCallError, KeyError => e
      raise RunnerError, "#{label} is unavailable: #{e.message}"
    end

    def verify_bound_interpreter!(operation_root, metadata)
      recorded = metadata.fetch("interpreter")
      if metadata.fetch("schema_version") == 1
        return verify_external_executable!(recorded, "bound Ruby interpreter")
      end

      path = File.join(operation_root, "interpreter")
      unless recorded.fetch("path") == path
        raise RunnerError, "bound Ruby interpreter path differs from the operation snapshot"
      end

      verify_executable_identity!(path, recorded, "bound Ruby interpreter")
      path
    rescue KeyError => e
      raise RunnerError, "bound Ruby interpreter is unavailable: #{e.message}"
    end

    def validated_operation!(handle, capability)
      operation_root, metadata = state.load_operation!(handle)
      revision = metadata["revision"]
      snapshot = store.open!(revision)
      registry = Registry.load!(snapshot)
      registry.capability!(capability)
      unless metadata.dig("provider", "target") == target
        raise RunnerError, "operation provider target does not match this installed runner"
      end

      [operation_root, metadata, snapshot, registry]
    rescue StoreError => e
      raise RunnerError, "operation is not bound to a valid canonical content store: #{e.message}"
    end

    def verify_executable_identity!(path, recorded, label)
      stat = SecurePaths.verify_private_file!(path, mode: 0o500)
      unless stat.dev == recorded["device"] && stat.ino == recorded["inode"] &&
             stat.size == recorded["size"]
        raise RunnerError, "#{label} does not match the published operation inode"
      end

      digest = Digest::SHA256.file(path).hexdigest
      raise RunnerError, "#{label} does not match the published operation hash" unless digest == recorded["sha256"]
    rescue PathError => e
      raise RunnerError, "#{label} is unsafe: #{e.message}"
    end

    def verify_runtime!(operation_root, metadata, snapshot)
      runtime = metadata.fetch("runtime")
      raise RunnerError, "operation runtime binding must be a nonempty object" unless runtime.is_a?(Hash) && !runtime.empty?

      runtime.each do |name, recorded|
        unless name.match?(/\A[a-z_]+\.rb\z/) && recorded.is_a?(Hash)
          raise RunnerError, "operation runtime binding is malformed"
        end

        path = File.join(operation_root, "runtime", name)
        verify_file_identity!(path, recorded, "operation runtime #{name}")
        Tree.verify_path_against_git!(
          git: store.git,
          repository: snapshot.repository,
          revision: snapshot.revision,
          path: path,
          source_relative: recorded.fetch("source"),
          private_home: File.join(snapshot.root, "home")
        )
      end
    rescue KeyError, StoreError => e
      raise RunnerError, "operation runtime does not match canonical content: #{e.message}"
    end

    def verify_file_identity!(path, recorded, label)
      stat = SecurePaths.verify_private_file!(path, mode: 0o400)
      unless stat.dev == recorded["device"] && stat.ino == recorded["inode"] &&
             stat.size == recorded["size"]
        raise RunnerError, "#{label} does not match the published operation inode"
      end

      digest = Digest::SHA256.file(path).hexdigest
      raise RunnerError, "#{label} does not match the published operation hash" unless digest == recorded["sha256"]
    rescue PathError => e
      raise RunnerError, "#{label} is unsafe: #{e.message}"
    end
  end
end
