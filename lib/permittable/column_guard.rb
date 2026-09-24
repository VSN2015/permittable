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
    # appends a ready-to-paste migration command.
    def ensure_columns_on!(label, klass, *fields, types: nil, check_types: false)
      return false unless schema_reachable?(klass)

      fields.flatten.compact.each do |field|
        unless klass.column_names.include?(field.to_s)
          raise ArgumentError,
                "#{label}: '#{field}' does not exist in the database (table: #{klass.table_name})." \
                "#{column_migration_hint(klass, field, types)}"
        end

        ensure_column_type!(label, klass, field, types) if check_types
      end
      true
    end

    # The type half of the drift guard, opt-in via Permittable
    # .check_column_types. It compares GROUPS rather than exact types (see
    # TYPE_GROUPS) and stays silent unless both sides are known, so it can
    # only fire on a genuine cross-family mismatch — a contract still saying
    # :datetime after the column became a string, say.
    def ensure_column_type!(label, klass, field, types)
      declared = types.is_a?(Hash) ? types[field.to_sym] : types
      column = klass.columns_hash[field.to_s]
      return unless declared && column

      # `column.type` is nil for a SQL type the adapter does not recognise
      # (a PostGIS geometry column without the extension loaded, a custom
      # domain type). That is exactly the "no faithful contract type" case
      # this guard documents staying silent for — not a reason to raise
      # NoMethodError out of a controller's class body.
      return unless column.type

      wanted = TYPE_GROUPS[declared.to_sym]
      actual = TYPE_GROUPS[column.type.to_sym]
      return if wanted.nil? || actual.nil? || wanted == actual
      return if wanted == :text && enum_attribute?(klass, field)

      raise ArgumentError,
            "#{label}: '#{field}' is declared :#{declared} but the column is :#{column.type} " \
            "(table: #{klass.table_name}). Change the contract to match the column, migrate the " \
            "column to match the contract, or declare the field virtual: true if it is not " \
            "backed by this column."
    end

    # A Rails enum is submitted by its NAME — `status: "shipped"` — whatever
    # the column stores, so `:string, in: Order.statuses.keys` is the correct
    # contract for an integer-backed enum, not drift. The model's enum mapping
    # is what casts between the two, so a text declaration on an enum column
    # is accepted whatever the column's group; any other declaration is still
    # held to the column's own group (`:integer` on an integer-backed enum
    # passes, `:datetime` does not). Only `enum` is recognised: an
    # `attribute :x, :datetime` over a string column is a deliberate override
    # this guard cannot tell from drift, and stays the documented trade-off.
    # `model:` is only duck-typed on column_names, hence the respond_to?.
    def enum_attribute?(klass, field)
      klass.respond_to?(:defined_enums) && klass.defined_enums.key?(field.to_s)
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
