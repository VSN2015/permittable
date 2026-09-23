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

    it "counts a via: :all route as body-accepting when nothing covers it" do
      hooks = bare_class("webhooks")
      hook_routes = %w[get post put patch delete].map do |verb|
        { controller: "webhooks", action: "receive", verb: verb, path: "/hooks" }
      end
      found = described_class.entries(controllers: [hooks], routes: hook_routes)
      expect(found.map(&:verb)).to eq(%w[delete get patch post put])
      expect(described_class.summary(found)[:uncovered_with_body]).to eq(3)
    end

    context "when a routed action has no action method" do
      # `resources :posts` routes all seven actions whether or not the
      # controller defines them; Rails 404s the ones it does not.
      let(:posts) do
        bare_class("posts").tap do |klass|
          klass.define_singleton_method(:action_methods) { Set.new(%w[index show]) }
        end
      end
      let(:post_routes) do
        [{ controller: "posts", action: "index", verb: "get", path: "/posts" },
         { controller: "posts", action: "create", verb: "post", path: "/posts" },
         { controller: "posts", action: "show", verb: "get", path: "/posts/{id}" },
         { controller: "posts", action: "update", verb: "patch", path: "/posts/{id}" }]
      end
      let(:found) { described_class.entries(controllers: [posts], routes: post_routes) }

      it "labels the entry rather than dropping it" do
        expect(found.map { |e| [e.action, e.missing_action?] }).to eq(
          [["index", false], ["create", true], ["show", false], ["update", true]]
        )
      end

      it "leaves it out of the strict count" do
        expect(described_class.summary(found)).to include(uncovered: 4, uncovered_with_body: 0, missing_actions: 2)
      end

      it "says so in the report instead of flagging a body" do
        report = described_class.format(found)
        expect(report).to match(%r{POST\s+/posts\s+create\s+no contract — no action method$})
        expect(report).not_to include("ACCEPTS A BODY")
        expect(report).to include("0 of those accept a request body")
        expect(report).to include("2 routed actions have no action method")
      end

      it "still counts the action once the controller defines it" do
        posts.define_singleton_method(:action_methods) { Set.new(%w[index show create update]) }
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(2)
      end

      it "assumes the action exists when the controller cannot say" do
        expect(entries.none?(&:missing_action?)).to be(true)
      end
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
        actions: 5, enforced: 1, monitored: 1, uncovered: 3, uncovered_with_body: 2, unguarded_models: 2,
        missing_actions: 0
      )
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
