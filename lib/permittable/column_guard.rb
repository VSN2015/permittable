require "active_support/core_ext/string/inflections"

module Permittable
  # Schema validation behind the drift guard. When the schema is unreachable —
  # no database yet (`db:create`, a fresh `db:migrate`, `assets:precompile`,
  # CI bootstrap) or the table not yet migrated — the check is skipped and
  # `false` is returned instead of raising, so controller classes stay
  # loadable. A missing column with a *reachable* schema still raises: the
  # rescue is scoped to ActiveRecord::ActiveRecordError precisely so real bugs
  # (NameError from a typo etc.) keep surfacing. Skipping is self-healing:
  # once the migration runs and classes reload, validation happens for real.
  module ColumnGuard
    # Column types that mean the same thing for a contract's purposes, grouped
    # so the check can catch a column RETYPED out from under a contract
    # without second-guessing a declaration that merely differs in flavour.
    #
    # The numeric group deliberately includes :boolean — a boolean stored as
    # an integer 0/1 is a real legacy pattern, and ActiveRecord casts cleanly
    # between all of them. The temporal group is one group for the same
    # reason: a :date contract on a datetime column is a narrowing, not drift.
    #
    # Anything absent here — :json, :jsonb, :binary, an adapter's own :inet or
    # :money — is NOT checked. A contract has no faithful type for those, so
    # whatever an app improvised is left alone rather than guessed about.
    TYPE_GROUPS = {
      string: :text, text: :text, citext: :text, uuid: :text, enum: :text, char: :text,
      integer: :numeric, bigint: :numeric, float: :numeric, decimal: :numeric, boolean: :numeric,
      date: :temporal, datetime: :temporal, time: :temporal, timestamp: :temporal, timestamptz: :temporal
    }.freeze

    module_function

    # `types:` teaches the error message: a Symbol/String applies to every
    # listed field, a Hash maps field => type. The raised ArgumentError then
    # appends a ready-to-paste migration command. `allowed:` maps field =>
    # its `in:`, for the fields that declare one; only the enum rule reads it.
    def ensure_columns_on!(label, klass, *fields, types: nil, check_types: false, allowed: nil)
      return false unless schema_reachable?(klass)

      fields.flatten.compact.each do |field|
        unless klass.column_names.include?(field.to_s)
          raise ArgumentError,
                "#{label}: '#{field}' does not exist in the database (table: #{klass.table_name})." \
                "#{column_migration_hint(klass, field, types)}"
        end

        ensure_column_type!(label, klass, field, types, allowed) if check_types
      end
      true
    end

    # The type half of the drift guard, opt-in via Permittable
    # .check_column_types. It compares GROUPS rather than exact types (see
    # TYPE_GROUPS) and stays silent unless both sides are known, so it can
    # only fire on a genuine cross-family mismatch — a contract still saying
    # :datetime after the column became a string, say.
    def ensure_column_type!(label, klass, field, types, allowed = nil)
      declared = types.is_a?(Hash) ? types[field.to_sym] : types
      column = klass.columns_hash[field.to_s]
      return unless declared && column

      wanted = TYPE_GROUPS[declared.to_sym]
      enum = enum_attribute?(klass, field)
      # Checked before the column's type, which an enum's contract does not
      # depend on: see ensure_enum_contract!.
      return ensure_enum_contract!(label, klass, field, declared, allowed && allowed[field.to_sym]) if enum && wanted == :text

      # `column.type` is nil for a SQL type the adapter does not recognise
      # (a PostGIS geometry column without the extension loaded, a custom
      # domain type). That is exactly the "no faithful contract type" case
      # this guard documents staying silent for — not a reason to raise
      # NoMethodError out of a controller's class body.
      return unless column.type

      actual = TYPE_GROUPS[column.type.to_sym]
      return if wanted.nil? || actual.nil? || wanted == actual

      # On an enum, `virtual: true` would be the wrong advice: it switches
      # off the existence check too, and the field IS backed by this column.
      fix = if enum
              "'#{field}' is an enum on #{model_expr(klass)}: declare it :string, in: #{enum_keys_expr(klass, field)}."
            else
              "Change the contract to match the column, migrate the column to match the contract, " \
                "or declare the field virtual: true if it is not backed by this column."
            end
      raise ArgumentError,
            "#{label}: '#{field}' is declared :#{declared} but the column is :#{column.type} " \
            "(table: #{klass.table_name}). #{fix}"
    end

    # `model:` is only duck-typed on column_names, hence the respond_to?.
    def enum_attribute?(klass, field)
      klass.respond_to?(:defined_enums) && klass.defined_enums.key?(field.to_s)
    end

    # A Rails enum is submitted by its NAME — `status: "shipped"` — whatever
    # the column stores, so a text declaration is the right contract for any
    # enum, integer-backed included, and is not held to the column's group.
    # The price of that exemption is an `in:` naming what the enum accepts:
    # assignment raises ArgumentError for anything else, so without one
    # `status: "bogus"` passes the contract and becomes a 500 in the action.
    # A string-backed enum is held to the same rule even though its column
    # group already matched — the 500 is identical. Any other declaration on
    # an enum is still held to the column's own group (`:integer` on an
    # integer-backed enum passes, `:datetime` does not).
    #
    # Accepted means what the enum's cast accepts: every name, plus every
    # stored value that is a String (a string-backed enum takes `"p"` for
    # `pro:` as readily as `"pro"`). An integer-backed enum's stored values
    # are not accepted — a request carries `"0"`, which maps to nothing. A
    # Range, or anything else without a finite list, cannot be checked, so it
    # is refused rather than trusted.
    #
    # Only `enum` is recognised. The attribute API (`attribute :x, :datetime`
    # over a string column) is left compared against the column by choice:
    # an enum's mapping says exactly which strings are valid, an attribute
    # override says nothing a contract could be checked against.
    def ensure_enum_contract!(label, klass, field, declared, listed)
      problem =
        if listed.nil?
          "declared :#{declared} without an in:"
        elsif listed.is_a?(Range) || !listed.respond_to?(:to_a)
          "declared :#{declared} with an in: that does not list its values"
        else
          stray = listed.to_a - enum_values(klass, field)
          return if stray.empty?

          "declared :#{declared} with an in: listing values it would refuse: #{stray.map(&:inspect).join(', ')}"
        end

      raise ArgumentError,
            "#{label}: '#{field}' is an enum on #{model_expr(klass)}, #{problem} (table: #{klass.table_name}). " \
            "A value outside the enum would pass the contract and then raise on assignment. " \
            "Declare it with in: #{enum_keys_expr(klass, field)}."
    end

    def enum_values(klass, field)
      mapping = klass.defined_enums[field.to_s]
      mapping.keys.map(&:to_s) + mapping.values.grep(String)
    end

    # `Order.statuses.keys` when the enum's plural reader exists, and the
    # always-valid `defined_enums["..."]` spelling when it does not (a name
    # that is not a Ruby identifier, a duck-typed model).
    def enum_keys_expr(klass, field)
      reader = field.to_s.pluralize
      if reader.match?(/\A[a-z_][a-zA-Z0-9_]*\z/) && klass.respond_to?(reader)
        "#{model_expr(klass)}.#{reader}.keys"
      else
        "#{model_expr(klass)}.defined_enums[#{field.to_s.inspect}].keys"
      end
    end

    def model_expr(klass)
      klass.name || "Model"
    end

    def column_migration_hint(klass, field, types)
      type = types.is_a?(Hash) ? types[field.to_sym] : types
      column = [field, type].compact.join(":")
      " Add it with: bin/rails generate migration " \
        "Add#{field.to_s.camelize}To#{klass.table_name.to_s.camelize} #{column}"
    end

    # True when the class's table can actually be inspected. Connection errors
    # (ConnectionNotEstablished, NoDatabaseError, adapter errors) all inherit
    # from ActiveRecord::ActiveRecordError; the defined? guard keeps this gem
    # loadable without activerecord (a host without it cannot pass `model:`
    # anyway).
    def schema_reachable?(klass)
      klass.table_exists?
    rescue StandardError => e
      raise unless defined?(ActiveRecord::ActiveRecordError) && e.is_a?(ActiveRecord::ActiveRecordError)

      false
    end
  end
end
