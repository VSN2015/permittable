module Permittable
  # Converts frozen contract data — the rule and field hashes built by
  # ContractBuilder — into JSON Schema (draft 2020-12, the dialect OpenAPI 3.1
  # request bodies use). This is the third reader of the contract registry,
  # after the request validator and the column guard: because a contract is
  # data, a schema exported from it cannot drift from what the server
  # actually enforces.
  #
  # The exported schema describes the DECLARED INPUT SHAPE in its canonical
  # JSON encoding. Two deliberate consequences:
  #   * Coercion additionally accepts string-encoded scalars ("42", "true")
  #     for form/query payloads; the schema documents the JSON types only.
  #   * `validate:`/`transform:`/`finalize` are opaque callables — they never
  #     change what a client may SEND, so fields carrying them are flagged
  #     with `x-permittable-*` extensions rather than mistranslated.
  #
  # Emission is deterministic (fixed key insertion order, declaration-order
  # properties) so generated documents are committable and diff-stable.
  module JsonSchema
    module_function

    SCALAR_SCHEMAS = {
      string: { "type" => "string" },
      integer: { "type" => "integer" },
      float: { "type" => "number" },
      # Coercion accepts Numeric or String for :decimal; string is the
      # precision-safe form, so both encodings are documented.
      decimal: { "type" => %w[string number], "format" => "decimal" },
      boolean: { "type" => "boolean" },
      date: { "type" => "string", "format" => "date" },
      datetime: { "type" => "string", "format" => "date-time" }
    }.freeze

    # Ruby regexp constructs with no ECMA-262 equivalent (\Z, \h, \K, \R, \G,
    # inline flag groups, absence operator, conditionals, POSIX classes,
    # possessive quantifiers). A source matching this is left untranslated —
    # the scan is deliberately over-eager on escaped lookalikes because a
    # wrong pattern in published docs is worse than a missing one.
    UNTRANSLATABLE = /
      \\[ZhHKRG]          |
      \(\?[a-z-]+[:)]     |
      \(\?~               |
      \(\?\(              |
      \[\[:               |
      [*+?]\+
    /x

    # Request-body schema for one rule from `permittable_contracts` /
    # `permit_rule_for`: the object schema of its fields, wrapped in the
    # `root:` envelope when the rule declares one. The wrapper itself stays
    # permissive even under `unknown: :error` — the runtime never inspects
    # sibling keys outside the root.
    def rule(permit_rule)
      schema = object(permit_rule[:fields], unknown: permit_rule[:unknown])
      return schema unless permit_rule[:root]

      root = permit_rule[:root].to_s
      { "type" => "object", "properties" => { root => schema }, "required" => [root] }
    end

    # Object schema for a field list; `unknown:` applies at every nesting
    # level, exactly like the runtime check.
    def object(fields, unknown: :ignore)
      schema = {
        "type" => "object",
        "properties" => fields.to_h { |f| [f[:name].to_s, field(f, unknown: unknown)] }
      }
      required = fields.select { |f| f[:required] }.map { |f| f[:name].to_s }
      schema["required"] = required unless required.empty?
      schema["additionalProperties"] = false if unknown == :error
      schema
    end

    # Schema fragment for one field hash of any kind.
    def field(field, unknown: :ignore)
      schema = case field[:kind]
               when :scalar then scalar_schema(field)
               when :nested then object(field[:fields], unknown: unknown)
               when :array then array_schema(field, unknown: unknown)
               end
      annotate(schema, field)
    end

    def scalar_schema(field)
      schema = SCALAR_SCHEMAS.fetch(field[:type]).dup
      apply_in!(schema, field[:in])
      apply_string_bounds!(schema, field)
      apply_pattern!(schema, field[:format])
      schema
    end

    def array_schema(field, unknown:)
      schema = { "type" => "array" }
      min, max = length_bounds(field[:length])
      schema["minItems"] = min if min
      schema["maxItems"] = max if max
      schema["items"] = field[:fields] ? object(field[:fields], unknown: unknown) : SCALAR_SCHEMAS.fetch(field[:of]).dup
      schema
    end

    def apply_in!(schema, allowed)
      return unless allowed

      unless allowed.is_a?(Range)
        schema["enum"] = allowed.map { |v| json_value(v) }
        return
      end
      # Runtime bounds-checks Ranges with cover?; numeric endpoints map onto
      # minimum/maximum, anything else (a Range of strings) has no JSON
      # Schema equivalent and is carried as an extension.
      unless allowed.begin.is_a?(Numeric) || allowed.end.is_a?(Numeric)
        schema["x-permittable-range"] = allowed.inspect
        return
      end
      schema["minimum"] = json_value(allowed.begin) if allowed.begin
      schema[allowed.exclude_end? ? "exclusiveMaximum" : "maximum"] = json_value(allowed.end) if allowed.end
    end

    def apply_string_bounds!(schema, field)
      return unless field[:type] == :string

      min, max = length_bounds(field[:length])
      # "" is ABSENT and an absent required field violates, so a required
      # string can never validly be empty — the schema says so.
      min = 1 if field[:required] && min.to_i < 1
      schema["minLength"] = min if min
      schema["maxLength"] = max if max
    end

    def apply_pattern!(schema, regexp)
      return unless regexp

      pattern = ecma_pattern(regexp)
      if pattern
        schema["pattern"] = pattern
      else
        schema["x-permittable-pattern"] = regexp.inspect
      end
    end

    # Conservative Ruby → ECMA-262 translation: \A/\z anchors become ^/$.
    # Flagged regexps bail entirely (JSON Schema's `pattern` has no flag
    # slot, and /x//m/i all change semantics), as does any source containing
    # an untranslatable construct.
    def ecma_pattern(regexp)
      return nil unless regexp.options.zero?

      source = regexp.source
      return nil if source.match?(UNTRANSLATABLE)

      source.gsub('\A', "^").gsub('\z', "$")
    end

    # length: reasons about characters on strings and element count on
    # arrays; either way it is an exact Integer or a Range (possibly endless
    # / beginless, possibly exclusive).
    def length_bounds(spec)
      case spec
      when Integer then [spec, spec]
      when Range
        max = spec.end && spec.exclude_end? ? spec.end - 1 : spec.end
        [spec.begin, max]
      else [nil, nil]
      end
    end

    # Documentation keys shared by every field kind. `default:`/`example:`
    # are authored values (possibly Date/Time/BigDecimal literals), so they
    # are re-encoded as JSON scalars.
    def annotate(schema, field)
      schema["default"] = json_value(field[:default]) if field.key?(:default)
      schema["examples"] = [json_value(field[:example])] if field.key?(:example)
      schema["description"] = field[:desc] if field[:desc]
      if field[:sensitive]
        schema["writeOnly"] = true
        schema["x-permittable-sensitive"] = true
      end
      schema["x-permittable-custom-validation"] = true if field[:validate]
      schema["x-permittable-transformed"] = true if field[:transform]
      schema
    end

    def json_value(value)
      case value
      when Array then value.map { |v| json_value(v) }
      when BigDecimal then value.to_s("F")
      when Time then value.utc.iso8601
      # DateTime subclasses Date, so it must match first.
      when DateTime then value.to_time.utc.iso8601
      when Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end
  end
end
