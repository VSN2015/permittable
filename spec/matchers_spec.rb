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

  it "sees sensitive: on a child that inherited it from its container" do
    cascaded = Class.new(FakeController) do
      include Permittable

      permit_params(:create) do
        optional :payment, sensitive: true do
          required :card_number, :string
          optional :id, :string, sensitive: false
        end
      end
    end
    expect(cascaded).to permit_param("payment.card_number").sensitive
    expect(failure_of { expect(cascaded).to permit_param("payment.id").sensitive })
      .to include("expected the field to be sensitive")
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

  it "checks an opaque :json field with as(:json)" do
    opaque = Class.new(FakeController) do
      include Permittable

      permit_params(:create) { optional :metadata, :json, length: 0..8 }
    end
    expect(opaque).to permit_param(:metadata).as(:json).optional.with_length(0..8)
    expect(failure_of { expect(opaque).to permit_param(:metadata).as(:string) })
      .to include("expected type :string, but the contract declares :json")
  end

  it "checks a format: preset by name, and a Regexp by value" do
    presets = Class.new(FakeController) do
      include Permittable

      permit_params(:create) do
        required :email, :string, format: :email
        required :code,  :string, format: /\A[A-Z]{3}\z/
      end
    end
    expect(presets).to permit_param(:email).matching(:email)
    expect(presets).to permit_param(:code).matching(/\A[A-Z]{3}\z/)
    expect(failure_of { expect(presets).to permit_param(:email).matching(:uuid) })
      .to include("expected format: :uuid, but the contract declares format: :email")
    expect(failure_of { expect(presets).to permit_param(:code).matching(:uuid) })
      .to include("expected format: :uuid, but the contract declares format: /\\A[A-Z]{3}\\z/")
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

  describe "the negated form" do
    let(:with_admin) do
      Class.new(FakeController) do
        include Permittable

        permit_params(:create) { optional :admin, :boolean }
      end
    end

    it "refuses a negated qualifier instead of passing on a field it does permit" do
      expect { expect(with_admin).not_to permit_param(:admin).for_action(:create).required }
        .to raise_error(ArgumentError, /here: required.*ambiguous.*`to permit_param\(:admin\)\.for_action\(:create\)\.optional`/m)
      expect { expect(with_admin).not_to permit_param(:admin).for_action(:create).as(:string) }
        .to raise_error(ArgumentError, /here: as :string.*ambiguous/m)
    end

    it "refuses every narrowing chain, not only required and type" do
      chains = {
        as_array: ->(m) { m.as_array(of: :string) },
        optional: ->(m) { m.optional },
        within: ->(m) { m.within(1..2) },
        matching: ->(m) { m.matching(/x/) },
        with_length: ->(m) { m.with_length(1..2) },
        with_default: ->(m) { m.with_default(1) },
        virtual: ->(m) { m.virtual },
        sensitive: ->(m) { m.sensitive },
        nullable: ->(m) { m.nullable }
      }
      chains.each do |name, chain|
        expect { expect(with_admin).not_to chain.call(permit_param(:admin).for_action(:create)) }
          .to raise_error(ArgumentError, /ambiguous/), "expected not_to ...#{name} to raise"
      end
    end

    it "fails, rather than passing silently, when the action resolves to no rule" do
      message = failure_of { expect(with_admin).not_to permit_param(:admin).for_action(:craete) }
      expect(message).to include("not to permit :admin for #craete")
      expect(message).to include("no contract covering #craete")
    end

    it "fails when the subject declares no contracts at all" do
      empty = Class.new(FakeController) { include Permittable }
      message = failure_of { expect(empty).not_to permit_param(:admin) }
      expect(message).to include("declares no contracts")
    end

    it "resolves the subject before refusing qualifiers, so a wrong subject is reported first" do
      expect { expect(Class.new).not_to permit_param(:admin).required }
        .to raise_error(ArgumentError, /include Permittable/)
    end

    it "fails for a key under an opaque :json field, which lets any nested key through" do
      opaque = Class.new(FakeController) do
        include Permittable

        permit_params(:create, root: :user) do
          optional :meta, :json
          optional :settings do
            optional :prefs, :json
          end
        end
      end
      message = failure_of { expect(opaque).not_to permit_param("meta.admin") }
      expect(message).to include(%(not to permit "meta.admin"))
      expect(message).to include("opaque :json field :meta")
      expect(failure_of { expect(opaque).not_to permit_param("settings.prefs.admin") })
        .to include(%(opaque :json field "settings.prefs"))
      expect(failure_of { expect(opaque).not_to permit_param("user.meta.admin") })
        .to include(%(relative to root: :user, so write permit_param("meta.admin")))
    end

    it "fails for a root-prefixed path, naming the path relative to root:" do
      message = failure_of { expect(controller).not_to permit_param("user.email").for_action(:create) }
      expect(message).to include("relative to root: :user")
      expect(message).to include("permit_param(:email)")
      expect(failure_of { expect(controller).not_to permit_param("user.address.zip").for_action(:create) })
        .to include(%(permit_param("address.zip")))
    end

    it "still passes for an undeclared field on a resolved rule, and fails for a declared one" do
      expect(with_admin).not_to permit_param(:owner).for_action(:create)
      expect(failure_of { expect(with_admin).not_to permit_param(:admin).for_action(:create) })
        .to include("but the contract declares it")
    end
  end

  it "passes for a key under an opaque :json field, but will not check qualifiers it cannot see" do
    opaque = Class.new(FakeController) do
      include Permittable

      permit_params(:create) { optional :meta, :json }
    end
    expect(opaque).to permit_param("meta.admin")
    expect(failure_of { expect(opaque).to permit_param("meta.admin").as(:string) })
      .to include("inside the opaque :json field :meta, which declares nothing about its keys")
  end

  it "fails a root-prefixed path with a hint, instead of listing what is declared" do
    message = failure_of { expect(controller).to permit_param("user.email").for_action(:create) }
    expect(message).to include("paths are relative to root: :user")
    expect(message).to include("permit_param(:email)")
  end

  it "rejects an empty or malformed dotted path with an ArgumentError" do
    ["", "a.", ".a", "a..b"].each do |path|
      expect { expect(controller).to permit_param(path).for_action(:create) }
        .to raise_error(ArgumentError, /\APermittable: .*#{Regexp.escape(path.inspect)}/)
      expect { expect(controller).not_to permit_param(path).for_action(:create) }
        .to raise_error(ArgumentError, /\APermittable: /)
    end
  end

  it "says an array of hashes is one, instead of printing an empty of:" do
    message = failure_of { expect(controller).to permit_param(:line_items).for_action(:create).as_array(of: :string) }
    expect(message).to include("expected an array of :string, but :line_items is an array of hashes")
    expect(message).not_to include("of: :\n")
    expect(message).not_to end_with("of: :")

    message = failure_of { expect(controller).to permit_param(:line_items).for_action(:create).as(:string) }
    expect(message).to include(":line_items is an array of hashes")
  end

  it "reports a non-array field once, not also as an empty of:" do
    message = failure_of { expect(controller).to permit_param(:email).for_action(:create).as_array(of: :string) }
    expect(message).to include("expected an array field")
    expect(message).not_to include("of: :")
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
