# frozen_string_literal: true

require "json"
require "openssl"

module AgentDoctor
  module SignedLaunchReadiness
    CAPABILITY_FILE = "signed-launch-capability.json"
    DISPATCHER_TRUST_FILE = "dispatcher-launch-trust.json"
    WORKFLOW_TRUST_FILE = "workflow-control-lifecycle-trust.json"

    module_function

    def assess(host:, target:)
      return unknown(host, reason: "target-unavailable") unless target.is_a?(String) && !target.strip.empty?

      root = File.expand_path(target.to_s)
      agents = File.join(root, ".agents")
      paths = {
        capability: File.join(agents, CAPABILITY_FILE),
        dispatcher: File.join(agents, DISPATCHER_TRUST_FILE),
        workflow: File.join(agents, WORKFLOW_TRUST_FILE)
      }
      return unsupported(host) if clean_unsupported_host?(host:, root:, agents:, paths:)

      capability = read_record(paths.fetch(:capability), root:, agents:)
      dispatcher = read_record(paths.fetch(:dispatcher), root:, agents:)
      workflow = read_record(paths.fetch(:workflow), root:, agents:)
      if capability_record?(capability, host:) &&
         dispatcher_anchor?(dispatcher, capability.fetch("dispatcher_launch_key_id")) &&
         workflow_anchor?(workflow, capability.fetch("workflow_control_lifecycle_key_id"))
        return {
          "type" => "agent-workflow-signed-launch-readiness",
          "version" => 1,
          "host" => host,
          "capability" => "supported",
          "ready" => true,
          "reason" => "host-producer-and-trust-anchors-ready",
          "dispatcher_launch" => "supported",
          "workflow_control_lifecycle" => "supported",
          "waiver" => "not-required",
          "producer" => capability.fetch("producer")
        }
      end

      unknown(host)
    rescue SystemCallError, JSON::ParserError, OpenSSL::PKey::PKeyError
      unknown(host)
    end

    def unsupported(host)
      {
        "type" => "agent-workflow-signed-launch-readiness",
        "version" => 1,
        "host" => host,
        "capability" => "unsupported",
        "ready" => false,
        "reason" => "host-producer-unavailable",
        "dispatcher_launch" => "unsupported",
        "workflow_control_lifecycle" => "unsupported",
        "waiver" => "exact-batch-scoped-human-required"
      }
    end

    def unknown(host, reason: "host-capability-unknown")
      {
        "type" => "agent-workflow-signed-launch-readiness",
        "version" => 1,
        "host" => host,
        "capability" => "UNKNOWN",
        "ready" => false,
        "reason" => reason,
        "dispatcher_launch" => "UNKNOWN",
        "workflow_control_lifecycle" => "UNKNOWN",
        "waiver" => "not-permitted-while-capability-unknown"
      }
    end

    def path_present?(path)
      File.exist?(path) || File.symlink?(path)
    end
    private_class_method :path_present?

    def clean_unsupported_host?(host:, root:, agents:, paths:)
      return false unless host == "codex" && paths.values.none? { |path| path_present?(path) }
      return false unless safe_owned_directory?(root)
      return true unless path_present?(agents)

      safe_owned_directory?(agents)
    end
    private_class_method :clean_unsupported_host?

    def safe_owned_directory?(path)
      stat = File.lstat(path)
      stat.directory? && stat.uid == File.stat(__FILE__).uid && (stat.mode & 0o022).zero?
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end
    private_class_method :safe_owned_directory?

    def read_record(path, root:, agents:)
      return unless [root, agents].all? { |directory| safe_owned_directory?(directory) }

      helper_uid = File.stat(__FILE__).uid
      stat = File.lstat(path)
      return unless stat.file? && stat.uid == helper_uid && (stat.mode & 0o022).zero?

      record = JSON.parse(File.read(path, encoding: "UTF-8"))
      record if record.is_a?(Hash)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
    private_class_method :read_record

    def capability_record?(record, host:)
      expected = %w[
        dispatcher_launch_key_id host producer type version workflow_control_lifecycle_key_id
      ]
      record.is_a?(Hash) && record.keys.sort == expected &&
        record["type"] == "agent-workflow-signed-launch-capability" && record["version"] == 1 &&
        record["host"] == host && nonempty?(record["producer"]) &&
        nonempty?(record["dispatcher_launch_key_id"]) &&
        nonempty?(record["workflow_control_lifecycle_key_id"])
    end
    private_class_method :capability_record?

    def dispatcher_anchor?(record, key_id)
      public_anchor?(
        record,
        type: "agent-workflow-dispatcher-trust-anchor",
        key_id_field: "agent_workflow_dispatcher_trusted_key_id",
        public_key_field: "agent_workflow_dispatcher_trusted_public_key_pem",
        key_id:
      )
    end
    private_class_method :dispatcher_anchor?

    def workflow_anchor?(record, key_id)
      public_anchor?(
        record,
        type: "agent-workflow-control-lifecycle-trust-anchor",
        key_id_field: "agent_workflow_control_lifecycle_trusted_key_id",
        public_key_field: "agent_workflow_control_lifecycle_trusted_public_key_pem",
        key_id:
      )
    end
    private_class_method :workflow_anchor?

    def public_anchor?(record, type:, key_id_field:, public_key_field:, key_id:)
      expected = [key_id_field, public_key_field, "type", "version"].sort
      return false unless record.is_a?(Hash) && record.keys.sort == expected &&
                          record["type"] == type && record["version"] == 1 &&
                          record[key_id_field] == key_id && nonempty?(record[public_key_field])

      key = OpenSSL::PKey.read(record.fetch(public_key_field))
      key.is_a?(OpenSSL::PKey::RSA) && !key.private? && key.n.num_bits >= 2048
    rescue OpenSSL::PKey::PKeyError
      false
    end
    private_class_method :public_anchor?

    def nonempty?(value)
      value.is_a?(String) && !value.strip.empty? && !value.strip.casecmp?("UNKNOWN")
    end
    private_class_method :nonempty?
  end
end
