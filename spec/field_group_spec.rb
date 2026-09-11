RSpec.describe Permittable::FieldGroup do
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

  let(:address) do
    Permittable.fields do
      required :city, :string, length: 1..80
      optional :zip,  :string, format: /\A\d{5}\z/
    end
  end

  let(:user) do
    Permittable.fields do
      required :name,  :string
      required :email, :string, format: /@/
      optional :plan,  :string, in: %w[free pro], default: "free"
      optional :ssn,   :string, sensitive: true, virtual: true
      array    :tags,  of: :string, length: 0..3
    end
  end

  after { Permittable.filter_parameter_registry.reset! }

  describe "Permittable.fields" do
    it "builds a frozen, introspectable field list" do
      expect(address).to be_frozen
      expect(address.names).to eq(%i[city zip])
      expect(address.fields.first).to include(name: :city, kind: :scalar, type: :string, required: true)
      expect(address.fields).to be_frozen
    end

    it "validates every field at definition time, not at use time" do
      expect { Permittable.fields { optional :a, :string, minimum: 3 } }
        .to raise_error(ArgumentError, /unknown option\(s\) :minimum for field :a/)
    end

    it "requires a block declaring at least one field" do
      expect { Permittable.fields }.to raise_error(ArgumentError, /requires a block/)
      expect { Permittable.fields {} }.to raise_error(ArgumentError, /at least one field/)
    end

    it "rejects finalize, which belongs to a contract" do
      expect { Permittable.fields { required(:a, :string) && finalize { |p| p } } }
        .to raise_error(ArgumentError, /finalize belongs to a contract, not a field group/)
    end
  end

  describe "use" do
    it "splices a group in at the point of use, preserving declaration order" do
      klass = permittable_class do
        permit_params(:create) do
          required :name, :string
          use Permittable.fields { optional :zip, :string }
          optional :note, :string
        end
      end
      expect(klass.permit_rule_for("create")[:fields].map { |f| f[:name] }).to eq(%i[name zip note])
    end

    it "works inside a nested block and an array block" do
      group = address
      klass = permittable_class do
        permit_params(:create) do
          optional :home do
            use group
          end
          array :others do
            use group
          end
        end
      end
      result = controller(klass, params: { home: { city: "Hanoi", zip: "10000" },
                                           others: [{ city: "Hue" }] }).permitted_params
      expect(result[:home].to_h).to eq("city" => "Hanoi", "zip" => "10000")
      expect(result[:others].first.to_h).to eq("city" => "Hue")
    end

    it "validates the spliced fields at request time exactly as if declared inline" do
      group = address
      klass = permittable_class { permit_params(:create) { use group } }
      expect { controller(klass, params: { city: "Hanoi", zip: "abc" }).permitted_params }
        .to raise_error(Permittable::InvalidParameters) { |e|
          expect(e.details).to eq([{ param: "zip", code: "format" }])
        }
    end

    it "relaxes every spliced field with optional: true — how update reuses create" do
      group = user
      klass = permittable_class do
        permit_params(:create, root: :user) { use group }
        permit_params(:update, root: :user) { use group, optional: true }
      end
      create = klass.permit_rule_for("create")[:fields]
      update = klass.permit_rule_for("update")[:fields]
      expect(create.select { |f| f[:required] }.map { |f| f[:name] }).to eq(%i[name email])
      expect(update.any? { |f| f[:required] }).to be(false)

      # A partial update of one field is now legal, and defaults still apply.
      result = controller(klass, params: { user: { name: "Jo" } }, action: "update").permitted_params
      expect(result.to_h).to eq("name" => "Jo", "plan" => "free")
    end

    it "leaves nested sub-fields required under optional: true (send an address, name the city)" do
      group = Permittable.fields do
        required :address do
          required :city, :string
        end
      end
      klass = permittable_class { permit_params(:create) { use group, optional: true } }
      fields = klass.permit_rule_for("create")[:fields]
      expect(fields.first[:required]).to be(false)
      expect(fields.first[:fields].first[:required]).to be(true)
      expect { controller(klass, params: { address: {} }).permitted_params }
        .to raise_error(Permittable::InvalidParameters, /address.city/)
    end

    it "selects a subset with only: and except:, in the group's own order" do
      group = user
      klass = permittable_class do
        permit_params(:create) { use group, only: %i[email name] }
        permit_params(:update) { use group, except: %i[ssn tags plan] }
      end
      expect(klass.permit_rule_for("create")[:fields].map { |f| f[:name] }).to eq(%i[name email])
      expect(klass.permit_rule_for("update")[:fields].map { |f| f[:name] }).to eq(%i[name email])
    end

    it "fails at class load when only:/except: names a field the group does not declare" do
      group = address
      expect { permittable_class { permit_params(:create) { use group, only: %i[city postcode] } } }
        .to raise_error(ArgumentError, /only: names :postcode, which the group does not declare \(it declares: :city, :zip\)/)
      expect { permittable_class { permit_params(:create) { use group, except: %i[postcode] } } }
        .to raise_error(ArgumentError, /except: names :postcode/)
    end

    it "rejects only: with except:, and a selection that keeps nothing" do
      group = address
      expect { permittable_class { permit_params(:create) { use group, only: %i[city], except: %i[zip] } } }
        .to raise_error(ArgumentError, /use takes only: OR except:, not both/)
      expect { permittable_class { permit_params(:create) { use group, except: %i[city zip] } } }
        .to raise_error(ArgumentError, /selects no fields from the group/)
    end

    it "still catches a name declared twice, so overriding must be explicit" do
      group = address
      expect do
        permittable_class do
          permit_params(:create) do
            use group
            required :city, :string
          end
        end
      end.to raise_error(ArgumentError, /field :city is declared twice/)

      klass = permittable_class do
        permit_params(:create) do
          use group, except: %i[city]
          required :city, :string, length: 1..5
        end
      end
      expect(klass.permit_rule_for("create")[:fields].last[:length]).to eq(1..5)
    end

    it "composes: a group can use another group" do
      inner = address
      outer = Permittable.fields do
        required :label, :string
        use inner
      end
      expect(outer.names).to eq(%i[label city zip])
    end

    it "accepts a standalone Contract as a group, so a webhook and a controller share one definition" do
      contract = Permittable::Contract.define { required :city, :string }
      klass = permittable_class { permit_params(:create) { use contract } }
      expect(klass.permit_rule_for("create")[:fields].map { |f| f[:name] }).to eq(%i[city])
    end

    it "rejects anything that is not a field group" do
      expect { permittable_class { permit_params(:create) { use %i[city] } } }
        .to raise_error(ArgumentError, /use expects a field group/)
    end

    it "registers spliced sensitive fields and guards spliced columns" do
      group = user
      permittable_class { permit_params(:create) { use group } }
      expect(Permittable.filter_parameter_registry.include?("ssn")).to be(true)
    end
  end
end
