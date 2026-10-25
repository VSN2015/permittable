module Permittable
  # The request walker, pointed at an authored array or `:json`
  # `default:`/`example:` at class load — the same permittable_check_array
  # and permittable_check_json a request goes through, so the two cannot
  # drift apart. Two seams are overridden:
  #
  #   * the field WHOSE default:/example: is being validated does not run
  #     its own `transform:` — see permittable_transform below for exactly
  #     which field that is and why. A SUB-FIELD's own transform: still
  #     runs, so what gets stored is what an equivalent request would
  #     produce — for a default:, and, under a transforming array, only
  #     where an array-level validate: reads its output. An example: is
  #     read `as_sent`, which is what gets stored: no transform at any
  #     depth, no sub-field default filled in and no array-level validate:.
  #     When an array-level validate: exists somewhere in it, it is read
  #     once more first, like a default, to VALIDATE it as a request would
  #     be (see ContractBuilder, which decides). An example documents what a
  #     client SENDS, so it must not be read through app code that reshapes
  #     the value into what the action receives.
  #   * violations carry no `message:` — they become an ArgumentError for
  #     the contract's author, not a response for a client, and I18n may not
  #     be loaded yet.
  class AuthoredValues
    include Permittable

    def self.read_array(field, value, as_sent: false)
      new.read_array(field, value, as_sent: as_sent)
    end

    def self.read_json(field, value)
      new.read_json(field, value)
    end

    def self.summary(violations)
      new.summary(violations)
    end

    # [value as a request would get it, violations]
    def read_array(field, value, as_sent: false)
      violations = []
      @field = field
      @as_sent = as_sent
      @read_by_validate = fields_under_validate(field) if field[:transform]
      read = permittable_check_array(field, value, path: field[:name].to_s, unknown: :ignore, violations: violations)
      [read, violations]
    end

    # [:ok, value as a request would get it] or [:error, code]. A request's
    # hash reaches permittable_check_json indifferent, as every Hash inside
    # the walker's params is, so the authored one is made so first, the way
    # the walker reads a nested hash. permittable_check_json then hands
    # `validate:` a deep copy, as it does a request's, and returns that copy.
    def read_json(field, value)
      permittable_check_json(field, ActiveSupport::HashWithIndifferentAccess.new(value))
    end

    def summary(violations)
      permittable_violation_summary(violations)
    end

    private

    # Suppresses transform: for the field WHOSE default/example is being
    # authored-validated (@field, compared by identity) — never for a
    # sub-field nested inside it. A sub-field's own transform: is app code
    # too, but it belongs to a DIFFERENT field's contract: an equivalent
    # request sending that sub-field's value would run it, so the stored
    # default has to match, or an omitted field and an explicitly-sent
    # identical value silently diverge (and the exported OpenAPI default,
    # which reads this same value, documents one the server never produces).
    #
    # When @field itself has a transform:, it never runs here either way and
    # its result is discarded anyway (validate_array_authored_value! stores
    # the value AS AUTHORED instead — see its comment). A sub-field's
    # transform: output is another matter: a request runs it, then the
    # array-level `validate:` on that result, and only then the array's own
    # transform. So a `validate:` that reads `i[:tags].is_a?(Array)` must be
    # handed the transformed `tags`, or a contract every request satisfies
    # fails at class load. But a transform: is app code (`Account.find`), so
    # under such an array it runs ONLY where its output is consumed: for a
    # field below an array declaring `validate:` (the walked array counts),
    # not merely somewhere in the same subtree, where a `validate:` on a
    # sibling branch reads nothing of it. Without an own transform: of its
    # own, @field's read is what gets stored, so every sub-field's runs.
    #
    # `as_sent` (the stored read of an example:) runs none, at any depth.
    def permittable_transform(field, value)
      return value if @as_sent || field.equal?(@field)
      return value if @field[:transform] && !@read_by_validate.key?(field)

      super
    end

    # The fields below `field` whose output an array's `validate:` sees: all
    # those under an array that declares one, counting `field` itself, by
    # identity (the walker hands the very field hashes it was given).
    def fields_under_validate(field, found = {}.compare_by_identity, under_validate: false)
      under_validate ||= field[:kind] == :array && field[:validate]
      Array(field[:fields]).each do |sub|
        found[sub] = true if under_validate
        fields_under_validate(sub, found, under_validate: under_validate)
      end
      found
    end

    # Nor does it run an array-level validate:, which expects the transformed
    # sub-fields a request hands it. The validating read has already run it
    # on exactly those, so the stored read, which would hand it the
    # untransformed ones, must not (it could raise on a shape it never sees).
    def permittable_array_validator(field)
      super unless @as_sent
    end

    # What a client sends has no defaults filled in: an omitted sub-field
    # stays omitted, at any depth, so the published example does not show a
    # value (`cents: 0`) that no client sends. The walker fills them in; drop
    # exactly what it filled, by the walker's own absence rule.
    def permittable_check_hash(fields, hash, **)
      result = super
      return result unless @as_sent

      fields.each do |field|
        key = field[:name].to_s
        next unless field.key?(:default)
        next unless permittable_absent?(permittable_normalized(field, hash[key]), hash, key)
        next if permittable_explicit_null?(field, hash, key)

        result.delete(key)
      end
      result
    end

    # An authored hash is exported as a schema `default`/`example`, and JSON
    # has no NaN or Infinity: JSON.generate raises on them when the document
    # is written, long after the class loaded. A request cannot carry one
    # (JSON has none; a form sends Strings), so only the authored value is
    # held to it, here, and not permittable_check_json for every request.
    def permittable_check_json(field, value)
      status, read = super
      return [:error, "invalid_type"] if status == :ok && non_finite_inside?(value)

      [status, read]
    end

    def non_finite_inside?(value)
      case value
      when Float then !value.finite?
      when Hash then value.each_value.any? { |v| non_finite_inside?(v) }
      when Array then value.any? { |v| non_finite_inside?(v) }
      else false
      end
    end

    def permittable_violation(_field, param, code)
      { param: param, code: code.to_s }
    end
  end
end
