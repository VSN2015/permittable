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

    it "falls back to x-permittable-pattern for flagged or Ruby-only regexps" do
      [/abc/i, /\A\h+\z/, /(?i)x/, /[[:alpha:]]+/, /a*+b/].each do |regexp|
        prop = property("a") { optional :a, :string, format: regexp }
        expect(prop).not_to have_key("pattern"), "expected #{regexp.inspect} to be untranslatable"
        expect(prop["x-permittable-pattern"]).to eq(regexp.inspect)
      end
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
