# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "secure_paths"

module AgentWorkflowsOperation
  Capability = Data.define(
    :name,
    :executable,
    :runtime,
    :installation_trust,
    :instruction_dependencies,
    :mutation,
    :requires_current_provider
  )

  class Registry
    REGISTRY_PATH = "operation-capabilities.json"

    attr_reader :assets, :capabilities

    def self.load!(snapshot)
      path = File.join(snapshot.tree, REGISTRY_PATH)
      payload = JSON.parse(File.binread(path))
      new(payload, snapshot.tree)
    rescue Errno::ENOENT
      raise RegistryError, "canonical snapshot is missing #{REGISTRY_PATH}"
    rescue JSON::ParserError => e
      raise RegistryError, "capability registry is invalid JSON: #{e.message}"
    end

    def initialize(payload, tree)
      raise RegistryError, "capability registry root must be an object" unless payload.is_a?(Hash)
      raise RegistryError, "unsupported capability registry schema" unless payload["schema_version"] == 1

      @tree = tree
      @assets = validate_assets!(payload["assets"])
      @capabilities = validate_capabilities!(payload["capabilities"])
      raise RegistryError, "capability registry must declare pr-merge-submit" unless @capabilities.key?("pr-merge-submit")
    end

    def capability!(name)
      capabilities.fetch(name) { raise RegistryError, "unknown operation capability: #{name}" }
    end

    private

    def validate_assets!(value)
      raise RegistryError, "registry assets must be an object" unless value.is_a?(Hash)

      skill = validate_instruction_file!(value["skill"], "assets.skill")
      workflow = validate_instruction_file!(value["workflow"], "assets.workflow")
      skills = validate_named_skill_files!(value["skills"], "assets.skills")
      related_workflows = validate_named_instruction_files!(
        value["related_workflows"],
        "assets.related_workflows"
      )
      docs = value["docs"]
      validated_docs = validate_named_instruction_files!(docs, "assets.docs")
      {
        "skill" => skill,
        "workflow" => workflow,
        "skills" => skills,
        "related_workflows" => related_workflows,
        "docs" => validated_docs
      }
    end

    def validate_capabilities!(value)
      unless value.is_a?(Hash) && !value.empty?
        raise RegistryError, "registry capabilities must be a nonempty object"
      end

      value.to_h do |name, definition|
        unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9-]*\z/)
          raise RegistryError, "capability names must be lowercase identifiers"
        end
        raise RegistryError, "capability #{name} must be an object" unless definition.is_a?(Hash)

        executable = validate_executable!(definition["executable"], "capabilities.#{name}.executable")
        runtime = validate_runtime!(definition["runtime"], "capabilities.#{name}.runtime")
        unless runtime.value?(executable)
          raise RegistryError, "capability #{name} runtime must include its executable"
        end

        dependencies = definition["instruction_dependencies"]
        unless dependencies.is_a?(Array) && !dependencies.empty?
          raise RegistryError, "capability #{name} must declare instruction dependencies"
        end

        dependencies = dependencies.map.with_index do |path, index|
          validate_instruction_file!(path, "capabilities.#{name}.instruction_dependencies[#{index}]")
        end
        mutation = definition["mutation"]
        current = definition["requires_current_provider"]
        unless [true, false].include?(mutation) && [true, false].include?(current)
          raise RegistryError, "capability #{name} mutation/current flags must be booleans"
        end
        if mutation && !current
          raise RegistryError, "mutating capability #{name} must require a current provider"
        end

        installation_trust = validate_installation_trust!(
          definition.fetch("installation_trust", []),
          "capabilities.#{name}.installation_trust"
        )

        [name, Capability.new(
          name: name,
          executable: executable,
          runtime: runtime,
          installation_trust: installation_trust,
          instruction_dependencies: dependencies,
          mutation: mutation,
          requires_current_provider: current
        )]
      end
    end

    def validate_installation_trust!(value, label)
      raise RegistryError, "#{label} must be an array" unless value.is_a?(Array)

      paths = value.map.with_index do |path, index|
        unless path.is_a?(String) && path.match?(%r{\A\.agents/[a-z][a-z0-9-]*\.json\z})
          raise RegistryError, "#{label}[#{index}] must name a fixed .agents JSON trust anchor"
        end

        path
      end
      raise RegistryError, "#{label} must not contain duplicates" unless paths.uniq.length == paths.length

      paths
    end

    def validate_runtime!(value, label)
      raise RegistryError, "#{label} must be a nonempty object" unless value.is_a?(Hash) && !value.empty?

      runtime = value.to_h do |role, path|
        unless role.is_a?(String) && role.match?(/\A[a-z][a-z0-9-]*\z/)
          raise RegistryError, "#{label} roles must be lowercase identifiers"
        end

        validate_regular_file!(path, "#{label}.#{role}")
        [role, path]
      end
      if runtime.values.uniq.length != runtime.length
        raise RegistryError, "#{label} must not assign one source path to multiple roles"
      end

      runtime
    end

    def validate_instruction_file!(relative, label)
      validate_regular_file!(relative, label)
      relative
    end

    def validate_named_instruction_files!(value, label)
      raise RegistryError, "registry #{label} must be a nonempty object" unless value.is_a?(Hash) && !value.empty?

      value.to_h do |name, path|
        unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]*\z/)
          raise RegistryError, "registry #{label} keys must be snake_case identifiers"
        end

        [name, validate_instruction_file!(path, "#{label}.#{name}")]
      end
    end

    def validate_named_skill_files!(value, label)
      validated = validate_named_instruction_files!(value, label)
      validated.each do |name, path|
        expected = "skills/#{name.tr('_', '-')}/SKILL.md"
        next if path == expected

        raise RegistryError, "registry #{label}.#{name} must name #{expected}"
      end
      validated
    end

    def validate_executable!(relative, label)
      path = validate_regular_file!(relative, label)
      raise RegistryError, "#{label} is not executable: #{relative}" unless (File.stat(path).mode & 0o111).positive?

      relative
    end

    def validate_regular_file!(relative, label)
      SecurePaths.safe_relative_path!(relative, label: label)
      path = File.join(@tree, relative)
      current = @tree
      relative.split("/")[0...-1].each do |component|
        current = File.join(current, component)
        stat = File.lstat(current)
        raise RegistryError, "#{label} has a symlink ancestor: #{current}" if stat.symlink?
        raise RegistryError, "#{label} ancestor is not a directory: #{current}" unless stat.directory?
      end
      stat = File.lstat(path)
      raise RegistryError, "#{label} must resolve to a regular non-symlink file" unless stat.file? && !stat.symlink?

      path
    rescue Errno::ENOENT
      raise RegistryError, "#{label} is missing from the canonical snapshot: #{relative}"
    end
  end
end
