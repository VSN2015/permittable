RSpec.describe Permittable::Contract do
  let(:contract) do
    described_class.define(root: :user) do
      required :email, :string, format: /@/
      optional :age,   :integer, in: 18..120
      optional :plan,  :string, in: %w[free pro], default: "free"
    end
  end

  after { Permittable.filter_parameter_registry.reset! }

  describe ".define" do
    it "requires a block with at least one field" do
      expect { described_class.define }.to raise_error(ArgumentError, /requires a block/)
      expect { described_class.define {} }.to raise_error(ArgumentError, /at least one field/)
    end

    it "propagates contract mistakes at definition time" do
      expect { described_class.define { required :a, :money } }
        .to raise_error(ArgumentError, /unknown type :money/)
    end

    it "exposes the frozen rule for introspection" do
      expect(contract.rule).to be_frozen
      expect(contract.rule[:root]).to eq(:user)
      expect(contract.rule[:fields].map { |f| f[:name] }).to eq(%i[email age plan])
    end
  end

  describe "#call" do
    it "returns a valid result with cast, defaulted, indifferent params" do
      result = contract.call("user" => { "email" => "A@B.C", "age" => "30" })
      expect(result).to be_valid
      expect(result.params).to eq("email" => "A@B.C", "age" => 30, "plan" => "free")
      expect(result.params[:plan]).to eq("free")
    end

    it "returns an invalid result carrying the violation details, with nil params" do
      result = contract.call(user: { email: "nope", age: 17 })
      expect(result).to be_invalid
      expect(result.params).to be_nil
      expect(result.violations).to contain_exactly(
        { param: "user.email", code: "format" },
        { param: "user.age", code: "inclusion" }
      )
    end

    it "treats a missing root as a violation, not an exception" do
      result = contract.call({})
      expect(result).to be_invalid
      expect(result.violations).to eq([{ param: "user", code: "missing" }])
    end

    it "treats nil input as an empty hash and rejects non-hash input loudly" do
      expect(contract.call(nil)).to be_invalid
      expect { contract.call("payload") }.to raise_error(ArgumentError, /expects a Hash/)
    end

    it "keeps calls independent — a contract instance is reusable" do
      expect(contract.call({})).to be_invalid
      expect(contract.call(user: { email: "a@b.c" })).to be_valid
    end

    it "runs finalize with violate! support" do
      c = described_class.define do
        required :starts_on, :date
        required :ends_on,   :date
        finalize do |p|
          violate!("ends_on", :before_start) if p[:ends_on] < p[:starts_on]
          p
        end
      end
      expect(c.call(starts_on: "2026-01-02", ends_on: "2026-01-01").violations)
        .to eq([{ param: "ends_on", code: "before_start" }])
      expect(c.call(starts_on: "2026-01-01", ends_on: "2026-01-02")).to be_valid
    end

    it "does not exempt the router's bookkeeping keys — standalone input has no router" do
      c = described_class.define(unknown: :error) { optional :name, :string }
      result = c.call(name: "x", action: "boom", controller: "hax")
      expect(result.violations).to contain_exactly(
        { param: "action", code: "unknown" },
        { param: "controller", code: "unknown" }
      )
    end

    it "stays enforce-semantics even when the app-wide mode is monitor" do
      Permittable.mode = :monitor
      begin
        result = contract.call(user: { email: "nope" })
        expect(result).to be_invalid
        expect(result.params).to be_nil
      ensure
        Permittable.mode = :enforce
      end
    end
  end

  describe "#call!" do
    it "returns the params on success" do
      expect(contract.call!(user: { email: "a@b.c" })).to eq("email" => "a@b.c", "plan" => "free")
    end

    it "raises InvalidParameters carrying details and status on violation" do
      expect { contract.call!(user: { email: "nope" }) }
        .to raise_error(Permittable::InvalidParameters) do |e|
          expect(e.details).to eq([{ param: "user.email", code: "format" }])
          expect(e.status).to eq(:unprocessable_entity)
        end
    end

    it "uses 400 semantics for a missing root, like a controller would" do
      expect { contract.call!({}) }.to raise_error(Permittable::InvalidParameters) do |e|
        expect(e.status).to eq(:bad_request)
      end
    end
  end

  describe "#json_schema" do
    it "emits the same JSON Schema the OpenAPI exporter would" do
      schema = contract.json_schema
      expect(schema).to eq(Permittable::JsonSchema.rule(contract.rule))
      expect(schema.dig("properties", "user", "properties", "age", "type")).to eq("integer")
    end
  end

  it "registers sensitive fields with the filter registry" do
    described_class.define { optional :ssn, :string, sensitive: true }
    expect(Permittable.filter_parameter_registry.include?(:ssn)).to be(true)
  end

  it "instruments violations like a controller does" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
      events << payload
    end
    begin
      contract.call(user: { email: "nope" })
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
    expect(events.length).to eq(1)
    expect(events.first[:details]).to eq([{ param: "user.email", code: "format" }])
  end
end
