RSpec.describe Permittable::Audit do
  def controller_class(name, &declaration)
    klass = Class.new(FakeController) do
      include Permittable

      class_eval(&declaration) if declaration
    end
    klass.define_singleton_method(:controller_path) { name }
    klass
  end

  # A controller that never included the concern — exactly the unguarded case
  # the audit exists to surface.
  def bare_class(name)
    Class.new(FakeController) { def self.name = "Bare" }.tap do |klass|
      klass.define_singleton_method(:controller_path) { name }
    end
  end

  let(:users) do
    controller_class("users") do
      permit_params :create, root: :user, model: nil do
        required :name, :string
      end
      permit_params :destroy, mode: :monitor do
        optional :reason, :string
      end
    end
  end

  let(:routes) do
    [{ controller: "users", action: "index", verb: "get", path: "/users" },
     { controller: "users", action: "create", verb: "post", path: "/users" },
     { controller: "users", action: "update", verb: "patch", path: "/users/{id}" },
     { controller: "users", action: "destroy", verb: "delete", path: "/users/{id}" },
     { controller: "legacy", action: "create", verb: "post", path: "/legacy" }]
  end

  let(:entries) { described_class.entries(controllers: [users, bare_class("legacy")], routes: routes) }

  after { Permittable.filter_parameter_registry.reset! }

  describe ".entries" do
    it "pairs every routed action with the rule a request would resolve to" do
      expect(entries.map { |e| [e.controller, e.action, e.covered?] }).to eq(
        [["legacy", "create", false],
         ["users", "index", false],
         ["users", "create", true],
         ["users", "destroy", true],
         ["users", "update", false]]
      )
    end

    it "reports the EFFECTIVE mode, since an audit runs inside the app that configures it" do
      expect(entries.find { |e| e.action == "create" && e.controller == "users" }.mode).to eq(:enforce)
      expect(entries.find { |e| e.action == "destroy" }.mode).to eq(:monitor)

      Permittable.mode = :monitor
      fresh = described_class.entries(controllers: [users], routes: routes)
      expect(fresh.find { |e| e.action == "create" }.mode).to eq(:monitor)
    ensure
      Permittable.mode = :enforce
    end

    it "covers controllers that never included the concern" do
      legacy = entries.first
      expect(legacy.covered?).to be(false)
      expect(legacy.mode).to be_nil
    end

    it "knows which uncovered actions accept a request body" do
      uncovered = entries.reject(&:covered?)
      expect(uncovered.select(&:body?).map { |e| [e.controller, e.action] })
        .to eq([%w[legacy create], %w[users update]])
      expect(uncovered.reject(&:body?).map { |e| e.action }).to eq(["index"])
    end

    it "reports whether a rule guards its columns against the schema" do
      guarded = controller_class("guarded") do
        permit_params(:create, model: nil) { required :a, :string }
      end
      entry = described_class.entries(controllers: [guarded],
                                      routes: [{ controller: "guarded", action: "create", verb: "post", path: "/g" }]).first
      expect(entry.model).to be_nil
      expect(entry.unknown).to eq(:ignore)
    end

    it "expands a catch-all rule across every routed action of its controller" do
      catch_all = controller_class("things") { permit_params { optional :q, :string } }
      thing_routes = [{ controller: "things", action: "index", verb: "get", path: "/things" },
                      { controller: "things", action: "create", verb: "post", path: "/things" }]
      expect(described_class.entries(controllers: [catch_all], routes: thing_routes).map(&:covered?))
        .to eq([true, true])
    end
  end

  describe ".stale" do
    it "finds contracts declared for actions no route reaches" do
      expect(described_class.stale(controllers: [users], routes: routes)).to eq({})

      renamed = controller_class("users") do
        permit_params(:create) { required :a, :string }
        permit_params(:archive) { required :b, :string }
      end
      expect(described_class.stale(controllers: [renamed], routes: routes)).to eq("users" => ["archive"])
    end
  end

  describe ".summary" do
    it "counts coverage, with the body-accepting gap called out separately" do
      expect(described_class.summary(entries)).to eq(
        actions: 5, enforced: 1, monitored: 1, uncovered: 3, uncovered_with_body: 2, unguarded_models: 2
      )
    end

    # rails_routes expands `scope "(:locale)"` into one descriptor per URL.
    # The table lists both — each is a real URL — but they are one routed
    # action, and one unguarded POST must not count as two.
    it "counts an action once however many paths reach it" do
      localized = routes + [{ controller: "users", action: "create", verb: "post", path: "/{locale}/users" },
                            { controller: "legacy", action: "create", verb: "post", path: "/{locale}/legacy" }]
      expanded = described_class.entries(controllers: [users, bare_class("legacy")], routes: localized)
      expect(expanded.length).to eq(7)
      expect(described_class.summary(expanded)).to eq(described_class.summary(entries))
    end
  end

  describe ".format" do
    it "renders a grouped table, the summary, and any stale contracts" do
      report = described_class.format(entries, stale: { "users" => ["archive"] })
      expect(report).to include("users")
      expect(report).to include("POST   /users")
      expect(report).to include("create")
      expect(report).to include("no contract")
      expect(report).to include("monitor")
      expect(report).to include("3 without a contract")
      expect(report).to include("2 of those accept a request body")
      expect(report).to include("users#archive")
    end

    it "says so plainly when there is nothing to report" do
      expect(described_class.format([], stale: {})).to include("no routed actions")
    end
  end
end
