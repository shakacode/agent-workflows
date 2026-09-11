# frozen_string_literal: true

module TrustConfigShape
  module_function

  def strict_string_list(value, name:)
    case value
    when nil
      []
    when String
      validate_string!(value, name:)
      [value]
    when Array
      value.each { |entry| validate_string!(entry, name:) }
      value
    else
      raise ArgumentError, "#{name} must be a nonempty string or an array of nonempty strings"
    end
  end

  def validate_string!(value, name:)
    return if value.is_a?(String) && !value.empty?

    raise ArgumentError, "#{name} must be a nonempty string or an array of nonempty strings"
  end
end
