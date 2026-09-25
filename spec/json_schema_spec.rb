RSpec.describe Permittable::JsonSchema do
  def rule_for(**opts, &contract)
    klass = Class.new(FakeController) { include Permittable }
    klass.permit_params(:create, **opts, &contract)
    klass.permit_rule_for(:create)
  end

  def schema_for(**opts, &contract)
    described_class.rule(rule_for(**opts, &contract))
  end

  def property(name, **opts, &contract)
    schema_for(**opts, &contract)["properties"][name]
  end

  def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  after { Permittable.filter_parameter_registry.reset! }

  describe "scalar types" do
    it "maps every scalar type onto its canonical JSON encoding" do
      props = schema_for do
        optional :s,   :string
        optional :i,   :integer
        optional :f,   :float
        optional :d,   :decimal
        optional :b,   :boolean
        optional :day, :date
        optional :at,  :datetime
      end["properties"]
      expect(props["s"]).to eq("type" => "string")
      expect(props["i"]).to eq("type" => "integer")
      expect(props["f"]).to eq("type" => "number")
      expect(props["d"]).to eq("type" => %w[string number], "format" => "decimal")
      expect(props["b"]).to eq("type" => "boolean")
      expect(props["day"]).to eq("type" => "string", "format" => "date")
      expect(props["at"]).to eq("type" => "string", "format" => "date-time")
    end
  end

  describe "required and absence semantics" do
    it "collects required fields and gives required strings minLength 1 (empty string is absent)" do
      schema = schema_for do
        required :name, :string
        optional :note, :string
      end
      expect(schema["required"]).to eq(["name"])
      expect(schema["properties"]["name"]["minLength"]).to eq(1)
      expect(schema["properties"]["note"]).not_to have_key("minLength")
    end

    it "raises the required-string floor above a length: minimum of zero" do
      prop = property("name") { required :name, :string, length: 0..10 }
      expect(prop["minLength"]).to eq(1)
      expect(prop["maxLength"]).to eq(10)
    end
  end

  describe "length:" do
    it "maps a Range, an exact Integer, and an exclusive Range onto min/maxLength" do
      expect(property("a") { optional :a, :string, length: 2..5 }).to include("minLength" => 2, "maxLength" => 5)
      expect(property("a") { optional :a, :string, length: 4 }).to include("minLength" => 4, "maxLength" => 4)
      expect(property("a") { optional :a, :string, length: 1...10 }).to include("maxLength" => 9)
    end
  end

  describe "in:" do
    it "maps an Array to enum and a numeric Range to minimum/maximum (exclusive end honoured)" do
      expect(property("plan") { optional :plan, :string, in: %w[free pro] }["enum"]).to eq(%w[free pro])
      expect(property("age") { optional :age, :integer, in: 18..120 }).to include("minimum" => 18, "maximum" => 120)
      expect(property("pct") { optional :pct, :integer, in: 0...100 }).to include("minimum" => 0, "exclusiveMaximum" => 100)
    end

    # The enum is built from the members as the RUNTIME holds them — cast by
    # the field's own type at class load — so it cannot advertise a value the
    # server refuses, nor publish "1" for a field whose JSON type is integer.
    it "exports the cast members, in the field's own JSON type" do
      expect(property("status") { optional :status, :string, in: %i[draft published] }["enum"]).to eq(%w[draft published])
      expect(property("n") { optional :n, :integer, in: %w[1 2 3] }["enum"]).to eq([1, 2, 3])
      expect(property("day") { optional :day, :date, in: [Date.new(2026, 9, 5)] }["enum"]).to eq(["2026-09-05"])
      expect(property("status") { optional :status, :string, in: { draft: 0, published: 1 } }["enum"]).to eq(%w[draft published])
    end

    # Re-encoding a cast Time drops what iso8601 does not print: a member
    # written with fractional seconds exported as the whole second, which
    # the server then refused. A String member is therefore published as
    # written, and every published member must be one the server accepts.
    it "exports a String-authored :date/:datetime member as written, and the server accepts each one" do
      contract = Permittable::Contract.define do
        optional :at,  :datetime, in: ["2026-09-05T10:00:00.25Z", "2026-09-05T15:00:00+05:00", Time.utc(2026, 1, 1)]
        optional :day, :date,     in: ["Sep 5, 2026", Date.new(2026, 9, 6)]
      end
      props = described_class.rule(contract.permittable_contracts.first)["properties"]
      expect(props["at"]["enum"]).to eq(["2026-09-05T10:00:00.25Z", "2026-09-05T15:00:00+05:00", "2026-01-01T00:00:00Z"])
      expect(props["day"]["enum"]).to eq(["Sep 5, 2026", "2026-09-06"])
      props.each do |name, schema|
        schema["enum"].each do |member|
          expect(contract.call(name => member).violations).to be_empty, "#{name}: #{member.inspect} was refused"
        end
      end
    end

    # A Time/DateTime/TimeWithZone member is re-encoded, so it must keep the
    # sub-second digits it has — whole seconds named an instant the server
    # refused.
    it "exports a sub-second Time-like :datetime member with its fractional digits, and the server accepts it" do
      members = [Time.utc(2026, 9, 5, 10, 0, Rational(1, 4)), DateTime.new(2026, 9, 5, 11, 0, Rational(123_456_789, 10**9)),
                 Time.utc(2026, 9, 5, 12).in_time_zone("Tokyo") + Rational(1, 1000), Time.utc(2026, 9, 5, 13)]
      contract = Permittable::Contract.define { optional :at, :datetime, in: members }
      enum = described_class.rule(contract.rule)["properties"]["at"]["enum"]
      expect(enum).to eq(["2026-09-05T10:00:00.25Z", "2026-09-05T11:00:00.123456789Z",
                          "2026-09-05T12:00:00.001Z", "2026-09-05T13:00:00Z"])
      enum.each { |member| expect(contract.call(at: member).violations).to be_empty, "#{member} was refused" }
    end

    it "exports an :in that only answers include? as custom validation, not as an enum" do
      allowlist = Object.new
      def allowlist.include?(_value) = true
      prop = property("sku") { optional :sku, :string, in: allowlist }
      expect(prop).not_to have_key("enum")
      expect(prop["x-permittable-custom-validation"]).to be(true)

      plans = Class.new do
        include Enumerable

        def each(&) = %w[free pro].each(&)
        def include?(value) = %w[free pro].include?(value.to_s.downcase)
      end.new
      prop = property("plan") { optional :plan, :string, in: plans }
      expect(prop).not_to have_key("enum")
      expect(prop["x-permittable-custom-validation"]).to be(true)
    end

    # A Hash/Array/Set subclass overriding include? is opaque exactly like
    # the plain-Object and Enumerable allowlists above — its raw contents
    # (keys, elements) are not what it actually matches, so no enum can
    # honestly be published for it.
    it "exports a Hash/Array/Set subclass overriding include? as custom validation too" do
      # Non-empty: assert_satisfiable! reads any object's own empty? at
      # class load, and this Hash subclass inherits Hash's — unrelated to
      # its overridden include?, but a truly empty one would already fail
      # that check on its own, before ever reaching the list/opaque split.
      registry = Class.new(Hash) { def include?(value) = value.to_s.start_with?("custom-") }.new
      registry[:unrelated] = 1
      allowlist = Class.new(Array) { def include?(value) = any? { |c| c.to_s.casecmp?(value.to_s) } }.new(%w[pro])
      fuzzy = Class.new(Set) { def include?(value) = any? { |c| c.to_s.include?(value.to_s) } }.new(%w[pro])
      [registry, allowlist, fuzzy].each do |allowed|
        prop = property("sku") { optional :sku, :string, in: allowed }
        expect(prop).not_to have_key("enum")
        expect(prop["x-permittable-custom-validation"]).to be(true)
      end
    end

    it "emits BigDecimal bounds as JSON numbers, which is all minimum/maximum may be" do
      # The natural way to bound a price. Routed through the authored-value
      # re-encoding, the bounds came out as the strings "0.01" / "999.99" —
      # which the metaschema forbids, so the whole document was invalid.
      prop = property("price") { optional :price, :decimal, in: BigDecimal("0.01")..BigDecimal("999.99") }
      expect(prop).to include("minimum" => 0.01, "maximum" => 999.99)
      expect(prop.values_at("minimum", "maximum")).to all(be_a(Float))

      exact = property("qty") { optional :qty, :decimal, in: BigDecimal("1")...BigDecimal("100") }
      expect(exact).to include("minimum" => 1, "exclusiveMaximum" => 100)
      expect(exact.values_at("minimum", "exclusiveMaximum")).to all(be_a(Integer))

      endless = property("tip") { optional :tip, :decimal, in: BigDecimal("0.5").. }
      expect(endless).to include("minimum" => 0.5)
      expect(endless.keys.grep(/maximum/i)).to be_empty
    end

    # The server's own verdict on a value a client sends as the JSON number
    # `value`: the field's cast, then its rules — exactly what a request runs.
    def server_accepts?(field_rule, value)
      Permittable::Coercion.check_scalar(field_rule[:fields].first, value).first == :ok
    end

    it "rounds a bound a double cannot hold INWARD, verified against the field's own comparison" do
      # 0.1000000000000000001 has no double. to_f rounds it to 0.1, and a
      # client sending 0.1 would pass a published `minimum: 0.1` and then be
      # refused. How far inward is right depends on the TYPE: a :decimal reads
      # the number back as BigDecimal("0.1…") and compares exactly, while a
      # :float compares the Float itself, through BigDecimal#<=>'s own
      # limited-precision reading of it — so one double inward is enough for
      # the first and not for the second.
      bound = BigDecimal("0.1000000000000000001")
      %i[decimal float].each do |type|
        low_rule = rule_for { optional :x, type, in: bound.. }
        high_rule = rule_for { optional :x, type, in: ..bound }
        low = described_class.rule(low_rule)["properties"]["x"]["minimum"]
        high = described_class.rule(high_rule)["properties"]["x"]["maximum"]

        expect(server_accepts?(low_rule, low)).to be(true), "#{type}: the server refuses the published minimum #{low}"
        expect(server_accepts?(low_rule, low.prev_float)).to be(false), "#{type}: #{low} is further inward than needed"
        expect(server_accepts?(high_rule, high)).to be(true), "#{type}: the server refuses the published maximum #{high}"
      end
      # The nearest double below the bound needs no nudge on either type. (On
      # a :float the server's lossy comparison would accept a few doubles
      # more; the bound only ever moves inward, so those stay unpublished —
      # stricter, the safe way.)
      expect(property("x") { optional :x, :decimal, in: ..bound }["maximum"]).to eq(0.1)
      expect(property("x") { optional :x, :float, in: ..bound }["maximum"]).to eq(0.1)
      expect(property("x") { optional :x, :decimal, in: bound.. }["minimum"]).to eq(0.1.next_float)
      expect(property("x") { optional :x, :float, in: bound.. }["minimum"]).to be > 0.1.next_float
    end

    it "treats an infinite bound as no bound at all" do
      # BigDecimal("Infinity") used to crash the whole export (to_i raises
      # FloatDomainError), and Float::INFINITY is not a JSON number.
      decimal = property("x") { optional :x, :decimal, in: BigDecimal("0")..BigDecimal("Infinity") }
      expect(decimal).to include("minimum" => 0)
      expect(decimal.keys.grep(/maximum/i)).to be_empty

      float = property("x") { optional :x, :float, in: -Float::INFINITY...Float::INFINITY }
      expect(float.keys.grep(/imum/i)).to be_empty
      expect { JSON.generate(float) }.not_to raise_error
    end

    it "publishes an integral bound beyond Float::MAX exactly, matching master" do
      # 10**400 has no double — `to_f` overflows it to Infinity — but a JSON
      # integer literal has no size limit, and master published it outright:
      # `minimum: 10**400`. The inward-nudge machinery routes a candidate
      # bound through `to_f` to ask the field's own cast whether it is
      # "honoured", which itself overflows to Infinity for a bound this
      # large and used to walk the bound to Infinity and drop it — looser
      # than master, not merely a labelled divergence.
      huge = 10**400
      expect(property("x") { optional :x, :float, in: huge.. }).to include("minimum" => huge)
      expect(property("x") { optional :x, :float, in: ..(-huge) }).to include("maximum" => -huge)
      expect(property("x") { optional :x, :decimal, in: BigDecimal("1e400").. }).to include("minimum" => huge)
    end

    it "omits a FRACTIONAL bound beyond Float::MAX, unlike an integral one" do
      # BigDecimal("1e400") + 0.5 has no double either, but unlike an
      # integral bound it has no arbitrary-precision JSON representation
      # this exporter emits without going through Float — publishing it
      # exactly would mean a raw decimal number literal rather than a Ruby
      # Integer/Float, which this exporter does not produce. It is omitted,
      # same as a genuinely infinite bound, and deliberately so (see
      # CHANGELOG) rather than silently.
      fractional = BigDecimal("1e400") + BigDecimal("0.5")
      prop = property("x") { optional :x, :decimal, in: fractional.. }
      expect(prop.keys.grep(/imum/i)).to be_empty
    end

    it "omits a NaN bound, which compares to nothing" do
      # Ruby refuses a two-sided Range with a NaN end, but an endless one
      # builds — and NaN is no JSON number either.
      prop = property("x") { optional :x, :float, in: Float::NAN.. }
      expect(prop.keys.grep(/imum/i)).to be_empty
    end

    it "carries a non-numeric Range as an extension instead of guessing" do
      prop = property("code") { optional :code, :string, in: "a".."m" }
      expect(prop["x-permittable-range"]).to eq('"a".."m"')
      expect(prop).not_to have_key("minimum")
    end
  end

  describe "format: translation" do
    it "translates \\A/\\z anchors to ^/$" do
      expect(property("zip") { optional :zip, :string, format: /\A\d{5}\z/ }["pattern"]).to eq("^\\d{5}$")
    end

    it "refuses to translate Ruby's ^ and $, which are LINE anchors" do
      # The runtime accepts "evil\n12345" for /^\d{5}$/ — Ruby anchors a line,
      # ECMA-262 anchors the whole string without the m flag. Emitting the
      # source verbatim would publish a pattern stricter than the server
      # enforces, which is the one thing an export from contract data is
      # supposed to make impossible.
      prop = property("zip") { optional :zip, :string, format: /^\d{5}$/ }
      expect(prop).not_to have_key("pattern")
      expect(prop["x-permittable-pattern"]).to eq("/^\\d{5}$/")
    end

    it "still translates an ESCAPED dollar or caret, which are literals" do
      expect(property("amount") { optional :amount, :string, format: /\A\$\d+\z/ }["pattern"])
        .to eq("^\\$\\d+$")
    end

    it "falls back to x-permittable-pattern for flagged or Ruby-only regexps" do
      [/abc/i, /\A\h+\z/, /(?i)x/, /[[:alpha:]]+/, /a*+b/].each do |regexp|
        prop = property("a") { optional :a, :string, format: regexp }
        expect(prop).not_to have_key("pattern"), "expected #{regexp.inspect} to be untranslatable"
        expect(prop["x-permittable-pattern"]).to eq(regexp.inspect)
      end
    end

    # Each of these is a SyntaxError under the `u` flag Ajv compiles with, or
    # means something else in ECMA-262 — {,3} is a literal there without the
    # flag, && two ampersands, a backreference to a group that took no part
    # matches the empty string — so none may be published as `pattern`.
    it "falls back for constructs ECMA-262 lacks or reads differently" do
      [/\A(?>a+)b\z/, /a(?#note)b/, /(?'n'a)\k'n'/, /\Aa{,3}\z/, /\A\e\z/, /\A[a-z&&[^q]]\z/,
       /\A\101\z/, /\A\01\z/, /\A[a\S]\z/, /\Aa{2}?\z/, /\A+a/, /a{2}{3}/, /(?=a)*b/, /\x7/,
       /(?<n>a)\g<n>/, /[a-z[0-9]]/, /(?<a>x)|(?<a>y)/,
       /\A(a)?\1b\z/, /\A(?<y>\d)\k<y>\z/, /\Aa\b/, /\Aa\B/].each do |regexp|
        prop = property("a") { optional :a, :string, format: regexp }
        expect(prop).not_to have_key("pattern"), "expected #{regexp.inspect} to be untranslatable"
        expect(prop["x-permittable-pattern"]).to eq(regexp.inspect)
      end
    end

    # Ruby warns about the bare - or ] in each of these, so they are built
    # quietly. `[$-&&%]` is the empty intersection of $-& and %, matching
    # nothing in Ruby; in ECMA-262 it is a class that accepts "%". `[a-&&z]`
    # is a SyntaxError in Unicode mode, and a leading ] ends an empty class.
    it "refuses an intersection or nested class straight after a range hyphen, and a leading ]" do
      ["[$-&&%]", "[a-&&z]", "[!-[a]]", "[]a]"].each do |source|
        regexp = quietly { Regexp.new(source) }
        expect(described_class.ecma_pattern(regexp)).to be_nil, "expected #{source} to be untranslatable"
      end
    end

    # Ruby's \b counts a non-ASCII letter as a word character and Unicode
    # mode's does not, so /\Aa\b/ rejects "aé" at runtime and ^a\b accepts it.
    # Inside a class \b is a backspace in both.
    it "keeps a backspace \\b inside a class" do
      expect(described_class.ecma_pattern(/\A[\b]\z/)).to eq('^[\b]$')
    end

    # A literal - right after a completed range is not "a different range in
    # Unicode mode" — both dialects read [a-c-e] as the set {a, b, c, -, e},
    # rejecting "d". Regression: this used to be refused outright, so a
    # common format: like /\A[a-zA-Z0-9-_]+\z/ published no pattern at all.
    # Built via Regexp.new and quietly, like the other ambiguous-hyphen
    # cases below, so the suite prints no regexp warnings.
    it "keeps a literal - right after a completed range, in both engines" do
      {
        '\A[a-zA-Z0-9-_]+\z' => '^[a-zA-Z0-9-_]+$',
        '\A[A-Za-z0-9-_.]+\z' => '^[A-Za-z0-9-_.]+$',
        '\A[a-z0-9-_]{3,16}\z' => '^[a-z0-9-_]{3,16}$',
        '\A[a-z-A-Z]\z' => '^[a-z-A-Z]$',
        '\A[a-c-e]\z' => '^[a-c-e]$',
        # The hyphen may itself reopen a range, chaining like Ruby does.
        '\A[a-z--x]\z' => '^[a-z--x]$'
      }.each do |source, expected|
        regexp = quietly { Regexp.new(source) }
        expect(described_class.ecma_pattern(regexp)).to eq(expected), "expected #{source} to translate to #{expected}"
      end
    end

    # A class escape (\d, \D, \w, \W, \s, \S) can never sit next to a range
    # hyphen in a real Regexp: Ruby itself raises building the source, on
    # either side of the hyphen, so this can never reach the translator.
    # ecma_pattern's own refusal for it (previous == :set) is a defensive
    # backstop, not something a live disagreement between the two engines
    # depends on.
    it "cannot even construct a class escape beside a range hyphen, so its refusal in ecma_pattern is a backstop" do
      ['[\d-z]', '[\s-z]', '[\w-z]', '[a-\d]', '[a-\S]'].each do |source|
        expect { Regexp.new(source) }.to raise_error(RegexpError)
      end
    end

    # rubocop:disable-next Style/RedundantRegexpEscape -- the redundant escapes are what is under test
    it "un-escapes the identity escapes Unicode mode rejects, but keeps \\- inside a class" do
      expect(described_class.ecma_pattern(/\A\d{3}\-\d{4}\z/)).to eq('^\d{3}-\d{4}$')
      expect(described_class.ecma_pattern(/\A\#\ \z/)).to eq("^# $")
      expect(described_class.ecma_pattern(/\A[\w\-\#]+\z/)).to eq('^[\w\-#]+$')
      expect(described_class.ecma_pattern(%r{\A\$\.\/\z})).to eq('^\$\.\/$')
    end

    it "spells out Ruby's ASCII-only \\s, which ECMA-262 widens to every Unicode space" do
      expect(described_class.ecma_pattern(/\A\s\z/)).to eq('^[ \t\n\v\f\r]$')
      expect(described_class.ecma_pattern(/\A\S\z/)).to eq('^[^ \t\n\v\f\r]$')
      expect(described_class.ecma_pattern(/\A[^@\s]+\z/)).to eq('^[^@ \t\n\v\f\r]+$')
    end

    it "carries \\S in a class only where it can be written exactly" do
      # The any-character idiom: \s and \S together cover everything whatever
      # either one means, so ECMA-262's wider \s is harmless here.
      expect(described_class.ecma_pattern(/\A[\s\S]*\z/)).to eq('^[\s\S]*$')
      expect(described_class.ecma_pattern(/\A[a\S\s]\z/)).to eq('^[\s\S]$')
      expect(described_class.ecma_pattern(/\A[^\s\S]\z/)).to eq('^[^\s\S]$')
      # rubocop:disable-next Style/RedundantRegexpCharacterClass -- the single-member class is what is under test
      expect(described_class.ecma_pattern(/\A[\S]\z/)).to eq('^[^ \t\n\v\f\r]$')
      expect(described_class.ecma_pattern(/\A[^\S]\z/)).to eq('^[ \t\n\v\f\r]$')
    end

    it "spells out Ruby's dot, which ECMA-262 without the s flag also refuses at \\r, U+2028 and U+2029" do
      expect(described_class.ecma_pattern(/\A.+\z/)).to eq('^[^\n]+$')
      expect(described_class.ecma_pattern(/\A[.]\z/)).to eq("^[.]$")
    end

    it "rewrites only real \\A and \\z anchors, never an escaped backslash followed by A or z" do
      expect(described_class.ecma_pattern(/\A\\A\z/)).to eq('^\\\\A$')
      expect(described_class.ecma_pattern(/\A\\z\z/)).to eq('^\\\\z$')
    end

    it "carries the \\u{...} and \\x escapes that survive into the source" do
      expect(described_class.ecma_pattern(Regexp.new('\A\u{41}\x42\z'))).to eq('^\u{41}\x42$')
    end

    it "escapes a brace Ruby reads as a literal, which Unicode mode rejects bare" do
      expect(described_class.ecma_pattern(/\A{\d}\z/)).to eq('^\{\d\}$')
    end
  end

  describe "format: presets" do
    it "emits the JSON Schema format keyword alongside the pattern it still asserts" do
      schema = property("id") { required :id, :string, format: :uuid }
      expect(schema).to eq(
        "type" => "string", "format" => "uuid", "minLength" => 1,
        "pattern" => "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
      )
    end

    it "maps :url onto uri and :hostname onto hostname" do
      expect(property("site") { optional :site, :string, format: :url }["format"]).to eq("uri")
      expect(property("host") { optional :host, :string, format: :hostname }["format"]).to eq("hostname")
    end

    it "emits a translated pattern with no format keyword for a preset JSON Schema has no name for" do
      schema = property("slug") { optional :slug, :string, format: :slug }
      expect(schema.key?("format")).to be(false)
      expect(schema["pattern"]).to eq("^[a-z0-9]+(?:-[a-z0-9]+)*$")
    end

    it "emails export as a real pattern, not the extension a flagged regexp would need" do
      schema = property("email") { optional :email, :string, format: :email }
      expect(schema["format"]).to eq("email")
      expect(schema["pattern"]).to start_with("^[a-zA-Z0-9")
      expect(schema.key?("x-permittable-pattern")).to be(false)
    end

    it "says nothing extra for a hand-written Regexp" do
      expect(property("code") { optional :code, :string, format: /\A[A-Z]{3}\z/ })
        .to eq("type" => "string", "pattern" => "^[A-Z]{3}$")
    end
  end

  describe "documentation annotations" do
    it "emits default:, desc:, and example: as default / description / examples" do
      prop = property("plan") do
        optional :plan, :string, in: %w[free pro], default: "free", desc: "Billing plan", example: "pro"
      end
      expect(prop).to include("enum" => %w[free pro], "default" => "free",
                              "description" => "Billing plan", "examples" => ["pro"])
    end

    it "publishes an authored default:/example: cast to the field's own type" do
      props = schema_for do
        optional :age, :integer, default: "18", example: "21"
        optional :opt_in, :boolean, default: "false"
        array :ids, of: :integer, default: %w[1 2]
      end["properties"]

      expect(props["age"]).to include("type" => "integer", "default" => 18, "examples" => [21])
      expect(props["opt_in"]).to include("type" => "boolean", "default" => false)
      expect(props["ids"]).to include("default" => [1, 2])
    end

    it "exports a :decimal default:/example: as a JSON number when a Float holds it exactly, else as a string" do
      price = property("price") { optional :price, :decimal, default: 1.5, example: "19.99" }
      expect(price["default"]).to eq(1.5).and be_a(Float)
      expect(price["examples"]).to eq([19.99])

      precise = property("rate") { optional :rate, :decimal, default: "0.1000000000000000055511151231257827" }
      expect(precise["default"]).to eq("0.1000000000000000055511151231257827")
    end

    it "exports a :decimal in: as an enum member using the same numeric-vs-string rule as default:/example:, " \
       "so a default is always found in its own enum" do
      exact = property("price") { optional :price, :decimal, in: [BigDecimal("1.5"), BigDecimal("2.5")], default: BigDecimal("1.5") }
      expect(exact["enum"]).to eq([1.5, 2.5])
      expect(exact["enum"]).to include(exact["default"])

      precise = property("rate") do
        optional :rate, :decimal, in: [BigDecimal("0.1000000000000000055511151231257827")],
                                  default: BigDecimal("0.1000000000000000055511151231257827")
      end
      expect(precise["enum"]).to eq(["0.1000000000000000055511151231257827"])
      expect(precise["enum"]).to include(precise["default"])
    end

    it "never recurses the :decimal numeric-export rule into a :json field's opaque contents" do
      money = property("totals") { optional :totals, :json, default: { "net" => BigDecimal("2.5") } }
      expect(money["default"]).to eq("net" => "2.5")

      # A finite BigDecimal inside :json stays a string (above); a non-finite
      # one must not crash the export by becoming Float::INFINITY along the
      # way — :json contents are opaque and pass through untyped.
      infinite = property("totals") { optional :totals, :json, default: { "cap" => BigDecimal("Infinity") } }
      expect(infinite["default"]).to eq("cap" => "Infinity")
      expect { JSON.generate(infinite) }.not_to raise_error
    end

    it "re-encodes authored Date/Time/BigDecimal values as JSON scalars" do
      expect(property("day") { optional :day, :date, default: Date.new(2026, 1, 5) }["default"]).to eq("2026-01-05")
      expect(property("at") { optional :at, :datetime, example: Time.utc(2026, 1, 5, 10) }["examples"])
        .to eq(["2026-01-05T10:00:00Z"])
      expect(property("price") { optional :price, :decimal, example: BigDecimal("19.99") }["examples"]).to eq([19.99])
    end

    it "marks sensitive fields writeOnly and flags opaque callables as extensions" do
      props = schema_for do
        optional :ssn,  :string, sensitive: true
        optional :slug, :string, validate: ->(v) { v.match?(/\A[a-z-]+\z/) }
        optional :tags, :string, transform: ->(v) { v.split(",") }
      end["properties"]
      expect(props["ssn"]).to include("writeOnly" => true, "x-permittable-sensitive" => true)
      expect(props["slug"]["x-permittable-custom-validation"]).to be(true)
      expect(props["slug"]).not_to have_key("pattern")
      expect(props["tags"]["x-permittable-transformed"]).to be(true)
    end

    it "exports normalize: as x-permittable-normalize — the preset's name, or true for a custom proc" do
      # The server checks the NORMALIZED value, so minLength/maxLength/pattern
      # describe a string the client never sends. The step is not a keyword
      # JSON Schema has; it is flagged so a client can apply it first.
      props = schema_for do
        required :name,  :string, length: 3..10, normalize: :squish
        optional :email, :string, normalize: "email"
        optional :code,  :string, normalize: ->(v) { v.delete("-") }
        optional :plain, :string
      end["properties"]
      expect(props["name"]).to include("minLength" => 3, "maxLength" => 10, "x-permittable-normalize" => "squish")
      expect(props["email"]["x-permittable-normalize"]).to eq("email")
      expect(props["code"]["x-permittable-normalize"]).to be(true)
      expect(props["plain"]).not_to have_key("x-permittable-normalize")
    end

    it "marks a child that inherited sensitive: from its container writeOnly too" do
      props = schema_for do
        optional :payment, sensitive: true do
          required :card_number, :string
          optional :id, :string, sensitive: false
        end
      end["properties"]["payment"]["properties"]
      expect(props["card_number"]).to include("writeOnly" => true, "x-permittable-sensitive" => true)
      expect(props["id"]).not_to have_key("writeOnly")
    end
  end

  describe "nullable:" do
    it "adds null to the declared type on every field kind" do
      props = schema_for do
        optional :s, :string, nullable: true
        optional :d, :decimal, nullable: true
        optional :tags, :string, nullable: true
        optional :address, nullable: true do
          required :city, :string
        end
      end["properties"]
      expect(props["s"]["type"]).to eq(%w[string null])
      expect(props["d"]["type"]).to eq(%w[string number null])
      expect(props["address"]["type"]).to eq(%w[object null])
    end

    it "adds null to a nullable array's type without touching its items" do
      schema = property("tags") { array :tags, of: :integer, nullable: true }
      expect(schema["type"]).to eq(%w[array null])
      expect(schema["items"]).to eq("type" => "integer")
    end

    it "lists null in an enum, which is instance-wide rather than type-scoped" do
      schema = property("plan") { optional :plan, :string, in: %w[free pro], nullable: true }
      expect(schema["enum"]).to eq(["free", "pro", nil])
    end

    it "leaves a numeric range's bounds alone (minimum/maximum only apply to numbers)" do
      schema = property("age") { optional :age, :integer, in: 18..120, nullable: true }
      expect(schema).to eq("type" => %w[integer null], "minimum" => 18, "maximum" => 120)
    end

    it "documents an authored null default" do
      schema = property("nickname") { optional :nickname, :string, nullable: true, default: nil }
      expect(schema).to eq("type" => %w[string null], "default" => nil)
    end

    it "keeps a non-nullable field's type a bare string" do
      expect(property("s") { optional :s, :string }["type"]).to eq("string")
    end
  end

  describe ":json fields" do
    it "documents an opaque object, carrying the bounds it declares" do
      schema = property("metadata") { optional :metadata, :json, length: 0..8, max_depth: 3 }
      expect(schema).to eq("type" => "object", "minProperties" => 0, "maxProperties" => 8,
                           "x-permittable-max-depth" => 3)
    end

    it "says nothing about the shape when no bounds are declared" do
      expect(property("metadata") { optional :metadata, :json }).to eq("type" => "object")
    end

    it "annotates it like any other field" do
      schema = property("metadata") do
        optional :metadata, :json, desc: "Opaque client state", sensitive: true,
                                   default: { "seeded" => true }, example: { "k" => "v" }
      end
      expect(schema).to include("type" => "object", "description" => "Opaque client state",
                                "writeOnly" => true, "x-permittable-sensitive" => true,
                                "default" => { "seeded" => true }, "examples" => [{ "k" => "v" }])
    end

    it "adds null to a nullable opaque object" do
      expect(property("metadata") { optional :metadata, :json, nullable: true }["type"]).to eq(%w[object null])
    end

    it "re-encodes non-JSON scalars inside an authored hash" do
      schema = property("metadata") { optional :metadata, :json, default: { "on" => Date.new(2026, 9, 4) } }
      expect(schema["default"]).to eq("on" => "2026-09-04")
    end
  end

  describe "nested hashes and unknown:" do
    it "maps nested blocks to object schemas, propagating unknown: :error at every level" do
      schema = schema_for(unknown: :error) do
        required :name, :string
        optional :address, desc: "Postal address" do
          required :city, :string
          optional :zip,  :string
        end
      end
      expect(schema["additionalProperties"]).to be(false)
      address = schema["properties"]["address"]
      expect(address["type"]).to eq("object")
      expect(address["required"]).to eq(["city"])
      expect(address["additionalProperties"]).to be(false)
      expect(address["description"]).to eq("Postal address")
    end

    it "leaves objects permissive under unknown: :ignore (the strong-parameters default)" do
      expect(schema_for { required :name, :string }).not_to have_key("additionalProperties")
    end
  end

  describe "arrays" do
    it "maps arrays of scalars, arrays of hashes, and element-count bounds" do
      schema = schema_for do
        array :tag_names, of: :string, length: 0..10, default: []
        array :line_items, required: true do
          required :sku,      :string
          required :quantity, :integer, in: 1..99
        end
      end
      tags = schema["properties"]["tag_names"]
      expect(tags).to include("type" => "array", "minItems" => 0, "maxItems" => 10, "default" => [])
      expect(tags["items"]).to eq("type" => "string")

      expect(schema["required"]).to eq(["line_items"])
      items = schema["properties"]["line_items"]["items"]
      expect(items["required"]).to eq(%w[sku quantity])
      expect(items["properties"]["quantity"]).to include("minimum" => 1, "maximum" => 99)
    end
  end

  describe "root:" do
    it "wraps a rooted contract, requiring the root key but keeping the wrapper permissive" do
      schema = schema_for(root: :user, unknown: :error) { required :name, :string }
      expect(schema["required"]).to eq(["user"])
      expect(schema).not_to have_key("additionalProperties")
      inner = schema["properties"]["user"]
      expect(inner["required"]).to eq(["name"])
      expect(inner["additionalProperties"]).to be(false)
    end
  end
end
