module Permittable
  # The request walker, pointed at an authored array `default:`/`example:`
  # at class load — the same permittable_check_array a request goes
  # through, so the two cannot drift apart. Two seams are overridden:
  #
  #   * `transform:` is NOT run. It is app code reshaping a value the client
  #     sent, and a default is stored as the contract reads it, not as the
  #     app reshapes it — so a contract with transform: hands out its
  #     default untransformed, exactly as it always has, and nothing of the
  #     app's runs at class load beyond the `validate:` an authored value was
  #     already checked with.
  #   * violations carry no `message:` — they become an ArgumentError for
  #     the contract's author, not a response for a client, and I18n may not
  #     be loaded yet.
  class AuthoredValues
    include Permittable

    def self.read_array(field, value)
      new.read_array(field, value)
    end

    def self.summary(violations)
      new.summary(violations)
    end

    # [value as a request would get it, violations]
    def read_array(field, value)
      violations = []
      read = permittable_check_array(field, value, path: field[:name].to_s, unknown: :ignore, violations: violations)
      [read, violations]
    end

    def summary(violations)
      permittable_violation_summary(violations)
    end

    private

    def permittable_transform(_field, value)
      value
    end

    def permittable_violation(_field, param, code)
      { param: param, code: code.to_s }
    end
  end
end
