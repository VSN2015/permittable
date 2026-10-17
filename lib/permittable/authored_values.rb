module Permittable
  # The request walker, pointed at an authored array `default:`/`example:`
  # at class load — the same permittable_check_array a request goes
  # through, so the two cannot drift apart. Two seams are overridden:
  #
  #   * the field WHOSE default:/example: is being validated does not run
  #     its own `transform:` — see permittable_transform below for exactly
  #     which field that is and why. A SUB-FIELD's own transform: still
  #     runs, so what gets stored is what an equivalent request would
  #     produce — for a default:. An example: is read `as_sent`, which is
  #     what gets stored: no transform at any depth, no sub-field default
  #     filled in and no array-level validate:. When an array-level validate:
  #     exists somewhere in it, it is read once more first, like a default,
  #     to VALIDATE it as a request would be (see ContractBuilder, which
  #     decides). An example documents what a client SENDS, so it must not
  #     be read through app code that reshapes the value into what the
  #     action receives.
  #   * violations carry no `message:` — they become an ArgumentError for
  #     the contract's author, not a response for a client, and I18n may not
  #     be loaded yet.
  class AuthoredValues
    include Permittable

    def self.read_array(field, value, as_sent: false)
      new.read_array(field, value, as_sent: as_sent)
    end

    def self.summary(violations)
      new.summary(violations)
    end

    # [value as a request would get it, violations]
    def read_array(field, value, as_sent: false)
      violations = []
      @field = field
      @as_sent = as_sent
      read = permittable_check_array(field, value, path: field[:name].to_s, unknown: :ignore, violations: violations)
      [read, violations]
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
    # When @field itself has a transform:, its result is discarded anyway
    # (validate_array_authored_value! stores the value AS AUTHORED instead —
    # see its comment), so nothing inside its subtree is worth reading
    # transformed: suppressing every nested call too keeps that walk free of
    # app code, exactly as a scalar default's cast-only check already is.
    #
    # `as_sent` (the stored read of an example:) runs none, at any depth.
    def permittable_transform(field, value)
      return value if @as_sent || @field[:transform] || field.equal?(@field)

      super
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

    def permittable_violation(_field, param, code)
      { param: param, code: code.to_s }
    end
  end
end
