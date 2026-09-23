require "ripper"

module Permittable
  # Drafts a permit_params contract from what the app already knows: the
  # model's columns (types, NOT NULL, database defaults) and, when the
  # controller source is available, the params calls already in it — both
  # spellings, `params.require(:user).permit(:name, tags: [])` and Rails 8's
  # `params.expect(user: [:name, tags: []])`. The draft is a
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

    # One column as the drafting code sees it: the database facts, plus what
    # the MODEL layers on top — an enum accessor that changes what a client
    # sends, or a reason the column must not be client-writable at all.
    # Building these once in columns_for keeps every drafting path (columns
    # alone, or a scan typed from columns) reading the same answers.
    DraftColumn = Struct.new(:name, :type, :null, :default, :default_function, :enum, :omitted, keyword_init: true)

    # Column type => contract type. Document-shaped columns map onto the
    # opaque `:json` field — the shape stays undeclared, which is what a
    # jsonb column is for, and `max_depth:`/`length:` can bound it later.
    # Anything absent here (binary, geometry, ...) has no faithful
    # representation and becomes a TODO comment rather than a guess.
    COLUMN_TYPES = {
      string: :string, text: :string, citext: :string, uuid: :string,
      integer: :integer, bigint: :integer, float: :float, decimal: :decimal,
      boolean: :boolean, date: :date, datetime: :datetime,
      timestamp: :datetime, timestamptz: :datetime,
      json: :json, jsonb: :json, hstore: :json
    }.freeze

    # What a source scan recovered from the `params.permit` and Rails 8
    # `params.expect` calls already in a controller. `scalars` are plain
    # `:key` arguments, `arrays` are `key: []`, `nested` maps `key: [:a, :b]`
    # onto its sub-keys, `nested_arrays` maps the `key: [[:a, :b]]` an
    # `expect` call spells an array of hashes with, and `unparsed` keeps
    # verbatim anything the conservative parser would otherwise have silently
    # dropped.
    Scan = Struct.new(:root, :scalars, :arrays, :nested, :nested_arrays, :unparsed, :calls, keyword_init: true) do
      def found?
        calls.positive?
      end
    end

    # One permit call, with an optional leading `.require(:root)`. The args
    # capture tolerates brackets and newlines but not parentheses — a call
    # whose arguments contain a method call is skipped entirely rather than
    # half-read.
    PERMIT_CALL = /params\s*(?:\.\s*require\(\s*:(\w+)\s*\))?\s*\.\s*permit\(([^()]*)\)/m

    # One Rails 8 `params.expect` call — the replacement for
    # `require(...).permit(...)`, and the reason this scanner exists twice: a
    # Rails 8 controller has no permit calls to read, so without this the
    # generator would fall back to columns alone and lose everything the app
    # already knows about its own params. Same conservative capture as
    # PERMIT_CALL: brackets and newlines are fine, a parenthesis means a
    # method call in the arguments and the whole call is skipped rather than
    # half-read.
    EXPECT_CALL = /params\s*\.\s*expect\(([^()]*)\)/m

    # The required root envelope of an expect call: `user: [...]`, where the
    # brackets hold fields — not the empty `tag_names: []` of an
    # array-of-scalars root, and not the `comments: [[...]]` of an
    # array-of-hashes root, neither of which a rooted contract can express.
    EXPECT_ENVELOPE = /\A(\w+):\s*\[\s*(?![\[\]])(.*?)\s*\]\z/m

    # A permit key: `:name`, `"name"`, or `'name'` (quotes must match —
    # anything else stays unparsed rather than guessed).
    SCALAR_KEY = /\A(?::(\w+)|"(\w+)"|'(\w+)')\z/
    ARRAY_ARG  = /\A(\w+):\s*\[\s*\]\z/m
    NESTED_ARG = /\A(\w+):\s*\[([^\[\]]*)\]\z/m
    # expect-only: `comments: [[:body, :author]]` is an array of hashes.
    NESTED_ARRAY_ARG = /\A(\w+):\s*\[\s*\[([^\[\]]*)\]\s*\]\z/m

    # Comment tokens. Ripper (stdlib) is used rather than a regexp because `#`
    # is only a comment sometimes — it also appears inside string literals and
    # `#{}` interpolation, and a permit call inside interpolation IS live code.
    # String CONTENT is deliberately kept: `permit("name")` is a supported
    # spelling, and its keys live in string tokens.
    COMMENT_TOKENS = %i[on_comment on_embdoc on_embdoc_beg on_embdoc_end].freeze

    module_function

    # `source` with its comments removed. A controller keeping a commented-out
    # `params.require(:admin).permit(:superuser)` for reference had :admin
    # drafted as its root and :superuser as a permitted field — a wrong
    # suggestion, and a security-flavoured one, from a line that does not run.
    #
    # Anything Ripper cannot lex falls back to the source unchanged, so a
    # syntactically odd file scans exactly as it did before rather than not at
    # all.
    def executable_source(source)
      tokens = Ripper.lex(source)
      return source if tokens.nil? || tokens.empty?

      tokens.reject { |token| COMMENT_TOKENS.include?(token[1]) }.map { |token| token[2] }.join
    rescue StandardError
      source
    end

    # Merge every `params.permit` and `params.expect` call found in the
    # EXECUTABLE part of `source` into one Scan. The first root seen wins,
    # matching how a controller normally sticks to one envelope across
    # actions. Comments are stripped first for both call shapes — a
    # commented-out `expect` is no more code than a commented-out `permit`.
    def scan(source)
      result = Scan.new(root: nil, scalars: [], arrays: [], nested: {}, nested_arrays: {},
                        unparsed: [], calls: 0)
      source = executable_source(source.to_s)
      source.scan(PERMIT_CALL) do |root, args|
        result.calls += 1
        result.root ||= root&.to_sym
        split_args(args).each { |arg| classify_arg(result, arg) }
      end
      # One capture group, so scan yields a one-element Array rather than
      # auto-splatting the way PERMIT_CALL's two groups do.
      source.scan(EXPECT_CALL) do |(args)|
        result.calls += 1
        classify_expect_args(result, split_args(args))
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
      render(root: root, model: columns && model, body: body)
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
      model.columns.reject { |c| skipped.include?(c.name) }.to_h { |c| [c.name, draft_column(model, c)] }
    rescue StandardError
      nil
    end

    def draft_column(model, column)
      enum = enum_for(model, column.name)
      default = column.default
      default = enum[:mapping].find { |_key, value| value.to_s == default.to_s }&.first || default if enum && default
      DraftColumn.new(name: column.name, type: column.type, null: column.null, default: default,
                      default_function: column.respond_to?(:default_function) && column.default_function,
                      enum: enum && enum[:values], omitted: omitted_reason(model, column.name))
    end

    # A Rails enum stores an integer but is ASSIGNED its key: a form sends
    # "shipped", never 1, so drafting the column type (:integer) would reject
    # every legitimate request. The draft references the model's own
    # accessor rather than inlining today's keys, so adding a value to the
    # enum cannot leave the contract rejecting it.
    def enum_for(model, name)
      return nil unless model.respond_to?(:defined_enums)

      mapping = model.defined_enums[name]
      mapping && { mapping: mapping, values: "#{model.name}.#{name.pluralize}.keys" }
    end

    # Columns that exist but that no client should be able to write. Both are
    # kept out of the fields and named in a TODO instead, so the omission is
    # visible rather than silent.
    def omitted_reason(model, name)
      # Only a model that actually uses STI: the inheritance column is set
      # (not nil) AND exists. Mass-assigning it changes which class the
      # record is loaded as — `type: "Admin"` on a signup form.
      if model.respond_to?(:inheritance_column) && model.inheritance_column.to_s == name
        return "is the STI inheritance column — assigning it changes the record's class, so no client should send it; " \
               "if clients really pick the subclass, declare it with in: the allowed class names"
      end
      return nil unless model.respond_to?(:locking_column) && model.locking_column.to_s == name

      "is the optimistic-locking column — Rails increments it on every save; if your edit forms round-trip it " \
        "as a hidden field for stale-update detection, declare `optional :#{name}, :integer` on the :update rule"
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

    # An expect call's arguments. The bracketed argument is the required root
    # envelope and its contents are the fields. Plain symbols are fields only
    # when there is no envelope (`params.expect(:q, :page)` is a rootless
    # filter); alongside one they are route params rather than body fields,
    # so they stay visible instead of being drafted as contract fields — as
    # does a second envelope, which belongs under a different root than one
    # rooted contract can express.
    def classify_expect_args(result, args)
      envelopes, others = args.partition { |arg| EXPECT_ENVELOPE.match?(arg) }
      root = envelopes.first
      return others.each { |arg| classify_arg(result, arg) } unless root

      match = EXPECT_ENVELOPE.match(root)
      result.root ||= match[1].to_sym
      split_args(match[2]).each { |inner| classify_arg(result, inner) }
      (envelopes.drop(1) + others).each { |arg| result.unparsed |= [unparsed_arg(arg)] }
    end

    def classify_arg(result, arg)
      if (key = scalar_key(arg))
        result.scalars |= [key]
      elsif (match = ARRAY_ARG.match(arg))
        result.arrays |= [match[1].to_sym]
      elsif (match = NESTED_ARRAY_ARG.match(arg))
        classify_nested(result, match, arg, into: result.nested_arrays)
      elsif (match = NESTED_ARG.match(arg))
        classify_nested(result, match, arg, into: result.nested)
      else
        result.unparsed |= [unparsed_arg(arg)]
      end
    end

    def classify_nested(result, match, arg, into:)
      keys = split_args(match[2]).map { |part| scalar_key(part) }
      return result.unparsed |= [unparsed_arg(arg)] if keys.any?(&:nil?)

      key = match[1].to_sym
      into[key] = (into[key] || []) | keys
    end

    def unparsed_arg(arg)
      arg.gsub(/\s+/, " ")
    end

    def scalar_key(part)
      match = SCALAR_KEY.match(part)
      match && (match[1] || match[2] || match[3]).to_sym
    end

    # -- drafting -----------------------------------------------------------

    # model_name.param_key is the key Rails form helpers submit under and
    # `params.require` reads — `blog_post` for Blog::Post, where demodulizing
    # the class name gave `post` and an enforced draft 400'd every submit.
    def default_root(model)
      return model.model_name.param_key.to_sym if model.respond_to?(:model_name)

      model.name.demodulize.underscore.to_sym
    end

    def signature(root:, model:, actions: DEFAULT_ACTIONS)
      parts = ["permit_params #{actions.map(&:inspect).join(', ')}"]
      parts << "root: :#{root}" if root
      parts << "model: #{model.name}" if model
      parts << "mode: :monitor do"
      parts.join(", ")
    end

    def column_lines(columns)
      columns.map { |column| column_line(column) }
    end

    # Names are emitted with Symbol#inspect, so a column called `first-name`
    # or `2fa_enabled` drafts as `:"first-name"` rather than as Ruby that
    # does not parse.
    def column_line(column)
      return "# TODO: #{column.name} #{column.omitted}" if column.omitted

      type = column.enum ? :string : COLUMN_TYPES[column.type]
      return "# TODO: #{column.name} (#{column.type}) has no contract type — declare it as a nested block or an array" unless type

      line = "#{required_column?(column) ? 'required' : 'optional'} #{column.name.to_sym.inspect}, :#{type}"
      line += ", in: #{column.enum}" if column.enum
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

      !column.default_function
    end

    def scanned_lines(scan, columns)
      lines = scan.scalars.map { |name| scanned_scalar_line(name, columns) }
      lines += scan.arrays.map do |name|
        "array :#{name}, of: :string # TODO: confirm the element type, and declare length: — an array without one is unbounded"
      end
      scan.nested.each { |name, keys| lines += nested_lines(name, keys) }
      scan.nested_arrays.each { |name, keys| lines += nested_array_lines(name, keys) }
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
        sub_field_lines(keys) +
        ["end"]
    end

    # No TODO on the kind here, unlike nested_lines: `params.expect` spells an
    # array of hashes `#{name}: [[...]]`, which says definitively what the
    # equivalent permit call (`#{name}: [...]`) leaves ambiguous.
    def nested_array_lines(name, keys)
      ["array :#{name} do"] + sub_field_lines(keys) + ["end"]
    end

    def sub_field_lines(keys)
      keys.map { |key| "  optional :#{key}, :string # TODO: confirm the type" }
    end

    HEADER = "# Drafted by permittable:generate — review the TODOs, then deploy: monitor\n" \
             "# mode reports violations (instrumentation + log) without rejecting requests.\n".freeze

    UPDATE_NOTE = "# :update has nothing required — a PATCH sends only the fields it changes.\n".freeze

    # One rule, unless a column made something `required`: that is true of a
    # create, but an update carrying only the edited field would be rejected
    # for everything it left out. So the update gets its own rule — the same
    # fields, every one optional — and only when both actions are drafted.
    def render(root:, model:, body:, actions: DEFAULT_ACTIONS)
      rules = split_rules(actions, body).map do |rule_actions, lines|
        "#{signature(root: root, model: model, actions: rule_actions)}\n#{lines.map { |line| "  #{line}\n" }.join}end\n"
      end
      HEADER + rules.join("\n#{UPDATE_NOTE}")
    end

    REQUIRED_LINE = /\Arequired /

    def split_rules(actions, body)
      return [[actions, body]] unless body.any?(REQUIRED_LINE) && (%i[create update] - actions).empty?

      [[actions - [:update], body], [[:update], body.map { |line| line.sub(REQUIRED_LINE, "optional ") }]]
    end
  end
end
