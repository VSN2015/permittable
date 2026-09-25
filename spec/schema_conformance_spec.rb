# The gem's headline claim: because a contract is data, a schema exported from
# it "cannot drift from what the server actually enforces". Every other spec
# checks one side or the other — this one checks that the two AGREE, by
# walking canonical JSON payloads through the contract and through its own
# exported schema and comparing the verdicts.
#
# Where they legitimately differ, the payload says so and why. Those exemptions
# are deliberately narrow, and each asserts its DIRECTION: the server may
# accept what its docs reject (a client following the docs is merely
# conservative). The reverse (a client following the docs gets a surprise
# 422) is allowed only where JSON Schema has no keyword for the rule at all,
# under its own label, and only with the rule still visible on the field. A
# new divergence therefore fails this spec rather than shipping quietly.

# The payload table, kept out of the example group so its constants do not
# leak onto Object from inside an RSpec block.
module SchemaConformance
  # A payload's expectation: :agree, or the reason the two may differ.
  #
  # Three run the SAFE way — the server accepts what its docs reject:
  #
  #   :coerced_encoding — the runtime accepts a non-canonical encoding of the
  #     declared type ("30" for an integer, 1 for a string) because form and
  #     query payloads are all strings. JsonSchema documents the canonical JSON
  #     encoding only, which its own comment calls out.
  #   :null_is_absence — the runtime reads an explicit null as ABSENCE, so
  #     `{"age": null}` means the same as `{}`. JSON Schema has no way to say
  #     that: `type: integer` reads null as a present value of the wrong type.
  #     (A `nullable:` field is not this case: there the null IS a value, the
  #     exporter widens `type` to say so, and the two agree.)
  #   :normalized_encoding — the runtime runs `normalize:` BEFORE it checks,
  #     so a padded value whose normalized form fits ("  abcdefghij  " under
  #     squish and maxLength 10) is accepted though its raw form is too long.
  #
  # The rest run the OTHER way — the schema is LOOSER than the server, and a
  # client following it can still be surprised by a 422 — so each is labelled
  # separately rather than waved through, and LOOSER names the keyword the
  # DIVERGING FIELD'S OWN schema must still carry, so a tool that wants to
  # close the gap can find the rule:
  #
  #   :extension_only — the contract enforces a bound JSON Schema has no
  #     keyword for (`max_depth:`). The exporter does not drop the bound — it
  #     emits it as `x-permittable-max-depth`.
  #   :range_extension — a Range of non-numbers (`in: "a".."m"`), which
  #     minimum/maximum cannot express, carried as `x-permittable-range`.
  #   :custom_validation — a `validate:` proc is opaque app code, so the
  #     schema can only flag it: `x-permittable-custom-validation`.
  #   :normalized_first — the `normalize:` step, the unsafe way round: "   "
  #     passes a minLength of 3 and then squishes to "" (absent), " a  "
  #     passes it and squishes to "a" (too short). JSON Schema has no keyword
  #     for "transform, then check", so the step is exported as
  #     `x-permittable-normalize`.
  #   :format_annotation — :decimal, :date and :datetime accept a STRING, and
  #     what makes that string valid is its `format` ("decimal", "date",
  #     "date-time"), which draft 2020-12 treats as an annotation unless a
  #     validator opts in. So "abc", "NaN" and "2026-02-30" pass the schema
  #     and fail the cast.
  #   :string_decimal — minimum/maximum only ever constrain numbers, so a
  #     bounded :decimal's string encoding skips them: "5000" sails past a
  #     `maximum` of 999.99 that the server enforces on the parsed value. The
  #     bound is still published, as a number, for a client that parses first.
  LOOSER = {
    extension_only: "x-permittable-max-depth",
    range_extension: "x-permittable-range",
    custom_validation: "x-permittable-custom-validation",
    normalized_first: "x-permittable-normalize",
    format_annotation: "format",
    string_decimal: "maximum"
  }.freeze

  CASES = {
    "scalars and bounds" => {
      contract: proc {
        required :name, :string, length: 1..8
        optional :age, :integer, in: 18..120
        optional :score, :float
        optional :ok, :boolean
      },
      payloads: [
        [{ "name" => "Jo" }, :agree],
        [{ "name" => "Jo", "age" => 18 }, :agree],
        [{ "name" => "Jo", "age" => 120 }, :agree],
        [{ "name" => "Jo", "score" => 1.5 }, :agree],
        [{ "name" => "Jo", "ok" => true }, :agree],
        [{}, :agree],
        [{ "name" => "" }, :agree],
        [{ "name" => "waaaaytoolong" }, :agree],
        [{ "name" => "Jo", "age" => 17 }, :agree],
        [{ "name" => "Jo", "age" => 121 }, :agree],
        [{ "name" => "Jo", "age" => [] }, :agree],
        [{ "name" => "Jo", "age" => "30" }, :coerced_encoding],
        [{ "name" => "Jo", "ok" => "true" }, :coerced_encoding],
        [{ "name" => 42 }, :coerced_encoding],
        [{ "name" => "Jo", "age" => nil }, :null_is_absence]
      ]
    },
    "a required string with no length: of its own" => {
      # The `minLength: 1` the exporter adds because "" is ABSENT, and an
      # absent required field violates — so a required string can never
      # validly be empty. Without it the docs would accept "" and the server
      # would answer 422.
      contract: proc { required :title, :string },
      payloads: [
        [{ "title" => "x" }, :agree],
        [{ "title" => "" }, :agree],
        [{}, :agree]
      ]
    },
    "enum and default" => {
      contract: proc { optional :plan, :string, in: %w[free pro], default: "free" },
      payloads: [
        [{}, :agree],
        [{ "plan" => "free" }, :agree],
        [{ "plan" => "gold" }, :agree],
        [{ "plan" => nil }, :null_is_absence]
      ]
    },
    "an exclusive range" => {
      contract: proc { optional :pct, :integer, in: 0...100 },
      payloads: [[{ "pct" => 0 }, :agree], [{ "pct" => 99 }, :agree], [{ "pct" => 100 }, :agree]]
    },
    "endless and beginless lengths" => {
      contract: proc {
        optional :a, :string, length: (3..)
        optional :b, :string, length: (..4)
      },
      payloads: [
        [{ "a" => "abc" }, :agree], [{ "a" => "ab" }, :agree],
        [{ "b" => "abcd" }, :agree], [{ "b" => "abcde" }, :agree]
      ]
    },
    "an exact length" => {
      contract: proc { optional :code, :string, length: 3 },
      payloads: [[{ "code" => "abc" }, :agree], [{ "code" => "ab" }, :agree], [{ "code" => "abcd" }, :agree]]
    },
    "a format" => {
      contract: proc { optional :zip, :string, format: /\A\d{5}\z/ },
      payloads: [[{ "zip" => "10000" }, :agree], [{ "zip" => "1000" }, :agree], [{ "zip" => "abcde" }, :agree]]
    },
    "a nullable field, where an explicit null IS a value" => {
      # The counterpart to :null_is_absence — `nullable:` makes the null a
      # value the contract accepts, and the exporter widens `type` to say so,
      # so the two agree with no divergence to declare.
      contract: proc {
        optional :nickname, :string, nullable: true
        optional :tier, :string, in: %w[free pro], nullable: true
      },
      payloads: [
        [{ "nickname" => "Jo" }, :agree],
        [{ "nickname" => nil }, :agree],
        [{}, :agree],
        [{ "nickname" => 1 }, :coerced_encoding],
        [{ "tier" => nil }, :agree],
        [{ "tier" => "pro" }, :agree],
        [{ "tier" => "gold" }, :agree]
      ]
    },
    "an opaque :json field with bounds" => {
      # The shape is deliberately undeclared, but the BOUNDS are exported:
      # minProperties/maxProperties are real keywords, while max_depth: has no
      # JSON Schema equivalent and rides along as an x-permittable extension
      # the validator ignores — so the schema is looser than the runtime there,
      # in the documented direction.
      contract: proc { optional :metadata, :json, length: 1..2, max_depth: 2 },
      payloads: [
        [{ "metadata" => { "a" => 1 } }, :agree],
        [{ "metadata" => { "a" => 1, "b" => 2 } }, :agree],
        [{ "metadata" => {} }, :agree],
        [{ "metadata" => { "a" => 1, "b" => 2, "c" => 3 } }, :agree],
        [{ "metadata" => [] }, :agree],
        [{ "metadata" => { "a" => { "b" => { "c" => 1 } } } }, :extension_only]
      ]
    },
    "a normalized string" => {
      contract: proc { required :name, :string, length: 3..10, normalize: :squish },
      payloads: [
        [{ "name" => "Jo Jo" }, :agree],
        [{ "name" => "ab" }, :agree],
        [{ "name" => "waaaaytoolong" }, :agree],
        [{ "name" => "  abcdefghij  " }, :normalized_encoding],
        [{ "name" => "   " }, :normalized_first],
        [{ "name" => " a  " }, :normalized_first]
      ]
    },
    "a decimal bounded by BigDecimals" => {
      # The natural way to bound a price — and the bounds must come out as
      # JSON numbers, or the validator has nothing to compare against.
      contract: proc { optional :price, :decimal, in: BigDecimal("0.01")..BigDecimal("999.99") },
      payloads: [
        [{ "price" => 5 }, :agree],
        [{ "price" => 0.01 }, :agree],
        [{ "price" => 999.99 }, :agree],
        [{ "price" => 0.001 }, :agree],
        [{ "price" => 1000 }, :agree],
        [{ "price" => "5.00" }, :agree],
        [{ "price" => "5000" }, :string_decimal]
      ]
    },
    "a string range, a validate: proc, and formats that only annotate" => {
      contract: proc {
        optional :code,  :string, in: "a".."m"
        optional :slug,  :string, validate: ->(v) { v.match?(/\A[a-z-]+\z/) }
        optional :price, :decimal
        optional :day,   :date
        optional :at,    :datetime
      },
      payloads: [
        [{ "code" => "b" }, :agree],
        [{ "code" => "zebra" }, :range_extension],
        [{ "slug" => "a-slug" }, :agree],
        [{ "slug" => "Not A Slug" }, :custom_validation],
        [{ "price" => "12.50" }, :agree],
        [{ "price" => 12.5 }, :agree],
        [{ "price" => "abc" }, :format_annotation],
        [{ "price" => "NaN" }, :format_annotation],
        [{ "day" => "2026-02-28" }, :agree],
        [{ "day" => "2026-02-30" }, :format_annotation],
        [{ "at" => "2026-02-28T10:00:00Z" }, :agree],
        [{ "at" => "not a time" }, :format_annotation]
      ]
    },
    "arrays" => {
      contract: proc { array :tags, of: :string, length: 1..3 },
      payloads: [
        [{ "tags" => ["a"] }, :agree],
        [{ "tags" => %w[a b c] }, :agree],
        [{ "tags" => [] }, :agree],
        [{ "tags" => %w[a b c d] }, :agree],
        [{ "tags" => "no" }, :agree],
        [{ "tags" => [1] }, :coerced_encoding]
      ]
    },
    "an array of hashes" => {
      contract: proc {
        array :line_items, required: true, length: 1..2 do
          required :sku, :string
        end
      },
      payloads: [
        [{ "line_items" => [{ "sku" => "A" }] }, :agree],
        [{ "line_items" => [{}] }, :agree],
        [{ "line_items" => [] }, :agree],
        [{}, :agree]
      ]
    },
    "a nested hash under unknown: :error" => {
      unknown: :error,
      contract: proc {
        optional :address do
          required :city, :string
          optional :zip, :string
        end
      },
      payloads: [
        [{ "address" => { "city" => "Hanoi" } }, :agree],
        [{ "address" => {} }, :agree],
        [{ "address" => { "city" => "Hanoi", "nope" => "x" } }, :agree],
        [{ "address" => "flat" }, :agree]
      ]
    },
    "a rooted contract" => {
      root: :user,
      contract: proc { required :name, :string },
      payloads: [
        [{ "user" => { "name" => "Jo" } }, :agree],
        [{ "user" => {} }, :agree],
        [{}, :agree]
      ]
    }
  }.freeze
end

RSpec.describe "the exported schema against what the contract enforces" do
  def host_for(root:, unknown:, &contract)
    klass = Class.new do
      include Permittable

      attr_accessor :params

      def action_name
        "call"
      end
    end
    klass.permit_params(:call, root: root, unknown: unknown, &contract)
    klass
  end

  def runtime_verdict(klass, payload)
    host = klass.new
    host.params = payload
    host.permitted_params
    :accept
  rescue Permittable::InvalidParameters
    :reject
  end

  SchemaConformance::CASES.each do |label, spec|
    context "with #{label}" do
      let(:klass) { host_for(root: spec[:root] || false, unknown: spec[:unknown] || :ignore, &spec[:contract]) }
      let(:schema) { Permittable::JsonSchema.rule(klass.permit_rule_for("call")) }

      spec[:payloads].each do |payload, expectation|
        it "#{expectation == :agree ? 'agrees on' : "diverges (#{expectation}) for"} #{payload.inspect}" do
          runtime = runtime_verdict(klass, payload)
          documented = TinyJsonSchema.valid?(schema, payload) ? :accept : :reject

          if expectation == :agree
            expect(documented).to eq(runtime),
                                  "contract said #{runtime}, its own schema said #{documented} " \
                                  "(#{TinyJsonSchema.errors(schema, payload).inspect}); schema: #{schema.inspect}"
          elsif SchemaConformance::LOOSER.key?(expectation)
            # The unsafe direction, allowed only where JSON Schema has no
            # keyword that says it — and only with the rule still visible on
            # the field that diverges, so a tool that wants it can find it.
            expect([runtime, documented]).to eq(%i[reject accept]),
                                             "#{expectation} is for a rule the schema cannot carry; " \
                                             "got runtime=#{runtime}, documented=#{documented}"
            expect(diverging_field_schema(schema, payload)).to include(SchemaConformance::LOOSER.fetch(expectation))
          else
            # Only ever in the safe direction: a client following the docs is
            # conservative, never surprised by a 422.
            expect([runtime, documented]).to eq(%i[accept reject]),
                                             "#{expectation} is only allowed where the server accepts and the docs " \
                                             "reject; got runtime=#{runtime}, documented=#{documented}"
          end
        end
      end
    end
  end

  it "covers every keyword the exporter can emit for the declarations under test" do
    emitted = SchemaConformance::CASES.each_value.flat_map do |spec|
      schema = Permittable::JsonSchema.rule(
        host_for(root: spec[:root] || false, unknown: spec[:unknown] || :ignore, &spec[:contract]).permit_rule_for("call")
      )
      keywords_in(schema)
    end.uniq
    # Annotations carry no assertion, so the validator ignores them by design.
    annotations = %w[default description examples writeOnly format]
    unchecked = emitted - annotations - %w[
      type enum minimum maximum exclusiveMaximum minLength maxLength pattern
      required properties additionalProperties items minItems maxItems
      minProperties maxProperties
    ]
    expect(unchecked.grep_v(/\Ax-permittable-/)).to be_empty,
                                                    "the exporter emits #{unchecked.inspect}, which TinyJsonSchema does not check"
  end

  # The schema of the one field a looser payload is about: descend through
  # `properties` along the payload's keys while the payload names exactly one
  # of them, stopping at the field whose value is not itself described
  # property by property (a scalar, or an opaque `:json` object).
  def diverging_field_schema(schema, payload)
    loop do
      raise ArgumentError, "a looser payload must name one field: #{payload.inspect}" unless payload.is_a?(Hash) && payload.size == 1

      key, value = payload.first
      schema = schema.fetch("properties").fetch(key)
      return schema unless value.is_a?(Hash) && schema["properties"]

      payload = value
    end
  end

  def keywords_in(node)
    return [] unless node.is_a?(Hash)

    node.keys + node.flat_map { |key, value| key == "properties" ? value.values.flat_map { |v| keywords_in(v) } : keywords_in(value) }
  end
end
