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
       /(?<n>a)\g<n>/, /[a-z[0-9]]/, /[]a]/, /(?<a>x)|(?<a>y)/,
       /\A(a)?\1b\z/, /\A(?<y>\d)\k<y>\z/].each do |regexp|
        prop = property("a") { optional :a, :string, format: regexp }
        expect(prop).not_to have_key("pattern"), "expected #{regexp.inspect} to be untranslatable"
        expect(prop["x-permittable-pattern"]).to eq(regexp.inspect)
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

    it "spells out Ruby's dot, which ECMA-262 without the s flag also refuses at \\r, U+2028 and U+2029" do
      expect(described_class.ecma_pattern(/\A.+\z/)).to eq('^[^\n]+$')
      expect(described_class.ecma_pattern(/\A[.]\z/)).to eq("^[.]$")
    end

    it "rewrites only real \\A and \\z anchors, never an escaped backslash followed by A or z" do
      expect(described_class.ecma_pattern(/\A\\A\z/)).to eq('^\\\\A$')
      expect(described_class.ecma_pattern(/\A\\z\z/)).to eq('^\\\\z$')
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

    it "re-encodes authored Date/Time/BigDecimal values as JSON scalars" do
      expect(property("day") { optional :day, :date, default: Date.new(2026, 1, 5) }["default"]).to eq("2026-01-05")
      expect(property("at") { optional :at, :datetime, example: Time.utc(2026, 1, 5, 10) }["examples"])
        .to eq(["2026-01-05T10:00:00Z"])
      expect(property("price") { optional :price, :decimal, example: BigDecimal("19.99") }["examples"]).to eq(["19.99"])
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
