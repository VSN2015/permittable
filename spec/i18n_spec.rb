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

  # The Rails i18n guide's per-request locale switch. `enforce: true` and
  # monitor-mode rules validate in a before_action registered by
  # `include Permittable`, so that check sits in the callback chain exactly
  # where the include is, and resolves its messages in whatever locale is
  # current THEN. A switch has to wrap it to be seen.
  describe "under a per-request locale switch", :integration do
    around do |example|
      available = I18n.available_locales
      I18n.available_locales = %i[en de]
      example.run
    ensure
      I18n.available_locales = available
    end

    before do
      I18n.backend.store_translations(:en, permittable: { errors: { missing: "is required" } })
      I18n.backend.store_translations(:de, permittable: { errors: { missing: "fehlt" } })
    end

    # `declare_switch` is a block of callback macros, run on the class either
    # before or after `include Permittable`.
    def switching_controller(rule_options, switch: :after_include, &declare_switch)
      IntegrationHarness.build_controller do
        class_eval(&declare_switch) if switch == :before_include
        include Permittable

        class_eval(&declare_switch) if switch == :after_include

        permit_params :create, root: :user, **rule_options do
          required :name, :string
        end

        def create
          render json: { received: permitted_params }
        end

        def switch_locale(&action)
          I18n.with_locale(params[:locale] || I18n.default_locale, &action)
        end
      end
    end

    def create_with(controller)
      IntegrationHarness.dispatch(controller, :create, method: "POST", query: "locale=de",
                                                       json: { user: { nme: "x" } })
    end

    def first_message(result)
      JSON.parse(result.body)["error"]["details"].first["message"]
    end

    it "translates in the request's locale when the check is lazy" do
      controller = switching_controller({}) { around_action :switch_locale }
      expect(first_message(create_with(controller))).to eq("fehlt")
    end

    it "translates an enforce: true rule in the request's locale when the switch is prepended" do
      controller = switching_controller({ enforce: true }) { prepend_around_action :switch_locale }
      result = create_with(controller)
      expect(result.status).to eq(422)
      expect(first_message(result)).to eq("fehlt")
    end

    it "translates an enforce: true rule in the request's locale when the switch is declared before the include" do
      controller = switching_controller({ enforce: true }, switch: :before_include) { around_action :switch_locale }
      expect(first_message(create_with(controller))).to eq("fehlt")
    end

    it "translates a monitor-mode rule's event in the request's locale when the switch is prepended" do
      controller = switching_controller({ mode: :monitor }) { prepend_around_action :switch_locale }
      details = nil
      subscriber = ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
        details = payload[:details]
      end
      result = create_with(controller)
      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(result.status).to eq(200)
      expect(details).to eq([{ param: "user.name", code: "missing", message: "fehlt" }])
    end

    it "runs the eager check in registration order, so a plain around_action declared after the include is too late" do
      controller = switching_controller({ enforce: true }) { around_action :switch_locale }
      expect(first_message(create_with(controller))).to eq("is required")
    end
  end
end
