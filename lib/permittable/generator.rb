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
    # dropped. `conflicts` names each key permitted in more than one shape,
    # which is drafted once, in its richest shape (see SHAPES).
    Scan = Struct.new(:root, :scalars, :arrays, :nested, :nested_arrays, :unparsed, :conflicts, :calls,
                      keyword_init: true) do
      def found?
        calls.positive?
      end

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

    # A permit key: `:name`, `"name"`, or `'name'` (quotes must match —
    # anything else stays unparsed rather than guessed).
    SCALAR_KEY = /\A(?::(\w+)|"(\w+)"|'(\w+)')\z/
    ARRAY_ARG  = /\A(\w+):\s*\[\s*\]\z/m
    NESTED_ARG = /\A(\w+):\s*\[([^\[\]]*)\]\z/m
    # expect-only: `comments: [[:body, :author]]` is an array of hashes.
    NESTED_ARRAY_ARG = /\A(\w+):\s*\[\s*\[([^\[\]]*)\]\s*\]\z/m

    # The shapes a scanned key can take, richest first, with how a conflict
    # TODO names each. A key seen in two shapes across actions is declared
    # once — a contract rejects a field declared twice — in the richest one,
    # because that is the shape at least one action demonstrably accepts: a
    # scalar declaration would reject the hash or array that action is sent,
    # `key: [:a]` names sub-keys where `key: []` names none, and `key: [[:a]]`
    # is expect's definitive spelling of the array of hashes that `key: [:a]`
    # leaves ambiguous.
    SHAPES = {
      nested_arrays: "an array of hashes", nested: "a nested hash", arrays: "an array", scalars: "a scalar"
    }.freeze

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
    def scan(source)
      result = Scan.new(root: nil, scalars: [], arrays: [], nested: {}, nested_arrays: {},
                        unparsed: [], conflicts: [], calls: 0)
      source = executable_source(source.to_s)
      calls = source.scan(PERMIT_CALL).map { |root, args| [root&.to_sym, split_args(args), []] }
      # One capture group, so scan yields a one-element Array rather than
      # auto-splatting the way PERMIT_CALL's two groups do.
      calls += source.scan(EXPECT_CALL).map { |(args)| expect_call(split_args(args)) }
      result.calls = calls.size
      result.root = choose_root(calls)
      calls.each { |root, fields, extras| merge_call(result, root, fields, extras) }
      resolve_conflicts(result)
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

      return fallback_draft(model, scan, columns) if scan && !scan.fields?

      root = scan ? scan.root : default_root(model)
      body = scan ? scanned_lines(scan, columns) : column_lines(columns.values)
      render(signature(root: root, model: columns && model), body)
    end

    # A scan that found calls but no fields — `permit(*PERMITTED)`, or every
    # call belonging to another envelope — drafted a contract with only TODO
    # lines, which raises `a contract must declare at least one field` the
    # moment it is pasted. The columns are the next best knowledge, so they
    # are drafted instead, with the scan's TODOs kept beneath them and its
    # root preferred to the model's. With no columns either there is nothing
    # loadable to draft, so nil, as for no knowledge at all.
    def fallback_draft(model, scan, columns)
      return nil unless columns

      root = scan.root || default_root(model)
      render(signature(root: root, model: model), column_lines(columns.values) + scan_todo_lines(scan))
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

    # An expect call's arguments, as `[root, fields, extras]`. The bracketed
    # argument is the required root envelope and its contents are the fields.
    # Plain symbols are fields only when there is no envelope
    # (`params.expect(:q, :page)` is a rootless filter); alongside one they
    # are route params rather than body fields, so they stay visible instead
    # of being drafted as contract fields — as does a second envelope, which
    # belongs under a different root than one rooted contract can express.
    def expect_call(args)
      envelopes, others = args.partition { |arg| EXPECT_ENVELOPE.match?(arg) }
      return [nil, others, []] if envelopes.empty?

      match = EXPECT_ENVELOPE.match(envelopes.first)
      [match[1].to_sym, split_args(match[2]), envelopes.drop(1) + others]
    end

    # The envelope declaring the most fields across its calls, the first seen
    # on a tie. Now that the losing envelopes become TODOs rather than
    # fields, "first seen" alone would let an index action's
    # `require(:search).permit(:q)` win the root and push the real
    # `expect(post: [...])` into a TODO.
    def choose_root(calls)
      rooted = calls.select(&:first).group_by(&:first)
      best = rooted.each_with_index.max_by { |(_, same), index| [same.sum { |call| call[1].size }, -index] }
      best&.first&.first
    end

    # Fold one call into the scan: its fields when it shares the scan's root
    # (including both having none), a TODO otherwise. Another root's call is
    # kept in expect's `root: [...]` spelling, so the TODO says which envelope
    # its fields belong to.
    def merge_call(result, root, fields, extras)
      if root == result.root
        fields.each { |arg| classify_arg(result, arg) }
      else
        extras = (root ? ["#{root}: [#{fields.join(', ')}]"] : fields) + extras
      end
      extras.each { |arg| result.unparsed |= [unparsed_arg(arg)] }
    end

    # Keep each key in its richest shape only (SHAPES is ordered richest
    # first) and name every key dropped from a poorer one.
    def resolve_conflicts(result)
      SHAPES.each_key.with_index do |winner, index|
        shape_keys(result, winner).each do |key|
          losers = SHAPES.keys.drop(index + 1).select { |shape| shape_keys(result, shape).include?(key) }
          next if losers.empty?

          losers.each { |shape| result[shape].delete(key) }
          result.conflicts << conflict_message(key, winner, losers)
        end
      end
    end

    def shape_keys(result, shape)
      keys = result[shape]
      keys.is_a?(Hash) ? keys.keys : keys
    end

    # "tags is permitted as both a scalar and an array — drafted as the array"
    def conflict_message(key, winner, losers)
      shapes = (losers.reverse + [winner]).map { |shape| SHAPES[shape] }
      listed = shapes.size == 2 ? "both #{shapes.join(' and ')}" : "#{shapes[0..-2].join(', ')} and #{shapes.last}"
      "#{key} is permitted as #{listed} — drafted as #{SHAPES[winner].sub(/\Aan? /, 'the ')}"
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

    def scanned_lines(scan, columns)
      lines = scan.scalars.map { |name| scanned_scalar_line(name, columns) }
      lines += scan.arrays.map do |name|
        "array :#{name}, of: :string # TODO: confirm the element type, and declare length: — an array without one is unbounded"
      end
      scan.nested.each { |name, keys| lines += nested_lines(name, keys) }
      scan.nested_arrays.each { |name, keys| lines += nested_array_lines(name, keys) }
      lines + scan_todo_lines(scan)
    end

    def scan_todo_lines(scan)
      # Array(): a Scan built by hand before `conflicts` existed leaves it nil.
      Array(scan.conflicts).map { |conflict| "# TODO: #{conflict}" } +
        scan.unparsed.map { |arg| "# TODO: could not parse from the permit call: #{arg}" }
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

    def render(signature, body)
      "#{HEADER}#{signature}\n#{body.map { |line| "  #{line}\n" }.join}end\n"
    end
  end
end
