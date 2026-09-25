require "permittable/json_schema/ecma_pattern"

module Permittable
  # Converts frozen contract data — the rule and field hashes built by
  # ContractBuilder — into JSON Schema (draft 2020-12, the dialect OpenAPI 3.1
  # request bodies use). This is the third reader of the contract registry,
  # after the request validator and the column guard: because a contract is
  # data, a schema exported from it cannot drift from what the server
  # actually enforces.
  #
  # The exported schema describes the DECLARED INPUT SHAPE in its canonical
  # JSON encoding. Three deliberate consequences:
  #   * Coercion additionally accepts string-encoded scalars ("42", "true")
  #     for form/query payloads; the schema documents the JSON types only.
  #   * Coercion reads an explicit `null` as ABSENCE, so `{"age": null}` means
  #     the same as `{}`. JSON Schema cannot say that — `type: integer` reads
  #     null as a present value of the wrong type — so the schema rejects a
  #     null the server would accept and ignore.
  #   * `validate:`/`transform:`/`finalize` are opaque callables — they never
  #     change what a client may SEND, so fields carrying them are flagged
  #     with `x-permittable-*` extensions rather than mistranslated.
  #
  # All three leave the schema STRICTER than the server, never looser: a
  # client that validates against the published document is conservative,
  # never surprised by a 422. spec/schema_conformance_spec.rb holds that line,
  # asserting the direction of every divergence it permits.
  #
  # Where a rule has no JSON Schema keyword, the schema is LOOSER instead,
  # and a client following it can still earn a 422. Each such rule stays
  # visible on its own field, and the conformance spec labels each one
  # rather than letting it pass as agreement:
  #   * a `:json` field's `max_depth:` — `x-permittable-max-depth`;
  #   * a Range of non-numbers (`in: "a".."m"`) — `x-permittable-range`;
  #   * a `validate:` proc — `x-permittable-custom-validation`;
  #   * a `normalize:` step, which the server runs BEFORE it checks, so
  #     "   " passes a minLength of 3 and is then absent —
  #     `x-permittable-normalize`;
  #   * the string encoding of :decimal, :date and :datetime, whose validity
  #     rests on `format`, an annotation in draft 2020-12 — so "abc", "NaN"
  #     and "2026-02-30" pass the schema and fail the cast;
  #   * the string encoding of a BOUNDED :decimal, which minimum/maximum
  #     (number-only keywords) never see — the numeric bound is published
  #     for a client that parses first.
  # (A `normalize:` step also runs the safe way: "  abcdefghij  " is too
  # long for a maxLength of 10 and fine once squished.)
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
               when :json then opaque_schema(field)
               when :nested then object(field[:fields], unknown: unknown)
               when :array then array_schema(field, unknown: unknown)
               end
      nullify!(schema, field)
      annotate(schema, field)
    end

    # `nullable: true` means an explicitly-sent empty value yields null, so
    # the type gains "null". Assigning over the existing key keeps its
    # position, preserving deterministic emission. `enum` is the one keyword
    # that constrains the instance rather than one type (minLength, pattern,
    # minimum and friends only apply to instances of their own type), so a
    # nullable enum has to list null itself or it would reject the very null
    # the type now permits.
    def nullify!(schema, field)
      return schema unless field[:nullable]

      schema["type"] = Array(schema["type"]) + ["null"] if schema["type"]
      schema["enum"] += [nil] if schema.key?("enum")
      schema
    end

    def scalar_schema(field)
      schema = SCALAR_SCHEMAS.fetch(field[:type]).dup
      apply_format_name!(schema, field)
      apply_in!(schema, field)
      apply_string_bounds!(schema, field)
      apply_pattern!(schema, field[:format])
      schema
    end

    # A `:json` field's shape is deliberately undeclared, so the schema says
    # "an object" and carries only the bounds the field does declare. JSON
    # Schema has no nesting-depth keyword, so `max_depth:` stays visible as an
    # extension rather than being dropped or mistranslated.
    def opaque_schema(field)
      schema = { "type" => "object" }
      min, max = length_bounds(field[:length])
      schema["minProperties"] = min if min
      schema["maxProperties"] = max if max
      schema["x-permittable-max-depth"] = field[:max_depth] if field[:max_depth]
      schema
    end

    # A `format:` preset also names the JSON Schema `format` keyword the
    # ecosystem understands, which a hand-written Regexp cannot. `pattern` is
    # still emitted next to it: in draft 2020-12 `format` is an annotation
    # unless a validator opts into asserting it, so the pattern is what
    # actually enforces.
    def apply_format_name!(schema, field)
      json = FORMATS.dig(field[:format_name], :json)
      schema["format"] = json if json
    end

    def array_schema(field, unknown:)
      schema = { "type" => "array" }
      min, max = length_bounds(field[:length])
      schema["minItems"] = min if min
      schema["maxItems"] = max if max
      schema["items"] = field[:fields] ? object(field[:fields], unknown: unknown) : SCALAR_SCHEMAS.fetch(field[:of]).dup
      schema
    end

    # A list is stored cast by the field's type, so its enum is what the
    # runtime compares against; `in_published` overrides the members an
    # exact re-encoding would get wrong (see Coercion.published_in_member).
    # An object that only answers include? says nothing a schema can list —
    # annotate flags it as custom validation instead.
    def apply_in!(schema, field)
      allowed = field[:in]
      return unless allowed
      return if opaque_in?(allowed)

      unless allowed.is_a?(Range)
        # The same numeric-vs-string rule default:/example: use (decimal_json)
        # applies here too — a :decimal in: member is otherwise always
        # exported as a string, so a numerically-exported default: is no
        # longer a member of its own enum's exported list. in_published (a
        # :date/:datetime member kept in its authored String form, see
        # Coercion.published_in_member) takes precedence over the cast
        # members when both apply.
        schema["enum"] = (field[:in_published] || allowed).map { |v| json_value(v, decimal: :number) }
        return
      end
      # Runtime bounds-checks Ranges with cover?; numeric endpoints map onto
      # minimum/maximum, anything else (a Range of strings) has no JSON
      # Schema equivalent and is carried as an extension.
      unless allowed.begin.is_a?(Numeric) || allowed.end.is_a?(Numeric)
        schema["x-permittable-range"] = allowed.inspect
        return
      end
      type = field[:type]
      min = json_bound(allowed, "minimum", type) if allowed.begin
      schema["minimum"] = min if min
      keyword = allowed.exclude_end? ? "exclusiveMaximum" : "maximum"
      max = json_bound(allowed, keyword, type) if allowed.end
      schema[keyword] = max if max
    end

    # The types whose cast turns a JSON number into the value `in:` compares,
    # so a published bound can be checked against the server's own verdict.
    NUMERIC_TYPES = %i[integer float decimal].freeze

    # minimum/maximum must be JSON numbers — the metaschema says so — so a
    # bound is NOT an authored value for json_value, which renders a
    # BigDecimal as its precision-safe string and made `in:
    # BigDecimal("0.01")..BigDecimal("999.99")` publish an invalid document.
    # Integer and Float pass through; any other Numeric (BigDecimal,
    # Rational) becomes an Integer when it is one, else a Float.
    #
    # An infinite endpoint (Float::INFINITY, BigDecimal("Infinity")) means
    # "no bound", and neither it nor NaN — which compares to nothing — is a
    # JSON number, so both are omitted: nil. (to_i on either raises, which
    # used to take the whole export down with it.)
    #
    # A Float cannot hold every decimal. to_f rounds to the NEAREST double,
    # which can land on the wrong side of the bound: 0.1000000000000000001
    # becomes 0.1, and a client sending 0.1 passes `minimum: 0.1` and is then
    # refused. How far is "wrong" depends on the field's TYPE, not on the
    # bound: a :decimal reads the number back as BigDecimal("0.1") and
    # compares exactly, while a :float compares the Float through
    # BigDecimal#<=>, which reads it at limited precision and so needs a few
    # doubles more. Rather than model either, the bound asks the server:
    # while the most extreme value the published keyword admits would be
    # refused by the field's own cast and comparison, the bound moves one
    # double INWARD. The published range can then only be narrower than the
    # enforced one — the safe direction — and stops at the first double the
    # server accepts. (It never moves outward: where a lossy comparison
    # would also accept a few doubles beyond the nearest one, those stay
    # unpublished.) A decimal of up to 15 significant digits — every price —
    # round-trips through a double, so it is emitted as written.
    #
    # An INTEGRAL bound past Float::MAX (`10**400`) needs none of this: a
    # JSON number literal has no size limit, so it is exact as published,
    # with no Float rounding to guard against in the first place. Asking the
    # server would instead break it — the field's own cast runs the bound
    # through `to_f`, which overflows a value this large to Infinity — so
    # the loop below walked the bound to Infinity and dropped it, though
    # master published it as `minimum: 10**400` outright. It is returned
    # here before the loop runs. A FRACTIONAL bound past Float::MAX has no
    # such escape (there is no arbitrary-precision JSON number this exporter
    # emits without going through Float) and stays omitted, same as a
    # genuinely infinite bound — see CHANGELOG.
    def json_bound(range, keyword, type)
      value = keyword == "minimum" ? range.begin : range.end
      return nil unless value.finite?

      bound = value.is_a?(Float) || value != value.to_i ? value.to_f : value.to_i
      return bound if bound.is_a?(Integer) && !bound.to_f.finite?

      step = keyword == "minimum" ? :next_float : :prev_float
      # A fractional bound past Float::MAX converts to Infinity, which no
      # step moves; it is then as unrepresentable as an infinite one.
      bound = bound.to_f.public_send(step) until !bound.finite? || honoured?(range, keyword, type, bound)
      bound if bound.finite?
    end

    # Would the server accept the most extreme value `keyword: bound`
    # admits? Only the one side is asked — a range narrower than a double
    # can span admits no double at all, and checking both ends would never
    # settle. A non-numeric field type has no cast to ask, so its bound is
    # published as converted.
    def honoured?(range, keyword, type, bound)
      return true unless NUMERIC_TYPES.include?(type)

      side = keyword == "minimum" ? (range.begin..) : Range.new(nil, range.end, range.exclude_end?)
      status, value = Coercion.cast(type, admitted_extreme(keyword, type, bound))
      status == :ok && side.cover?(value)
    end

    # The value nearest the bound that the published keyword still lets
    # through: the bound itself for minimum/maximum, the double (or, on an
    # :integer field, the integer) just below it for exclusiveMaximum.
    def admitted_extreme(keyword, type, bound)
      if type == :integer
        return bound.ceil if keyword == "minimum"
        return bound.floor if keyword == "maximum"

        return bound.ceil - 1
      end
      keyword == "exclusiveMaximum" ? bound.to_f.prev_float : bound
    end

    # A host's own include?-answering object, kept by the contract as given —
    # the same predicate the contract used to decide it was not a list.
    def opaque_in?(allowed)
      !allowed.nil? && !allowed.is_a?(Range) && Coercion.in_list(allowed).nil?
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

    # Ruby → ECMA-262 translation, conservative by construction — see
    # EcmaPattern. Flagged regexps bail entirely (JSON Schema's `pattern` has
    # no flag slot, and /x//m/i all change semantics).
    #
    # A `format:` preset goes through the same translation as an app's own
    # regexp and needs no exemption: the tokenizer reads a class as a unit,
    # so the `*+` inside :email's class is two literals rather than a
    # possessive quantifier, and :email's `\#` is written as the bare `#`
    # Unicode mode requires.
    def ecma_pattern(regexp)
      return nil unless regexp.options.zero?

      EcmaPattern.translate(regexp.source)
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
    # are stored as the contract casts them (Date, Time, BigDecimal), so they
    # are re-encoded as JSON scalars.
    #
    # The :decimal numeric-export rule (decimal_json) is scoped to a
    # :decimal field's OWN value and never recurses into a :json field's
    # contents: those are opaque and pass through uncast, so a BigDecimal
    # found inside one is documented the same way it always was — a string,
    # via BigDecimal#to_s("F") — rather than reinterpreted as a JSON number
    # (silently changing a value outside any :decimal schema's justification)
    # or coerced through Float, where a non-finite BigDecimal (Infinity, NaN)
    # would crash JSON.generate.
    def annotate(schema, field)
      decimal_mode = field[:kind] == JSON_TYPE ? :string : :number
      schema["default"] = json_value(field[:default], decimal: decimal_mode) if field.key?(:default)
      schema["examples"] = [json_value(field[:example], decimal: decimal_mode)] if field.key?(:example)
      schema["description"] = field[:desc] if field[:desc]
      if field[:sensitive]
        schema["writeOnly"] = true
        schema["x-permittable-sensitive"] = true
      end
      schema["x-permittable-custom-validation"] = true if field[:validate] || opaque_in?(field[:in])
      schema["x-permittable-transformed"] = true if field[:transform]
      apply_normalize!(schema, field)
      schema
    end

    # The server checks the NORMALIZED string, so minLength/maxLength/pattern
    # describe a value the client never sends: under `normalize: :squish`,
    # "   " satisfies a minLength of 3 and then squishes to "" (absent), and
    # " a  " satisfies it and squishes to "a". JSON Schema has no keyword for
    # "transform, then check", so the step is flagged rather than dropped —
    # by the preset's name, which a client can apply itself, or `true` for a
    # host proc, which is as opaque as `transform:`. The preset is recovered
    # by identity from the resolved callable, because the contract stores the
    # lambda it runs rather than the name it was declared by.
    def apply_normalize!(schema, field)
      normalizer = field[:normalize]
      return unless normalizer

      preset = NORMALIZERS.key(normalizer)
      schema["x-permittable-normalize"] = preset ? preset.to_s : true
    end

    def json_value(value, decimal: :string)
      case value
      when Array then value.map { |v| json_value(v, decimal: decimal) }
      # An authored `:json` default/example is a whole hash; its values get
      # the same re-encoding as any other authored scalar.
      when Hash then value.to_h { |k, v| [k.to_s, json_value(v, decimal: decimal)] }
      when BigDecimal then decimal == :number ? decimal_json(value) : value.to_s("F")
      when Time then exact_iso8601(value.getutc)
      # DateTime subclasses Date, so it must match first.
      when DateTime then exact_iso8601(value.to_time.getutc)
      when Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end

    # A :decimal default/example is stored cast — a BigDecimal, even when it
    # was authored as `1.5` — and exporting every BigDecimal as a string
    # turned the number such a default had always been published as into
    # "1.5". So it is a JSON number whenever a Float carries it exactly (the
    # Float's shortest text reads back as the same BigDecimal), which is what
    # a JSON number is to most consumers anyway, and a string only when the
    # precision would otherwise be lost. Both spellings are within the
    # :decimal schema's own `["string", "number"]`.
    def decimal_json(value)
      float = value.to_f
      BigDecimal(float.to_s) == value ? float : value.to_s("F")
    end

    # iso8601 prints whole seconds unless told otherwise, and a sub-second
    # instant re-encoded that way names a DIFFERENT instant — one an `in:`
    # listing the original refuses. So as many fractional digits as the
    # value has, up to the nanoseconds Time#nsec can report.
    def exact_iso8601(time)
      nsec = time.nsec
      digits = nsec.zero? ? 0 : 9 - nsec.to_s.rjust(9, "0")[/0*\z/].length
      time.iso8601(digits)
    end
  end
end
