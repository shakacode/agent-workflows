# frozen_string_literal: true

module GitHubJsonStringValidation
  module_function

  def decoded_json_strings_valid?(value)
    case value
    when String
      value.valid_encoding?
    when Array
      value.all? { |item| decoded_json_strings_valid?(item) }
    when Hash
      value.all? do |key, item|
        decoded_json_strings_valid?(key) && decoded_json_strings_valid?(item)
      end
    else
      true
    end
  end
end
