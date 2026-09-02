module Permittable
  # Drafts a permit_params contract from what the app already knows: the
  # model's columns (types, NOT NULL, database defaults) and, when the
  # controller source is available, the strong-parameters calls already in it
  # (`params.require(:user).permit(:name, tags: [])`). The draft is a
  # STARTING POINT, not an oracle — everything the generator cannot know for
  # sure is marked with a TODO comment instead of guessed, and the whole
  # contract is emitted in monitor mode so pasting it changes nothing until
  # the TODOs are reviewed and the mode is flipped.
  #
  #   Permittable::Generator.for_controller(UsersController, source: File.read(path))
  #   Permittable::Generator.draft(model: User)
  #
  # Rails apps get the same thing as a rake task:
  #
  #   bin/rails permittable:generate                      # every uncovered controller
  #   bin/rails "permittable:generate[UsersController]"   # one controller
  module Generator
    DEFAULT_ACTIONS = %i[create update].freeze
    SKIPPED_COLUMNS = %w[created_at updated_at].freeze

    # Column type => contract type. Anything absent here (json, jsonb, hstore,
    # binary, ...) has no faithful scalar representation and becomes a TODO
    # comment rather than a guess.
    COLUMN_TYPES = {
      string: :string, text: :string, citext: :string, uuid: :string,
      integer: :integer, bigint: :integer, float: :float, decimal: :decimal,
      boolean: :boolean, date: :date, datetime: :datetime,
      timestamp: :datetime, timestamptz: :datetime
    }.freeze

    # What a source scan recovered from existing permit calls. `scalars` are
    # plain `:key` arguments, `arrays` are `key: []`, `nested` maps `key:
    # [:a, :b]` onto its sub-keys, and `unparsed` keeps verbatim anything the
    # conservative parser would otherwise have silently dropped.
    Scan = Struct.new(:root, :scalars, :arrays, :nested, :unparsed, :calls, keyword_init: true) do
      def found?
        calls.positive?
      end
    end

    # One permit call, with an optional leading `.require(:root)`. The args
    # capture tolerates brackets and newlines but not parentheses — a call
    # whose arguments contain a method call is skipped entirely rather than
    # half-read.
    PERMIT_CALL = /params\s*(?:\.\s*require\(\s*:(\w+)\s*\))?\s*\.\s*permit\(([^()]*)\)/m

    # A permit key: `:name`, `"name"`, or `'name'` (quotes must match —
    # anything else stays unparsed rather than guessed).
    SCALAR_KEY = /\A(?::(\w+)|"(\w+)"|'(\w+)')\z/
    ARRAY_ARG  = /\A(\w+):\s*\[\s*\]\z/m
    NESTED_ARG = /\A(\w+):\s*\[([^\[\]]*)\]\z/m

    module_function

    # Merge every permit call found in `source` into one Scan. The first
    # `.require(:root)` seen wins, matching how a controller normally sticks
    # to one envelope across actions.
    def scan(source)
      result = Scan.new(root: nil, scalars: [], arrays: [], nested: {}, unparsed: [], calls: 0)
      (source || "").scan(PERMIT_CALL) do |root, args|
        result.calls += 1
        result.root ||= root&.to_sym
        split_args(args).each { |arg| classify_arg(result, arg) }
      end
      result
    end

    # Draft a contract for one controller: model inferred from
    # controller_name (or passed explicitly), permit calls scanned from
    # `source:` when given. Returns nil when there is nothing to draft from.
    def for_controller(controller, source: nil, model: nil)
      draft(model: model || infer_model(controller), scan: scan(source))
    end

    # The core: knowledge in (columns and/or a scan), snippet out. Returns a
    # String of valid Ruby, or nil when neither source of knowledge exists.
    def draft(model: nil, scan: nil)
      columns = columns_for(model)
      scan = nil unless scan&.found?
      return nil unless columns || scan

      root = scan ? scan.root : default_root(model)
      body = scan ? scanned_lines(scan, columns) : column_lines(columns.values)
      render(signature(root: root, model: columns && model), body)
    end

    def infer_model(controller)
      return nil unless controller.respond_to?(:controller_name)

      model = controller.controller_name.classify.safe_constantize
      model.respond_to?(:columns) ? model : nil
    end

    # The columns a contract should cover, keyed by name — or nil when there
    # is no model or its schema is unreachable (same philosophy as the drift
    # guard: never let generation crash on a half-migrated database).
    def columns_for(model)
      return nil unless model.respond_to?(:columns)
      return nil unless model.table_exists?

      # Array() flattens a composite primary key (an Array in Rails 7.1+)
      # into its column names; a nil primary key becomes [].
      skipped = SKIPPED_COLUMNS + Array(model.primary_key).map(&:to_s)
      model.columns.reject { |c| skipped.include?(c.name) }.to_h { |c| [c.name, c] }
    rescue StandardError
      nil
    end

    # -- scan parsing -------------------------------------------------------

    # Split a permit argument list on top-level commas only, so `address:
    # [:city, :zip]` stays one argument.
    def split_args(args)
      parts = [+""]
      depth = 0
      args.each_char do |char|
        depth += 1 if "[{".include?(char)
        depth -= 1 if "]}".include?(char)
        next parts << +"" if char == "," && depth.zero?

        parts.last << char
      end
      parts.map(&:strip).reject(&:empty?)
    end

    def classify_arg(result, arg)
      if (key = scalar_key(arg))
        result.scalars |= [key]
      elsif (match = ARRAY_ARG.match(arg))
        result.arrays |= [match[1].to_sym]
      elsif (match = NESTED_ARG.match(arg))
        classify_nested(result, match, arg)
      else
        result.unparsed |= [arg.gsub(/\s+/, " ")]
      end
    end

    def classify_nested(result, match, arg)
      keys = split_args(match[2]).map { |part| scalar_key(part) }
      return result.unparsed |= [arg.gsub(/\s+/, " ")] if keys.any?(&:nil?)

      result.nested[match[1].to_sym] = (result.nested[match[1].to_sym] || []) | keys
    end

    def scalar_key(part)
      match = SCALAR_KEY.match(part)
      match && (match[1] || match[2] || match[3]).to_sym
    end

    # -- drafting -----------------------------------------------------------

    def default_root(model)
      model.name.demodulize.underscore.to_sym
    end

    def signature(root:, model:)
      parts = ["permit_params #{DEFAULT_ACTIONS.map(&:inspect).join(', ')}"]
      parts << "root: :#{root}" if root
      parts << "model: #{model.name}" if model
      parts << "mode: :monitor do"
      parts.join(", ")
    end

    def column_lines(columns)
      columns.map { |column| column_line(column) }
    end

    def column_line(column)
      type = COLUMN_TYPES[column.type]
      return "# TODO: #{column.name} (#{column.type}) has no scalar contract type — declare it as a nested block or an array" unless type

      line = "#{required_column?(column) ? 'required' : 'optional'} :#{column.name}, :#{type}"
      line += " # database default: #{column.default.inspect}" unless column.default.nil?
      line
    end

    # NOT NULL without a database default is the only case a client truly
    # must send the field. A database default is deliberately NOT copied into
    # the contract as `default:` — a contract default is injected on every
    # request that omits the field, which would overwrite columns on partial
    # updates; the database already handles creation.
    def required_column?(column)
      return false if column.null
      return false unless column.default.nil?

      column.respond_to?(:default_function) && column.default_function ? false : true
    end

    def scanned_lines(scan, columns)
      lines = scan.scalars.map { |name| scanned_scalar_line(name, columns) }
      lines += scan.arrays.map { |name| "array :#{name}, of: :string # TODO: confirm the element type" }
      scan.nested.each { |name, keys| lines += nested_lines(name, keys) }
      lines + scan.unparsed.map { |arg| "# TODO: could not parse from the permit call: #{arg}" }
    end

    def scanned_scalar_line(name, columns)
      column = columns && columns[name.to_s]
      return column_line(column) if column
      return "optional :#{name}, :string, virtual: true # TODO: not a database column — confirm the type" if columns

      "optional :#{name}, :string # TODO: confirm the type"
    end

    def nested_lines(name, keys)
      ["optional :#{name} do # TODO: drafted from `#{name}: [...]` — if this is an array of hashes, use `array :#{name} do`"] +
        keys.map { |key| "  optional :#{key}, :string # TODO: confirm the type" } +
        ["end"]
    end

    HEADER = "# Drafted by permittable:generate — review the TODOs, then deploy: monitor\n" \
             "# mode reports violations (instrumentation + log) without rejecting requests.\n".freeze

    def render(signature, body)
      "#{HEADER}#{signature}\n#{body.map { |line| "  #{line}\n" }.join}end\n"
    end
  end
end
