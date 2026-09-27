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
    # sends (`enum_integers` when it stores Integers), a default the model
    # fills in, or a `sensitive` role (:sti, :locking) that makes the column
    # dangerous to leave client-writable. `default` is the comment describing
    # whichever default applies, and `unread` the error that stopped the
    # model's enum and default from being read.
    # Building these once in columns_for keeps every drafting path (columns
    # alone, or a scan typed from columns) reading the same answers.
    #
    # `rule` and `listed` are how column_line is told what it is drafting
    # for: the rule (see render) and whether the controller's permit call
    # lists the column. They ride on the column, set by in_rule, so the scan
    # path hands them to column_line without its own methods changing.
    DraftColumn = Struct.new(:name, :type, :null, :default, :default_function, :enum, :enum_integers, :sensitive,
                             :unread, :rule, :listed, keyword_init: true) do
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
    # dropped. `conflicts` names each key permitted in more than one shape
    # (see resolve_conflicts), and `undecided` lists the keys among them
    # drafted as no shape at all. What parsed fine but belongs outside the
    # chosen root's contract is kept apart from `unparsed`, so its TODO can
    # say why: `route_params` holds what is never a body field (a single-key
    # expect lookup, and what an expect call spells beside its envelope);
    # `rootless` holds the keys of the rootless calls once an envelope won —
    # a filter or a body, the scan cannot tell; `other_envelopes` maps each
    # losing root onto its calls, spelled as the source spells them. `calls`
    # counts the params calls found.
    Scan = Struct.new(:root, :scalars, :arrays, :nested, :nested_arrays, :unparsed, :conflicts, :undecided,
                      :route_params, :rootless, :other_envelopes, :calls, keyword_init: true) do
      def found?
        calls.positive?
      end

      # Whether the chosen root's calls parsed into any field. A draft checks
      # its lines instead (Generator.declares_field?): a scanned key whose
      # column has no contract type is a field here but only a TODO there.
      def fields?
        [scalars, arrays, nested, nested_arrays].any? { |shape| !shape.empty? }
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
    # The lookahead skips whitespace itself: `\[\s*(?!...)` let `\s*` match
    # nothing and waved the spaced `tag_names: [ ]` through as an envelope
    # with no fields.
    EXPECT_ENVELOPE = /\A(\w+):\s*\[(?!\s*[\[\]])\s*(.*?)\s*\]\z/m

    # An envelope whose fields live in a constant: `post: PERMITTED_PARAMS`.
    # The fields cannot be read, but the root can, and read as a rootless
    # argument it let a `params.permit(:page)` beside it take the root.
    EXPECT_CONSTANT_ENVELOPE = /\A(\w+):\s*((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)\z/

    # The key of a single-key rootless EXPECT lookup that is a route param,
    # not input: the Rails 8 scaffold's `Post.find(params.expect(:id))`, or a
    # nested resource's `params.expect(:post_id)`. Only an expect call with
    # that one key counts: `params.expect(:id, :q)` is a filter that names an
    # id, and `params.permit(:group_id)` is mass assignment, not a lookup.
    ROUTE_PARAM_KEY = /\A(?:id|\w+_id)\z/

    # A permit key: `:name`, `"name"`, or `'name'` (quotes must match —
    # anything else stays unparsed rather than guessed).
    SCALAR_KEY = /\A(?::(\w+)|"(\w+)"|'(\w+)')\z/
    ARRAY_ARG  = /\A(\w+):\s*\[\s*\]\z/m
    NESTED_ARG = /\A(\w+):\s*\[([^\[\]]*)\]\z/m
    # expect-only: `comments: [[:body, :author]]` is an array of hashes.
    NESTED_ARRAY_ARG = /\A(\w+):\s*\[\s*\[([^\[\]]*)\]\s*\]\z/m

    # The shapes a scanned key can take, richest first, with how a conflict
    # TODO names each (see resolve_conflicts).
    SHAPES = {
      nested_arrays: "an array of hashes", nested: "a nested hash", arrays: "an array", scalars: "a scalar"
    }.freeze
    HASH_SHAPES = %i[nested nested_arrays].freeze

    # One params call, or one envelope of an expect call, at its offset in
    # the source. `route_params` are never body fields, whichever root wins:
    # the arguments an expect call spells beside its envelope, and the key of
    # a single-key route-param lookup (ROUTE_PARAM_KEY). `spelling` is how an
    # envelope's TODO quotes it if it loses.
    Call = Struct.new(:position, :root, :fields, :route_params, :spelling)
    private_constant :Call

    # Comment tokens. Ripper (stdlib) is used rather than a regexp because `#`
    # is only a comment sometimes — it also appears inside string literals and
    # `#{}` interpolation, and a permit call inside interpolation IS live code.
    # String CONTENT is deliberately kept: `permit("name")` is a supported
    # spelling, and its keys live in string tokens.
    COMMENT_TOKENS = %i[on_comment on_embdoc on_embdoc_beg on_embdoc_end].freeze

    # A string/heredoc/regexp literal's CONTENT, as opposed to the Ruby
    # syntax around it. Used by masked_source — see there for why this is
    # kept apart from comments rather than treated the same way.
    STRING_CONTENT_TOKENS = %i[on_tstring_content].freeze

    # What a masked string/heredoc/regexp content token's characters become,
    # except `(`/`)` (see mask_content): not a word character, so `params`,
    # `permit`, `require`, and `expect` can never spell out of it.
    MASK_CHAR = "\u0000".freeze

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
      tokens = code_tokens(source)
      return source unless tokens

      tokens.map { |token| token[2] }.join
    rescue StandardError
      source
    end

    # executable_source with every string/heredoc/regexp literal's CONTENT
    # run through mask_content, same length so a MatchData's offsets against
    # this text still locate the same characters in executable_source.
    #
    # A call spelled out as TEXT inside a string — a log line quoting
    # `params.require(:admin).permit(:superuser)` for humans — has no
    # `params`, `permit`, `require`, or `expect` left once masked, so
    # PERMIT_CALL and EXPECT_CALL can no longer match it there; the same
    # conflation as a `#` comment (see executable_source), just reached
    # through a string literal instead. A REAL call's own string argument
    # (`permit("name")`) still matches: `params`, `.`, `permit`, and the
    # parens around it are code tokens, never string content, so masking
    # never touches them — only the argument text inside the parens is
    # masked here, and scan reads that text back out of executable_source by
    # offset rather than off this string.
    def masked_source(source)
      tokens = code_tokens(source)
      return source unless tokens

      tokens.map { |token| STRING_CONTENT_TOKENS.include?(token[1]) ? mask_content(token[2]) : token[2] }.join
    rescue StandardError
      source
    end

    # One string/heredoc/regexp content token, masked: every character
    # becomes MASK_CHAR except `(`/`)`, which are left alone. Keeping parens
    # literal costs nothing PERMIT_CALL/EXPECT_CALL look for — the words
    # they require are gone either way — and keeps a call already open
    # before the string closing on the same paren it always did: a lenient
    # lex can swallow real code into an unterminated string's content, exactly
    # as a stray `"` does today (see the "mismatched quotes" scan spec), and
    # masking every character there would eat the `)` that call is
    # conservatively parsed with.
    def mask_content(text)
      text.gsub(/[^()]/, MASK_CHAR)
    end

    # The lexed tokens shared by executable_source and masked_source, with
    # comments already dropped — nil when Ripper could not lex `source` at
    # all, or found nothing.
    def code_tokens(source)
      tokens = Ripper.lex(source)
      return nil if tokens.nil? || tokens.empty?

      tokens.reject { |token| COMMENT_TOKENS.include?(token[1]) }
    end

    # Merge every `params.permit` and `params.expect` call found in the
    # EXECUTABLE part of `source` into one Scan, under one root (see
    # choose_root), matching how a controller normally sticks to one
    # envelope across actions. Comments are stripped first for both call shapes — a
    # commented-out `expect` is no more code than a commented-out `permit`.
    #
    # The root is chosen from ALL the calls before any field is merged,
    # because one rooted contract can express only one envelope. A Rails 8
    # scaffold's `Post.find(params.expect(:id))` in `set_post`, or an index
    # action's `params.permit(:page)`, sits beside `params.expect(post: [...])`
    # and is a route param or a filter, not a body field — merged in, it was
    # drafted as `optional :id` inside the `post` envelope. So only the chosen
    # root's calls become fields; another envelope, and a rootless call once
    # there is an envelope, stay visible as TODOs. A file of only rootless
    # calls is a filter contract and still drafts them as fields.
    #
    # The calls are read in SOURCE order, whichever spelling each uses:
    # scanning every permit call before every expect call made "first seen"
    # mean "first permit call", so a later search form could outrank the
    # expect envelope above it. The sort is made stable by the index, because
    # the envelopes of one expect call share a position and `sort_by` alone
    # may reorder them.
    #
    # `model:` names the envelope a Rails form for that model sends; see
    # choose_root. `exclude:` lists roots (nil for the rootless calls) that
    # may not be chosen — see for_controller.
    def scan(source, model: nil, exclude: [])
      result = Scan.new(root: nil, scalars: [], arrays: [], nested: {}, nested_arrays: {}, unparsed: [],
                        conflicts: [], undecided: [], route_params: [], rootless: [], other_envelopes: {}, calls: 0)
      raw = source.to_s
      source = executable_source(raw)
      masked = masked_source(raw)
      permits = matches(masked, PERMIT_CALL).map { |match| permit_call(source, match) }
      expects = matches(masked, EXPECT_CALL).map { |match| expect_calls(match.begin(0), split_args(group(source, match, 1))) }
      result.calls = permits.size + expects.size
      calls = (permits + expects).flatten.sort_by.with_index { |call, index| [call.position, index] }
      result.root = choose_root(calls, model&.name && default_root(model), exclude)
      calls.each { |call| merge_call(result, call) }
      resolve_conflicts(result)
      drop_drafted_todos(result)
      result
    end

    def matches(source, pattern)
      source.to_enum(:scan, pattern).map { Regexp.last_match }
    end

    # The real text under one of masked_source's MatchData groups, read back
    # out of `source` (executable_source, not masked_source) at the same
    # offsets — nil when the group did not participate in the match. See
    # masked_source for why a matched call's own text lives in `source`
    # rather than in the MatchData itself.
    def group(source, match, index)
      return nil unless match.begin(index)

      source[match.begin(index)...match.end(index)]
    end

    # Draft a contract for one controller: model inferred from
    # controller_name (or passed explicitly), permit calls scanned from
    # `source:` when given. Returns nil when there is nothing to draft from.
    #
    # When the chosen root cannot be drafted at all — the model's envelope
    # permits only a binary column, and the model has no column a contract
    # can declare — the next candidate root is tried rather than returning
    # nil, until one drafts or none is left: a draft rooted at the other
    # envelope in the file is a better starting point than no draft, and it
    # is what master drafted.
    def for_controller(controller, source: nil, model: nil)
      model ||= infer_model(controller)
      excluded = []
      loop do
        scan = scan(source, model: model, exclude: excluded)
        result = draft(model: model, scan: scan)
        return result if result || !scan.found? || excluded.include?(scan.root)

        excluded << scan.root
      end
    end

    # The core: knowledge in (columns and/or a scan), snippet out. Returns a
    # String of valid Ruby, or nil when neither source of knowledge exists —
    # or when neither can declare a single field, since a contract of only
    # TODO lines raises `a contract must declare at least one field` the
    # moment it is pasted.
    def draft(model: nil, scan: nil)
      columns = columns_for(model)
      scan = nil unless scan&.found?
      return nil unless columns || scan
      return column_draft(model, columns.values, []) unless scan

      shared = scanned_lines(scan, listed_columns(columns, :shared))
      return fallback_draft(model, scan, columns) unless declares_field?(shared)

      render(root: scan.root, model: columns && model) { |rule| scanned_lines(scan, listed_columns(columns, rule)) }
    end

    # The columns as one rule drafts them (see DraftColumn#in_rule), each
    # marked listed: on the scan path a column is drafted only because the
    # controller's own calls name it.
    def listed_columns(columns, rule)
      columns&.transform_values { |column| column.in_rule(rule, listed: true) }
    end

    # Whether any line declares a field. Scan#fields? cannot answer this
    # alone: a scanned key whose column has no contract type (binary,
    # geometry) drafts only a TODO.
    def declares_field?(lines)
      lines.any? { |line| !line.start_with?("#") }
    end

    # A scan that found calls but no fields — `permit(*PERMITTED)`, or every
    # call belonging to another envelope — drafted a contract with only TODO
    # lines, which raises `a contract must declare at least one field` the
    # moment it is pasted. The columns are the next best knowledge, so they
    # are drafted instead, with the scan's TODOs kept beneath them — minus
    # any column the scan's TODOs say is not drafted: a key permitted in
    # shapes that accept different input, and a route param.
    #
    # The scan's rootlessness is kept only when the rootless calls carried a
    # body field (see rootless_body?): a rootless `params.permit(*KEYS)`
    # controller drafted under the model's root would answer 400 to every
    # request it already serves once enforced. A "rootless" scan that found
    # only a route-param lookup — `Post.find(params.expect(:id))` beside a
    # `permit(policy(@post).permitted_attributes)` the scanner skips — says
    # nothing about the body, so it gets the model's root, as master drafted.
    # With no columns either there is nothing loadable to draft, so nil.
    def fallback_draft(model, scan, columns)
      return nil unless columns

      root = scan.root || (rootless_body?(scan) ? nil : default_root(model))
      undrafted = (Array(scan.undecided) + Array(scan.route_params).filter_map { |arg| scalar_key(arg) }).map(&:to_s)
      drafted = columns.except(*undrafted)
      # As in drop_drafted_todos: a rootless key the columns now declare is
      # not also a "not in this contract" TODO.
      scan = scan.dup.tap { |copy| copy.rootless = Array(scan.rootless).reject { |arg| drafted.key?(scalar_key(arg).to_s) } }
      column_draft(model, drafted.values, scan_todo_lines(scan), root: root)
    end

    # Whether a rootless scan's calls carried at least one body field —
    # parsed, unparsable, or permitted in conflicting shapes. Route-param
    # lookups are filed under `route_params`, not here.
    def rootless_body?(scan)
      scan.fields? || !scan.unparsed.empty? || !Array(scan.conflicts).empty?
    end

    # A draft from the columns, or nil when none of them has a contract type
    # to declare it with (render returns nil for a body of comments only).
    def column_draft(model, columns, todos, root: default_root(model))
      render(root: root, model: model) { |rule| column_lines(columns.map { |column| column.in_rule(rule) }) + todos }
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

    # The sensitive role is read OUTSIDE model_facts' rescue: it only
    # compares the column's name with the model's STI and locking settings,
    # and a failed enum or default read must not also make `type` or
    # `lock_version` client-writable.
    def draft_column(model, column)
      DraftColumn.new(name: column.name, type: column.type, null: column.null,
                      default_function: column.respond_to?(:default_function) && column.default_function,
                      sensitive: sensitive_role(model, column.name), **model_facts(model, column))
    end

    # What the model adds to one column. An error reading it degrades THAT
    # column to its database facts, with the error in a TODO — rather than
    # raising, which would abort permittable:generate for every controller
    # over one odd model, or dropping the column, which would hide it. The
    # message is squished because it lands in a one-line comment, where a
    # newline would end the comment and leave the draft unparseable.
    def model_facts(model, column)
      enum = enum_for(model, column.name)
      { enum: enum && enum[:accessor], enum_integers: enum && enum[:mapping].values.all?(Integer),
        default: default_note(model, column, enum) }
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
      declared = model_default(model, column.name, enum)
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
    # Proc default at once.
    #
    # The note is written from the default AS DECLARED (its private
    # `user_provided_value`, the same in 6.1–8.1), never from `value`:
    # casting runs the attribute type's code, which is the app's, and can
    # raise — `attribute :prefs, :json, default: {}` does. A Proc is not
    # called either: drafting must not run app code with side effects, and
    # today's value says nothing about tomorrow's. An enum default declared
    # by its stored value is shown as its key, like a database one.
    def model_default(model, name, enum)
      return nil unless model.respond_to?(:_default_attributes) && defined?(ActiveModel::Attribute::UserProvidedDefault)

      attribute = model._default_attributes[name]
      return nil unless attribute.is_a?(ActiveModel::Attribute::UserProvidedDefault)

      declared = attribute.send(:user_provided_value)
      return "computed by a Proc" if declared.is_a?(Proc)
      return nil if declared.nil?

      declared = enum[:mapping].key(declared) || declared if enum
      default_literal(declared)
    end

    # How a declared default reads in a comment: strings and Symbols (an
    # enum key given as `:pending`) quoted, numbers and times as people
    # write them — `1.5` rather than BigDecimal's `0.15e1`. Anything else is
    # inspected and squished, since the note must stay on one line.
    def default_literal(value)
      case value
      when String, Symbol then value.to_s.inspect
      when BigDecimal then value.to_s("F")
      when Numeric then value.to_s
      else value.respond_to?(:strftime) ? value.to_s : value.inspect.squish
      end
    end

    # A Rails enum stores an integer but is ASSIGNED its key: a form sends
    # "shipped", never 1, so drafting the column type (:integer) would reject
    # every legitimate request. The draft references the model's own
    # accessor rather than inlining today's keys, so adding a value to the
    # enum cannot leave the contract rejecting it.
    #
    # Rails defines the accessor for any enum name, but only an identifier
    # can be CALLED as `Model.name`: a `first-status` enum's
    # `Order.first-statuses.keys` parses as `Order.first - statuses.keys`,
    # which runs a query when the draft loads. defined_enums reaches the
    # same mapping by name.
    def enum_for(model, name)
      return nil unless model.respond_to?(:defined_enums)

      mapping = model.defined_enums[name]
      return nil unless mapping

      plural = name.pluralize
      accessor = METHOD_NAME.match?(plural) ? "#{model.name}.#{plural}" : "#{model.name}.defined_enums[#{name.inspect}]"
      { mapping: mapping, accessor: accessor }
    end

    METHOD_NAME = /\A[a-z_][a-zA-Z0-9_]*\z/

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

    # An expect call's arguments, as one Call per envelope. The bracketed
    # arguments are required root envelopes and their contents are fields.
    # Plain symbols are fields only when there is no envelope
    # (`params.expect(:q, :page)` is a rootless filter); alongside one they
    # are route params rather than body fields, so they stay visible instead
    # of being drafted as contract fields. Each envelope is its own candidate
    # root: `expect(post: [...], comment: [...])` can be where the comment
    # contract's fields live, and reading only the first envelope hid them.
    def expect_calls(position, args)
      envelopes, others = args.partition { |arg| envelope(arg) }
      return [expect_rootless_call(position, others)] if envelopes.empty?

      envelopes.each_with_index.map do |arg, index|
        root, fields = envelope(arg)
        Call.new(position, root, fields, index.zero? ? others : [], unparsed_arg(arg))
      end
    end

    # An expect argument as `[root, fields]` when it is an envelope, else nil.
    # A constant envelope's one "field" is the constant, kept as unparsable.
    def envelope(arg)
      if (match = EXPECT_ENVELOPE.match(arg))
        [match[1].to_sym, split_args(match[2])]
      elsif (match = EXPECT_CONSTANT_ENVELOPE.match(arg))
        [match[1].to_sym, [match[2]]]
      end
    end

    # A rooted permit call is quoted as the call itself, on one line, so its
    # TODO can be found in the source it came from. `source` is
    # executable_source: `match` was found by scanning masked_source, whose
    # own text may hold placeholders rather than a real string argument's
    # characters (see masked_source), so every group is read back out of
    # `source` by position instead of off `match` directly.
    def permit_call(source, match)
      args = split_args(group(source, match, 2))
      root = group(source, match, 1)
      return Call.new(match.begin(0), nil, args, []) unless root

      spelling = unparsed_arg(group(source, match, 0)).gsub(/\(\s+/, "(").gsub(/\s+\)/, ")")
      Call.new(match.begin(0), root.to_sym, args, [], spelling)
    end

    # A rootless expect call — or, when its one key is a route param
    # (ROUTE_PARAM_KEY), a lookup with no fields at all, so it can neither
    # score toward the root nor be drafted as a field when the rootless calls
    # win.
    def expect_rootless_call(position, args)
      route = args.size == 1 && (key = scalar_key(args.first)) && ROUTE_PARAM_KEY.match?(key.to_s)
      route ? Call.new(position, nil, [], args) : Call.new(position, nil, args, [])
    end

    # The model's own envelope wins outright when one of the calls uses it
    # (`preferred`, derived like default_root): it is the envelope a Rails
    # form for the model sends, and the only way to root a
    # `require(:post).permit(*PERMITTED)` that has no field to score with.
    #
    # With no model to say which envelope is the form's, an envelope with a
    # parsed field beats the rootless calls, as any envelope always did: an
    # index action's `params.permit(:page, :per_page)` must not take the root
    # from a one-field `post_params` on a guess. An envelope with NO parsed
    # field — `expect(search: FILTERS)` — only beats rootless calls that have
    # none either: beside `params.permit(:title, :body)` it would root a draft
    # with nothing to declare, where master drafted title and body.
    #
    # Otherwise the candidate — an envelope, or, with a model that no
    # envelope matches, the rootless calls together (root nil) — declaring
    # the most distinct PARSED fields across its calls wins. Now that
    # the losers become TODOs rather than fields, "first seen" alone let an
    # index action's `require(:search).permit(:q)` win the root and push the
    # real `expect(post: [...])` into a TODO; and considering envelopes only
    # let that same search form beat a rootless `params.permit(:title, :body,
    # :published)` carrying the whole create body. Unparsable arguments
    # (`*PERMITTED`) count for nothing: they are not fields the draft can
    # declare.
    #
    # A tie goes to an envelope, then to the first seen in the source. The
    # envelope wins a tie because a rootless key beside one is usually a
    # route or query param: a one-field Rails 8 scaffold calls
    # `params.expect(:id)` in `set_post` above `params.expect(post: [:title])`.
    def choose_root(calls, preferred = nil, exclude = [])
      calls = calls.reject { |call| exclude.include?(call.root) }
      return preferred if preferred && calls.any? { |call| call.root == preferred }

      scores = calls.group_by(&:root).transform_values do |same|
        same.flat_map { |call| call.fields.filter_map { |arg| parse_arg(arg)&.at(1) } }.uniq.size
      end
      scores = envelopes_first(scores) unless preferred
      best = scores.each_with_index.max_by { |(root, score), index| [score, root ? 1 : 0, -index] }
      best&.first&.first
    end

    # The model-less rule above: the rootless candidate is dropped when an
    # envelope has a parsed field, or when it has none itself.
    def envelopes_first(scores)
      envelopes = scores.except(nil)
      return scores if envelopes.empty?

      envelopes.values.max.positive? || scores.fetch(nil, 0).zero? ? envelopes : scores
    end

    # Fold one call into the scan: its fields when it shares the scan's root
    # (including both having none), a TODO otherwise — its arguments filed
    # under its own root, or as rootless keys, so the TODO says where they
    # belong rather than that they could not be read.
    def merge_call(result, call)
      if call.root == result.root
        call.fields.each { |arg| classify_arg(result, arg) }
      elsif call.root
        result.other_envelopes[call.root] = (result.other_envelopes[call.root] || []) | [call.spelling]
      else
        result.rootless |= call.fields.map { |arg| unparsed_arg(arg) }
      end
      result.route_params |= call.route_params.map { |arg| unparsed_arg(arg) }
    end

    # A key the winning root drafts as a field is not also a TODO: beside
    # `expect(post: [:title, :group_id])`, a `Group.find(params.expect(:group_id))`
    # lookup or a rootless `params.permit(:group_id)` would otherwise say
    # "not a body field" about a field the draft declares. Only a bare key is
    # dropped: a shaped copy (`tags: [:z]` beside the envelope's `tags: [:a]`)
    # may carry sub-keys the drafted field lacks, and dropping its TODO would
    # lose them.
    def drop_drafted_todos(result)
      drafted = SHAPES.keys.flat_map { |shape| shape_keys(result, shape) }
      %i[route_params rootless].each do |member|
        result[member] = result[member].reject { |arg| drafted.include?(scalar_key(arg)) }
      end
    end

    # A key permitted in two shapes across actions is declared once — a
    # contract rejects a field declared twice — and how depends on whether
    # one shape accepts what the other is sent:
    #
    # - a nested hash and an array of hashes merge into the array of hashes,
    #   with the sub-keys of both: `key: [[:a]]` is expect's definitive
    #   spelling of the array of hashes that `key: [:a]` leaves ambiguous,
    #   and dropping the loser's sub-keys would reject the ones its action
    #   sends;
    # - an array of scalars and either hash shape accept disjoint input, so
    #   neither is drafted — picking one would reject what the other action
    #   sends — and the TODO names both;
    # - anything else goes to the richer shape (SHAPES is ordered richest
    #   first), the one at least one action demonstrably accepts: a scalar
    #   declaration would reject the hash or array that action is sent.
    def resolve_conflicts(result)
      SHAPES.keys.flat_map { |shape| shape_keys(result, shape) }.uniq.each do |key|
        shapes = SHAPES.keys.select { |shape| shape_keys(result, shape).include?(key) }
        next if shapes.size < 2

        result.conflicts << resolve_conflict(result, key, shapes)
      end
    end

    def resolve_conflict(result, key, shapes)
      merged = (HASH_SHAPES - shapes).empty?
      result.nested_arrays[key] |= result.nested[key] if merged
      if shapes.include?(:arrays) && shapes.intersect?(HASH_SHAPES)
        shapes.each { |shape| result[shape].delete(key) }
        result.undecided << key
        return "#{key} is permitted as #{listed_shapes(shapes)}, which accept different input — " \
               "drafted as #{shapes.size == 2 ? 'neither' : 'none of them'}; declare the shape its actions share"
      end

      shapes.drop(1).each { |shape| result[shape].delete(key) }
      "#{key} is permitted as #{listed_shapes(shapes)} — drafted as #{the_shape(shapes.first)}" \
        "#{merge_note(shapes) if merged}"
    end

    # A merge keeps the nested hash's sub-keys, so only a scalar is dropped.
    def merge_note(shapes)
      " with the nested hash's sub-keys merged in#{', dropping the scalar' if shapes.include?(:scalars)}"
    end

    def the_shape(shape)
      SHAPES[shape].sub(/\Aan? /, "the ")
    end

    def shape_keys(result, shape)
      keys = result[shape]
      keys.is_a?(Hash) ? keys.keys : keys
    end

    # "both a scalar and an array", "a scalar, a nested hash and an array of
    # hashes" — poorest first.
    def listed_shapes(shapes)
      names = shapes.reverse.map { |shape| SHAPES[shape] }
      names.size == 2 ? "both #{names.join(' and ')}" : "#{names[0..-2].join(', ')} and #{names.last}"
    end

    def classify_arg(result, arg)
      shape, key, sub_keys = parse_arg(arg)
      if shape.nil?
        result.unparsed |= [unparsed_arg(arg)]
      elsif sub_keys
        result[shape][key] = (result[shape][key] || []) | sub_keys
      else
        result[shape] |= [key]
      end
    end

    # One permit argument as `[shape, key]`, or `[shape, key, sub_keys]` for
    # the two hash shapes — nil when the conservative parser cannot read it,
    # including a nested list with any sub-key it cannot read.
    def parse_arg(arg)
      if (key = scalar_key(arg))
        [:scalars, key]
      elsif (match = ARRAY_ARG.match(arg))
        [:arrays, match[1].to_sym]
      elsif (match = NESTED_ARRAY_ARG.match(arg))
        nested_arg(:nested_arrays, match)
      elsif (match = NESTED_ARG.match(arg))
        nested_arg(:nested, match)
      end
    end

    # An empty list (`meta: [[ ]]`, `meta: [ , ]`) is unparsable too: it
    # would draft a `do end` block, which the DSL rejects.
    def nested_arg(shape, match)
      sub_keys = split_args(match[2]).map { |part| scalar_key(part) }
      [shape, match[1].to_sym, sub_keys] unless sub_keys.empty? || sub_keys.any?(&:nil?)
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
      todos << enum_todo(column) if column.enum_integers
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
    # common client, send the key. Only for an enum that stores Integers — a
    # string-backed one has no second spelling to admit.
    def enum_todo(column)
      "TODO: Rails also assigns the stored integers (#{column.name}: 1) — if API clients send them, add " \
        "#{column.enum}.values.map(&:to_s) to in: and map them back to keys with transform:"
    end

    def unread_todo(column)
      "TODO: could not read what the model adds to #{column.name} (#{column.unread}) — check its enum and " \
        "default by hand"
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

    # Scanned names are emitted with Symbol#inspect, not as `:#{name}`: a
    # string-keyed `permit("2fa")` scans to a name that is not a bare symbol
    # literal, and `:2fa` would make the whole draft a SyntaxError.
    def scanned_lines(scan, columns)
      lines = scan.scalars.map { |name| scanned_scalar_line(name, columns) }
      lines += scan.arrays.map do |name|
        "array #{name.to_sym.inspect}, of: :string " \
          "# TODO: confirm the element type, and declare length: — an array without one is unbounded"
      end
      scan.nested.each { |name, keys| lines += nested_lines(name, keys) }
      scan.nested_arrays.each { |name, keys| lines += nested_array_lines(name, keys) }
      lines + scan_todo_lines(scan)
    end

    # Each TODO says why the scan did not draft it: a parsed argument that
    # belongs outside this contract is not one the parser failed to read.
    def scan_todo_lines(scan)
      # Array()/to_h: a Scan built by hand before these members existed leaves them nil.
      Array(scan.conflicts).map { |conflict| "# TODO: #{conflict}" } +
        scan.unparsed.map { |arg| "# TODO: could not parse from the permit call: #{arg}" } +
        scan.other_envelopes.to_h.flat_map do |root, spellings|
          spellings.map { |spelling| "# TODO: belongs to another envelope (#{root}): #{spelling}" }
        end +
        Array(scan.route_params).map { |arg| route_param_todo(scan, arg) } +
        Array(scan.rootless).map { |arg| "# TODO: outside the #{scan.root} envelope, so not in this contract: #{arg}" }
    end

    # Only a bare key is a route or query param; an array or hash an expect
    # call spells beside its envelope is body input this root cannot reach.
    # A rootless call's keys (`rootless`) get the neutral wording whatever
    # their shape: beside an envelope they may be a filter or a whole body.
    def route_param_todo(scan, arg)
      return "# TODO: route or query param, not a body field: #{arg}" if scalar_key(arg)
      return "# TODO: outside the #{scan.root} envelope, so not in this contract: #{arg}" if scan.root

      "# TODO: sent beside another envelope, so not in this contract: #{arg}"
    end

    def scanned_scalar_line(name, columns)
      column = columns && columns[name.to_s]
      return column_line(column) if column

      field = "optional #{name.to_sym.inspect}, :string"
      return "#{field}, virtual: true # TODO: not a database column — confirm the type" if columns

      "#{field} # TODO: confirm the type"
    end

    def nested_lines(name, keys)
      ["optional #{name.to_sym.inspect} do # TODO: drafted from `#{name}: [...]` — " \
       "if this is an array of hashes, use `array #{name.to_sym.inspect} do`"] +
        sub_field_lines(keys) +
        ["end"]
    end

    # No TODO on the kind here, unlike nested_lines: `params.expect` spells an
    # array of hashes `#{name}: [[...]]`, which says definitively what the
    # equivalent permit call (`#{name}: [...]`) leaves ambiguous.
    def nested_array_lines(name, keys)
      ["array #{name.to_sym.inspect} do"] + sub_field_lines(keys) + ["end"]
    end

    def sub_field_lines(keys)
      keys.map { |key| "  optional #{key.to_sym.inspect}, :string # TODO: confirm the type" }
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
    #
    # Every drafted line is a declaration or a `# TODO` comment. A body of
    # comments only — a model whose sole columns are `type` and
    # `lock_version`, or have no contract type — would be a rule declaring
    # no field, which raises `a contract must declare at least one field`
    # when pasted. There is then nothing loadable to draft: nil, as for no
    # knowledge at all, which the rake task already skips.
    def render(root:, model:, &lines)
      shared = lines.call(:shared)
      return nil if shared.all? { |line| line.start_with?("#") }

      update = lines.call(:update)
      rules = shared == update ? [[DEFAULT_ACTIONS, shared]] : [[%i[create], lines.call(:create)], [%i[update], update]]
      bodies = rules.map do |actions, body|
        "#{signature(root: root, model: model, actions: actions)}\n#{body.map { |line| "  #{line}\n" }.join}end\n"
      end
      HEADER + bodies.join("\n#{UPDATE_NOTE}")
    end
  end
end
