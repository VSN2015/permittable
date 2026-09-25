require "open3"

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

    it "distinguishes an explicitly-null nullable field from an absent one" do
      patch = described_class.define do
        optional :nickname, :string, nullable: true
        optional :bio, :string
      end
      expect(patch.call(nickname: nil, bio: nil).params.to_h).to eq("nickname" => nil)
      expect(patch.call({}).params.to_h).to eq({})
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

    it "does not exempt the router's or a form's bookkeeping keys — standalone input has neither" do
      c = described_class.define(unknown: :error) { optional :name, :string }
      result = c.call(name: "x", action: "boom", controller: "hax", authenticity_token: "tok")
      expect(result.violations).to contain_exactly(
        { param: "action", code: "unknown" },
        { param: "controller", code: "unknown" },
        { param: "authenticity_token", code: "unknown" }
      )
    end

    it "does not exempt path-parameter or wrapper-key names either — standalone input has no request" do
      c = described_class.define(unknown: :error) { optional :name, :string }
      result = c.call(name: "x", id: "1", user: { name: "x" })
      expect(result.violations).to contain_exactly({ param: "id", code: "unknown" }, { param: "user", code: "unknown" })
    end

    # The documented promise. A webhook payload has no Rails params builder in
    # front of it, so it reaches the contract with whatever a client sent —
    # malformed UTF-8 and non-finite Floats included.
    it "never raises on client input it cannot use — every case is a violation" do
      malformed = "caf\xC3"
      cases = {
        described_class.define { array :ids, of: :integer, validate: ->(a) { a.sum < 100 } } =>
          [{ ids: ["x", 2] }, "ids[0]"],
        described_class.define { required :n, :integer } => [{ n: Float::NAN }, "n"],
        described_class.define { required :n, :integer } => [{ n: Float::INFINITY }, "n"],
        described_class.define { required :s, :string, normalize: :squish } => [{ s: malformed }, "s"],
        described_class.define { required :s, :string, normalize: :strip } => [{ s: malformed }, "s"],
        described_class.define { required :s, :string, format: /\Acaf/ } => [{ s: malformed }, "s"],
        described_class.define { required :s, :string, format: :email } => [{ s: malformed }, "s"],
        described_class.define { array :tags, of: :string } => [{ tags: [malformed] }, "tags[0]"]
      }
      cases.each do |c, (input, param)|
        result = nil
        expect { result = c.call(input) }.not_to raise_error, "for #{input.inspect}"
        expect(result.violations).to eq([{ param: param, code: "invalid_type" }]), "for #{input.inspect}"
      end
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

  describe "without Rails loaded" do
    # spec_helper loads ActiveRecord, which pulls in every ActiveSupport core
    # extension and would mask a require the gem itself forgot. A standalone
    # Contract (webhook payload, job argument) may be the only thing an app
    # loads, so exercise nested input in a bare subprocess.
    it "validates nested hash input with only `require \"permittable\"`" do
      script = <<~RUBY
        require "json"
        require "permittable"
        contract = Permittable::Contract.define(unknown: :error) do
          required :user do
            required :test_key, :integer
          end
          optional :address_attributes do
            required :location, :integer
          end
        end
        print JSON.generate(contract.call!(user: { test_key: "1" }, address_attributes: { location: "2" }).to_h)
      RUBY
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
      expect(status).to be_success, err
      expect(out).to eq('{"user":{"test_key":1},"address_attributes":{"location":2}}')
    end

    it "casts every scalar type with only `require \"permittable\"`" do
      # :datetime named ActiveSupport::TimeWithZone unguarded, and nothing in
      # the gem loaded it — so a host that had not loaded ActiveSupport's time
      # extensions got NameError instead of a validated param.
      script = <<~RUBY
        require "json"
        require "permittable"
        contract = Permittable::Contract.define do
          required :s, :string
          required :i, :integer
          required :f, :float
          required :d, :decimal
          required :b, :boolean
          required :on, :date
          required :at, :datetime
          required :zoned, :datetime
        end
        # A REAL TimeWithZone, cast here rather than in-process: the constant
        # existing is not enough, it also needs the Time core extensions, and
        # an in-process example cannot see that because spec_helper has
        # already loaded them.
        require "active_support/time_with_zone"
        zoned = ActiveSupport::TimeZone["Asia/Bangkok"].local(2026, 9, 5, 17, 30)
        out = contract.call!(s: "x", i: "1", f: "1.5", d: "2.50", b: "true",
                             on: "2026-09-05", at: "2026-09-05T10:30:00Z", zoned: zoned)
        print JSON.generate(out.transform_values(&:to_s))
      RUBY
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq(
        "s" => "x", "i" => "1", "f" => "1.5", "d" => "0.25e1", "b" => "true",
        "on" => "2026-09-05", "at" => "2026-09-05 10:30:00 UTC",
        "zoned" => "2026-09-05 10:30:00 UTC"
      )
    end

    it "does not rewrite the caller's own Time while normalising it to UTC" do
      moment = Time.new(2026, 9, 5, 17, 30, 0, "+07:00")
      result = described_class.define { required :at, :datetime }.call!(at: moment)
      expect(result[:at]).to eq(Time.utc(2026, 9, 5, 10, 30))
      expect(result[:at].utc?).to be(true)
      # `Time#utc` converts its receiver, and `Time#to_time` returns self.
      expect(moment.utc?).to be(false)
      expect(moment.utc_offset).to eq(7 * 3600)
    end

    it "accepts an ActiveSupport::TimeWithZone for a :datetime without touching its cached UTC instance" do
      require "active_support/time"
      zone = ActiveSupport::TimeZone["Asia/Bangkok"]
      moment = zone.local(2026, 9, 5, 17, 30)
      result = described_class.define { required :at, :datetime }.call!(at: moment)
      expect(result[:at]).to eq(Time.utc(2026, 9, 5, 10, 30))
      expect(result[:at].utc?).to be(true)
      expect(result[:at]).not_to be(moment.utc)
    end
  end
end
