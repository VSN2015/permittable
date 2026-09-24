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
    # sends, a default the model fills in, or a `sensitive` role (:sti,
    # :locking) that makes the column dangerous to leave client-writable.
    # `default` is the comment describing whichever default applies, and
    # `unread` the error that stopped the model's side from being read.
    # Building these once in columns_for keeps every drafting path (columns
    # alone, or a scan typed from columns) reading the same answers.
    #
    # `rule` and `listed` are how column_line is told what it is drafting
    # for: the rule (see render) and whether the controller's permit call
    # lists the column. They ride on the column, set by in_rule, so the scan
    # path hands them to column_line without its own methods changing.
    DraftColumn = Struct.new(:name, :type, :null, :default, :default_function, :enum, :sensitive, :unread,
                             :rule, :listed, keyword_init: true) do
      def in_rule(rule, listed: false)
        self.class.new(**to_h, rule: rule, listed: listed)
      end
    end

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
      render(root: root, model: columns && model) do |rule|
        if scan
          scanned_lines(scan, columns&.transform_values { |column| column.in_rule(rule, listed: true) })
        else
          column_lines(columns.values.map { |column| column.in_rule(rule) })
        end
      end
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
      columns = schema_columns(model)
      columns&.to_h { |column| [column.name, draft_column(model, column)] }
    end

    # Only schema access is rescued here. The model introspection layered on
    # top (draft_column) must not share this rescue: an error there would
    # otherwise discard EVERY column — the draft silently falls back to a
    # scan alone, or to nothing — for what is one column's problem.
    def schema_columns(model)
      return nil unless model.respond_to?(:columns)
      return nil unless model.table_exists?

      # Array() flattens a composite primary key (an Array in Rails 7.1+)
      # into its column names; a nil primary key becomes [].
      skipped = SKIPPED_COLUMNS + Array(model.primary_key).map(&:to_s)
      model.columns.reject { |c| skipped.include?(c.name) }
    rescue StandardError
      nil
    end

    def draft_column(model, column)
      DraftColumn.new(name: column.name, type: column.type, null: column.null,
                      default_function: column.respond_to?(:default_function) && column.default_function,
                      **model_facts(model, column))
    end

    # What the model adds to one column. An error reading it degrades THAT
    # column to its database facts, with the error in a TODO — rather than
    # raising, which would abort permittable:generate for every controller
    # over one odd model, or dropping the column, which would hide it. The
    # message is squished because it lands in a one-line comment, where a
    # newline would end the comment and leave the draft unparseable.
    def model_facts(model, column)
      enum = enum_for(model, column.name)
      { enum: enum && enum[:accessor], default: default_note(model, column, enum),
        sensitive: sensitive_role(model, column.name) }
    rescue StandardError => e
      { default: database_default_note(column, nil), unread: "#{e.class}: #{e.message}".squish }
    end

    # The default Rails actually applies, as a comment. One the MODEL
    # declares — `attribute :carrier, default: "post"`, `enum ..., default:
    # :pending` — never reaches the schema, yet it fills the field on create
    # just as a database default does, so it too keeps a NOT NULL column
    # from being `required`. It wins over the database's, as it does in
    # Rails.
    def default_note(model, column, enum)
      declared = model_default(model, column.name)
      declared ? "model default: #{declared}" : database_default_note(column, enum)
    end

    # An enum's database default is its stored integer; shown as its key
    # (`"pending"`, not `0`), which is what the drafted field accepts.
    def database_default_note(column, enum)
      default = column.default
      return nil if default.nil?

      default = enum[:mapping].find { |_key, value| value.to_s == default.to_s }&.first || default if enum
      "database default: #{default.inspect}"
    end

    # `_default_attributes` (nodoc, but what `column_defaults` is built from
    # in every supported Rails, 6.1–8.1) holds a UserProvidedDefault for each
    # default the model declares; the rest came from the database. Read per
    # attribute rather than through column_defaults, which evaluates every
    # Proc default at once. A Proc is not called at all — drafting must not
    # run app code with side effects, and today's value says nothing about
    # tomorrow's. Its value is cast the way the model reads it, so an enum's
    # comes back as its key.
    def model_default(model, name)
      return nil unless model.respond_to?(:_default_attributes) && defined?(ActiveModel::Attribute::UserProvidedDefault)

      attribute = model._default_attributes[name]
      return nil unless attribute.is_a?(ActiveModel::Attribute::UserProvidedDefault)
      return "computed by a Proc" if attribute.send(:user_provided_value).is_a?(Proc)

      attribute.value&.inspect
    end

    # A Rails enum stores an integer but is ASSIGNED its key: a form sends
    # "shipped", never 1, so drafting the column type (:integer) would reject
    # every legitimate request. The draft references the model's own
    # accessor rather than inlining today's keys, so adding a value to the
    # enum cannot leave the contract rejecting it.
    def enum_for(model, name)
      return nil unless model.respond_to?(:defined_enums)

      mapping = model.defined_enums[name]
      mapping && { mapping: mapping, accessor: "#{model.name}.#{name.pluralize}" }
    end

    # The role that makes a column dangerous for a client to write — :sti,
    # :locking, or nil. What the draft then does with it is column_line's
    # call, since that depends on whether the permit call lists it.
    def sensitive_role(model, name)
      # Only a model that actually uses STI: the inheritance column is set
      # (not nil) AND exists. Mass-assigning it changes which class the
      # record is loaded as — `type: "Admin"` on a signup form.
      return :sti if model.respond_to?(:inheritance_column) && model.inheritance_column.to_s == name

      :locking if locking_column?(model, name)
    end

    # Mirrors the STI check's respect for `inheritance_column = nil`: with
    # `self.lock_optimistically = false` Rails never reads or bumps the
    # column, so it is an ordinary integer and drafts as one.
    def locking_column?(model, name)
      return false unless model.respond_to?(:locking_column) && model.locking_column.to_s == name

      !model.respond_to?(:lock_optimistically) || model.lock_optimistically
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

    # One column's line in one rule — `column.rule` is :shared (a single
    # :create, :update rule), :create, or :update, which never requires
    # anything (see render). `column.listed` says the controller's own
    # permit call lists the column, which decides what a sensitive column
    # becomes.
    #
    # Names are emitted with Symbol#inspect, so a column called `first-name`
    # or `2fa_enabled` drafts as `:"first-name"` rather than as Ruby that
    # does not parse.
    def column_line(column)
      return "# TODO: #{column.name} #{omitted_note(column)}" if column.sensitive && !column.listed

      type = column.enum ? :string : COLUMN_TYPES[column.type]
      return "# TODO: #{column.name} (#{column.type}) has no contract type — declare it as a nested block or an array" unless type

      required = column.rule != :update && required_column?(column)
      line = "#{required ? 'required' : 'optional'} #{column.name.to_sym.inspect}, :#{type}"
      line += ", in: #{column.enum}.keys" if column.enum
      notes = [column.default, *column_todos(column)].compact
      notes.empty? ? line : "#{line} # #{notes.join('; ')}"
    end

    # Drafting from columns alone, a sensitive column is left out of the
    # fields — nothing says any client sends it — and named here instead.
    # The lock_version note says where to declare it in the rules actually
    # drafted: stale-update detection is an update's concern, so a split
    # :create rule points at the :update rule rather than at itself.
    def omitted_note(column)
      return STI_OMITTED if column.sensitive == :sti

      where = column.rule == :create ? "in the :update rule below" : "here"
      "is the optimistic-locking column — Rails increments it on every save; if your edit forms round-trip it " \
        "as a hidden field for stale-update detection, declare `optional #{column.name.to_sym.inspect}, :integer` #{where}"
    end

    STI_OMITTED = "is the STI inheritance column — assigning it changes the record's class, so no client should " \
                  "send it; if clients really pick the subclass, declare it with in: the allowed class names".freeze

    # The TODOs a drafted column line carries. A sensitive column the permit
    # call lists stays a field — omitting lock_version there would silently
    # switch off the stale-update detection the app wired up, the moment the
    # draft is enforced — but says why it deserves a second look.
    def column_todos(column)
      todos = []
      todos << "TODO: #{column.name} #{SCANNED_SENSITIVE.fetch(column.sensitive)}" if column.sensitive
      todos << enum_todo(column) if column.enum
      todos << unread_todo(column) if column.unread
      todos
    end

    SCANNED_SENSITIVE = {
      locking: "is the optimistic-locking column — kept because the permit call lists it: an edit form that " \
               "round-trips it is how Rails detects a stale update; never give it a default:",
      sti: "is the STI inheritance column — kept because the permit call lists it, but assigning it changes the " \
           "record's class: restrict it with in: the subclass names a client may pick"
    }.freeze

    # Rails assigns an enum its stored integer too (`status: 1` from a JSON
    # client), but a :string field passes that on as "1" — which in: rejects,
    # and which Rails' enum rejects as well, so admitting it also means mapping
    # it back to its key. Left as a TODO rather than drafted: forms, the
    # common client, send the key.
    def enum_todo(column)
      "TODO: Rails also assigns the stored integers (#{column.name}: 1) — if API clients send them, add " \
        "#{column.enum}.values.map(&:to_s) to in: and map them back to keys with transform:"
    end

    def unread_todo(column)
      "TODO: could not read what the model adds to #{column.name} (#{column.unread}) — check its enum, " \
        "default and STI/locking role by hand"
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
    # fields, every one optional.
    #
    # `lines` drafts the body for one rule (see DraftColumn#in_rule), so
    # each rule is drafted rather than edited from another's text. The
    # single-rule body and the :update body differ exactly when some column
    # was drafted `required`, which is the test for splitting.
    def render(root:, model:, &lines)
      shared = lines.call(:shared)
      update = lines.call(:update)
      rules = shared == update ? [[DEFAULT_ACTIONS, shared]] : [[%i[create], lines.call(:create)], [%i[update], update]]
      bodies = rules.map do |actions, body|
        "#{signature(root: root, model: model, actions: actions)}\n#{body.map { |line| "  #{line}\n" }.join}end\n"
      end
      HEADER + bodies.join("\n#{UPDATE_NOTE}")
    end
  end
end
