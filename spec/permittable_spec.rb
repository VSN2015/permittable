RSpec.describe Permittable do
  # FakeController responds to neither before_action nor rescue_from, so the
  # concern's guarded included-block installs nothing — specs drive
  # #permitted_params / #enforce_params_contract directly.
  def permittable_class(&declaration)
    Class.new(FakeController) do
      include Permittable

      class_eval(&declaration) if declaration
    end
  end

  def controller(klass, params: {}, action: "create")
    c = klass.new(params: params)
    c.define_singleton_method(:action_name) { action }
    c
  end

  # Build + validate in one step for the common case.
  def permit(params, action: "create", &declaration)
    controller(permittable_class(&declaration), params: params, action: action).permitted_params
  end

  def violations_for(params, action: "create", &declaration)
    permit(params, action: action, &declaration)
    raise "expected InvalidParameters"
  rescue described_class::InvalidParameters => e
    e
  end

  after { Permittable.filter_parameter_registry.reset! }

  # Shared by the observability and monitor-mode blocks.
  def recording_notifications
    events = []
    subscription = ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
      events << payload
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
    events
  end

  describe "macro validation" do
    it "requires a block" do
      expect { permittable_class { permit_params :create } }
        .to raise_error(ArgumentError, /requires a block/)
    end

    it "rejects an empty contract" do
      expect { permittable_class { permit_params(:create) {} } }
        .to raise_error(ArgumentError, /at least one field/)
    end

    it "rejects an unknown :unknown mode" do
      expect { permittable_class { permit_params(:create, unknown: :explode) { required :a } } }
        .to raise_error(ArgumentError, /:unknown must be one of ignore, log, error/)
    end

    it "rejects a non-Symbol root, pointing at the rootless recipe for several envelopes" do
      expect { permittable_class { permit_params(:create, root: %i[user address_attributes]) { required :a } } }
        .to raise_error(ArgumentError, /:root must be one key.*rootless contract with one nested block per key/)
    end

    it "rejects an unknown field option, naming the allowed ones" do
      expect { permittable_class { permit_params(:create) { required :a, :string, minimum: 3 } } }
        .to raise_error(ArgumentError, /unknown option\(s\) :minimum for field :a.*allowed:/)
    end

    it "rejects an unknown type" do
      expect { permittable_class { permit_params(:create) { required :a, :money } } }
        .to raise_error(ArgumentError, /unknown type :money.*supported: string, integer/)
    end

    it "rejects required + default (default implies optional)" do
      expect { permittable_class { permit_params(:create) { required :a, :string, default: "x" } } }
        .to raise_error(ArgumentError, /required and cannot have a :default/)
    end

    it "rejects format/length/normalize on non-string fields" do
      %i[format length normalize].zip([/\d/, 1..3, :squish]).each do |opt, value|
        expect { permittable_class { permit_params(:create) { required :a, :integer, opt => value } } }
          .to raise_error(ArgumentError, /:#{opt} is only supported on :string fields/)
      end
    end

    it "rejects :in that does not respond to include?" do
      expect { permittable_class { permit_params(:create) { required :a, :integer, in: 5 } } }
        .to raise_error(ArgumentError, /:in for field :a must respond to include\?/)
    end

    it "rejects a bound no value could satisfy, rather than failing every request" do
      expect { permittable_class { permit_params(:create) { optional :age, :integer, in: 65..18 } } }
        .to raise_error(ArgumentError, /:in for :age is empty \(65\.\.18\)/)
      expect { permittable_class { permit_params(:create) { optional :s, :string, length: 5..2 } } }
        .to raise_error(ArgumentError, /:length for :s is empty \(5\.\.2\)/)
      expect { permittable_class { permit_params(:create) { optional :s, :string, length: 3...3 } } }
        .to raise_error(ArgumentError, /:length for :s is empty/)
      expect { permittable_class { permit_params(:create) { optional :plan, :string, in: [] } } }
        .to raise_error(ArgumentError, /:in for :plan is empty/)
      expect { permittable_class { permit_params(:create) { optional :s, :string, length: -1 } } }
        .to raise_error(ArgumentError, /:length for :s must be a non-negative Integer or a Range/)
    end

    it "accepts an endless, beginless, or single-value bound" do
      expect { permittable_class { permit_params(:create) { optional :age, :integer, in: 18.. } } }.not_to raise_error
      expect { permittable_class { permit_params(:create) { optional :s, :string, length: ..80 } } }.not_to raise_error
      expect { permittable_class { permit_params(:create) { optional :s, :string, length: 5..5 } } }.not_to raise_error
    end

    it "rejects a required field whose length: forbids every non-empty value" do
      # "" is absent and an absent required field violates, so a required
      # string can never validly be empty — a max length of 0 leaves nothing.
      expect { permittable_class { permit_params(:create) { required :n, :string, length: 0 } } }
        .to raise_error(ArgumentError, /:length for :n is 0 on a required field/)
      expect { permittable_class { permit_params(:create) { required :n, :string, length: 0..0 } } }
        .to raise_error(ArgumentError, /:length for :n is 0 on a required field/)
      expect { permittable_class { permit_params(:create) { optional :n, :string, length: 0 } } }.not_to raise_error
    end

    it "checks a block array's default: against the block's own fields" do
      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "nonsense" => true }] do
              required :sku, :string
            end
          end
        end
      end.to raise_error(ArgumentError, /:default for array :items.*is missing :sku/)

      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => %w[an array] }] do
              required :sku, :string
            end
          end
        end
      end.to raise_error(ArgumentError, /:default for array :items.*:sku.*invalid_type/)

      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => "a" }] do
              required :sku, :string
            end
          end
        end
      end.not_to raise_error
    end

    it "reads absence in a block array's default: the way a request does" do
      # "" is absent, so a client sending { "sku" => "" } gets `missing` — but
      # a default: is applied WITHOUT revalidation, so accepting one here
      # hands the app the exact value the contract refuses from a client.
      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => "" }] do
              required :sku, :string
            end
          end
        end
      end.to raise_error(ArgumentError, /:default for array :items.*is missing :sku/)

      # normalize: runs BEFORE the absence rule at request time; a default
      # that normalizes to empty is absent for the same reason.
      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => "   " }] do
              required :sku, :string, normalize: :squish
            end
          end
        end
      end.to raise_error(ArgumentError, /:default for array :items.*is missing :sku/)
    end

    it "accepts an empty value a block array's default: is allowed to carry" do
      # nullable: splits the absence rule — an explicitly-sent empty value is
      # a null, not an absence, so it is a legal thing for a default to say.
      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => "" }] do
              required :sku, :string, nullable: true
            end
          end
        end
      end.not_to raise_error

      # An optional sub-field is simply omitted when absent.
      expect do
        permittable_class do
          permit_params(:create) do
            array :items, default: [{ "sku" => "a", "note" => "" }] do
              required :sku, :string
              optional :note, :string
            end
          end
        end
      end.not_to raise_error
    end

    it "rejects a non-callable :validate" do
      expect { permittable_class { permit_params(:create) { required :a, :string, validate: :nope } } }
        .to raise_error(ArgumentError, /:validate for field :a must be callable/)
    end

    it "rejects a duplicate field in the same contract" do
      expect do
        permittable_class do
          permit_params(:create) do
            required :a
            optional :a
          end
        end
      end
        .to raise_error(ArgumentError, /:a is declared twice/)
    end

    it "rejects a type combined with a nested block" do
      expect { permittable_class { permit_params(:create) { required(:a, :string) { required :b } } } }
        .to raise_error(ArgumentError, /takes a type OR a nested block/)
    end

    it "rejects an empty nested block" do
      expect { permittable_class { permit_params(:create) { required(:a) {} } } }
        .to raise_error(ArgumentError, /nested field :a declares no sub-fields/)
    end

    it "rejects array with both of: and a block" do
      expect { permittable_class { permit_params(:create) { array(:a, of: :string) { required :b } } } }
        .to raise_error(ArgumentError, /takes of: OR a block/)
    end

    it "rejects a non-Array array default and elements violating of:" do
      expect { permittable_class { permit_params(:create) { array :a, default: "x" } } }
        .to raise_error(ArgumentError, /:default for array :a must be an Array/)
      expect { permittable_class { permit_params(:create) { array :a, of: :integer, default: ["x"] } } }
        .to raise_error(ArgumentError, /contains an element violating of: :integer/)
    end

    it "rejects a default that violates the field's own contract" do
      expect { permittable_class { permit_params(:create) { optional :a, :string, in: %w[x y], default: "z" } } }
        .to raise_error(ArgumentError, /:default for field :a violates its own contract \(inclusion\)/)
    end

    it "rejects an unknown normalize preset, listing the presets" do
      expect { permittable_class { permit_params(:create) { optional :a, :string, normalize: :shout } } }
        .to raise_error(ArgumentError, /unknown :normalize preset :shout.*squish, strip, downcase, upcase, email/)
    end

    it "carries desc:/example: as documentation-only data the runtime never reads" do
      klass = permittable_class do
        permit_params(:create, desc: "Create a user") do
          required :name, :string, desc: "Display name", example: "Jo"
          array :tags, of: :string, example: %w[a b]
          optional(:address, desc: "Postal address") { required :city, :string }
        end
      end
      rule = klass.permit_rule_for(:create)
      expect(rule[:desc]).to eq("Create a user")
      expect(rule[:fields].first).to include(desc: "Display name", example: "Jo")
      expect(controller(klass, params: { name: "Jo" }).permitted_params.to_h).to eq("name" => "Jo")
    end

    it "rejects an example: that violates its own field's contract, like a default" do
      expect { permittable_class { permit_params(:create) { optional :plan, :string, in: %w[free pro], example: "gold" } } }
        .to raise_error(ArgumentError, /:example for field :plan violates its own contract \(inclusion\)/)
      expect { permittable_class { permit_params(:create) { array :ids, of: :integer, example: ["x"] } } }
        .to raise_error(ArgumentError, /:example for array :ids contains an element violating of: :integer/)
      expect { permittable_class { permit_params(:create) { required(:a, example: {}) { required :b } } } }
        .to raise_error(ArgumentError, /unknown option\(s\) :example for field :a/)
    end
  end

  describe "type casting" do
    it "casts integers strictly" do
      result = permit({ n: "42" }) { permit_params(:create) { required :n, :integer } }
      expect(result[:n]).to eq(42)

      e = violations_for({ n: "abc" }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
      expect(violations_for({ n: "4.5" }) { permit_params(:create) { required :n, :integer } }.details.first[:code]).to eq("invalid_type")
    end

    it "accepts a whole Float for :integer but rejects a fractional one (JSON numbers)" do
      klass = permittable_class { permit_params(:create) { required :n, :integer } }
      expect(controller(klass, params: { n: 42.0 }).permitted_params[:n]).to eq(42)
      expect { controller(klass, params: { n: 42.5 }).permitted_params }
        .to raise_error(described_class::InvalidParameters)
    end

    it "rejects array/hash values where a scalar is expected (type confusion)" do
      e = violations_for({ n: ["1"] }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
      e = violations_for({ n: { x: "1" } }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
    end

    it "casts booleans from the strict truth set only" do
      klass = permittable_class { permit_params(:create) { required :flag, :boolean } }
      expect(controller(klass, params: { flag: "true" }).permitted_params[:flag]).to be(true)
      expect(controller(klass, params: { flag: "1" }).permitted_params[:flag]).to be(true)
      expect(controller(klass, params: { flag: "0" }).permitted_params[:flag]).to be(false)
      expect(controller(klass, params: { flag: false }).permitted_params[:flag]).to be(false)
      expect { controller(klass, params: { flag: "yes" }).permitted_params }
        .to raise_error(described_class::InvalidParameters)
    end

    it "casts float, decimal, date, and datetime" do
      result = permit({ f: "3.14", d: "19.99", day: "2026-08-15", at: "2026-08-15T10:00:00" }) do
        permit_params(:create) do
          required :f,   :float
          required :d,   :decimal
          required :day, :date
          required :at,  :datetime
        end
      end
      expect(result[:f]).to eq(3.14)
      expect(result[:d]).to eq(BigDecimal("19.99"))
      expect(result[:d]).to be_a(BigDecimal)
      expect(result[:day]).to eq(Date.new(2026, 8, 15))
      # Zoneless strings parse as UTC — deterministic across host timezones.
      expect(result[:at]).to eq(Time.utc(2026, 8, 15, 10))
    end

    it "rejects unparseable dates and datetimes" do
      expect(violations_for({ day: "not-a-day" }) do
        permit_params(:create) do
          required :day, :date
        end
      end.details.first[:code]).to eq("invalid_type")
      expect(violations_for({ at: "not-a-time" }) do
        permit_params(:create) do
          required :at, :datetime
        end
      end.details.first[:code]).to eq("invalid_type")
    end

    it "stringifies numbers and booleans for :string (JSON bodies)" do
      klass = permittable_class { permit_params(:create) { required :s } }
      expect(controller(klass, params: { s: 42 }).permitted_params[:s]).to eq("42")
      expect(controller(klass, params: { s: true }).permitted_params[:s]).to eq("true")
    end
  end

  describe "dates are parsed, never guessed" do
    let(:decl) do
      proc do
        permit_params(:create) do
          optional :on, :date
          optional :at, :datetime
        end
      end
    end

    it "accepts every format that fully specifies a date" do
      %w[2026-09-05 2026/09/05].each do |value|
        expect(permit({ on: value }, &decl)[:on]).to eq(Date.new(2026, 9, 5)), "for #{value}"
      end
      ["Sep 5, 2026", "5 September 2026", "2026-09-05T10:00:00Z"].each do |value|
        expect(permit({ on: value }, &decl)[:on]).to eq(Date.new(2026, 9, 5)), "for #{value}"
      end
    end

    it "REJECTS input whose missing parts would be invented from today" do
      # Date.parse fills these in from the current date, so the same request
      # produced a different value depending on the day it arrived.
      {
        "09/2026" => "no day",
        "5th" => "no month or year",
        "Sept" => "no day or year",
        "September" => "no day or year"
      }.each do |value, why|
        expect(violations_for({ on: value }, &decl).details)
          .to eq([{ param: "on", code: "invalid_type" }]), "expected #{value.inspect} (#{why}) to be rejected"
      end
    end

    it "still rejects what it always rejected" do
      %w[2026-13-01 2026-02-30 nonsense T].each do |value|
        expect(violations_for({ on: value }, &decl).details)
          .to eq([{ param: "on", code: "invalid_type" }]), "for #{value}"
      end
    end

    it "matches what Date.parse would have produced, including calendar validation" do
      # The Date is built from the parsed components rather than by parsing a
      # second time, so this pins that the two agree — leap years included.
      { "2026-09-05" => Date.new(2026, 9, 5),
        "2026/09/05" => Date.new(2026, 9, 5),
        "20260905" => Date.new(2026, 9, 5),
        "2024-02-29" => Date.new(2024, 2, 29) }.each do |value, expected|
        expect(permit({ on: value }, &decl)[:on]).to eq(expected), "for #{value}"
      end
      # 2026 is not a leap year, and there is no 30th of February in any.
      %w[2026-02-29 2026-02-30].each do |value|
        expect(violations_for({ on: value }, &decl).details)
          .to eq([{ param: "on", code: "invalid_type" }]), "for #{value}"
      end
    end

    it "accepts a Date object unchanged" do
      expect(permit({ on: Date.new(2026, 9, 5) }, &decl)[:on]).to eq(Date.new(2026, 9, 5))
    end

    it "applies the same rule to :datetime, where the time part may be absent" do
      expect(permit({ at: "2026-09-05T10:30:00Z" }, &decl)[:at]).to eq(Time.utc(2026, 9, 5, 10, 30))
      # A date with no time is midnight UTC, as documented.
      expect(permit({ at: "2026-09-05" }, &decl)[:at]).to eq(Time.utc(2026, 9, 5))
      # A time with no date used to become TODAY at that time.
      expect(violations_for({ at: "10:30" }, &decl).details).to eq([{ param: "at", code: "invalid_type" }])
      expect(violations_for({ at: "Sept" }, &decl).details).to eq([{ param: "at", code: "invalid_type" }])
    end

    it "accepts Time, DateTime and Date objects for :datetime, normalising to UTC" do
      expect(permit({ at: Time.utc(2026, 9, 5, 10, 30) }, &decl)[:at]).to eq(Time.utc(2026, 9, 5, 10, 30))
      expect(permit({ at: DateTime.new(2026, 9, 5, 10, 30, 0, "+07:00") }, &decl)[:at])
        .to eq(Time.utc(2026, 9, 5, 3, 30))
      expect(permit({ at: Date.new(2026, 9, 5) }, &decl)[:at]).to eq(Time.utc(2026, 9, 5))
    end
  end

  describe "numbers the type cannot faithfully hold" do
    let(:decl) do
      proc do
        permit_params(:create) do
          optional :f, :float
          optional :d, :decimal
        end
      end
    end

    def rejected(key, value, &decl)
      violations_for({ key => value }, &decl).details
    end

    it "rejects a :float that overflowed to Infinity" do
      ["1e400", "-1e400", "1#{"0" * 400}"].each do |value|
        expect(rejected(:f, value, &decl)).to eq([{ param: "f", code: "invalid_type" }]), "for #{value[0, 12]}"
      end
    end

    it "rejects a :float that underflowed to zero, losing the whole value" do
      ["1e-400", "-1e-400", "0.1e-400"].each do |value|
        expect(rejected(:f, value, &decl)).to eq([{ param: "f", code: "invalid_type" }]), "for #{value}"
      end
    end

    it "still accepts a genuine zero, however it is spelled" do
      ["0", "0.0", "-0.0", "0e10", "0.0000"].each do |value|
        expect(permit({ f: value }, &decl)[:f]).to eq(0.0), "for #{value}"
      end
    end

    it "rejects non-finite Float objects for both numeric types" do
      [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
        expect(rejected(:f, value, &decl)).to eq([{ param: "f", code: "invalid_type" }]), "for :float #{value}"
        expect(rejected(:d, value, &decl)).to eq([{ param: "d", code: "invalid_type" }]), "for :decimal #{value}"
      end
    end

    it "rejects the literal strings a client could send for a :decimal" do
      # BigDecimal("NaN") succeeds where Float("NaN") raises, so :decimal
      # accepted these while :float did not.
      %w[NaN Infinity -Infinity].each do |value|
        expect(rejected(:d, value, &decl)).to eq([{ param: "d", code: "invalid_type" }]), "for #{value}"
      end
    end

    it "keeps accepting the large exponents BigDecimal genuinely represents" do
      expect(permit({ d: "1e400" }, &decl)[:d]).to eq(BigDecimal("1e400"))
      expect(permit({ d: "0.0000000000000000001" }, &decl)[:d]).to eq(BigDecimal("1e-19"))
    end

    it "leaves ordinary numbers alone" do
      result = permit({ f: "1.5", d: "2.50" }, &decl)
      expect(result[:f]).to eq(1.5)
      expect(result[:d]).to eq(BigDecimal("2.5"))
      expect(permit({ f: 3, d: 4 }, &decl).to_h).to eq("f" => 3.0, "d" => BigDecimal("4"))
    end
  end

  describe "validations" do
    it "checks in: as Range (cover) and as Array (inclusion)" do
      decl = proc { permit_params(:create) { required :age, :integer, in: 18..120 } }
      expect(permit({ age: "30" }, &decl)[:age]).to eq(30)
      expect(violations_for({ age: "12" }, &decl).details).to eq([{ param: "age", code: "inclusion" }])

      e = violations_for({ plan: "gold" }) { permit_params(:create) { required :plan, :string, in: %w[free pro] } }
      expect(e.details.first[:code]).to eq("inclusion")
    end

    it "checks format on strings" do
      decl = proc { permit_params(:create) { required :zip, :string, format: /\A\d{5}\z/ } }
      expect(permit({ zip: "12345" }, &decl)[:zip]).to eq("12345")
      expect(violations_for({ zip: "12a45" }, &decl).details).to eq([{ param: "zip", code: "format" }])
    end

    it "checks length as a Range and as an exact Integer" do
      decl = proc { permit_params(:create) { required :name, :string, length: 1..3 } }
      expect(violations_for({ name: "toolong" }, &decl).details).to eq([{ param: "name", code: "length" }])

      exact = proc { permit_params(:create) { required :code, :string, length: 2 } }
      expect(permit({ code: "ab" }, &exact)[:code]).to eq("ab")
      expect(violations_for({ code: "abc" }, &exact).details.first[:code]).to eq("length")
    end

    it "normalizes before validating (presets and Procs)" do
      email = permit({ email: "  Jo@Example.COM " }) do
        permit_params(:create) { required :email, :string, normalize: :email, format: /\A\S+@\S+\z/ }
      end
      expect(email[:email]).to eq("jo@example.com")

      squished = permit({ name: "  a   b  " }) { permit_params(:create) { required :name, :string, normalize: :squish } }
      expect(squished[:name]).to eq("a b")

      custom = permit({ sku: "ab-1" }) { permit_params(:create) { required :sku, :string, normalize: ->(v) { v.upcase } } }
      expect(custom[:sku]).to eq("AB-1")
    end

    it "treats a value that NORMALIZES to empty as absent, like any other empty value" do
      decl = proc do
        permit_params(:create) do
          required :name, :string, normalize: :squish
          optional :plan, :string, normalize: :strip, default: "free"
          optional :note, :string, normalize: :strip, nullable: true
        end
      end
      expect(violations_for({ name: "   " }, &decl).details).to eq([{ param: "name", code: "missing" }])
      expect(permit({ name: "a", plan: "  " }, &decl)[:plan]).to eq("free")
      expect(permit({ name: "a", note: "  " }, &decl)[:note]).to be_nil
      expect(permit({ name: "  a   b  " }, &decl)[:name]).to eq("a b")
    end

    it "normalizes exactly once per value" do
      calls = 0
      counting = lambda do |v|
        calls += 1
        v.strip
      end
      result = permit({ name: " a " }) { permit_params(:create) { required :name, :string, normalize: counting } }

      expect(result[:name]).to eq("a")
      expect(calls).to eq(1)
    end

    it "runs a custom validate: — falsy fails as 'invalid', a Symbol fails as that code, truthy passes" do
      falsy = proc { permit_params(:create) { required :n, :integer, validate: ->(v) { v.even? } } }
      expect(permit({ n: "4" }, &falsy)[:n]).to eq(4)
      expect(violations_for({ n: "3" }, &falsy).details).to eq([{ param: "n", code: "invalid" }])

      coded = proc { permit_params(:create) { required :n, :integer, validate: ->(v) { v.even? || :must_be_even } } }
      expect(violations_for({ n: "3" }, &coded).details).to eq([{ param: "n", code: "must_be_even" }])
    end
  end

  describe "format: presets" do
    def format_violations(value, preset)
      violations_for({ v: value }) { permit_params(:create) { required :v, :string, format: preset } }.details
    end

    it "accepts the same emails URI::MailTo::EMAIL_REGEXP does, which is what apps write by hand" do
      expect(permit({ v: "a.b+c@example.co.uk" }) { permit_params(:create) { required :v, :string, format: :email } }[:v])
        .to eq("a.b+c@example.co.uk")
      expect(format_violations("nope", :email)).to eq([{ param: "v", code: "format" }])
      expect(Permittable::FORMATS[:email][:pattern]).to eq(URI::MailTo::EMAIL_REGEXP)
    end

    it "matches a canonical UUID in either case, and nothing else" do
      %w[123e4567-e89b-12d3-a456-426614174000 123E4567-E89B-12D3-A456-426614174000].each do |uuid|
        expect(permit({ v: uuid }) { permit_params(:create) { required :v, :string, format: :uuid } }[:v]).to eq(uuid)
      end
      %w[123e4567e89b12d3a456426614174000 123e4567-e89b-12d3-a456-42661417400 zzz].each do |bad|
        expect(format_violations(bad, :uuid)).to eq([{ param: "v", code: "format" }]), "for #{bad}"
      end
    end

    it "matches an http(s) URL and rejects other schemes or whitespace" do
      expect(permit({ v: "https://a.example/x?y=1" }) { permit_params(:create) { required :v, :string, format: :url } }[:v])
        .to eq("https://a.example/x?y=1")
      ["ftp://a.example", "javascript:alert(1)", "http://a b", "example.com"].each do |bad|
        expect(format_violations(bad, :url)).to eq([{ param: "v", code: "format" }]), "for #{bad}"
      end
    end

    it "matches a lowercase hyphenated slug" do
      expect(permit({ v: "my-post-2" }) { permit_params(:create) { required :v, :string, format: :slug } }[:v])
        .to eq("my-post-2")
      ["My-Post", "-leading", "trailing-", "double--hyphen", "under_score"].each do |bad|
        expect(format_violations(bad, :slug)).to eq([{ param: "v", code: "format" }]), "for #{bad}"
      end
    end

    it "resolves the preset to its Regexp on the frozen field, and remembers the name" do
      klass = permittable_class { permit_params(:create) { required :v, :string, format: :uuid } }
      field = klass.permit_rule_for("create")[:fields].first
      expect(field[:format]).to be_a(Regexp)
      expect(field[:format_name]).to eq(:uuid)
    end

    it "leaves a Regexp passed directly alone, with no preset name" do
      klass = permittable_class { permit_params(:create) { required :v, :string, format: /\Ax\z/ } }
      field = klass.permit_rule_for("create")[:fields].first
      expect(field[:format]).to eq(/\Ax\z/)
      expect(field.key?(:format_name)).to be(false)
    end

    it "rejects an unknown preset at class load, listing the presets" do
      expect { permittable_class { permit_params(:create) { required :v, :string, format: :postcode } } }
        .to raise_error(ArgumentError,
                        /unknown :format preset :postcode for field :v \(presets: email, uuid, url, slug, hostname, or pass a Regexp\)/)
    end

    it "still refuses format: on a non-string field" do
      expect { permittable_class { permit_params(:create) { required :v, :integer, format: :uuid } } }
        .to raise_error(ArgumentError, /:format is only supported on :string fields/)
    end

    it "checks an authored default:/example: against the resolved preset at class load" do
      expect { permittable_class { permit_params(:create) { optional :v, :string, format: :slug, default: "Nope" } } }
        .to raise_error(ArgumentError, /:default for field :v violates its own contract \(format\)/)
    end
  end

  describe "rule ordering: the cheap bound before the expensive one" do
    # A Regexp subclass, so it satisfies any `format:` type check while
    # recording whether the contract ever consulted it.
    let(:spy_format) do
      Class.new(Regexp) do
        def consulted?
          !!@consulted
        end

        def match?(value)
          @consulted = true
          super
        end
      end.new("\\A[a-z]+\\z")
    end

    it "does not consult format: for a value length: has already excluded" do
      spy = spy_format
      klass = permittable_class do
        permit_params(:create) { required :s, :string, length: 1..8, format: spy }
      end
      e = begin
        controller(klass, params: { s: "a" * 5_000 }).permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      expect(e.details).to eq([{ param: "s", code: "length" }])
      expect(spy.consulted?).to be(false)
    end

    it "still consults format: for a value within the length bound" do
      spy = spy_format
      klass = permittable_class do
        permit_params(:create) { required :s, :string, length: 1..8, format: spy }
      end
      e = begin
        controller(klass, params: { s: "AB" }).permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      expect(e.details).to eq([{ param: "s", code: "format" }])
      expect(spy.consulted?).to be(true)
    end

    it "reports length before in: and validate:, and leaves each of them working alone" do
      decl = proc do
        permit_params(:create) do
          optional :a, :string, length: 1..3, in: %w[hello]
          optional :b, :string, length: 1..3, validate: ->(_v) { raise "must not run" }
        end
      end
      expect(violations_for({ a: "hello" }, &decl).details).to eq([{ param: "a", code: "length" }])
      expect(violations_for({ b: "toolong" }, &decl).details).to eq([{ param: "b", code: "length" }])
      expect(violations_for({ a: "no" }, &decl).details).to eq([{ param: "a", code: "inclusion" }])
    end

    it "leaves a field with no length: bound checking format: as before" do
      decl = proc { permit_params(:create) { required :s, :string, format: /\A[a-z]+\z/ } }
      expect(violations_for({ s: "AB" }, &decl).details).to eq([{ param: "s", code: "format" }])
    end
  end

  describe "message: (custom error messages)" do
    it "rejects a message that is neither a String nor a code => String Hash" do
      expect { permittable_class { permit_params(:create) { required :a, :string, message: :nope } } }
        .to raise_error(ArgumentError, /:message for field :a must be a String or a Hash of violation code => String/)
      expect { permittable_class { permit_params(:create) { required :a, :string, message: { format: :nope } } } }
        .to raise_error(ArgumentError, /:message for field :a/)
      expect { permittable_class { permit_params(:create) { required :a, :string, message: {} } } }
        .to raise_error(ArgumentError, /:message for field :a/)
    end

    it "a String message covers every violation code on the field, and replaces (code) in the summary" do
      decl = proc { permit_params(:create) { required :email, :string, format: /@/, message: "must be a valid email" } }

      e = violations_for({ email: "nope" }, &decl)
      expect(e.details).to eq([{ param: "email", code: "format", message: "must be a valid email" }])
      expect(e.message).to eq("Invalid parameters: email must be a valid email")

      expect(violations_for({}, &decl).details)
        .to eq([{ param: "email", code: "missing", message: "must be a valid email" }])
    end

    it "a Hash message resolves per code — codes without an entry keep the bare shape" do
      decl = proc do
        permit_params(:create) do
          required :email, :string, format: /@/, message: { missing: "is required", format: "must be a valid email" }
        end
      end
      expect(violations_for({}, &decl).details).to eq([{ param: "email", code: "missing", message: "is required" }])
      expect(violations_for({ email: "nope" }, &decl).details)
        .to eq([{ param: "email", code: "format", message: "must be a valid email" }])

      e = violations_for({ email: ["x@y"] }, &decl) # invalid_type has no entry
      expect(e.details).to eq([{ param: "email", code: "invalid_type" }])
      expect(e.message).to eq("Invalid parameters: email (invalid_type)")

      string_keys = proc { permit_params(:create) { required :a, :string, message: { "missing" => "is required" } } }
      expect(violations_for({}, &string_keys).details).to eq([{ param: "a", code: "missing", message: "is required" }])
    end

    it "matches a Symbol code returned by a custom validate:" do
      decl = proc do
        permit_params(:create) do
          required :n, :integer, validate: ->(v) { v.even? || :must_be_even }, message: { must_be_even: "must be an even number" }
        end
      end
      expect(violations_for({ n: "3" }, &decl).details)
        .to eq([{ param: "n", code: "must_be_even", message: "must be an even number" }])
    end

    it "applies an array's message to violations on the array and on its elements" do
      decl = proc { permit_params(:create) { array :ages, of: :integer, length: 1..2, message: "must be one or two whole numbers" } }
      expect(violations_for({ ages: [] }, &decl).details)
        .to eq([{ param: "ages", code: "length", message: "must be one or two whole numbers" }])
      expect(violations_for({ ages: ["x"] }, &decl).details)
        .to eq([{ param: "ages[0]", code: "invalid_type", message: "must be one or two whole numbers" }])
    end

    it "nested fields resolve their own message, independent of the parent's" do
      decl = proc do
        permit_params(:create) do
          required :address, message: "must be an object" do
            required :zip, :string, format: /\A\d{5}\z/, message: { format: "must be five digits" }
          end
        end
      end
      expect(violations_for({ address: "nope" }, &decl).details)
        .to eq([{ param: "address", code: "invalid_type", message: "must be an object" }])
      expect(violations_for({ address: { zip: "abc" } }, &decl).details)
        .to eq([{ param: "address.zip", code: "format", message: "must be five digits" }])
    end

    it "violate! carries an optional message: into the detail" do
      e = violations_for({ a: "x" }) do
        permit_params(:create) do
          required :a, :string
          finalize do |p|
            violate!("a", :conflict, message: "cannot be combined with b")
            p
          end
        end
      end
      expect(e.details).to eq([{ param: "a", code: "conflict", message: "cannot be combined with b" }])
      expect(e.message).to eq("Invalid parameters: a cannot be combined with b")
    end

    it "flows into the rendered error envelope" do
      klass = permittable_class { permit_params(:create) { required :name, :string, message: { missing: "is required" } } }
      c = controller(klass, params: {})
      begin
        c.permitted_params
      rescue described_class::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      expect(c.rendered[:json][:error][:message]).to eq("Invalid parameters: name is required")
      expect(c.rendered[:json][:error][:details]).to eq([{ param: "name", code: "missing", message: "is required" }])
    end
  end

  describe "absence, defaults, and required" do
    let(:decl) do
      proc do
        permit_params(:create) do
          required :name, :string
          optional :plan, :string, default: "free"
          optional :note, :string
        end
      end
    end

    it "applies defaults when the key is missing, nil, or empty" do
      expect(permit({ name: "a" }, &decl)[:plan]).to eq("free")
      expect(permit({ name: "a", plan: nil }, &decl)[:plan]).to eq("free")
      expect(permit({ name: "a", plan: "" }, &decl)[:plan]).to eq("free")
    end

    it "OMITS absent optional fields (partial updates never nil-out columns)" do
      result = permit({ name: "a" }, &decl)
      expect(result.key?("note")).to be(false)
      expect(result.to_h).to eq("name" => "a", "plan" => "free")
    end

    it "flags a missing / nil / empty required field" do
      expect(violations_for({}, &decl).details).to eq([{ param: "name", code: "missing" }])
      expect(violations_for({ name: "" }, &decl).details).to eq([{ param: "name", code: "missing" }])
    end

    it "treats boolean false as PRESENT" do
      result = permit({ ok: false }) { permit_params(:create) { required :ok, :boolean } }
      expect(result[:ok]).to be(false)
    end

    it "hands each request its own copy of a mutable default:" do
      klass = permittable_class do
        permit_params(:create) do
          array :tags, of: :string, default: ["a"]
          optional :plan, :string, default: "free"
          optional :meta, :json, default: { "k" => "v" }
        end
      end
      first = controller(klass).permitted_params
      first[:tags] << "leak"
      first[:plan] << "!"
      first[:meta]["leak"] = true

      second = controller(klass).permitted_params
      expect(second[:tags]).to eq(["a"])
      expect(second[:plan]).to eq("free")
      expect(second[:meta].to_h).to eq("k" => "v")
      expect(second[:tags]).not_to be(first[:tags])
    end

    it "freezes its own copy of an authored value, never the caller's object" do
      authored = ["a"]
      klass = permittable_class { permit_params(:create) { array :tags, of: :string, default: authored } }
      stored = klass.permittable_contracts.last[:fields].first[:default]

      expect(stored).to be_frozen
      expect(stored).not_to be(authored)
      expect(authored).not_to be_frozen
    end

    it "delivers a default: in the normalized form it was validated in" do
      result = permit({}) do
        permit_params(:create) { optional :plan, :string, normalize: :squish, default: "  free  " }
      end
      expect(result[:plan]).to eq("free")
    end
  end

  describe "nullable:" do
    let(:decl) do
      proc do
        permit_params(:create) do
          optional :nickname, :string, nullable: true
          optional :plan, :string, in: %w[free pro], default: "free", nullable: true
          optional :age, :integer, in: 18..120, nullable: true
          optional :note, :string
        end
      end
    end

    it "yields an explicit nil when the key is present and empty" do
      result = permit({ nickname: nil }, &decl)
      expect(result.key?("nickname")).to be(true)
      expect(result["nickname"]).to be_nil
    end

    it "treats a present empty string as an explicit null too (the form-encoded convention)" do
      expect(permit({ nickname: "" }, &decl).fetch("nickname")).to be_nil
    end

    it "still OMITS the field when the key is absent" do
      expect(permit({}, &decl).key?("nickname")).to be(false)
    end

    it "prefers an explicit null over the field's default (the PATCH fix)" do
      expect(permit({ plan: nil }, &decl).fetch("plan")).to be_nil
      expect(permit({}, &decl)["plan"]).to eq("free")
    end

    it "skips in:/format:/length:/validate: for an explicit null" do
      expect(permit({ age: nil }, &decl).fetch("age")).to be_nil
      expect(permit({ plan: nil }, &decl).fetch("plan")).to be_nil
    end

    it "does not apply transform: to an explicit null" do
      result = permit({ tag: nil }) do
        permit_params(:create) { optional :tag, :string, nullable: true, transform: ->(v) { v.upcase } }
      end
      expect(result.fetch("tag")).to be_nil
    end

    it "leaves non-nullable fields absent-as-before" do
      expect(permit({ note: nil }, &decl).key?("note")).to be(false)
    end

    it "still violates `missing` for a required nullable field whose key is absent" do
      expect(violations_for({}) { permit_params(:create) { required :a, :string, nullable: true } }.details)
        .to eq([{ param: "a", code: "missing" }])
    end

    it "accepts an explicit null for a required nullable field (presence stated, value null)" do
      result = permit({ a: nil }) { permit_params(:create) { required :a, :string, nullable: true } }
      expect(result.fetch("a")).to be_nil
    end

    it "allows default: nil only on a nullable field (absent means clear — PUT semantics)" do
      result = permit({}) { permit_params(:create) { optional :a, :string, nullable: true, default: nil } }
      expect(result.fetch("a")).to be_nil

      expect { permittable_class { permit_params(:create) { optional :a, :string, default: nil } } }
        .to raise_error(ArgumentError, /:default for field :a is nil but the field is not nullable/)
    end

    it "nulls a whole nested block, distinctly from an empty hash" do
      decl = proc do
        permit_params(:create) do
          optional :address, nullable: true do
            required :city, :string
          end
        end
      end
      expect(permit({ address: nil }, &decl).fetch("address")).to be_nil
      expect(violations_for({ address: {} }, &decl).details).to eq([{ param: "address.city", code: "missing" }])
    end

    it "nulls a whole array, distinctly from an empty array" do
      decl = proc { permit_params(:create) { array :tags, of: :string, nullable: true, length: 1..3 } }
      expect(permit({ tags: nil }, &decl).fetch("tags")).to be_nil
      expect(violations_for({ tags: [] }, &decl).details).to eq([{ param: "tags", code: "length" }])
    end

    it "does not make an array's ELEMENTS nullable" do
      violations = violations_for({ tags: [nil] }) do
        permit_params(:create) { array :tags, of: :string, nullable: true }
      end
      expect(violations.details).to eq([{ param: "tags[0]", code: "invalid_type" }])
    end

    it "carries nullable: into the frozen rule so exporters can read it" do
      klass = permittable_class(&decl)
      field = klass.permit_rule_for("create")[:fields].first
      expect(field[:nullable]).to be(true)
    end
  end

  describe "root:" do
    let(:decl) { proc { permit_params(:create, root: :user) { required :name, :string } } }

    it "unwraps the root key and prefixes violation paths with it" do
      expect(permit({ user: { name: "Jo" }, other: "ignored" }, &decl)[:name]).to eq("Jo")
      expect(violations_for({ user: {} }, &decl).details).to eq([{ param: "user.name", code: "missing" }])
    end

    it "raises with status :bad_request when the root key is missing or not a hash" do
      e = violations_for({}, &decl)
      expect(e.status).to eq(:bad_request)
      expect(e.details).to eq([{ param: "user", code: "missing" }])

      expect(violations_for({ user: "nope" }, &decl).status).to eq(:bad_request)
    end

    it "says `missing` only when the root really is absent" do
      [{}, { user: nil }, { user: "" }].each do |params|
        expect(violations_for(params, &decl).details)
          .to eq([{ param: "user", code: "missing" }]), "for #{params.inspect}"
      end
    end

    it "says `invalid_type` for a root the client DID send with the wrong shape" do
      [{ user: "bob" }, { user: [] }, { user: 3 }, { user: false }].each do |params|
        e = violations_for(params, &decl)
        expect(e.details).to eq([{ param: "user", code: "invalid_type" }]), "for #{params.inspect}"
        # Still a malformed envelope, so still a 400.
        expect(e.status).to eq(:bad_request)
      end
    end
  end

  describe "unknown:" do
    it "ignores undeclared keys by default" do
      result = permit({ name: "a", extra: "x" }) { permit_params(:create) { required :name, :string } }
      expect(result.to_h).to eq("name" => "a")
    end

    it "flags undeclared keys with unknown: :error, skipping routing keys at the top level" do
      e = violations_for({ name: "a", extra: "x", controller: "users", action: "create", format: "json" }) do
        permit_params(:create, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "extra", code: "unknown" }])
    end

    it "skips the form bookkeeping keys Rails merges into a POST, flagging only the real stray" do
      e = violations_for({ name: "a", extra: "x", authenticity_token: "tok",
                           _method: "patch", utf8: "✓", commit: "Save" }) do
        permit_params(:create, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "extra", code: "unknown" }])
    end

    it "still flags a form key smuggled inside a root (the exemption is top-level only)" do
      e = violations_for({ user: { name: "a", authenticity_token: "smuggled" } }) do
        permit_params(:create, root: :user, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "user.authenticity_token", code: "unknown" }])
    end

    it "passes the form keys through in monitor mode — only the router's own keys are dropped" do
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :n, :integer } }
      passed = controller(klass, params: { n: "x", _method: "patch", controller: "users" }).permitted_params
      expect(passed.to_h).to eq("n" => "x", "_method" => "patch")
    end

    it "flags undeclared keys inside root and nested hashes (routing keys are only top-level)" do
      e = violations_for({ user: { name: "a", controller: "smuggled" } }) do
        permit_params(:create, root: :user, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "user.controller", code: "unknown" }])
    end

    it "never sees the root's siblings: a rooted contract reads only its envelope, like require().permit()" do
      params = { user: { name: "a" }, address_attributes: { location: 1 } }
      strict = permittable_class { permit_params(:create, root: :user, unknown: :error) { required :name, :string } }
      c = controller(strict, params: params)
      expect(c.permitted_params.to_h).to eq("name" => "a")
      expect(c.permittable_violations).to eq([])

      # Monitor's raw pass-through is the unwrapped envelope, siblings dropped too.
      monitored = permittable_class { permit_params(:create, root: :user, mode: :monitor) { required :name, :integer } }
      expect(controller(monitored, params: params).permitted_params.to_h).to eq("name" => "a")
    end

    it "logs undeclared keys with unknown: :log" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :name, :string } }
      c = controller(klass, params: { name: "a", extra: "x" })
      messages = []
      logger = Object.new
      logger.define_singleton_method(:warn) { |msg| messages << msg }
      c.define_singleton_method(:logger) { logger }

      expect(c.permitted_params.to_h).to eq("name" => "a")
      expect(messages.join).to match(/unknown parameter\(s\) ignored.*extra/)
    end
  end

  describe "nested hashes and arrays" do
    it "accepts several top-level envelopes via a rootless contract with one nested block per key" do
      decl = proc do
        permit_params(:create, unknown: :error) do
          required :user do
            required :test_key, :integer
          end
          optional :address_attributes do
            required :location, :integer
          end
        end
      end
      params = { user: { test_key: "1" }, address_attributes: { location: "2" }, controller: "users", action: "create" }
      expect(permit(params, &decl).to_h).to eq("user" => { "test_key" => 1 }, "address_attributes" => { "location" => 2 })

      e = violations_for({ user: { test_key: "1" }, billing_attributes: { plan: "pro" } }, &decl)
      expect(e.details).to eq([{ param: "billing_attributes", code: "unknown" }])
    end

    it "validates nested fields with dotted violation paths" do
      decl = proc do
        permit_params(:create, root: :user) do
          required :name, :string
          optional :address do
            required :city, :string
            optional :zip,  :string, format: /\A\d{5}\z/
          end
        end
      end
      result = permit({ user: { name: "Jo", address: { city: "Hanoi", zip: "10000" } } }, &decl)
      expect(result[:address].to_h).to eq("city" => "Hanoi", "zip" => "10000")

      e = violations_for({ user: { name: "Jo", address: { zip: "1" } } }, &decl)
      expect(e.details).to contain_exactly({ param: "user.address.city", code: "missing" },
                                           { param: "user.address.zip", code: "format" })
    end

    it "rejects a non-hash where a nested hash is declared" do
      e = violations_for({ address: "nope" }) { permit_params(:create) { optional(:address) { required :city } } }
      expect(e.details).to eq([{ param: "address", code: "invalid_type" }])
    end

    it "casts array elements and pinpoints the failing index" do
      decl = proc { permit_params(:create) { array :ids, of: :integer } }
      expect(permit({ ids: %w[1 2 3] }, &decl)[:ids]).to eq([1, 2, 3])
      expect(violations_for({ ids: %w[1 x 3] }, &decl).details).to eq([{ param: "ids[1]", code: "invalid_type" }])
    end

    it "validates arrays of hashes via a block" do
      decl = proc do
        permit_params(:create) do
          array :items do
            required :sku, :string
            optional :qty, :integer, default: 1
          end
        end
      end
      result = permit({ items: [{ sku: "a" }, { sku: "b", qty: "3" }] }, &decl)
      expect(result[:items].map(&:to_h)).to eq([{ "sku" => "a", "qty" => 1 }, { "sku" => "b", "qty" => 3 }])

      e = violations_for({ items: [{ sku: "a" }, "nope"] }, &decl)
      expect(e.details).to eq([{ param: "items[1]", code: "invalid_type" }])
    end

    it "checks array length (element count), requiredness, non-array values, and defaults" do
      expect(violations_for({ tags: %w[a b c] }) { permit_params(:create) { array :tags, length: 0..2 } }
        .details.first).to eq({ param: "tags", code: "length" })
      expect(violations_for({}) { permit_params(:create) { array :tags, required: true } }
        .details).to eq([{ param: "tags", code: "missing" }])
      expect(violations_for({ tags: "solo" }) { permit_params(:create) { array :tags } }
        .details).to eq([{ param: "tags", code: "invalid_type" }])
      expect(permit({}) { permit_params(:create) { array :tags, default: [] } }[:tags]).to eq([])
    end

    it "runs validate: on the whole cast array" do
      decl = proc { permit_params(:create) { array :ids, of: :integer, validate: ->(v) { v.uniq == v || :duplicates } } }
      expect(violations_for({ ids: %w[1 1] }, &decl).details).to eq([{ param: "ids", code: "duplicates" }])
    end
  end

  describe ":json (free-form hashes)" do
    let(:decl) { proc { permit_params(:create) { optional :metadata, :json } } }

    it "passes an arbitrary nested hash through untouched" do
      payload = { "any" => { "deep" => [1, "two", true, nil] }, "n" => 3 }
      expect(permit({ metadata: payload }, &decl)[:metadata].to_h).to eq(payload)
    end

    it "accepts an empty hash as a value (only nil and \"\" are absent)" do
      expect(permit({ metadata: {} }, &decl)[:metadata].to_h).to eq({})
    end

    it "rejects anything that is not a hash" do
      [[], "x", 3, true].each do |value|
        expect(violations_for({ metadata: value }, &decl).details)
          .to eq([{ param: "metadata", code: "invalid_type" }]), "for #{value.inspect}"
      end
    end

    it "omits an absent field and honours default:" do
      expect(permit({}, &decl).key?("metadata")).to be(false)
      result = permit({}) { permit_params(:create) { optional :metadata, :json, default: { "seeded" => true } } }
      expect(result[:metadata]).to eq("seeded" => true)
    end

    it "violates missing when required and absent" do
      expect(violations_for({}) { permit_params(:create) { required :metadata, :json } }.details)
        .to eq([{ param: "metadata", code: "missing" }])
    end

    it "does NOT descend into the opaque hash for unknown-key checking" do
      result = permit({ metadata: { "undeclared" => 1 } }) do
        permit_params(:create, unknown: :error) { optional :metadata, :json }
      end
      expect(result[:metadata].to_h).to eq("undeclared" => 1)
    end

    it "bounds nesting with max_depth:, counting arrays as a level" do
      decl = proc { permit_params(:create) { optional :metadata, :json, max_depth: 2 } }
      expect(permit({ metadata: { "a" => { "b" => 1 } } }, &decl)[:metadata]).to be_a(Hash)
      expect(permit({ metadata: { "a" => [1, 2] } }, &decl)[:metadata]).to be_a(Hash)
      expect(violations_for({ metadata: { "a" => { "b" => { "c" => 1 } } } }, &decl).details)
        .to eq([{ param: "metadata", code: "depth" }])
      expect(violations_for({ metadata: { "a" => [{ "b" => 1 }] } }, &decl).details)
        .to eq([{ param: "metadata", code: "depth" }])
    end

    it "bounds breadth with length: on the top-level key count" do
      decl = proc { permit_params(:create) { optional :metadata, :json, length: 0..2 } }
      expect(permit({ metadata: { "a" => 1, "b" => 2 } }, &decl)[:metadata].keys.length).to eq(2)
      expect(violations_for({ metadata: { "a" => 1, "b" => 2, "c" => 3 } }, &decl).details)
        .to eq([{ param: "metadata", code: "length" }])
    end

    it "runs validate: and transform: over the whole hash" do
      result = permit({ metadata: { "kind" => "a" } }) do
        permit_params(:create) do
          optional :metadata, :json,
                   validate: ->(h) { h.key?("kind") || :kind_required },
                   transform: ->(h) { h.merge("seen" => true) }
        end
      end
      expect(result[:metadata].to_h).to eq("kind" => "a", "seen" => true)

      violations = violations_for({ metadata: { "other" => 1 } }) do
        permit_params(:create) { optional :metadata, :json, validate: ->(h) { h.key?("kind") || :kind_required } }
      end
      expect(violations.details).to eq([{ param: "metadata", code: "kind_required" }])
    end

    it "does not transform a hash that failed its own bounds" do
      violations = violations_for({ metadata: { "a" => 1, "b" => 2 } }) do
        permit_params(:create) { optional :metadata, :json, length: 1, transform: ->(h) { h.merge("t" => 1) } }
      end
      expect(violations.details).to eq([{ param: "metadata", code: "length" }])
    end

    it "carries message:, desc:, sensitive: and nullable: like any other field" do
      result = permit({ metadata: nil }) do
        permit_params(:create) { optional :metadata, :json, nullable: true, sensitive: true }
      end
      expect(result.fetch("metadata")).to be_nil
      expect(Permittable.filter_parameter_registry.include?("metadata")).to be(true)

      violations = violations_for({ metadata: 1 }) do
        permit_params(:create) { optional :metadata, :json, message: "must be an object" }
      end
      expect(violations.details).to eq([{ param: "metadata", code: "invalid_type", message: "must be an object" }])
    end

    describe "macro validation" do
      it "rejects the string-only and array-only options" do
        %i[format normalize in of].each do |opt|
          expect { permittable_class { permit_params(:create) { optional :m, :json, opt => /x/ } } }
            .to raise_error(ArgumentError, /unknown option\(s\) :#{opt} for field :m/)
        end
      end

      it "rejects a nested block alongside the type" do
        expect { permittable_class { permit_params(:create) { optional(:m, :json) { required :a } } } }
          .to raise_error(ArgumentError, /takes a type OR a nested block/)
      end

      it "requires max_depth: to be a positive Integer" do
        expect { permittable_class { permit_params(:create) { optional :m, :json, max_depth: 0 } } }
          .to raise_error(ArgumentError, /:max_depth for :m must be a positive Integer/)
        expect { permittable_class { permit_params(:create) { optional :m, :json, max_depth: 1..3 } } }
          .to raise_error(ArgumentError, /:max_depth for :m must be a positive Integer/)
      end

      it "requires an authored default:/example: to be a Hash satisfying the field's own bounds" do
        expect { permittable_class { permit_params(:create) { optional :m, :json, default: [] } } }
          .to raise_error(ArgumentError, /:default for :m must be a Hash/)
        expect { permittable_class { permit_params(:create) { optional :m, :json, max_depth: 1, example: { "a" => { "b" => 1 } } } } }
          .to raise_error(ArgumentError, /:example for field :m violates its own contract \(depth\)/)
      end
    end
  end

  describe "array length: as a bound, not just a report" do
    it "stops at the length violation instead of checking every element" do
      decl = proc { permit_params(:create) { array :tags, of: :string, length: 0..2 } }
      # Every element is also wrong-typed; none of that is reported, because
      # the array is already rejected on its count.
      e = violations_for({ tags: Array.new(500) { |i| { "not" => i } } }, &decl)
      expect(e.details).to eq([{ param: "tags", code: "length" }])
    end

    it "does the same for an array of nested hashes, where each element would violate loudly" do
      decl = proc do
        permit_params(:create) do
          array :line_items, length: 1..2 do
            required :sku, :string
            required :qty, :integer
          end
        end
      end
      e = violations_for({ line_items: Array.new(300) { {} } }, &decl)
      expect(e.details).to eq([{ param: "line_items", code: "length" }])
    end

    it "does not hand validate: or transform: an array the contract already rejected" do
      seen = []
      decl = proc do
        permit_params(:create) do
          array :tags, of: :string, length: 0..1,
                       validate: ->(a) { seen << [:validate, a.length] }, transform: ->(_a) { seen << :transform }
        end
      end
      violations_for({ tags: %w[a b c] }, &decl)
      expect(seen).to be_empty
    end

    it "still reports element violations for an array within its bounds" do
      decl = proc { permit_params(:create) { array :tags, of: :integer, length: 0..5 } }
      e = violations_for({ tags: %w[1 x y] }, &decl)
      expect(e.details).to eq([{ param: "tags[1]", code: "invalid_type" }, { param: "tags[2]", code: "invalid_type" }])
    end

    it "leaves an array with no declared length: exactly as it was" do
      decl = proc { permit_params(:create) { array :tags, of: :integer } }
      e = violations_for({ tags: %w[1 x] }, &decl)
      expect(e.details).to eq([{ param: "tags[1]", code: "invalid_type" }])
    end

    it "keeps a valid array valid" do
      result = permit({ tags: %w[1 2] }) { permit_params(:create) { array :tags, of: :integer, length: 0..5 } }
      expect(result[:tags]).to eq([1, 2])
    end

    it "refuses an authored default: that is itself outside the bound, at class load" do
      expect { permittable_class { permit_params(:create) { array :t, of: :string, length: 0..1, default: %w[a b] } } }
        .to raise_error(ArgumentError, /:default for array :t violates its own contract \(length\)/)
      expect { permittable_class { permit_params(:create) { array :t, of: :string, length: 0..2, example: %w[a b] } } }
        .not_to raise_error
    end
  end

  describe "rule matching and inheritance" do
    it "the LAST matching rule wins and no positional actions means catch-all" do
      klass = permittable_class do
        permit_params { required :anything, :string }
        permit_params(:create) { required :name, :string }
      end
      expect(controller(klass, params: { name: "a" }, action: "create").permitted_params[:name]).to eq("a")
      expect(controller(klass, params: { anything: "x" }, action: "destroy").permitted_params[:anything]).to eq("x")
    end

    it "subclasses inherit contracts copy-on-write and can override" do
      parent = permittable_class { permit_params(:create) { required :name, :string } }
      child = Class.new(parent) { permit_params(:create) { required :title, :string } }

      expect(controller(child, params: { title: "t" }).permitted_params[:title]).to eq("t")
      expect(controller(parent, params: { name: "n" }).permitted_params[:name]).to eq("n")
      expect(parent.permittable_contracts.length).to eq(1)
    end

    it "exposes the contract registry for introspection" do
      klass = permittable_class { permit_params(:create, root: :user) { required :name, :string, length: 1..80 } }
      rule = klass.permit_rule_for(:create)
      expect(rule[:root]).to eq(:user)
      expect(rule[:fields].first).to include(name: :name, kind: :scalar, type: :string, required: true, length: 1..80)
      expect(klass.permit_rule_for(:destroy)).to be_nil
    end

    it "raises ArgumentError (programmer error) when no contract covers the action" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      expect { controller(klass, params: {}, action: "destroy").permitted_params }
        .to raise_error(ArgumentError, /no params contract declared covering #destroy/)
    end
  end

  describe "memoization and enforcement" do
    it "memoizes per action" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: { name: "a" })
      expect(c.permitted_params).to equal(c.permitted_params)
    end

    it "enforce_params_contract validates only rules that opted in" do
      lazy = permittable_class { permit_params(:create) { required :name, :string } }
      expect { controller(lazy, params: {}).enforce_params_contract }.not_to raise_error

      eager = permittable_class { permit_params(:create, enforce: true) { required :name, :string } }
      expect { controller(eager, params: {}).enforce_params_contract }
        .to raise_error(described_class::InvalidParameters)
    end
  end

  describe "observability" do
    it "registers sensitive: fields (nested included) with the FilterParameterRegistry" do
      permittable_class do
        permit_params(:create) do
          required :name, :string
          optional :ssn,  :string, sensitive: true
          optional :bank do
            required :iban, :string, sensitive: true
          end
        end
      end
      expect(Permittable.filter_parameter_registry.include?("ssn")).to be(true)
      expect(Permittable.filter_parameter_registry.include?("iban")).to be(true)
      expect(Permittable.filter_parameter_registry.include?("name")).to be(false)
    end

    it "cascades sensitive: from a nested block to every field inside it" do
      permittable_class do
        permit_params(:create) do
          optional :payment, sensitive: true do
            required :card_number, :string
            optional :cvv, :string
            optional :billing do
              optional :postcode, :string
            end
          end
        end
      end
      registry = Permittable.filter_parameter_registry
      %w[payment card_number cvv billing postcode].each do |name|
        expect(registry.include?(name)).to be(true), "expected :#{name} to be registered"
      end
    end

    it "cascades sensitive: from an array block to its element fields" do
      permittable_class do
        permit_params(:create) do
          array :cards, sensitive: true do
            required :pan, :string
            optional :expiry, :string
          end
        end
      end
      expect(Permittable.filter_parameter_registry.include?("pan")).to be(true)
      expect(Permittable.filter_parameter_registry.include?("expiry")).to be(true)
    end

    it "lets a sub-field opt OUT with sensitive: false, for a name too generic to redact app-wide" do
      permittable_class do
        permit_params(:create) do
          optional :payment, sensitive: true do
            required :card_number, :string
            # "id" would match user_id, valid, identity... app-wide.
            optional :id, :string, sensitive: false
            optional :meta, sensitive: false do
              optional :name, :string
            end
          end
        end
      end
      registry = Permittable.filter_parameter_registry
      expect(registry.include?("card_number")).to be(true)
      expect(registry.include?("id")).to be(false)
      expect(registry.include?("meta")).to be(false)
      expect(registry.include?("name")).to be(false)
    end

    it "does not register anything inside a container that is not sensitive" do
      permittable_class do
        permit_params(:create) do
          optional :bank do
            required :iban, :string, sensitive: true
            optional :branch, :string
          end
        end
      end
      registry = Permittable.filter_parameter_registry
      expect(registry.include?("iban")).to be(true)
      expect(registry.include?("bank")).to be(false)
      expect(registry.include?("branch")).to be(false)
    end

    it "actually redacts the nested values a Rails log would print" do
      permittable_class do
        permit_params(:create) do
          optional :ssn, :string, sensitive: true
          optional :payment, sensitive: true do
            required :card_number, :string
            optional :cvv, :string
            optional :billing do
              optional :postcode, :string
            end
          end
          array :cards, sensitive: true do
            required :pan, :string
          end
        end
      end
      filter = ActiveSupport::ParameterFilter.new([Permittable.filter_parameter_registry.to_proc])
      expect(filter.filter("ssn" => "111-22-3333",
                           "payment" => { "card_number" => "4111111111111111", "cvv" => "123",
                                          "billing" => { "postcode" => "SW1A 1AA" } },
                           "cards" => [{ "pan" => "5555555555554444" }]))
        .to eq("ssn" => "[FILTERED]",
               "payment" => { "card_number" => "[FILTERED]", "cvv" => "[FILTERED]",
                              "billing" => { "postcode" => "[FILTERED]" } },
               "cards" => [{ "pan" => "[FILTERED]" }])
    end

    it "stamps the cascade onto the field, so every reader of the contract agrees" do
      klass = permittable_class do
        permit_params(:create) do
          optional :payment, sensitive: true do
            required :card_number, :string
            optional :id, :string, sensitive: false
          end
        end
      end
      payment = klass.permit_rule_for(:create)[:fields].first
      card_number, id = payment[:fields]
      expect(card_number[:sensitive]).to be(true)
      expect(id[:sensitive]).to be(false)
    end

    describe "sensitive: name publication" do
      # A proc filter can only redact Strings, and ParameterFilter never calls
      # one for a Hash value at all — so the name has to reach Rails as a NAME
      # too. Permittable::Railtie installs the sink that does it; this covers
      # the publication itself, with no Rails in sight.
      after { Permittable.sensitive_parameter_sinks.clear }

      it "publishes every sensitive: name to an installed sink, nested ones included" do
        seen = []
        Permittable.on_sensitive_parameter { |name| seen << name }
        permittable_class do
          permit_params(:create) do
            required :name, :string
            optional :pin_code, :integer, sensitive: true
            optional :payment, sensitive: true do
              required :card_number, :string, sensitive: true
            end
          end
        end
        expect(seen).to contain_exactly("pin_code", "payment", "card_number")
      end

      it "replays the names already registered, so a late sink misses nothing" do
        # A contract can be declared before the Railtie's initializer runs —
        # a Permittable::Contract at require time, an eager-loaded controller.
        permittable_class { permit_params(:create) { optional :ssn, :string, sensitive: true } }
        seen = []
        Permittable.on_sensitive_parameter { |name| seen << name }

        expect(seen).to eq(["ssn"])
      end

      it "publishes the name normalized, however the field declared it" do
        seen = []
        Permittable.on_sensitive_parameter { |name| seen << name }
        permittable_class { permit_params(:create) { optional :SSN, :string, sensitive: true } }

        expect(seen).to eq(["ssn"])
      end
    end

    describe "the filter proc the Railtie appends" do
      # Rails runs railtie initializers BEFORE config/initializers, so an app
      # or host gem that swaps the registry does so AFTER the Railtie has
      # already appended its proc.
      after { Permittable.filter_parameter_registry = nil }

      def boot_filter
        ActiveSupport::ParameterFilter.new([Permittable.filter_parameter_proc])
      end

      it "redacts through whichever registry is current, not the one present at boot" do
        filter = boot_filter # boot: proc appended
        pooled = Permittable::FilterParameterRegistry.new
        Permittable.filter_parameter_registry = pooled # initializer: swap
        permittable_class { permit_params(:create) { optional :ssn, :string, sensitive: true } }

        expect(pooled.include?("ssn")).to be(true)
        expect(filter.filter("ssn" => "111-22-3333")).to eq("ssn" => "[FILTERED]")
      end

      it "is a stable object, so the Railtie's idempotence check still holds" do
        expect(Permittable.filter_parameter_proc).to be(Permittable.filter_parameter_proc)
        Permittable.filter_parameter_registry = Permittable::FilterParameterRegistry.new
        expect(Permittable.filter_parameter_proc).to be(Permittable.filter_parameter_proc)
      end

      it "still redacts through the default registry when nothing is swapped" do
        filter = boot_filter
        permittable_class { permit_params(:create) { optional :ssn, :string, sensitive: true } }
        expect(filter.filter("ssn" => "111-22-3333")).to eq("ssn" => "[FILTERED]")
      end

      it "carries entries registered BEFORE the swap into the new registry" do
        filter = boot_filter
        # A contract that loaded before the initializer ran — eager loading,
        # or any file required ahead of the swap.
        permittable_class { permit_params(:create) { optional :ssn, :string, sensitive: true } }

        pooled = Permittable::FilterParameterRegistry.new
        Permittable.filter_parameter_registry = pooled

        permittable_class { permit_params(:create) { optional :pin, :string, sensitive: true } }

        expect(pooled.include?("ssn")).to be(true)
        # Without the carry-forward this is the mirror image of the bug above:
        # the swap redacts only what was registered after it.
        expect(filter.filter("ssn" => "111-22-3333", "pin" => "1234", "note" => "keep"))
          .to eq("ssn" => "[FILTERED]", "pin" => "[FILTERED]", "note" => "keep")
      end

      it "refuses a registry that cannot be turned into a filter, at the swap rather than per request" do
        expect { Permittable.filter_parameter_registry = Set.new }
          .to raise_error(ArgumentError, /must respond to #to_proc \(got Set\)/)
        expect(Permittable.filter_parameter_registry).to be_a(Permittable::FilterParameterRegistry)
      end

      it "accepts a registry whose proc takes Rails' three-argument filter shape" do
        three = Class.new do
          def add(name) = names << name.to_s
          def names = (@names ||= [])
          def include?(key) = names.any? { |n| key.to_s.include?(n) }

          def to_proc
            registry = self
            ->(key, value, _original) { value.replace("[FILTERED]") if value.is_a?(String) && registry.include?(key) }
          end
        end.new
        Permittable.filter_parameter_registry = three
        permittable_class { permit_params(:create) { optional :ssn, :string, sensitive: true } }
        expect(boot_filter.filter("ssn" => "111-22-3333")).to eq("ssn" => "[FILTERED]")
      end
    end

    it "instruments invalid_parameters.permittable with the violation details" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
        events << payload
      end
      begin
        violations_for({}) { permit_params(:create) { required :name, :string } }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      expect(events.length).to eq(1)
      expect(events.first[:action]).to eq("create")
      expect(events.first[:details]).to eq([{ param: "name", code: "missing" }])
      expect(events.first[:mode]).to eq(:enforce)
    end

    it "instruments a rejected request exactly ONCE, however often the params are read" do
      klass = permittable_class { permit_params(:create, root: :user) { required :name, :string } }
      c = controller(klass, params: { user: {} })
      events = recording_notifications do
        c.permittable_violations
        3.times do
          c.permitted_params
        rescue described_class::InvalidParameters
          nil
        end
      end
      expect(events.length).to eq(1)
      expect(events.first[:details]).to eq([{ param: "user.name", code: "missing" }])
    end

    it "memoizes the rejection itself, re-raising the same error rather than revalidating" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: {})
      errors = Array.new(2) do
        c.permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      expect(errors.last).to be(errors.first)
      expect(c.permittable_violations).to eq([{ param: "name", code: "missing" }])
    end

    it "never memoizes ArgumentError — a missing contract is a programmer error, not a rejection" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: { name: "x" }, action: "archive")
      2.times do
        expect { c.permitted_params }.to raise_error(ArgumentError, /no params contract declared/)
      end
    end

    it "keys the rejection memo per action, so a second action validates and instruments on its own" do
      klass = permittable_class do
        permit_params(:create) { required :name, :string }
        permit_params(:update) { required :email, :string }
      end
      c = controller(klass, params: {})
      events = recording_notifications do
        2.times do
          c.permitted_params(:create)
        rescue described_class::InvalidParameters
          nil
        end
        2.times do
          c.permitted_params(:update)
        rescue described_class::InvalidParameters
          nil
        end
      end
      expect(events.map { |e| e[:details] })
        .to eq([[{ param: "name", code: "missing" }], [{ param: "email", code: "missing" }]])
    end

    it "does not adopt an unrelated exception as the memoized rejection's cause" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: {})
      first = begin
        c.permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      # A re-read from inside a rescue of something else: Ruby would otherwise
      # attach that exception to the memoized error as its cause, permanently.
      again = begin
        begin
          raise IOError, "unrelated"
        rescue IOError
          c.permitted_params
        end
      rescue described_class::InvalidParameters => e
        e
      end
      expect(again).to be(first)
      expect(again.cause).to be_nil
    end

    it "keeps a clean read memoized and silent" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: { name: "x" })
      events = recording_notifications { expect(c.permitted_params).to be(c.permitted_params) }
      expect(events).to be_empty
    end

    it "renders the shared error envelope from render_invalid_parameters" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: {})
      begin
        c.permitted_params
      rescue described_class::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      expect(c.rendered[:status]).to eq(:unprocessable_entity)
      expect(c.rendered[:json][:error][:code]).to eq("invalid_parameters")
      expect(c.rendered[:json][:error][:details]).to eq([{ param: "name", code: "missing" }])
    end
  end

  describe "bounded prose: log lines and summaries" do
    def logging_controller(klass, params:, action: "create")
      c = controller(klass, params: params, action: action)
      lines = []
      logger = Object.new
      logger.define_singleton_method(:warn) { |message| lines << message }
      c.define_singleton_method(:logger) { logger }
      [c, lines]
    end

    let(:many) { Array.new(5_000) { |i| ["extra_#{i}", "v"] }.to_h.merge("a" => "x") }

    it "lists at most ten unknown keys and counts the rest, instead of writing them all" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :a, :string } }
      c, lines = logging_controller(klass, params: many)
      c.permitted_params
      expect(lines.length).to eq(1)
      expect(lines.first.bytesize).to be < 400
      expect(lines.first).to include("extra_0, extra_1")
      expect(lines.first).to match(/and 4990 more/)
    end

    it "lists them in full when there are ten or fewer" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :a, :string } }
      c, lines = logging_controller(klass, params: { "a" => "x", "b" => 1, "c" => 2 })
      c.permitted_params
      expect(lines.first).to end_with("contract: b, c")
      expect(lines.first).not_to include("more")
    end

    it "bounds the exception summary while details stays complete" do
      klass = permittable_class { permit_params(:create, unknown: :error) { required :a, :string } }
      e = begin
        controller(klass, params: many).permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      expect(e.message.bytesize).to be < 400
      expect(e.message).to match(/and 4990 more/)
      # The machine-readable channel is untouched: every offender is still named.
      expect(e.details.length).to eq(5_000)
      expect(e.details.first).to eq(param: "extra_0", code: "unknown")
    end

    it "bounds the monitor-mode warn line too, and still instruments every violation" do
      klass = permittable_class { permit_params(:create, unknown: :error, mode: :monitor) { required :a, :string } }
      c, lines = logging_controller(klass, params: many)
      events = []
      subscription = ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
        events << payload
      end
      begin
        c.permitted_params
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      expect(lines.first.bytesize).to be < 400
      expect(lines.first).to match(/and 4990 more/)
      expect(events.first[:details].length).to eq(5_000)
    end

    it "lists exactly ten without a count, and eleven with one" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :a, :string } }
      ten = Array.new(10) { |i| ["k#{i}", "v"] }.to_h.merge("a" => "x")
      c, lines = logging_controller(klass, params: ten)
      c.permitted_params
      expect(lines.first).to end_with("contract: k0, k1, k2, k3, k4, k5, k6, k7, k8, k9")

      eleven = ten.merge("k10" => "v")
      c2, lines2 = logging_controller(klass, params: eleven)
      c2.permitted_params
      expect(lines2.first).to end_with("k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, and 1 more")
    end

    it "truncates a single enormous key, which the count cap alone did not bound" do
      klass = permittable_class { permit_params(:create, unknown: :error) { required :a, :string } }
      huge = "z" * 100_000
      e = begin
        controller(klass, params: { "a" => "x", huge => "v" }).permitted_params
      rescue described_class::InvalidParameters => e
        e
      end
      expect(e.message.bytesize).to be < 300
      expect(e.message).to include("z" * 20)
      expect(e.message).to include("...")
      # The machine-readable channel keeps the key whole.
      expect(e.details.first[:param]).to eq(huge)
    end

    it "truncates an enormous key in the :log line too" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :a, :string } }
      c, lines = logging_controller(klass, params: { "a" => "x", "y" * 100_000 => "v" })
      c.permitted_params
      expect(lines.first.bytesize).to be < 300
    end

    it "leaves an ordinary contract's message exactly as it was" do
      decl = proc { permit_params(:create) { required :a, :string, in: %w[x] } }
      expect(violations_for({ a: "nope" }, &decl).message).to eq("Invalid parameters: a (inclusion)")
    end
  end

  describe "monitor mode" do
    after { Permittable.mode = :enforce }

    it "rejects an unknown :mode at class load, and an unknown global mode at assignment" do
      expect { permittable_class { permit_params(:create, mode: :report) { required :a } } }
        .to raise_error(ArgumentError, /:mode must be one of enforce, monitor/)
      expect { Permittable.mode = :report }
        .to raise_error(ArgumentError, /mode must be one of enforce, monitor/)
      expect(Permittable.mode).to eq(:enforce)
    end

    it "returns the cast, defaulted result when the request is clean — identical to enforce" do
      result = permit({ user: { name: "Jo", age: "30" } }) do
        permit_params(:create, root: :user, mode: :monitor) do
          required :name, :string
          optional :age,  :integer
          optional :plan, :string, default: "free"
        end
      end
      expect(result.to_h).to eq("name" => "Jo", "age" => 30, "plan" => "free")
    end

    it "reports a violation instead of raising and passes the raw root through untouched" do
      klass = permittable_class do
        permit_params(:create, root: :user, mode: :monitor) do
          required :name, :string
          optional :age,  :integer, in: 18..120, transform: ->(v) { v * 2 }
          optional :plan, :string, default: "free"
        end
      end
      c = controller(klass, params: { user: { name: "Jo", age: "7" } })
      result = nil
      expect { result = c.permitted_params }.not_to raise_error
      # Raw pass-through: no cast, no default, no transform.
      expect(result.to_h).to eq("name" => "Jo", "age" => "7")
      expect(c.permittable_violations).to eq([{ param: "user.age", code: "inclusion" }])
    end

    it "instruments with mode: :monitor and warns through the logger" do
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      c = controller(klass, params: {})
      messages = []
      logger = Object.new
      logger.define_singleton_method(:warn) { |msg| messages << msg }
      c.define_singleton_method(:logger) { logger }

      events = recording_notifications { c.permitted_params }
      expect(events.length).to eq(1)
      expect(events.first[:mode]).to eq(:monitor)
      expect(events.first[:details]).to eq([{ param: "name", code: "missing" }])
      expect(messages.join).to match(/\[monitor\] #create would have been rejected: name \(missing\)/)
    end

    it "passes an empty hash through when the root: key is missing" do
      klass = permittable_class { permit_params(:create, root: :user, mode: :monitor) { required :name, :string } }
      c = controller(klass, params: { unrelated: "x" })
      expect(c.permitted_params.to_h).to eq({})
      expect(c.permittable_violations).to eq([{ param: "user", code: "missing" }])
    end

    it "drops only the router's bookkeeping keys from a rootless pass-through" do
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      c = controller(klass, params: { controller: "users", action: "create", extra: "kept" })
      expect(c.permitted_params.to_h).to eq("extra" => "kept")
    end

    it "follows Permittable.mode when the rule declares no mode, and a rule's own mode: wins both ways" do
      Permittable.mode = :monitor
      follows = permittable_class { permit_params(:create) { required :name, :string } }
      expect { controller(follows, params: {}).permitted_params }.not_to raise_error

      overrides = permittable_class { permit_params(:create, mode: :enforce) { required :name, :string } }
      expect { controller(overrides, params: {}).permitted_params }
        .to raise_error(described_class::InvalidParameters)

      Permittable.mode = :enforce
      monitored = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      expect { controller(monitored, params: {}).permitted_params }.not_to raise_error
    end

    it "enforce_params_contract validates monitor rules eagerly, without enforce: true" do
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      c = controller(klass, params: {})
      events = recording_notifications { expect { c.enforce_params_contract }.not_to raise_error }
      expect(events.length).to eq(1)
      expect(events.first[:mode]).to eq(:monitor)
    end

    it "memoizes the pass-through — a second read neither revalidates nor re-instruments" do
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      c = controller(klass, params: {})
      events = recording_notifications { expect(c.permitted_params).to equal(c.permitted_params) }
      expect(events.length).to eq(1)
    end

    it "monitors finalize violations the same way" do
      klass = permittable_class do
        permit_params(:create, mode: :monitor) do
          required :starts_on, :date
          required :ends_on,   :date
          finalize do |p|
            violate!("ends_on", :before_start) if p[:ends_on] < p[:starts_on]
            p
          end
        end
      end
      c = controller(klass, params: { starts_on: "2026-08-24", ends_on: "2026-08-01" })
      expect { c.permitted_params }.not_to raise_error
      expect(c.permittable_violations).to eq([{ param: "ends_on", code: "before_start" }])
      expect(c.permitted_params.to_h).to eq("starts_on" => "2026-08-24", "ends_on" => "2026-08-01")
    end

    it "permittable_violations returns [] for a clean request, and details under enforce without re-raising" do
      clean = permittable_class { permit_params(:create, mode: :monitor) { optional :name, :string } }
      expect(controller(clean, params: { name: "a" }).permittable_violations).to eq([])

      enforced = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(enforced, params: {})
      expect(c.permittable_violations).to eq([{ param: "name", code: "missing" }])
    end
  end

  describe "schema-drift guard (model:)" do
    before do
      ActiveRecord::Schema.define do
        create_table :permit_users do |t|
          t.string :name
          t.integer :age
        end
      end
    end

    after do
      ActiveRecord::Base.connection.drop_table(:permit_users, if_exists: true)
    end

    let(:model) do
      Class.new(TestModel) do
        self.table_name = "permit_users"
      end
    end

    it "accepts a contract whose scalar fields are all columns" do
      m = model
      expect do
        permittable_class do
          permit_params(:create, model: m) do
            required :name, :string
            optional :age,  :integer
          end
        end
      end.not_to raise_error
    end

    it "raises at class load for a field whose column does not exist, teaching both fixes" do
      m = model
      expect do
        permittable_class { permit_params(:create, model: m) { required :nickname, :string } }
      end.to raise_error(ArgumentError) do |e|
        expect(e.message).to match(/'nickname' does not exist in the database \(table: permit_users\)/)
        expect(e.message).to match(%r{bin/rails generate migration AddNicknameToPermitUsers nickname:string})
        expect(e.message).to match(/declare it with virtual: true/)
      end
    end

    it "skips virtual fields and (implicitly) nested/array fields" do
      m = model
      expect do
        permittable_class do
          permit_params(:create, model: m) do
            required :name, :string
            optional :password, :string, virtual: true
            array    :tag_names, of: :string
            optional(:address) { required :city, :string }
          end
        end
      end.not_to raise_error
    end

    describe "column types (Permittable.check_column_types)" do
      before do
        ActiveRecord::Schema.define do
          create_table :typed_things do |t|
            t.string   :title
            t.integer  :count
            t.decimal  :price
            t.boolean  :active
            t.datetime :starts_at
            t.date     :on
            t.json     :payload
            t.binary   :blob
            t.integer  :status
            t.string   :tier
          end
        end
      end

      after do
        Permittable.check_column_types = false
        ActiveRecord::Base.connection.drop_table(:typed_things, if_exists: true)
      end

      let(:typed) { Class.new(TestModel) { self.table_name = "typed_things" } }

      def declaring(model, &fields)
        -> { permittable_class { permit_params(:create, model: model, &fields) } }
      end

      it "is off by default, so no existing contract starts failing its deploy" do
        expect(&declaring(typed) { required :title, :integer }).not_to raise_error
      end

      context "when enabled" do
        before { Permittable.check_column_types = true }

        it "raises when the declared type and the column disagree, naming both and the fix" do
          expect(&declaring(typed) { required :title, :integer }).to raise_error(ArgumentError) do |e|
            expect(e.message).to match(/'title' is declared :integer but the column is :string/)
            expect(e.message).to match(/typed_things/)
          end
        end

        it "catches the drift that matters: a column retyped out from under a contract" do
          expect(&declaring(typed) { required :starts_at, :string }).to raise_error(ArgumentError, /:string but the column is :datetime/)
          expect(&declaring(typed) { required :count, :datetime }).to raise_error(ArgumentError, /:datetime but the column is :integer/)
        end

        it "accepts every declaration that matches" do
          expect(&declaring(typed) do
            required :title, :string
            optional :count, :integer
            optional :price, :decimal
            optional :active, :boolean
            optional :starts_at, :datetime
            optional :on, :date
          end).not_to raise_error
        end

        it "allows numeric and boolean to mix, which legacy schemas genuinely do" do
          # A boolean stored as an integer 0/1 is a real pattern, and AR casts
          # cleanly between the numeric types.
          expect(&declaring(typed) { optional :active, :integer }).not_to raise_error
          expect(&declaring(typed) { optional :count, :decimal }).not_to raise_error
          expect(&declaring(typed) { optional :price, :float }).not_to raise_error
        end

        it "allows the temporal types to mix" do
          expect(&declaring(typed) { optional :starts_at, :date }).not_to raise_error
          expect(&declaring(typed) { optional :on, :datetime }).not_to raise_error
        end

        it "never guesses about a column it has no faithful type for" do
          # json/jsonb/binary have no scalar contract type, so whatever an app
          # improvised for them is left alone rather than second-guessed.
          expect(&declaring(typed) { optional :payload, :string }).not_to raise_error
          expect(&declaring(typed) { optional :blob, :string }).not_to raise_error
        end

        context "with a Rails enum" do
          # `enum` is spelled positionally from Rails 7.0 and by keyword before
          # it; the keyword form is gone in 8.0, and the matrix covers both.
          def self.define_enum(klass, name, mapping)
            if ActiveRecord.version >= Gem::Version.new("7.0")
              klass.enum name, mapping
            else
              klass.enum name => mapping
            end
          end

          # Named, because the error messages name the model.
          let(:enum_model) do
            group = self.class
            stub_const("EnumThing", Class.new(TestModel) do
              self.table_name = "typed_things"
              group.define_enum(self, :status, { pending: 0, shipped: 1 })
              group.define_enum(self, :tier, { free: "f", pro: "p" })
              # An enum over a declared attribute, with no column behind it.
              attribute :ghost, :integer
              group.define_enum(self, :ghost, { boo: 0 })
            end)
          end

          # A `model:` is duck-typed on column_names, so the guard must not
          # assume the rest of ActiveRecord is there.
          def duck_model(columns, enums: nil)
            Class.new do
              define_singleton_method(:table_name) { "ducks" }
              define_singleton_method(:table_exists?) { true }
              define_singleton_method(:column_names) { columns.keys.map(&:to_s) }
              define_singleton_method(:columns_hash) do
                columns.to_h { |name, type| [name.to_s, Struct.new(:type).new(type)] }
              end
              define_singleton_method(:defined_enums) { enums } if enums
            end
          end

          it "accepts the :string declaration an enum is submitted as, listing its names" do
            m = enum_model
            expect(&declaring(m) { optional :status, :string, in: m.statuses.keys }).not_to raise_error
            expect(&declaring(m) { optional :status, :string, in: %w[pending] }).not_to raise_error
          end

          it "requires the in: — without it, an unknown name would pass and then raise on assignment" do
            expect(&declaring(enum_model) { optional :status, :string }).to raise_error(ArgumentError) do |e|
              expect(e.message).to match(/'status' is an enum on EnumThing/)
              expect(e.message).to include("in: EnumThing.statuses.keys")
              expect(e.message).not_to match(/virtual: true/)
            end
          end

          it "rejects an in: listing anything the enum would refuse, naming it" do
            m = enum_model
            expect(&declaring(m) { optional :status, :string, in: %w[pending bogus] })
              .to raise_error(ArgumentError, /"bogus"/)
            # An integer-backed enum's stored values are not names it accepts
            # as strings: `status: "0"` raises on assignment.
            expect(&declaring(m) { optional :status, :string, in: %w[0 1] })
              .to raise_error(ArgumentError, /"0", "1"/)
            expect(&declaring(m) { optional :status, :string, in: "a".."z" })
              .to raise_error(ArgumentError, /in: EnumThing.statuses.keys/)
          end

          it "holds a string-backed enum to the same rule, accepting its stored values too" do
            m = enum_model
            # Assignment accepts a mapped value as well as a name, and a
            # string-backed enum's values arrive as strings.
            expect(&declaring(m) { optional :tier, :string, in: %w[free p] }).not_to raise_error
            expect(&declaring(m) { optional :tier, :string })
              .to raise_error(ArgumentError, /in: EnumThing.tiers.keys/)
          end

          it "still accepts the column's own group" do
            expect(&declaring(enum_model) { optional :status, :integer }).not_to raise_error
          end

          it "still catches any other type, suggesting the enum contract rather than virtual: true" do
            expect(&declaring(enum_model) { optional :status, :datetime }).to raise_error(ArgumentError) do |e|
              expect(e.message).to match(/'status' is declared :datetime but the column is :integer/)
              expect(e.message).to include(":string, in: EnumThing.statuses.keys")
              expect(e.message).not_to match(/virtual: true/)
            end
          end

          it "leaves the same column without an enum checked as before" do
            expect(&declaring(typed) { optional :status, :string })
              .to raise_error(ArgumentError, /'status' is declared :string but the column is :integer/)
          end

          it "does not loosen the existence check for an enum with no column" do
            m = enum_model
            expect(&declaring(m) { optional :ghost, :string, in: m.ghosts.keys })
              .to raise_error(ArgumentError, /'ghost' does not exist in the database/)
          end

          it "is not consulted with the check off" do
            Permittable.check_column_types = false
            expect(&declaring(enum_model) { optional :status, :string }).not_to raise_error
          end

          it "treats a duck-typed model with no defined_enums as having none" do
            expect(&declaring(duck_model({ count: :integer })) { optional :count, :string })
              .to raise_error(ArgumentError, /'count' is declared :string but the column is :integer/)
          end

          it "spells the suggestion through defined_enums when the name is not a method" do
            duck = duck_model({ 'two-step': :integer }, enums: { "two-step" => { "on" => 1 } })
            expect(&declaring(duck) { optional :'two-step', :string })
              .to raise_error(ArgumentError, /in: .*\.defined_enums\["two-step"\]\.keys/)
          end
        end

        it "still skips virtual fields and a missing column still reports as missing" do
          expect(&declaring(typed) { optional :title, :integer, virtual: true }).not_to raise_error
          expect(&declaring(typed) { optional :nope, :integer }).to raise_error(ArgumentError, /does not exist/)
        end

        it "rejects an invalid setting at assignment" do
          expect { Permittable.check_column_types = "yes" }
            .to raise_error(ArgumentError, /check_column_types must be true or false/)
        end
      end
    end

    it "skips silently when the schema is unreachable (the ColumnGuard contract)" do
      unreachable = Class.new(TestModel) { self.table_name = "no_such_table" }
      expect do
        permittable_class { permit_params(:create, model: unreachable) { required :ghost, :string } }
      end.not_to raise_error
    end

    it "rejects a :model that is not a model class" do
      expect { permittable_class { permit_params(:create, model: "User") { required :name } } }
        .to raise_error(ArgumentError, /:model must be an ActiveRecord model class/)
    end

    it "model: true infers the class from controller_name, and raises without one" do
      stub_const("PermitUser", model)
      inferring = Class.new(FakeController) do
        def self.controller_name
          "permit_users"
        end
        include Permittable
      end
      expect { inferring.class_eval { permit_params(:create, model: true) { required :name, :string } } }
        .not_to raise_error
      expect(inferring.permit_rule_for(:create)[:model]).to eq(PermitUser)

      expect { permittable_class { permit_params(:create, model: true) { required :name } } }
        .to raise_error(ArgumentError, /model: true needs controller_name/)
    end
  end

  describe "transform:" do
    it "rejects a non-callable transform on scalar and array fields, and rejects it on nested fields" do
      expect { permittable_class { permit_params(:create) { required :a, :string, transform: :split } } }
        .to raise_error(ArgumentError, /:transform for field :a must be callable/)
      expect { permittable_class { permit_params(:create) { array :a, transform: :split } } }
        .to raise_error(ArgumentError, /:transform for field :a must be callable/)
      expect { permittable_class { permit_params(:create) { required(:a, transform: ->(v) { v }) { required :b } } } }
        .to raise_error(ArgumentError, /unknown option\(s\) :transform for field :a/)
    end

    it "reshapes a validated scalar (delimited string → array)" do
      result = permit({ ids: "1,2,3" }) do
        permit_params(:create) { required :ids, :string, transform: ->(v) { v.split(",") } }
      end
      expect(result[:ids]).to eq(%w[1 2 3])
    end

    it "runs AFTER validation — format sees the pre-transform string" do
      decl = proc do
        permit_params(:create) { required :ids, :string, format: /\A[\d,]+\z/, transform: ->(v) { v.split(",") } }
      end
      expect(permit({ ids: "1,2" }, &decl)[:ids]).to eq(%w[1 2])
      expect(violations_for({ ids: "1;2" }, &decl).details).to eq([{ param: "ids", code: "format" }])
    end

    it "does NOT run on defaults (they are authored in final shape) or absent fields" do
      decl = proc do
        permit_params(:create) { optional :ids, :string, default: "authored", transform: ->(v) { v.split(",") } }
      end
      expect(permit({}, &decl)[:ids]).to eq("authored")
      expect(permit({}) { permit_params(:create) { optional :ids, :string, transform: ->(_v) { raise "must not run" } } }
        .key?("ids")).to be(false)
    end

    it "reshapes a fully-valid array, but is skipped when any element violates" do
      decl = proc { permit_params(:create) { array :ids, of: :integer, transform: ->(a) { a.sum } } }
      expect(permit({ ids: %w[1 2 3] }, &decl)[:ids]).to eq(6)

      touchy = proc { permit_params(:create) { array :ids, of: :integer, transform: ->(a) { a.sum } } }
      e = violations_for({ ids: %w[1 x] }, &touchy)
      expect(e.details).to eq([{ param: "ids[1]", code: "invalid_type" }])
    end
  end

  describe "finalize" do
    it "requires a block, rejects a second declaration, and rejects nesting" do
      expect do
        permittable_class do
          permit_params(:create) do
            required :a
            finalize
          end
        end
      end
        .to raise_error(ArgumentError, /finalize requires a block/)
      expect do
        permittable_class do
          permit_params(:create) do
            required :a
            finalize { |p| p }
            finalize { |p| p }
          end
        end
      end
        .to raise_error(ArgumentError, /finalize may only be declared once/)
      expect do
        permittable_class do
          permit_params(:create) do
            required(:a) do
              required :b
              finalize { |p| p }
            end
          end
        end
      end
        .to raise_error(ArgumentError, /finalize is only available at the top level.*inside :a/)
    end

    it "restructures the validated hash — the zip-parallel-fields case" do
      signature = Struct.new(:image, :full_name, :debtor_id)
      decl = proc do
        permit_params(:create, root: :lease_addendum_form) do
          optional :resident_signatures, :string, transform: ->(v) { v.split("<<delimiter>>") }
          optional :signer_names,        :string, transform: ->(v) { v.split(",") }
          optional :signer_ids,          :string, transform: ->(v) { v.split(",") }

          finalize do |p|
            next p unless p[:resident_signatures]

            unless p[:signer_names]&.length == p[:resident_signatures].length &&
                   p[:signer_ids]&.length == p[:resident_signatures].length
              violate!("lease_addendum_form.signer_names", :length_mismatch)
            end

            p[:resident_signatures] = p[:resident_signatures]
                                      .zip(p[:signer_names], p[:signer_ids])
                                      .map { |image, name, id| signature.new(image, name, id) }
            p.except(:signer_names, :signer_ids)
          end
        end
      end

      result = permit({ lease_addendum_form: { resident_signatures: "img1<<delimiter>>img2",
                                               signer_names: "An,Binh", signer_ids: "7,9" } }, &decl)
      expect(result.keys).to eq(["resident_signatures"])
      expect(result[:resident_signatures].map(&:to_a)).to eq([%w[img1 An 7], %w[img2 Binh 9]])

      e = violations_for({ lease_addendum_form: { resident_signatures: "img1<<delimiter>>img2",
                                                  signer_names: "An", signer_ids: "7,9" } }, &decl)
      expect(e.details).to eq([{ param: "lease_addendum_form.signer_names", code: "length_mismatch" }])
    end

    it "violate! halts the block immediately — code after it never runs" do
      ran_past = false
      e = violations_for({ a: "x" }) do
        permit_params(:create) do
          required :a, :string
          finalize do |p|
            violate!("a", :nope)
            ran_past = true
            p
          end
        end
      end
      expect(e.details).to eq([{ param: "a", code: "nope" }])
      expect(ran_past).to be(false)
    end

    it "does not run when field validation already failed" do
      ran = false
      e = violations_for({}) do
        permit_params(:create) do
          required :a, :string
          finalize do |p|
            ran = true
            p
          end
        end
      end
      expect(e.details).to eq([{ param: "a", code: "missing" }])
      expect(ran).to be(false)
    end

    it "rewraps a plain Hash return with indifferent access, and rejects a non-Hash return" do
      result = permit({ a: "x" }) do
        permit_params(:create) do
          required :a, :string
          finalize { |p| { "combined" => p[:a] } }
        end
      end
      expect(result[:combined]).to eq("x")

      klass = permittable_class do
        permit_params(:create) do
          required :a, :string
          finalize { |p| p[:a] }
        end
      end
      expect { controller(klass, params: { a: "x" }).permitted_params }
        .to raise_error(ArgumentError, /finalize must return the params Hash \(got String\)/)
    end

    it "runs on a bare runner — controller state is out of reach (purity)" do
      klass = permittable_class do
        permit_params(:create) do
          required :a, :string
          finalize do |p|
            params
            p
          end
        end
      end
      expect { controller(klass, params: { a: "x" }).permitted_params }
        .to raise_error(NameError, /params/)
    end
  end

  describe "through the real ActionController stack", :integration do
    def build_api_controller(&extra)
      IntegrationHarness.build_controller do
        include Permittable

        permit_params :create, root: :user do
          required :name, :string, length: 1..80
          optional :age,  :integer, in: 18..120
          optional :plan, :string, default: "free"
        end

        def create
          render json: { received: permitted_params }
        end

        class_eval(&extra) if extra
      end
    end

    it "casts and defaults real form-encoded ActionController::Parameters" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { user: { name: "Jo", age: "30" } })
      expect(result.status).to eq(200)
      body = JSON.parse(result.body)
      expect(body["received"]).to eq("name" => "Jo", "age" => 30, "plan" => "free")
    end

    it "hands a :json field plain data, never nested ActionController::Parameters" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params(:create) { optional :metadata, :json }

        def create
          value = permitted_params[:metadata]
          # Assigning ActionController::Parameters to a jsonb attribute raises,
          # so what a contract passes through must already be plain data.
          leaked = value.values.map(&:class).map(&:name).grep(/Parameters/)
          render json: { classes: [value.class.name] + leaked }
        end
      end
      result = IntegrationHarness.dispatch(controller, :create, method: "POST",
                                                                params: { metadata: { nested: { deep: "1" } } })
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)["classes"]).to eq(["ActiveSupport::HashWithIndifferentAccess"])
    end

    it "instruments exactly once through the real rescue_from stack, however often the action reads" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params(:create, root: :user) do
          required :name, :string
          optional :note, :string
        end

        def create
          # The documented "would this request fail?" pattern, then the read.
          permittable_violations
          render json: { received: permitted_params }
        end
      end
      events = recording_notifications do
        @result = IntegrationHarness.dispatch(controller, :create, method: "POST",
                                                                   params: { user: { note: "hi" } })
      end
      expect(@result.status).to eq(422)
      expect(events.length).to eq(1)
      expect(events.first[:details]).to eq([{ param: "user.name", code: "missing" }])
    end

    it "rescues InvalidParameters into the 422 envelope with machine-readable details" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { user: { name: "Jo", age: "12" } })
      expect(result.status).to eq(422)
      body = JSON.parse(result.body)
      expect(body["success"]).to be(false)
      expect(body["error"]["code"]).to eq("invalid_parameters")
      expect(body["error"]["details"]).to eq([{ "param" => "user.age", "code" => "inclusion" }])
    end

    it "renders 400 when the root key is missing" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { name: "rootless" })
      expect(result.status).to eq(400)
      expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "user", "code" => "missing" }])
    end

    it "enforce: true rejects before the action body runs" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params :create, root: :user, enforce: true do
          required :name, :string
        end

        def create
          raise "action body must not run"
        end
      end
      result = IntegrationHarness.dispatch(controller, :create, method: "POST", params: {})
      expect(result.status).to eq(400)
    end

    it "mode: :monitor lets a violating request through to the action with the raw payload" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params :create, root: :user, mode: :monitor do
          required :name, :string
          optional :age,  :integer, in: 18..120
        end

        def create
          render json: { received: permitted_params, violations: permittable_violations }
        end
      end
      result = IntegrationHarness.dispatch(controller, :create,
                                           method: "POST", params: { user: { name: "Jo", age: "12" } })
      expect(result.status).to eq(200)
      body = JSON.parse(result.body)
      expect(body["received"]).to eq("name" => "Jo", "age" => "12")
      expect(body["violations"]).to eq([{ "param" => "user.age", "code" => "inclusion" }])
    end

    it "unknown: :error does not flag Rails' routing keys on top-level contracts" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params :index, unknown: :error do
          optional :page, :integer, default: 1
        end

        def index
          render json: permitted_params
        end
      end
      result = IntegrationHarness.dispatch(controller, :index, query: "page=2")
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)).to eq("page" => 2)

      result = IntegrationHarness.dispatch(controller, :index, query: "page=2&rogue=1")
      expect(result.status).to eq(422)
      expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "rogue", "code" => "unknown" }])
    end

    describe "unknown: :error on a rootless contract, with a real request" do
      # `wrap:` names the wrapper key: a String, as Rails derives it from
      # controller_name, or a Symbol, as the Rails docs write
      # `wrap_parameters :user`. `rule` overrides the permit_params options.
      def build_rootless_controller(wrap: nil, **rule, &fields)
        IntegrationHarness.build_controller do
          include Permittable

          wrap_parameters wrap, format: [:json] if wrap
          permit_params(:create, :update, unknown: :error, **rule, &fields)

          def create
            render json: permitted_params
          end

          def update
            render json: permitted_params
          end
        end
      end

      it "does not flag the router's path parameters (PATCH /users/1 merges `id`)" do
        controller = build_rootless_controller { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", params: { name: "Jo" },
                                                                  path_params: { id: "1" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("name" => "Jo")
      end

      it "does not flag ParamsWrapper's copy of a JSON body under the wrapper key" do
        controller = build_rootless_controller(wrap: "user") { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo" },
                                                                  path_params: { id: "1" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("name" => "Jo")
      end

      it "still flags a genuine extra key alongside the path and wrapper keys" do
        controller = build_rootless_controller(wrap: "user") { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo", rogue: 1 },
                                                                  path_params: { id: "1" })
        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "rogue", "code" => "unknown" }])
      end

      it "still flags a client-sent key that merely shares the wrapper's name" do
        # ParamsWrapper leaves a body alone when it already carries the key,
        # so here `user` is the client's own and is exempt from nothing.
        controller = build_rootless_controller(wrap: "user") { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH",
                                                                  json: { name: "Jo", user: { admin: true } })
        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "user", "code" => "unknown" }])
      end

      it "still flags a client-sent key that shares a Symbol wrapper name" do
        # `wrap_parameters :user` makes ParamsWrapper ask the string-keyed
        # params for :user, so it answers "not sent" and wraps anyway. Whether
        # the client sent the key must not hang on that spelling.
        controller = build_rootless_controller(wrap: :user) { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH",
                                                                  json: { name: "Jo", user: { admin: true } })
        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "user", "code" => "unknown" }])
      end

      it "does not flag the copy under a Symbol wrapper name either" do
        controller = build_rootless_controller(wrap: :user) { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("name" => "Jo")
      end

      # A scalar field that shares the wrapper key's name is ABSENT when Rails
      # made the copy: the client never sent it. Validating the copy instead
      # rejected a well-formed body as that field's invalid_type.
      it "treats a declared scalar field named like the wrapper key as absent when Rails made the copy" do
        controller = build_rootless_controller(wrap: "feedback") do
          optional :rating, :integer
          optional :feedback, :string
        end
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { rating: 5 })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("rating" => 5)
      end

      # A rootless contract that declares the wrapper key as a hash container
      # is reading Rails' copy ON PURPOSE — a root: spelled as a field — and
      # did so before the copy was ever dropped. It keeps the copy.
      it "keeps the copy for a rootless contract that reads it through a nested field" do
        controller = build_rootless_controller(wrap: "user", unknown: :ignore) do
          required :user do
            required :name, :string
          end
        end
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("user" => { "name" => "Jo" })
      end

      it "keeps the copy for a rootless contract that reads it as :json" do
        controller = build_rootless_controller(wrap: "user") do
          optional :name, :string
          optional :user, :json
        end
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("name" => "Jo", "user" => { "name" => "Jo" })
      end

      it "still validates that declared field when the client sent the key itself" do
        # The body already carries `user`, so ParamsWrapper stays out of it
        # and the value is the client's own.
        controller = build_rootless_controller(wrap: "user") do
          optional :name, :string
          optional :user, :string
        end
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo", user: "x" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq("name" => "Jo", "user" => "x")

        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo", user: { a: 1 } })
        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "user", "code" => "invalid_type" }])
      end

      it "resets the recorded wrapper key on every dispatch of a reused controller" do
        # Rails builds a controller per request, so this pins down only the
        # one piece of state this concern records before ParamsWrapper runs:
        # a request ParamsWrapper does not wrap (a form POST) must leave no
        # key behind from the one before. It does not claim a reused instance
        # is otherwise fresh — Metal#dispatch keeps @_params, for one.
        controller = build_rootless_controller(wrap: "user") { optional :name, :string }
        instance = controller.new
        IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo" }, instance: instance)
        expect(instance.instance_variable_get(:@permittable_wrapper_key)).to eq("user")

        IntegrationHarness.dispatch(controller, :create, method: "POST", params: { name: "Jo" }, instance: instance)
        expect(instance.instance_variable_get(:@permittable_wrapper_key)).to be_nil
      end

      it "still validates a declared path parameter" do
        controller = build_rootless_controller { required :id, :integer }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", path_params: { id: "abc" })
        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "id", "code" => "invalid_type" }])
      end

      it "leaves the path parameters and the wrapper's copy in monitor mode's pass-through" do
        # Only the CHECK changes: a legacy action being monitored still reads
        # params[:id] and params[:user] exactly as before the contract.
        controller = build_rootless_controller(wrap: "user", mode: :monitor) { optional :name, :string }
        result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { name: "Jo", rogue: 1 },
                                                                  path_params: { id: "1" })
        expect(result.status).to eq(200)
        expect(JSON.parse(result.body)).to eq(
          "name" => "Jo", "rogue" => 1, "id" => "1", "user" => { "name" => "Jo", "rogue" => 1 }
        )
      end
    end

    it "transform + finalize replace a params-mutating before_action end to end" do
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params :create, root: :lease_addendum_form do
          required :resident_signatures, :string, transform: ->(v) { v.split("<<delimiter>>") }
          required :signer_names,        :string, transform: ->(v) { v.split(",") }

          finalize do |p|
            violate!("lease_addendum_form.signer_names", :length_mismatch) unless p[:signer_names].length == p[:resident_signatures].length
            p[:signatures] = p[:resident_signatures].zip(p[:signer_names]).map { |image, name| { image: image, full_name: name } }
            p.except(:resident_signatures, :signer_names)
          end
        end

        def create
          render json: permitted_params
        end
      end

      both = { lease_addendum_form: { resident_signatures: "i1<<delimiter>>i2", signer_names: "An,Binh" } }
      ok = IntegrationHarness.dispatch(controller, :create, method: "POST", params: both)
      expect(ok.status).to eq(200)
      expect(JSON.parse(ok.body)).to eq("signatures" => [{ "image" => "i1", "full_name" => "An" },
                                                         { "image" => "i2", "full_name" => "Binh" }])

      short = { lease_addendum_form: { resident_signatures: "i1<<delimiter>>i2", signer_names: "An" } }
      mismatch = IntegrationHarness.dispatch(controller, :create, method: "POST", params: short)
      expect(mismatch.status).to eq(422)
      expect(JSON.parse(mismatch.body)["error"]["details"])
        .to eq([{ "param" => "lease_addendum_form.signer_names", "code" => "length_mismatch" }])
    end
  end
end
