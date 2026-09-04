require "permittable/rspec"

RSpec.describe "Permittable RSpec matchers" do
  include Permittable::Matchers

  def failure_of
    yield
    raise "expected the matcher to fail"
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e.message
  end

  let(:controller) do
    Class.new(FakeController) do
      include Permittable

      permit_params :create, :update, root: :user do
        required :email, :string, format: /@/
        optional :age,   :integer, in: 18..120
        optional :plan,  :string, in: %w[free pro], default: "free"
        optional :ssn,   :string, sensitive: true, virtual: true
        array    :tags,  of: :string, length: 0..10
        optional :address do
          required :city, :string
          optional :zip,  :string
        end
        array :line_items do
          required :sku, :string
        end
      end

      permit_params(:destroy) { optional :reason, :string }
    end
  end

  let(:single_contract_controller) do
    Class.new(FakeController) do
      include Permittable

      permit_params(:create) { required :name, :string }
    end
  end

  after { Permittable.filter_parameter_registry.reset! }

  it "passes for a declared field" do
    expect(controller).to permit_param(:email).for_action(:create)
  end

  it "checks the scalar type" do
    expect(controller).to permit_param(:age).for_action(:create).as(:integer)

    message = failure_of { expect(controller).to permit_param(:age).for_action(:create).as(:string) }
    expect(message).to include("type :string")
    expect(message).to include(":integer")
  end

  it "checks in:, format:, length:, and default:" do
    expect(controller).to permit_param(:age).for_action(:create).within(18..120)
    expect(controller).to permit_param(:email).for_action(:create).matching(/@/)
    expect(controller).to permit_param(:tags).for_action(:create).with_length(0..10)
    expect(controller).to permit_param(:plan).for_action(:create).with_default("free")

    message = failure_of { expect(controller).to permit_param(:age).for_action(:create).within(1..5) }
    expect(message).to include("in: 1..5")
  end

  it "checks required and optional" do
    expect(controller).to permit_param(:email).for_action(:create).required
    expect(controller).to permit_param(:age).for_action(:create).optional

    message = failure_of { expect(controller).to permit_param(:age).for_action(:create).required }
    expect(message).to include("required")
  end

  it "checks virtual and sensitive flags" do
    expect(controller).to permit_param(:ssn).for_action(:create).virtual.sensitive
  end

  it "checks the nullable flag" do
    nullable = Class.new(FakeController) do
      include Permittable

      permit_params(:create) do
        optional :nickname, :string, nullable: true
        optional :name, :string
      end
    end
    expect(nullable).to permit_param(:nickname).nullable
    expect(failure_of { expect(nullable).to permit_param(:name).nullable })
      .to include("expected the field to be nullable, but it is not")
  end

  it "checks arrays with as_array and an element type" do
    expect(controller).to permit_param(:tags).for_action(:create).as_array
    expect(controller).to permit_param(:tags).for_action(:create).as_array(of: :string)

    message = failure_of { expect(controller).to permit_param(:tags).for_action(:create).as(:string) }
    expect(message).to include("as_array")
  end

  it "resolves dotted paths through nested blocks and array blocks" do
    expect(controller).to permit_param("address.zip").for_action(:create).as(:string).optional
    expect(controller).to permit_param("line_items.sku").for_action(:create).required
  end

  it "fails for an undeclared field, listing what is declared" do
    message = failure_of { expect(controller).to permit_param(:admin).for_action(:create) }
    expect(message).to include(":admin")
    expect(message).to include("email")
    expect(message).to include("age")
  end

  it "supports not_to for undeclared fields, and explains a negated failure" do
    expect(controller).not_to permit_param(:admin).for_action(:create)

    message = failure_of { expect(controller).not_to permit_param(:email).for_action(:create) }
    expect(message).to include("not to permit")
  end

  it "uses the action's matching rule, so different actions see different contracts" do
    expect(controller).to permit_param(:reason).for_action(:destroy)
    expect(controller).not_to permit_param(:email).for_action(:destroy)
  end

  it "works without for_action when the controller declares exactly one contract" do
    expect(single_contract_controller).to permit_param(:name).as(:string).required
  end

  it "demands for_action when several contracts are declared" do
    expect { expect(controller).to permit_param(:email) }
      .to raise_error(ArgumentError, /for_action/)
  end

  it "rejects a subject that does not include Permittable" do
    expect { expect(Class.new).to permit_param(:email) }
      .to raise_error(ArgumentError, /include Permittable/)
    expect { expect(Object.new).to permit_param(:email) }
      .to raise_error(ArgumentError, /include Permittable/)
  end

  it "accepts a controller instance, resolving through its class" do
    instance = controller.new(params: {})
    expect(instance).to permit_param(:email).for_action(:create).as(:string)
    expect(instance).not_to permit_param(:admin).for_action(:create)
  end

  it "asserts on a standalone Permittable::Contract with the same chains" do
    contract = Permittable::Contract.define(root: :user) do
      required :email, :string
      optional :age, :integer, in: 18..120
    end
    expect(contract).to permit_param(:age).as(:integer).within(18..120)
    expect(contract).to permit_param(:email).for_action(:anything).required
    expect(contract).not_to permit_param(:admin)
  end

  it "fails clearly when the action has no contract at all" do
    message = failure_of { expect(single_contract_controller).to permit_param(:name).for_action(:archive) }
    expect(message).to include("no contract")
  end

  it "describes itself readably" do
    matcher = permit_param(:age).for_action(:create).as(:integer).within(18..120)
    expect(matcher.description).to eq("permit :age (for #create) as :integer, in: 18..120")
    expect(permit_param(:nickname).nullable.description).to eq("permit :nickname nullable")
  end
end
