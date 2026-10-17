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
  #     produce.
  #   * violations carry no `message:` — they become an ArgumentError for
  #     the contract's author, not a response for a client, and I18n may not
  #     be loaded yet.
  class AuthoredValues
    include Permittable

    def self.read_array(field, value)
      new.read_array(field, value)
    end

    def self.read_json(field, value)
      new.read_json(field, value)
    end

    def self.summary(violations)
      new.summary(violations)
    end

    # [value as a request would get it, violations]
    def read_array(field, value)
      violations = []
      @field = field
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
    # When @field itself has a transform:, its result is discarded anyway
    # (validate_array_authored_value! stores the value AS AUTHORED instead —
    # see its comment), so nothing inside its subtree is worth reading
    # transformed: suppressing every nested call too keeps that walk free of
    # app code, exactly as a scalar default's cast-only check already is.
    def permittable_transform(field, value)
      return value if @field[:transform] || field.equal?(@field)

      super
    end

    def permittable_violation(_field, param, code)
      { param: param, code: code.to_s }
    end
  end
end
