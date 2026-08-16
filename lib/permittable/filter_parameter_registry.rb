module Permittable
  # Registry of sensitive parameter names (populated by `sensitive: true`
  # contract fields) surfaced to Rails' log filtering. Appending plain symbols
  # to `config.filter_parameters` at class-load time misses every consumer
  # that snapshots the list at boot (ActiveRecord's `filter_attributes` copy,
  # lograge-style initializers, precompiled filters). A proc appended once at
  # boot by Permittable::Railtie consults this live registry at *filter time*,
  # so fields registered when a controller class loads later (lazy loading in
  # development) are still redacted.
  #
  # Matching mirrors Rails symbol-filter semantics: case-insensitive substring
  # match on the parameter key. The whole object is duck-typed (#add,
  # #include?, #to_proc, #reset!) so a host can swap in its own registry via
  # `Permittable.filter_parameter_registry=` and pool registrations.
  class FilterParameterRegistry
    FILTERED = "[FILTERED]".freeze

    def initialize
      @fields = Set.new
      @mutex = Mutex.new
      @pattern = nil
      # Stable object so the Railtie's idempotence check (`include?` before
      # `<<`) holds across repeated initializer runs. ActiveSupport's
      # ParameterFilter dups values before invoking proc filters, so in-place
      # String#replace is the supported redaction mechanism.
      @proc = lambda do |key, value|
        value.replace(FILTERED) if value.is_a?(String) && include?(key)
      end
    end

    def add(field)
      name = field.to_s.downcase
      return if name.empty?

      @mutex.synchronize do
        @pattern = nil if @fields.add?(name)
      end
      nil
    end

    def include?(key)
      regexp = pattern
      !regexp.nil? && regexp.match?(key.to_s)
    end

    def pattern
      @mutex.synchronize do
        next nil if @fields.empty?

        @pattern ||= Regexp.new(@fields.map { |f| Regexp.escape(f) }.join("|"), Regexp::IGNORECASE)
      end
    end

    def to_proc
      @proc
    end

    # Spec hygiene — the registry is process-global.
    def reset!
      @mutex.synchronize do
        @fields.clear
        @pattern = nil
      end
    end
  end
end
