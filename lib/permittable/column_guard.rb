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
    module_function

    # `types:` teaches the error message: a Symbol/String applies to every
    # listed field, a Hash maps field => type. The raised ArgumentError then
    # appends a ready-to-paste migration command.
    def ensure_columns_on!(label, klass, *fields, types: nil)
      return false unless schema_reachable?(klass)

      fields.flatten.compact.each do |field|
        next if klass.column_names.include?(field.to_s)

        raise ArgumentError,
              "#{label}: '#{field}' does not exist in the database (table: #{klass.table_name})." \
              "#{column_migration_hint(klass, field, types)}"
      end
      true
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
