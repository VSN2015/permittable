# A deliberately small JSON Schema validator, covering exactly the keywords
# Permittable::JsonSchema emits and nothing else. It exists so the suite can
# check the gem's headline claim — that an exported schema cannot drift from
# what the server enforces — without taking on a validator dependency for one
# spec file.
#
# Anything the exporter does not emit is out of scope on purpose: this is a
# measuring instrument, not a general validator.
module TinyJsonSchema
  module_function

  def valid?(schema, value)
    errors(schema, value).empty?
  end

  # [] when `value` satisfies `schema`, otherwise one entry per failure as
  # "<path>: <keyword>", so a spec failure names the offending keyword.
  def errors(schema, value, path = "")
    types = Array(schema["type"])
    return ["#{path}: type"] unless types.empty? || types.any? { |type| type_ok?(type, value) }

    out = []
    out << "#{path}: enum" if schema.key?("enum") && !schema["enum"].include?(value)
    out.concat(string_errors(schema, value, path)) if value.is_a?(String)
    out.concat(number_errors(schema, value, path)) if number?(value)
    out.concat(object_errors(schema, value, path)) if value.is_a?(Hash)
    out.concat(array_errors(schema, value, path)) if value.is_a?(Array)
    out
  end

  # JSON has no true/false-as-number, and Ruby's true is not Numeric anyway.
  def number?(value)
    value.is_a?(Numeric)
  end

  def type_ok?(type, value)
    case type
    when "string" then value.is_a?(String)
    when "integer" then value.is_a?(Integer)
    when "number" then number?(value)
    when "boolean" then [true, false].include?(value)
    when "object" then value.is_a?(Hash)
    when "array" then value.is_a?(Array)
    when "null" then value.nil?
    else raise ArgumentError, "TinyJsonSchema does not know the type #{type.inspect}"
    end
  end

  def string_errors(schema, value, path)
    out = []
    out << "#{path}: minLength" if schema["minLength"] && value.length < schema["minLength"]
    out << "#{path}: maxLength" if schema["maxLength"] && value.length > schema["maxLength"]
    out << "#{path}: pattern" if schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
    out
  end

  def number_errors(schema, value, path)
    out = []
    out << "#{path}: minimum" if schema["minimum"] && value < schema["minimum"]
    out << "#{path}: maximum" if schema["maximum"] && value > schema["maximum"]
    out << "#{path}: exclusiveMaximum" if schema["exclusiveMaximum"] && value >= schema["exclusiveMaximum"]
    out
  end

  def object_errors(schema, value, path)
    out = Array(schema["required"]).filter_map { |key| "#{path}/#{key}: required" unless value.key?(key) }
    (schema["properties"] || {}).each do |key, sub|
      out.concat(errors(sub, value[key], "#{path}/#{key}")) if value.key?(key)
    end
    if schema["additionalProperties"] == false
      out.concat((value.keys - (schema["properties"] || {}).keys).map { |key| "#{path}/#{key}: additionalProperties" })
    end
    out << "#{path}: minProperties" if schema["minProperties"] && value.length < schema["minProperties"]
    out << "#{path}: maxProperties" if schema["maxProperties"] && value.length > schema["maxProperties"]
    out
  end

  def array_errors(schema, value, path)
    out = []
    out << "#{path}: minItems" if schema["minItems"] && value.length < schema["minItems"]
    out << "#{path}: maxItems" if schema["maxItems"] && value.length > schema["maxItems"]
    value.each_with_index { |el, i| out.concat(errors(schema["items"], el, "#{path}[#{i}]")) } if schema["items"]
    out
  end
end
