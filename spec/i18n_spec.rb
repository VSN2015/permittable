require "i18n"

RSpec.describe "I18n violation messages" do
  def permittable_class(&declaration)
    Class.new(FakeController) do
      include Permittable

      class_eval(&declaration) if declaration
    end
  end

  def violations_for(params, action: "create", &declaration)
    klass = permittable_class(&declaration)
    c = klass.new(params: params)
    c.define_singleton_method(:action_name) { action }
    c.permittable_violations
  end

  after do
    I18n.backend.reload!
    Permittable.filter_parameter_registry.reset!
  end

  def store(errors)
    I18n.backend.store_translations(:en, permittable: { errors: errors })
  end

  it "keeps the bare { param:, code: } shape when no translation exists" do
    details = violations_for({}) { permit_params(:create) { required :name, :string } }
    expect(details).to eq([{ param: "name", code: "missing" }])
  end

  it "resolves permittable.errors.<code> into the violation message" do
    store(missing: "is required")
    details = violations_for({}) { permit_params(:create) { required :name, :string } }
    expect(details).to eq([{ param: "name", code: "missing", message: "is required" }])
  end

  it "rides the resolved message into the exception summary" do
    store(inclusion: "is not an allowed value")
    klass = permittable_class { permit_params(:create) { optional :plan, :string, in: %w[free pro] } }
    c = klass.new(params: { plan: "gold" })
    c.define_singleton_method(:action_name) { "create" }
    expect { c.permitted_params }.to raise_error(
      Permittable::InvalidParameters, /plan is not an allowed value/
    )
  end

  it "lets a field's own message: beat the translation" do
    store(missing: "is required")
    details = violations_for({}) do
      permit_params(:create) { required :name, :string, message: "cannot be blank" }
    end
    expect(details).to eq([{ param: "name", code: "missing", message: "cannot be blank" }])
  end

  it "falls back to the translation for codes a message: Hash does not cover" do
    store(missing: "is required")
    details = violations_for({ name: 3 }, action: "create") do
      permit_params(:create) { required :name, :string, format: /x/, message: { format: "looks wrong" } }
    end
    expect(details).to eq([{ param: "name", code: "format", message: "looks wrong" }])

    missing = violations_for({}) do
      permit_params(:create) { required :name, :string, message: { format: "looks wrong" } }
    end
    expect(missing).to eq([{ param: "name", code: "missing", message: "is required" }])
  end

  it "translates a missing root and unknown keys too" do
    store(missing: "is required", unknown: "is not a recognized parameter")
    root_details = violations_for({}) do
      permit_params(:create, root: :user) { required :name, :string }
    end
    expect(root_details).to eq([{ param: "user", code: "missing", message: "is required" }])

    unknown_details = violations_for({ name: "x", extra: "y" }) do
      permit_params(:create, unknown: :error) { required :name, :string }
    end
    expect(unknown_details).to eq([{ param: "extra", code: "unknown", message: "is not a recognized parameter" }])
  end

  it "translates violate! codes in finalize, with an explicit message: still winning" do
    store(before_start: "must be after the start date")
    translated = violations_for({ a: "2", b: "1" }) do
      permit_params(:create) do
        required :a, :integer
        required :b, :integer
        finalize do |p|
          violate!("b", :before_start) if p[:b] < p[:a]
          p
        end
      end
    end
    expect(translated).to eq([{ param: "b", code: "before_start", message: "must be after the start date" }])

    explicit = violations_for({ a: "2", b: "1" }) do
      permit_params(:create) do
        required :a, :integer
        required :b, :integer
        finalize do |p|
          violate!("b", :before_start, message: "own copy") if p[:b] < p[:a]
          p
        end
      end
    end
    expect(explicit).to eq([{ param: "b", code: "before_start", message: "own copy" }])
  end

  it "translates Symbol codes returned by validate:" do
    store(must_be_even: "must be an even number")
    details = violations_for({ n: "3" }) do
      permit_params(:create) { required :n, :integer, validate: ->(v) { v.even? || :must_be_even } }
    end
    expect(details).to eq([{ param: "n", code: "must_be_even", message: "must be an even number" }])
  end

  it "ignores a non-String translation instead of leaking structure" do
    I18n.backend.store_translations(:en, permittable: { errors: { missing: { nope: "nested" } } })
    details = violations_for({}) { permit_params(:create) { required :name, :string } }
    expect(details).to eq([{ param: "name", code: "missing" }])
  end
end
