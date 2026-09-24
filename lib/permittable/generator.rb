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
    # (see resolve_conflicts). What parsed fine but belongs outside the
    # chosen root's contract is kept apart from `unparsed`, so its TODO can
    # say why: `rootless` holds the keys of a rootless call once an envelope
    # won (a route or query param), `other_envelopes` maps each losing root
    # onto its arguments. `calls` counts the params calls found.
    Scan = Struct.new(:root, :scalars, :arrays, :nested, :nested_arrays, :unparsed, :conflicts,
                      :rootless, :other_envelopes, :calls, keyword_init: true) do
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

    # The key of a single-key rootless lookup that is a route param, not
    # input: the Rails 8 scaffold's `Post.find(params.expect(:id))`, or a
    # nested resource's `params.expect(:post_id)`. Only a call with that one
    # key counts — `params.permit(:id, :q)` is a filter that names an id.
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
    # a single-key route-param lookup (ROUTE_PARAM_KEY).
    Call = Struct.new(:position, :root, :fields, :route_params)
    private_constant :Call

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
    # choose_root.
    def scan(source, model: nil)
      result = Scan.new(root: nil, scalars: [], arrays: [], nested: {}, nested_arrays: {}, unparsed: [],
                        conflicts: [], rootless: [], other_envelopes: {}, calls: 0)
      source = executable_source(source.to_s)
      permits = matches(source, PERMIT_CALL).map { |match| permit_call(match) }
      expects = matches(source, EXPECT_CALL).map { |match| expect_calls(match.begin(0), split_args(match[1])) }
      result.calls = permits.size + expects.size
      calls = (permits + expects).flatten.sort_by.with_index { |call, index| [call.position, index] }
      result.root = choose_root(calls, model&.name && default_root(model))
      calls.each { |call| merge_call(result, call) }
      resolve_conflicts(result)
      result
    end

    def matches(source, pattern)
      source.to_enum(:scan, pattern).map { Regexp.last_match }
    end

    # Draft a contract for one controller: model inferred from
    # controller_name (or passed explicitly), permit calls scanned from
    # `source:` when given. Returns nil when there is nothing to draft from.
    def for_controller(controller, source: nil, model: nil)
      model ||= infer_model(controller)
      draft(model: model, scan: scan(source, model: model))
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

      body = scanned_lines(scan, columns)
      return fallback_draft(model, scan, columns) unless declares_field?(body)

      render(signature(root: scan.root, model: columns && model), body)
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
    # are drafted instead, with the scan's TODOs kept beneath them. The scan's
    # rootness is kept too: a rootless `params.permit(*KEYS)` controller
    # drafted under the model's root would answer 400 to every request it
    # already serves once the contract is enforced. With no columns either
    # there is nothing loadable to draft, so nil, as for no knowledge at all.
    def fallback_draft(model, scan, columns)
      return nil unless columns

      column_draft(model, columns.values, scan_todo_lines(scan), root: scan.root)
    end

    # A draft from the columns, or nil when none of them has a contract type
    # to declare it with.
    def column_draft(model, columns, todos, root: default_root(model))
      lines = column_lines(columns)
      declares_field?(lines) ? render(signature(root: root, model: model), lines + todos) : nil
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
      return [rootless_call(position, others)] if envelopes.empty?

      envelopes.each_with_index.map do |arg, index|
        root, fields = envelope(arg)
        Call.new(position, root, fields, index.zero? ? others : [])
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

    def permit_call(match)
      args = split_args(match[2])
      match[1] ? Call.new(match.begin(0), match[1].to_sym, args, []) : rootless_call(match.begin(0), args)
    end

    # A rootless call — or, when its one key is a route param
    # (ROUTE_PARAM_KEY), a lookup with no fields at all, so it can neither
    # score toward the root nor be drafted as a field when the rootless calls
    # win.
    def rootless_call(position, args)
      route = args.size == 1 && (key = scalar_key(args.first)) && ROUTE_PARAM_KEY.match?(key.to_s)
      route ? Call.new(position, nil, [], args) : Call.new(position, nil, args, [])
    end

    # The candidate — an envelope, or the rootless calls together (root nil)
    # — declaring the most distinct PARSED fields across its calls. Now that
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
    #
    # Before any of that, the model's own envelope wins outright when one of
    # the calls uses it (`preferred`, derived like default_root): it is the
    # envelope a Rails form for the model sends, and the only way to root a
    # `require(:post).permit(*PERMITTED)` that has no field to score with.
    def choose_root(calls, preferred = nil)
      return preferred if preferred && calls.any? { |call| call.root == preferred }

      candidates = calls.group_by(&:root)
      best = candidates.each_with_index.max_by do |(root, same), index|
        [same.flat_map { |call| call.fields.filter_map { |arg| parse_arg(arg)&.at(1) } }.uniq.size, root ? 1 : 0, -index]
      end
      best&.first&.first
    end

    # Fold one call into the scan: its fields when it shares the scan's root
    # (including both having none), a TODO otherwise — its arguments filed
    # under its own root, or as rootless keys, so the TODO says where they
    # belong rather than that they could not be read.
    def merge_call(result, call)
      if call.root == result.root
        call.fields.each { |arg| classify_arg(result, arg) }
      elsif call.root
        envelope = result.other_envelopes[call.root] || []
        result.other_envelopes[call.root] = envelope | call.fields.map { |arg| unparsed_arg(arg) }
      else
        result.rootless |= call.fields.map { |arg| unparsed_arg(arg) }
      end
      result.rootless |= call.route_params.map { |arg| unparsed_arg(arg) }
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
      return "# TODO: #{column.name} (#{column.type}) has no contract type — declare it as a nested block or an array" unless type

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
        scan.other_envelopes.to_h.map do |root, args|
          "# TODO: belongs to another envelope (#{root}): #{root}: [#{args.join(', ')}]"
        end +
        Array(scan.rootless).map { |arg| rootless_todo(scan, arg) }
    end

    # Only a bare key outside the envelope is a route or query param; an
    # array or hash there is body input this contract's root cannot reach.
    def rootless_todo(scan, arg)
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

    def render(signature, body)
      "#{HEADER}#{signature}\n#{body.map { |line| "  #{line}\n" }.join}end\n"
    end
  end
end
