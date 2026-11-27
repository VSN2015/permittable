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
    # The exception is :date over a time column, which keeps no value (see
    # type_mismatch?).
    #
    # Anything absent here — :json, :jsonb, :binary, an adapter's own :inet or
    # :money — is NOT checked. A contract has no faithful type for those, so
    # whatever an app improvised is left alone rather than guessed about.
    TYPE_GROUPS = {
      string: :text, text: :text, citext: :text, uuid: :text, enum: :text, char: :text,
      integer: :numeric, bigint: :numeric, float: :numeric, decimal: :numeric, boolean: :numeric,
      date: :temporal, datetime: :temporal, time: :temporal, timestamp: :temporal, timestamptz: :temporal
    }.freeze

    # The contract type an `array ..., of:` takes for a column element type,
    # for the array-column hint. Only scalar element types: `of:` takes no
    # other, so a jsonb[] column gets the hint without an `of:`.
    ARRAY_ELEMENT_TYPES = {
      string: :string, text: :string, citext: :string, uuid: :string,
      integer: :integer, bigint: :integer, float: :float, decimal: :decimal, boolean: :boolean,
      date: :date, datetime: :datetime, timestamp: :datetime, timestamptz: :datetime
    }.freeze

    module_function

    # `types:` teaches the error message: a Symbol/String applies to every
    # listed field, a Hash maps field => type. The raised ArgumentError then
    # appends a ready-to-paste migration command. `allowed:` maps field =>
    # its `in:`, for the fields that declare one, and `transformed:` lists
    # the fields that declare a `transform:`; only the enum rule reads them.
    def ensure_columns_on!(label, klass, *fields, types: nil, check_types: false, allowed: nil, transformed: nil)
      return false unless schema_reachable?(klass)

      fields.flatten.compact.each do |field|
        column = backing_column(klass, field)
        unless klass.column_names.include?(column) || attribute_declared?(klass, column)
          raise ArgumentError, ignored_column_message(label, klass, column) if ignored_column?(klass, column)

          raise ArgumentError, missing_column_message(label, klass, field, column, types)
        end

        ensure_column_type!(label, klass, field, types, allowed, transformed: transformed) if check_types
      end
      true
    end

    # `alias_attribute :title, :name` makes `title` an attribute assignment
    # accepts, backed by `name`'s column, so the existence check, the
    # ignored_columns check and the type check all look at the target. Aliases
    # may chain; the walk stops at a name it has seen, so a cycle cannot hang a
    # class body. A duck-typed model without `attribute_aliases` (or whose
    # reader returns nil) has none.
    def resolve_alias(klass, field)
      name = field.to_s
      aliases = attribute_aliases_of(klass)
      seen = [name]
      while (target = aliases[name])
        break if seen.include?(target.to_s)

        name = target.to_s
        seen << name
      end
      name
    end

    def attribute_aliases_of(klass)
      klass.respond_to?(:attribute_aliases) ? Hash(klass.attribute_aliases) : {}
    end

    # The column a field is stored in: its alias target's, or for a store
    # accessor (`store_accessor :settings, :theme`) the column of its store,
    # `settings`, itself resolved when the store is an alias. The field is then
    # a key inside that column, not a column of its own, so the column's type
    # says nothing about it (see ensure_column_type!). The guard accepts it for
    # the reason it accepts an alias or an enum: assignment takes it and the
    # data lands in a column. `virtual: true` stays the opt-out for what no
    # column holds. That is also why the store column itself must exist.
    def backing_column(klass, field)
      name = resolve_alias(klass, field)
      store = stored_attribute_store(klass, name)
      store ? resolve_alias(klass, store) : name
    end

    # The store (the column holding the hash) a `store_accessor` field lives
    # in, nil when `name` is a plain attribute. A real column of the same name
    # wins: it is the attribute Rails reads. A duck-typed model without
    # `stored_attributes` has none.
    #
    # `stored_attributes` lists the raw keys (`{settings: [:theme]}`), but the
    # accessor is named by `prefix:`/`suffix:` too (`settings_theme`), so the
    # name is accepted only when the model really has a store accessor's writer
    # under it, which is what assignment calls (see store_accessor_writer?). A
    # writer from anywhere else is an ordinary attribute, not a
    # store key. The store is then the one whose key the name is built from,
    # the longest key first and one whose name the accessor mentions next.
    # Rails does not record which prefix built which accessor, so two stores
    # sharing a key are ambiguous, and the guess may check the other's column.
    def stored_attribute_store(klass, name)
      return unless klass.respond_to?(:stored_attributes)
      return if klass.column_names.include?(name) || !store_accessor_writer?(klass, "#{name}=")

      pairs = Hash(klass.stored_attributes).flat_map { |store, keys| keys.map { |key| [store, key.to_s] } }
      pairs.select { |_store, key| name.include?(key) }
           .min_by { |store, key| [-key.length, name.include?(store.to_s) ? 0 : 1] }&.first
    end

    # Whether `writer` is a store accessor's, whatever the model has layered on
    # it. The accessor is defined by active_record/store.rb itself, so the
    # method chain is walked through `super` (an override in the model, a
    # subclass, a prepended or later-included module calls through to it) until
    # a method defined in that file turns up. That holds across Rails versions:
    # the module holding the accessors is `_store_accessors_module` on 6.1
    # through 8.1 and a `GeneratedStoreMethods` constant on main, which a
    # lookup of either would miss. An ordinary writer (`attr_accessor`, an
    # attribute-API or column writer) is defined elsewhere.
    STORE_SOURCE = %r{/active_record/store\.rb\z}

    def store_accessor_writer?(klass, writer)
      return false unless klass.method_defined?(writer)

      method = klass.instance_method(writer)
      while method
        return true if method.source_location&.first.to_s.match?(STORE_SOURCE)

        method = method.super_method
      end
      false
    end

    def missing_column_message(label, klass, field, column, types)
      store = stored_attribute_store(klass, resolve_alias(klass, field))
      return store_column_message(label, klass, field, store, column) if store

      if column == field.to_s
        return "#{label}: '#{field}' does not exist in the database (table: #{klass.table_name})." \
               "#{column_migration_hint(klass, field, types)}"
      end

      # An alias: the migration must add the column the alias points at,
      # not one named for the alias, which would still leave this check failing.
      "#{label}: '#{field}' is an alias of '#{column}', which does not exist in the database " \
        "(table: #{klass.table_name})." \
        "#{column_migration_hint(klass, column, types.is_a?(Hash) ? types[field.to_sym] : types)}"
    end

    # The store column is gone (dropped, or never migrated), so the accessor
    # reads and writes nothing. That is the column the migration is for, not
    # a column named after the accessor, which would shadow it.
    def store_column_message(label, klass, field, store, column)
      "#{label}: '#{field}' is a store_accessor of :#{store} on #{model_expr(klass)}, " \
        "but the table has no '#{column}' column (table: #{klass.table_name}). " \
        "Add the '#{column}' column that holds it, or declare the field virtual: true if the app handles it itself."
    end

    # The type half of the drift guard, opt-in via Permittable
    # .check_column_types. It compares GROUPS rather than exact types (see
    # TYPE_GROUPS) and stays silent unless both sides are known, so it can
    # only fire on a genuine cross-family mismatch — a contract still saying
    # :datetime after the column became a string, say.
    def ensure_column_type!(label, klass, field, types, allowed = nil, transformed: nil)
      declared = types.is_a?(Hash) ? types[field.to_sym] : types
      target = resolve_alias(klass, field)
      column = klass.columns_hash[target]
      if declared && column.nil?
        return ensure_attribute_type!(label, klass, field, declared, target, allowed: allowed, transformed: transformed)
      end
      return unless declared && column

      ensure_not_array_column!(label, klass, field, declared, column)

      wanted = TYPE_GROUPS[declared.to_sym]
      # An enum is keyed by the name it was declared on, which may be the
      # alias (`enum :phase` over `alias_attribute :phase, :status`) or the
      # target it points at.
      enum_name = [field.to_s, target].find { |name| enum_attribute?(klass, name) }
      enum = !enum_name.nil?
      # Checked before the column's type, which an enum's contract does not
      # depend on: see ensure_enum_contract!.
      if enum && (wanted == :text || integer_enum_declaration?(klass, enum_name, declared))
        return ensure_enum_contract!(label, klass, enum_name, declared, allowed && allowed[field.to_sym],
                                     transformed: Array(transformed).include?(field.to_sym), shown: field.to_s)
      end

      # `column.type` is nil for a SQL type the adapter does not recognise
      # (a PostGIS geometry column without the extension loaded, a custom
      # domain type). That is exactly the "no faithful contract type" case
      # this guard documents staying silent for — not a reason to raise
      # NoMethodError out of a controller's class body.
      return unless column.type

      return unless type_mismatch?(declared, column.type)

      # On an enum, `virtual: true` would be the wrong advice: it switches
      # off the existence check too, and the field IS backed by this column.
      fix = if enum
              "#{enum_subject(enum_name, field)} is an enum on #{model_expr(klass)}: " \
                "declare it :string, in: #{enum_keys_expr(klass, enum_name)}."
            else
              "Change the contract to match the column, migrate the column to match the contract, " \
                "or declare the field virtual: true if it is not backed by this column."
            end
      raise ArgumentError,
            "#{label}: '#{field}' is declared :#{declared} but the column is :#{column.type} " \
            "(table: #{klass.table_name}). #{fix}"
    end

    # `attribute :vip, :boolean` over no column: Rails assigns it like any
    # attribute, so it exists, and its type is the one the contract is compared
    # against, by the same groups. A store accessor or an attribute declared
    # without a type has none to compare. An enum over one is held to the same
    # in: rule as an enum over a column (see ensure_enum_contract!): assignment
    # refuses a value it does not map either way.
    def ensure_attribute_type!(label, klass, field, declared, target, allowed: nil, transformed: nil)
      enum_name = [field.to_s, target].find { |name| enum_attribute?(klass, name) }
      if enum_name
        return unless TYPE_GROUPS[declared.to_sym] == :text || integer_enum_declaration?(klass, enum_name, declared)

        return ensure_enum_contract!(label, klass, enum_name, declared, allowed && allowed[field.to_sym],
                                     transformed: Array(transformed).include?(field.to_sym), shown: field.to_s)
      end

      actual_type = attribute_declared?(klass, target) && klass.attribute_types[target].type
      return unless actual_type

      return unless type_mismatch?(declared, actual_type)

      raise ArgumentError,
            "#{label}: '#{field}' is declared :#{declared} but the attribute is :#{actual_type} " \
            "(attribute :#{target} on #{model_expr(klass)}). Change the contract to match the attribute, " \
            "or declare the field virtual: true if it is not backed by it."
    end

    # Whether a contract type and a column/attribute type disagree: different
    # groups, plus the one pair inside the temporal group that keeps nothing.
    # A time column has no date part, so a :date value casts to NULL there
    # (a :datetime value keeps its time of day, which is why it stays accepted).
    def type_mismatch?(declared, actual)
      wanted = TYPE_GROUPS[declared.to_sym]
      found = TYPE_GROUPS[actual.to_sym]
      return false if wanted.nil? || found.nil?

      wanted != found || (declared.to_sym == :date && actual.to_sym == :time)
    end

    # Whether `name` is declared through the attribute API (`attribute :vip,
    # :boolean`) rather than a column. A duck-typed model has no
    # attribute_types, and a column is checked by its own path.
    def attribute_declared?(klass, name)
      klass.respond_to?(:attribute_types) && klass.attribute_types.key?(name.to_s)
    end

    # A PostgreSQL array column reports its ELEMENT type as `type`, so
    # `optional :tags, :string` over `t.string :tags, array: true` sits in
    # the same group as the column and the group check passes — yet the
    # field rejects as invalid_type every array the column stores. Only a
    # scalar or :json field reaches this guard (an `array` field is
    # implicitly virtual), and neither accepts an Array, so any declaration
    # over an array column is the wrong shape.
    def ensure_not_array_column!(label, klass, field, declared, column)
      return unless column.respond_to?(:array?) && column.array?

      element = ARRAY_ELEMENT_TYPES[column.type&.to_sym]
      spelled = element ? "array :#{field}, of: :#{element}" : "array :#{field}"
      raise ArgumentError,
            "#{label}: '#{field}' is declared :#{declared} but the column is an array#{" (of :#{column.type})" if column.type} " \
            "(table: #{klass.table_name}), so every array it stores would be rejected as invalid_type. " \
            "Declare it `#{spelled}`, or declare the field virtual: true if it is not backed by this column."
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
    # group already matched — the 500 is identical. So is an `:integer`
    # declaration over an integer-backed enum, whose `status: 5` is cast and
    # then refused on assignment the same way; its list is the stored integers
    # (`Order.statuses.values`). Any other declaration on an enum is still
    # held to the column's own group (`:datetime` fails).
    #
    # Accepted means what the enum's cast accepts: every name, plus every
    # stored value that is a String (a string-backed enum takes `"p"` for
    # `pro:` as readily as `"pro"`). An integer-backed enum's stored values
    # are not accepted — a request carries `"0"`, which maps to nothing —
    # unless the field declares a `transform:`, which runs after `in:` and is
    # how permittable:generate's TODO maps them back to names. Only the stored
    # integers are admitted that way; the transform is app code, trusted to
    # do what the TODO spells. A Range, or anything else without a finite
    # list, cannot be checked, so it is refused rather than trusted.
    #
    # Only `enum` is recognised. The attribute API (`attribute :x, :datetime`
    # over a string column) is left compared against the column by choice:
    # an enum's mapping says exactly which strings are valid, an attribute
    # override says nothing a contract could be checked against.
    def ensure_enum_contract!(label, klass, field, declared, listed, transformed: false, shown: field)
      integer = integer_enum_declaration?(klass, field, declared)
      problem =
        if listed.nil?
          "declared :#{declared} without an in:"
        elsif listed.is_a?(Range) || !listed.respond_to?(:to_a)
          "declared :#{declared} with an in: that does not list its values"
        else
          accepted = integer ? klass.defined_enums[field.to_s].values : enum_values(klass, field)
          accepted += stored_integers(klass, field) if transformed && !integer
          stray = listed.to_a - accepted
          return if stray.empty?

          "declared :#{declared} with an in: listing values it would refuse: #{stray.map(&:inspect).join(', ')}" \
            "#{stored_integer_hint(klass, field, stray, transformed)}"
        end

      raise ArgumentError,
            "#{label}: #{enum_subject(field, shown)} is an enum on #{model_expr(klass)}, #{problem} (table: #{klass.table_name}). " \
            "A value outside the enum would pass the contract and then #{enum_failure(klass, field)}. " \
            "Declare it with in: #{enum_keys_expr(klass, field, integer ? :values : :keys)}."
    end

    # What assignment does with a value the enum does not map. Rails 7.1's
    # `enum ..., validate: true` records a validation error instead of raising;
    # its type answers assert_valid_value without raising. Older Rails, and a
    # duck-typed model, always raise.
    def enum_failure(klass, field)
      type = klass.respond_to?(:attribute_types) && klass.attribute_types[field.to_s]
      return "raise on assignment" unless type.respond_to?(:assert_valid_value)

      type.assert_valid_value("permittable-not-an-enum-value")
      "fail the model's enum validation"
    rescue ArgumentError
      "raise on assignment"
    end

    # `:integer` over an enum whose stored values are all integers: the request
    # carries one, and assignment accepts only the ones the enum maps.
    def integer_enum_declaration?(klass, field, declared)
      declared.to_sym == :integer && klass.defined_enums[field.to_s].values.all?(Integer)
    end

    # The field as an enum error names it: `'phase'`, or `'state' (an alias of
    # 'status')` when the enum is declared on the alias's target.
    def enum_subject(enum_name, shown)
      return "'#{shown}'" if enum_name.to_s == shown.to_s

      "'#{shown}' (an alias of '#{enum_name}')"
    end

    def enum_values(klass, field)
      mapping = klass.defined_enums[field.to_s]
      mapping.keys.map(&:to_s) + mapping.values.grep(String)
    end

    def stored_integers(klass, field)
      klass.defined_enums[field.to_s].values.grep(Integer).map(&:to_s)
    end

    def stored_integer_hint(klass, field, stray, transformed)
      return "" if transformed || !stray.intersect?(stored_integers(klass, field))

      " (a stored integer is accepted only beside a transform: mapping it back to its name)"
    end

    # `Order.statuses.keys` when the enum's plural reader exists, and the
    # always-valid `defined_enums["..."]` spelling when it does not (a name
    # that is not a Ruby identifier, a duck-typed model).
    def enum_keys_expr(klass, field, members = :keys)
      reader = field.to_s.pluralize
      if reader.match?(/\A[a-z_][a-zA-Z0-9_]*\z/) && klass.respond_to?(reader)
        "#{model_expr(klass)}.#{reader}.#{members}"
      else
        "#{model_expr(klass)}.defined_enums[#{field.to_s.inspect}].#{members}"
      end
    end

    def model_expr(klass)
      klass.name || "Model"
    end

    # `klass.column_names` leaves out `self.ignored_columns`, so an ignored
    # column that IS in the database reads as missing. Raising stays right
    # (`Model.new(field: ...)` raises UnknownAttributeError), but the
    # migration the missing-column message teaches would duplicate it.
    def ignored_column?(klass, field)
      klass.respond_to?(:ignored_columns) && klass.ignored_columns.map(&:to_s).include?(field.to_s)
    end

    # The column may have been dropped since it was ignored, with its name
    # left in ignored_columns; the table itself says which. That case needs
    # different advice: removing the name would only lead to a migration
    # that re-adds a column the app no longer wants.
    def ignored_column_message(label, klass, field)
      subject = "#{label}: '#{field}' is in #{model_expr(klass)}'s ignored_columns"
      if column_in_table?(klass, field)
        "#{subject} (table: #{klass.table_name}), so the model ignores that column " \
          "and assigning it raises ActiveModel::UnknownAttributeError. " \
          "Remove it from ignored_columns, or declare the field virtual: true if the app handles it itself."
      else
        "#{subject} but the table has no such column (table: #{klass.table_name}). " \
          "Remove it from ignored_columns and the field from the contract, " \
          "or declare the field virtual: true if the app handles it itself."
      end
    end

    # Unlike `column_names`, the connection's own column list includes the
    # columns the model ignores.
    def column_in_table?(klass, field)
      klass.connection_pool.with_connection { |connection| connection.column_exists?(klass.table_name, field) }
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
