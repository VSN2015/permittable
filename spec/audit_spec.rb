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
        expect(described_class.summary(found)).to include(uncovered: 2, uncovered_with_body: 0, missing_actions: 2)
      end

      it "says so in the report instead of flagging a body" do
        report = described_class.format(found)
        expect(report).to match(%r{POST\s+/posts\s+create\s+no contract — action not found$})
        expect(report).not_to include("ACCEPTS A BODY")
        expect(report).to include("4 routed actions: 0 enforced, 0 in monitor mode, 2 without a contract, " \
                                  "2 not found (Rails 404s them)")
        expect(report).to include("0 of those accept a request body")
      end

      it "still counts the action once the controller defines it" do
        posts.define_singleton_method(:action_methods) { Set.new(%w[index show create update]) }
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(2)
      end

      it "assumes the action exists when the controller cannot say" do
        expect(entries.none?(&:missing_action?)).to be(true)
      end

      # A duck listing Symbols once marked EVERY action missing, and strict
      # passed everything.
      it "normalises an action list of Symbols" do
        posts.define_singleton_method(:action_methods) { Set.new(%i[index show create update]) }
        expect(found.none?(&:missing_action?)).to be(true)
      end

      # The README quotes the singular form.
      it "says it, not them, for a single missing action" do
        posts.define_singleton_method(:action_methods) { Set.new(%w[index show update]) }
        expect(described_class.format(found)).to include("3 without a contract, 1 not found (Rails 404s it)")
      end

      it "reads the action list once per controller, however many routes it has" do
        allow(posts).to receive(:action_methods).and_call_original
        found
        expect(posts).to have_received(:action_methods).once
      end

      context "when a contract is left on it" do
        let(:covered) do
          controller_class("posts") { permit_params(:create) { required :title, :string } }.tap do |klass|
            klass.define_singleton_method(:action_methods) { Set.new(%w[index show]) }
          end
        end
        let(:found) { described_class.entries(controllers: [covered], routes: post_routes) }

        # A contract left on an action that no longer exists guards nothing, so
        # it must not read as coverage: the buckets stay disjoint and add up.
        it "counts it only as missing" do
          expect(described_class.summary(found)).to include(actions: 4, enforced: 0, monitored: 0, uncovered: 2,
                                                            unguarded_models: 0, missing_actions: 2)
        end

        it "shows the mode and that the action is not found" do
          expect(described_class.format(found)).to match(%r{POST\s+/posts\s+create\s+enforce  action not found$})
        end

        # Out of every bucket, it would otherwise vanish from the report's
        # conclusions — and a routed action Rails 404s is exactly the renamed
        # or deleted one the stale list exists for.
        it "lists the contract as stale" do
          expect(described_class.stale(controllers: [covered], routes: post_routes)).to eq("posts" => ["create"])
        end
      end
    end

    # Rails dispatches more than action_methods: an inherited method, an
    # `action_missing` handler, and a template with no method behind it all
    # run with the body parsed. Only an action none of them answers 404s.
    context "with a real ActionController" do
      around do |example|
        Dir.mktmpdir do |views|
          FileUtils.mkdir_p(File.join(views, "audit_pages"))
          File.write(File.join(views, "audit_pages", "preview.html.erb"), "preview")
          @views = views
          example.run
        end
      end

      let(:pages) do
        views = @views
        stub_const("AuditPagesController", Class.new(ActionController::Base) do
          prepend_view_path views

          def create
            head :created
          end
        end)
      end
      let(:child) { stub_const("AuditChildPagesController", Class.new(pages)) }
      let(:catch_all) do
        stub_const("AuditCatchAllController", Class.new(ActionController::Base) do
          def action_missing(_name, *)
            head :ok
          end
        end)
      end

      def missing?(controller, action)
        route = { controller: controller.controller_path, action: action, verb: "post", path: "/x" }
        described_class.entries(controllers: [controller], routes: [route]).first.missing_action?
      end

      it "finds an action inherited from a parent controller" do
        expect(missing?(child, "create")).to be(false)
      end

      it "finds every action of a controller that defines action_missing" do
        expect(missing?(catch_all, "anything")).to be(false)
      end

      it "finds a template-only action, which renders implicitly" do
        expect(missing?(pages, "preview")).to be(false)
        expect(missing?(child, "preview")).to be(false)
      end

      it "reports an action with no method, no action_missing and no template" do
        expect(missing?(pages, "destroy")).to be(true)
      end

      it "reports a missing action on an API controller, which has no template fallback" do
        api = stub_const("AuditApiThingsController", Class.new(ActionController::API) do
          def index
            head :ok
          end
        end)
        expect([missing?(api, "index"), missing?(api, "create")]).to eq([false, true])
      end

      # A via: :all route is five entries for one action; Rails need only be
      # asked once.
      it "asks Rails's resolver once per action, not once per verb" do
        allow(catch_all).to receive(:new).and_call_original
        verb_routes = %w[get post put patch delete].map do |verb|
          { controller: catch_all.controller_path, action: "anything", verb: verb, path: "/x" }
        end
        described_class.entries(controllers: [catch_all], routes: verb_routes)
        expect(catch_all).to have_received(:new).once
      end

      it "assumes the action exists when Rails's resolver cannot be asked" do
        unbuildable = stub_const("AuditUnbuildableController", Class.new(ActionController::Base) do
          def initialize(*) # rubocop:disable Lint/MissingSuper -- raising is the point
            raise ArgumentError, "needs collaborators"
          end
        end)
        expect(missing?(unbuildable, "create")).to be(false)
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
