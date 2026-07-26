# frozen_string_literal: true

module AutonomousMergePolicy
  module_function

  def duplicate_key_errors(yaml)
    stream = Psych.parse_stream(yaml)
    errors = []
    walk_for_duplicate_keys(stream, "$", errors)
    errors
  rescue Psych::Exception => e
    ["malformed trusted-base YAML: #{e.message.lines.first.to_s.strip}"]
  end

  def walk_for_duplicate_keys(node, path, errors)
    return unless node.respond_to?(:children) && node.children.is_a?(Array)

    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key_node, value_node|
        key = key_node.respond_to?(:value) ? key_node.value : nil
        if key.nil?
          errors << "#{path} contains a non-scalar mapping key"
        elsif seen.key?(key)
          errors << "#{path} contains duplicate key #{key.inspect}"
        else
          seen[key] = true
        end
        walk_for_duplicate_keys(value_node, "#{path}.#{key}", errors)
      end
    else
      node.children.each { |child| walk_for_duplicate_keys(child, path, errors) }
    end
  end
end
