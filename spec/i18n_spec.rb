require "i18n"

# I18n's own placeholder syntax is %{name}; these specs are about it.
# rubocop:disable Style/FormatStringToken

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

  # A translation written `"%{param} is required"` shipped its literal
  # placeholder: the lookup passed I18n no values, so it never interpolated.
  describe "interpolation" do
    it "fills %{param} and %{code} from the violation" do
      store(missing: "%{param} is required (%{code})", invalid_type: "no placeholders")
      details = violations_for({ user: { age: "x" } }) do
        permit_params(:create, root: :user) do
          required :name, :string
          optional :age, :integer
        end
      end
      expect(details).to contain_exactly(
        { param: "user.name", code: "missing", message: "user.name is required (missing)" },
        { param: "user.age", code: "invalid_type", message: "no placeholders" }
      )
    end

    it "cannot be broken by a client-controlled param containing a placeholder or a format directive" do
      store(unknown: "%{param} is not recognized")
      details = violations_for({ "%{code}%<x>d%s%%" => 1 }) { permit_params(:create, unknown: :error) { optional :a, :string } }
      expect(details).to eq([{ param: "%{code}%<x>d%s%%", code: "unknown", message: "%{code}%<x>d%s%% is not recognized" }])
    end

    it "keeps a placeholder it has no value for as written, and still fills the others" do
      store(missing: "%{field} is required", invalid_type: "%{param} needs %{field}")
      details = violations_for({ age: "x" }) do
        permit_params(:create) do
          required :name, :string
          optional :age, :integer
        end
      end
      expect(details).to contain_exactly(
        { param: "name", code: "missing", message: "%{field} is required" },
        { param: "age", code: "invalid_type", message: "age needs %{field}" }
      )
    end

    it "leaves % escapes and format directives in the copy as written" do
      store(missing: "100%% of %<x>s, %{param}")
      details = violations_for({}) { permit_params(:create) { required :name, :string } }
      expect(details).to eq([{ param: "name", code: "missing", message: "100%% of %<x>s, name" }])
    end

    it "does not read %{param} after a %% escape as a placeholder" do
      store(invalid_type: "%%{param} 100%% %{param}")
      details = violations_for({ age: "x" }) { permit_params(:create) { optional :age, :integer } }
      expect(details).to eq([{ param: "age", code: "invalid_type", message: "%%{param} 100%% age" }])
    end

    it "interpolates a violate! message too" do
      store(too_big: "%{param} is too big")
      details = violations_for({ n: "3" }) do
        permit_params(:create) do
          required :n, :integer
          finalize { |p| violate!(:n, :too_big) && p }
        end
      end
      expect(details).to eq([{ param: "n", code: "too_big", message: "n is too big" }])
    end
  end

  # The summary names each violation by its param and then its message. A
  # translation that spells the param itself (`%{param} is missing`) already
  # does, and the summary read `user.name user.name is missing (missing)`.
  describe "the prose summary" do
    def summary_of(klass, params)
      c = klass.new(params: params)
      c.define_singleton_method(:action_name) { "create" }
      c.permitted_params
    rescue Permittable::InvalidParameters => e
      e.message
    end

    let(:klass) do
      permittable_class do
        permit_params(:create, root: :user) do
          required :name, :string
          required :age, :integer, message: "must be a number"
          optional :nick, :string, in: %w[a b]
          finalize { |p| violate!(:name, :too_long) && p }
        end
      end
    end

    it "does not repeat the param before a translation that already names it" do
      store(missing: "%{param} is missing (%{code})")
      expect(summary_of(klass, { user: { age: "x" } }))
        .to eq("Invalid parameters: user.name is missing (missing), user.age must be a number")
    end

    it "keeps the param prefix for a translation without %{param} and for a field's own message:" do
      store(missing: "is missing", inclusion: "is not allowed")
      expect(summary_of(klass, { user: { age: "x", nick: "z" } }))
        .to eq("Invalid parameters: user.name is missing, user.age must be a number, user.nick is not allowed")
    end

    it "agrees for a violate! code in finalize, and for a Contract's raised message" do
      store(too_long: "%{param} is too long")
      c = Permittable::Contract.define(root: :user) do
        required :name, :string
        finalize { |p| violate!("user.name", :too_long) && p }
      end
      expect { c.call!("user" => { "name" => "x" }) }
        .to raise_error(Permittable::InvalidParameters, "Invalid parameters: user.name is too long")
    end

    it "agrees in the monitor-mode log line" do
      store(missing: "%{param} is missing")
      klass = permittable_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      c = klass.new(params: {})
      c.define_singleton_method(:action_name) { "create" }
      messages = []
      logger = Object.new
      logger.define_singleton_method(:warn) { |msg| messages << msg }
      c.define_singleton_method(:logger) { logger }
      c.permitted_params
      expect(messages.join).to include("would have been rejected: name is missing").and(satisfy { !_1.include?("name name") })
    end
  end

  # With `unknown: :error`, every undeclared key is a violation, and each one
  # used to ask I18n for the same copy again: 200,000 keys took 34 seconds.
  it "looks a code's translation up once per validation, not once per violation" do
    store(unknown: "is not recognized")
    extra = (1..500).to_h { |i| ["k#{i}", 1] }
    klass = permittable_class { permit_params(:create, unknown: :error) { optional :a, :string } }
    c = klass.new(params: extra)
    c.define_singleton_method(:action_name) { "create" }
    expect(I18n).to receive(:t).with("permittable.errors.unknown", default: nil).once.and_call_original
    expect(c.permittable_violations.map { _1[:message] }.uniq).to eq(["is not recognized"])
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

    # pins the documented limitation; delete if the callback order is ever changed
    it "runs the eager check in registration order, so a plain around_action declared after the include is too late" do
      controller = switching_controller({ enforce: true }) { around_action :switch_locale }
      expect(first_message(create_with(controller))).to eq("is required")
    end
  end
end

# rubocop:enable Style/FormatStringToken
