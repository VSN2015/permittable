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

    # permittable_contracts is a class_attribute, so a subclass carries every
    # rule its parent declared. Judged one class at a time, a shared base
    # (routed to nothing) and each subclass routed to a different slice of
    # its actions all read as stale.
    context "when subclasses inherit the contract" do
      def subclass(parent, name)
        Class.new(parent).tap { |klass| klass.define_singleton_method(:controller_path) { name } }
      end

      let(:base) do
        controller_class("api/base") do
          permit_params(:create) { required :a, :string }
          permit_params(:update) { required :b, :string }
        end
      end
      let(:accounts) { subclass(base, "api/accounts") }
      let(:posts) { subclass(base, "api/posts") }
      let(:split_routes) do
        [{ controller: "api/accounts", action: "create", verb: "post", path: "/accounts" },
         { controller: "api/posts", action: "update", verb: "patch", path: "/posts/{id}" }]
      end

      it "does not report a shared base whose subclass routes the action" do
        shared = controller_class("api/base") { permit_params(:create) { required :a, :string } }
        child = subclass(shared, "api/users")
        users_routes = [{ controller: "api/users", action: "create", verb: "post", path: "/users" }]
        expect(described_class.stale(controllers: [shared, child], routes: users_routes)).to eq({})
      end

      it "counts an action as reached when any controller carrying the contract routes it" do
        expect(described_class.stale(controllers: [base, accounts, posts], routes: split_routes)).to eq({})
      end

      # Not under every subclass too, and not dropped because no subclass
      # declared it: an inherited rule nothing routes is still stale.
      it "reports a contract no carrier routes once, under the class that declared it" do
        expect(described_class.stale(controllers: [base, accounts], routes: split_routes.first(1)))
          .to eq("api/base" => ["update"])
      end

      it "counts the base's own routes when it is routed as well as subclassed" do
        routed_base = [split_routes.first, { controller: "api/base", action: "update", verb: "patch", path: "/base/{id}" }]
        expect(described_class.stale(controllers: [base, accounts], routes: routed_base)).to eq({})
      end

      # Inheritance runs one way: a request to the parent never resolves
      # through a rule only its subclass declared.
      it "does not let a parent's routes keep a subclass's own contract alive" do
        posts.permit_params(:archive) { required :c, :string }
        parent_archive = split_routes + [{ controller: "api/base", action: "archive", verb: "post", path: "/base" }]
        expect(described_class.stale(controllers: [base, accounts, posts], routes: parent_archive))
          .to eq("api/posts" => ["archive"])
      end

      it "still treats a route the carrier would 404 as no route" do
        accounts.define_singleton_method(:action_methods) { Set.new(%w[index]) }
        expect(described_class.stale(controllers: [base, accounts, posts], routes: split_routes))
          .to eq("api/base" => ["create"])
      end

      # The declaring class carries its rule whether or not it was passed, so
      # a report naming it never contradicts its own routes.
      it "judges an inherited contract by its declaring class even when only a subclass is passed" do
        routed_base = [split_routes.first, { controller: "api/base", action: "update", verb: "patch", path: "/base/{id}" }]
        expect(described_class.stale(controllers: [accounts], routes: routed_base)).to eq({})
        expect(described_class.stale(controllers: [accounts], routes: split_routes.first(1)))
          .to eq("api/base" => ["update"])
      end
    end
  end

  describe ".summary" do
    it "counts coverage, with the body-accepting gap called out separately" do
      expect(described_class.summary(entries)).to eq(
        actions: 5, enforced: 1, monitored: 1, uncovered: 3, uncovered_with_body: 2, unguarded_models: 2,
        missing_actions: 0
      )
    end

    # rails_routes expands `scope "(:locale)"` into one descriptor per URL,
    # each tagged with the route it came from. The table lists both — each is
    # a real URL — but they are one route, and one unguarded POST must not
    # count as two.
    it "counts the paths expanded from one route once" do
      sourced = routes.each_with_index.map { |route, index| route.merge(route: index) }
      localized = sourced + [{ controller: "users", action: "create", verb: "post", path: "/{locale}/users", route: 1 },
                             { controller: "legacy", action: "create", verb: "post", path: "/{locale}/legacy", route: 4 }]
      expanded = described_class.entries(controllers: [users, bare_class("legacy")], routes: localized)
      expect(expanded.length).to eq(7)
      expect(described_class.summary(expanded)).to eq(described_class.summary(entries))
    end

    # Two routes to the same action are two ways in, not one: each unguarded
    # POST is its own gap, and `[strict]` must count both. A hand-built
    # descriptor with no `route:` is its own route.
    it "counts distinct routes to the same action separately" do
      admin = routes + [{ controller: "legacy", action: "create", verb: "post", path: "/admin/legacy" }]
      counts = described_class.summary(described_class.entries(controllers: [users, bare_class("legacy")],
                                                               routes: admin))
      expect(counts).to include(actions: 6, uncovered: 4, uncovered_with_body: 3)
    end

    # `route:` is a position within ONE rails_routes call, so two lists
    # concatenated (an app plus a mounted engine) reuse the same small
    # integers. Route 0 of one controller is not route 0 of another.
    it "keeps a reused route index on different controllers apart" do
      app = [{ controller: "legacy", action: "create", verb: "post", path: "/legacy", route: 0 }]
      engine = [{ controller: "imports", action: "create", verb: "post", path: "/imports", route: 0 }]
      found = described_class.entries(controllers: [bare_class("legacy"), bare_class("imports")],
                                      routes: app + engine)
      expect(described_class.summary(found)).to include(actions: 2, uncovered_with_body: 2)
    end

    it "tells a route's expanded paths from a second route, reading a real route set" do
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw do
        scope("(:locale)") { post "legacy", to: "legacy#create" }
        post "admin/legacy", to: "legacy#create"
      end
      descriptors = Permittable::OpenAPI.rails_routes(Struct.new(:routes).new(route_set))
      found = described_class.entries(controllers: [bare_class("legacy")], routes: descriptors)
      expect(found.map(&:path)).to contain_exactly("/legacy", "/{locale}/legacy", "/admin/legacy")
      expect(described_class.summary(found)).to include(actions: 2, uncovered_with_body: 2)
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

    # The summary counts routes, the table lists rows; when the two differ,
    # the report gives both numbers and names each.
    it "says how many rows the table lists when one route expands to several" do
      sourced = routes.each_with_index.map { |route, index| route.merge(route: index) }
      localized = sourced + [{ controller: "legacy", action: "create", verb: "post", path: "/{locale}/legacy", route: 4 }]
      expanded = described_class.entries(controllers: [users, bare_class("legacy")], routes: localized)
      report = described_class.format(expanded)
      expect(report).to include("5 routed actions in 6 rows: ")
      expect(described_class.format(entries)).to include("5 routed actions: ")
    end

    # A row is a verb on a path, not a path: PATCH and PUT on the two locale
    # variants are four rows over two distinct paths, so the number printed
    # must be labelled as rows.
    it "counts rows, not distinct paths, when a route answers several verbs" do
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { scope("(:locale)") { resources :posts, only: :update } }
      descriptors = Permittable::OpenAPI.rails_routes(Struct.new(:routes).new(route_set))
      found = described_class.entries(controllers: [bare_class("posts")], routes: descriptors)
      expect(found.map(&:path).uniq.length).to eq(2)
      expect(described_class.format(found)).to include("2 routed actions in 4 rows: ")
    end

    # The README quotes the plural lines; a count of one must not read as
    # "1 of those accept".
    it "agrees in number when a summary count is one" do
      one = controller_class("users") { permit_params(:create, model: nil) { required :name, :string } }
      report = described_class.format(described_class.entries(controllers: [one], routes: routes.first(3)))
      expect(report).to include("\n  1 of those accepts a request body — untrusted input reaches the action unchecked\n")
      expect(report).to include("\n  1 covered action declares no model:, so no schema-drift guard runs for it\n")
      expect(described_class.format(entries))
        .to include("\n  2 covered actions declare no model:, so no schema-drift guard runs for them\n")
    end

    it "says so plainly when there is nothing to report" do
      expect(described_class.format([], stale: {})).to include("no routed actions")
    end
  end

  # Endpoints that are not the app's to guard — ActiveStorage's direct
  # uploads, a catch-all 404 — leave the counts and [strict], but never the
  # report: each is listed in a section of its own, with the reason.
  describe "the ignore list" do
    after do
      Permittable.audit_ignore = nil
      Permittable.audit_ignore_outside_root = true
    end

    describe "Permittable.audit_ignore" do
      it "is empty until configured" do
        expect(Permittable.audit_ignore).to eq([])
      end

      it "takes controller paths as Rails names them, and controller#action" do
        Permittable.audit_ignore = %w[active_storage/direct_uploads application#not_found application#not_found]
        expect(Permittable.audit_ignore).to eq(%w[active_storage/direct_uploads application#not_found])
        expect(Permittable.audit_ignore).to be_frozen
      end

      # Frozen, so nothing joins the list without passing the writer's check.
      it "is added to with +=, not in place" do
        Permittable.audit_ignore = ["legacy"]
        expect { Permittable.audit_ignore << "webhooks" }.to raise_error(FrozenError)
        Permittable.audit_ignore += ["webhooks#receive"]
        expect(Permittable.audit_ignore).to eq(%w[legacy webhooks#receive])
        expect { Permittable.audit_ignore += ["Webhooks"] }.to raise_error(ArgumentError)
      end

      it "resets to empty when set to nil" do
        Permittable.audit_ignore = ["legacy"]
        Permittable.audit_ignore = nil
        expect(Permittable.audit_ignore).to eq([])
      end

      # The likeliest mistake is the class name for the path, which would
      # otherwise match nothing and ignore nothing.
      it "rejects a class name, naming the controller path it meant" do
        expect { Permittable.audit_ignore = ["ActiveStorage::DirectUploadsController"] }
          .to raise_error(ArgumentError, %r{did you mean "active_storage/direct_uploads"\?})
      end

      # A class named in an initializer autoloads it during boot, which
      # Zeitwerk refuses for a reloadable controller — so the path it is.
      it "rejects a controller class, naming its path" do
        klass = controller_class("legacy/invoices")
        expect { Permittable.audit_ignore = [klass] }
          .to raise_error(ArgumentError, %r{did you mean "legacy/invoices"\?})
      end

      it "rejects anything else, and keeps the list it had" do
        Permittable.audit_ignore = ["legacy"]
        [%r{\Aadmin/}, :application, " application", "/admin/users", "application#", "a#b#c", ""].each do |bad|
          expect { Permittable.audit_ignore = [bad] }.to raise_error(ArgumentError, /audit_ignore/)
        end
        expect(Permittable.audit_ignore).to eq(["legacy"])
      end
    end

    describe "Permittable.audit_ignore_outside_root" do
      it "is on by default" do
        expect(Permittable.audit_ignore_outside_root).to be(true)
      end

      it "takes only true or false" do
        Permittable.audit_ignore_outside_root = false
        expect(Permittable.audit_ignore_outside_root).to be(false)
        expect { Permittable.audit_ignore_outside_root = "no" }.to raise_error(ArgumentError, /true or false/)
      end
    end

    describe "a controller on the list" do
      let(:found) do
        described_class.entries(controllers: [users, bare_class("legacy")], routes: routes, ignore: ["legacy"])
      end

      it "marks every routed action of it ignored, and says why" do
        expect(found.select(&:ignored?).map { |e| [e.controller, e.action, e.ignored] })
          .to eq([["legacy", "create", :configured]])
        expect(found.reject(&:ignored?).map(&:controller).uniq).to eq(["users"])
      end

      it "leaves it out of the counts" do
        expect(described_class.summary(found))
          .to include(actions: 4, uncovered: 2, uncovered_with_body: 1, unguarded_models: 2)
      end

      it "reads Permittable.audit_ignore by default" do
        Permittable.audit_ignore = ["legacy"]
        defaulted = described_class.entries(controllers: [users, bare_class("legacy")], routes: routes)
        expect(defaulted.find { |e| e.controller == "legacy" }.ignored).to eq(:configured)
      end
    end

    # `match "*path", to: "application#not_found", via: :all` answers every
    # verb, so POST, PUT and PATCH read as accepting a body. Naming the action
    # ignores the catch-all and nothing else on ApplicationController.
    describe "a controller#action on the list" do
      let(:descriptors) do
        route_set = ActionDispatch::Routing::RouteSet.new
        route_set.draw do
          post "feedback", to: "application#feedback"
          match "*path", to: "application#not_found", via: :all
        end
        Permittable::OpenAPI.rails_routes(Struct.new(:routes).new(route_set))
      end
      let(:found) do
        described_class.entries(controllers: [bare_class("application")], routes: descriptors,
                                ignore: ["application#not_found"])
      end

      it "ignores every verb of the catch-all, and only the catch-all" do
        expect(found.select(&:ignored?).map(&:action).uniq).to eq(["not_found"])
        expect(found.select(&:ignored?).map(&:verb)).to include("post", "put", "patch")
        expect(found.reject(&:ignored?).map { |e| [e.action, e.verb] }).to eq([%w[feedback post]])
      end

      # The rake task's [strict] fails on exactly this number.
      it "takes the catch-all out of the strict count" do
        unignored = described_class.entries(controllers: [bare_class("application")], routes: descriptors, ignore: [])
        expect(described_class.summary(unignored)[:uncovered_with_body]).to be > 1
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(1)
      end
    end

    it "passes [strict] when every gap left is an ignored one" do
      found = described_class.entries(controllers: [users, bare_class("legacy")], routes: routes,
                                      ignore: %w[legacy users#update])
      expect(found.count { |e| e.ignored? && e.body? && !e.covered? }).to eq(2)
      expect(described_class.summary(found)[:uncovered_with_body]).to eq(0)
    end

    describe "in the report" do
      let(:found) do
        hook_routes = %w[get post].map { |verb| { controller: "webhooks", action: "receive", verb: verb, path: "/hooks" } }
        described_class.entries(controllers: [users, bare_class("legacy"), bare_class("webhooks")],
                                routes: routes + hook_routes, ignore: %w[legacy webhooks#receive])
      end
      let(:report) { described_class.format(found, unmatched: []) }

      it "lists ignored actions in a section of their own, with their verbs and the reason" do
        expect(report).to include(<<~TEXT)

          Ignored by Permittable.audit_ignore (left out of the counts above):
            legacy#create     POST
            webhooks#receive  GET, POST
        TEXT
      end

      it "keeps them out of the table and the summary" do
        table = report.split("\n\n").first
        expect(table).not_to include("legacy")
        expect(table).not_to include("webhooks")
        expect(report).to include("4 routed actions: 1 enforced, 1 in monitor mode, 2 without a contract")
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(1)
        expect(report).to match(/1 of those accepts? a request body/)
      end

      it "still reports when every routed action is ignored" do
        all = described_class.entries(controllers: [bare_class("legacy")], routes: routes, ignore: ["legacy"])
        expect(described_class.format(all, unmatched: [])).to include("0 routed actions", "legacy#create")
      end
    end

    # An entry that matches nothing does nothing, so a typo would leave the
    # gap it was meant to close — or, worse, read as closed. It is listed.
    describe "an entry that matches nothing" do
      it "is found by .unmatched_ignores" do
        expect(described_class.unmatched_ignores(entries, ignore: %w[legacy legacy#create legacy#craete leagcy]))
          .to eq(%w[legacy#craete leagcy])
      end

      it "counts a match among ignored entries too" do
        found = described_class.entries(controllers: [bare_class("legacy")], routes: routes, ignore: ["legacy"])
        expect(described_class.unmatched_ignores(found, ignore: %w[legacy legacy#create])).to eq([])
      end

      it "is listed in the report, from Permittable.audit_ignore by default" do
        Permittable.audit_ignore = %w[legacy users#craete]
        report = described_class.format(described_class.entries(controllers: [users, bare_class("legacy")],
                                                                routes: routes))
        expect(report).to include("\nPermittable.audit_ignore entries that match no routed action " \
                                  "(a typo, or a route since removed?):\n  users#craete\n")
      end

      it "does not fail [strict] on its own" do
        found = described_class.entries(controllers: [users], routes: routes.first(4), ignore: %w[users#update nope])
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(0)
      end
    end

    # Engines and gems — ActiveStorage, ActionMailbox, Rails's own rails/*
    # controllers — are not the app's to guard, so a controller whose source
    # is outside the app root is ignored by default. Located by the constant's
    # own definition, so these load real files.
    describe "controllers outside the app root" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          @loaded = []
          example.run
        ensure
          @loaded.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
        end
      end

      let(:root) { File.join(@dir, "app") }

      # A named controller defined by a real file at `relative` under the
      # tmpdir, so const_source_location has a definition site to report.
      def controller_file(relative, const, path)
        file = File.join(@dir, relative)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, <<~RUBY)
          class #{const} < FakeController
            def self.controller_path = #{path.inspect}

            def create; end
          end
        RUBY
        load file
        @loaded << const
        Object.const_get(const)
      end

      let(:app_controller) do
        controller_file("app/app/controllers/audit_widgets_controller.rb", "AuditWidgetsController", "widgets")
      end
      let(:engine_controller) do
        controller_file("gems/uploader/app/controllers/audit_uploads_controller.rb", "AuditUploadsController",
                        "uploader/uploads")
      end
      let(:upload_routes) do
        [{ controller: "widgets", action: "create", verb: "post", path: "/widgets" },
         { controller: "uploader/uploads", action: "create", verb: "post", path: "/rails/uploads" }]
      end

      def ignored(found)
        found.to_h { |e| [e.controller, e.ignored] }
      end

      it "ignores a controller defined outside the root, and only that one" do
        found = described_class.entries(controllers: [app_controller, engine_controller], routes: upload_routes,
                                        ignore: [], root: root)
        expect(ignored(found)).to eq("widgets" => nil, "uploader/uploads" => :outside_root)
        expect(described_class.summary(found)[:uncovered_with_body]).to eq(1)
      end

      it "lists it under its own reason in the report" do
        found = described_class.entries(controllers: [app_controller, engine_controller], routes: upload_routes,
                                        ignore: [], root: root)
        expect(described_class.format(found, unmatched: []))
          .to include("\nIgnored as outside the app root (set Permittable.audit_ignore_outside_root = false " \
                      "to audit them):\n  uploader/uploads#create  POST\n")
      end

      # bundler-cache on CI, and Docker images, install gems under the app's
      # own vendor/bundle — inside the root, and still not the app's code.
      it "ignores a gem installed inside the root" do
        gem_dir = File.join(root, "vendor", "bundle", "ruby", "3.2.0")
        vendored = controller_file("app/vendor/bundle/ruby/3.2.0/gems/uploader/app/controllers/audit_vendored_controller.rb",
                                   "AuditVendoredController", "uploader/uploads")
        allow(Gem).to receive(:path).and_return([gem_dir])
        found = described_class.entries(controllers: [vendored], routes: upload_routes.last(1), ignore: [], root: root)
        expect(ignored(found)).to eq("uploader/uploads" => :outside_root)
      end

      # A GEM_HOME set to the app, or above it, cannot tell a gem's file from
      # the app's; trusting it would ignore every controller and pass [strict].
      it "does not trust a gem directory that holds the root itself" do
        allow(Gem).to receive(:path).and_return([@dir, root])
        found = described_class.entries(controllers: [app_controller], routes: upload_routes.first(1), ignore: [],
                                        root: root)
        expect(ignored(found)).to eq("widgets" => nil)
      end

      it "names the configured reason when a controller is both, so its entry is not unmatched" do
        found = described_class.entries(controllers: [engine_controller], routes: upload_routes.last(1),
                                        ignore: ["uploader/uploads"], root: root)
        expect(ignored(found)).to eq("uploader/uploads" => :configured)
        expect(described_class.unmatched_ignores(found, ignore: ["uploader/uploads"])).to eq([])
      end

      # For a gate, a false alarm beats a missed endpoint.
      it "audits a controller whose source cannot be located" do
        found = described_class.entries(controllers: [bare_class("legacy")], routes: routes, ignore: [], root: root)
        expect(found.none?(&:ignored?)).to be(true)
      end

      it "falls back to the controller's own methods when its constant cannot be located" do
        anonymous = Class.new(FakeController) { def self.controller_path = "uploader/uploads" }
        # A location outside the root is the point, so not __FILE__/__LINE__.
        outside = File.join(@dir, "gems/uploader/anonymous.rb")
        anonymous.class_eval("def create; end", outside, 1) # rubocop:disable Style/EvalWithLocation
        found = described_class.entries(controllers: [anonymous], routes: upload_routes.last(1), ignore: [], root: root)
        expect(ignored(found)).to eq("uploader/uploads" => :outside_root)
      end

      it "takes the root from Rails.root by default" do
        app = root
        stub_const("Rails", Module.new.tap { |m| m.define_singleton_method(:root) { Pathname.new(app) } })
        expect(described_class.app_root).to eq(root)
        found = described_class.entries(controllers: [app_controller, engine_controller], routes: upload_routes)
        expect(ignored(found)).to eq("widgets" => nil, "uploader/uploads" => :outside_root)
      end

      it "audits everything when Permittable.audit_ignore_outside_root is off" do
        stub_const("Rails", Module.new.tap { |m| m.define_singleton_method(:root) { Pathname.new("/srv/app") } })
        Permittable.audit_ignore_outside_root = false
        expect(described_class.app_root).to be_nil
        found = described_class.entries(controllers: [engine_controller], routes: upload_routes.last(1))
        expect(found.none?(&:ignored?)).to be(true)
      end

      it "has no root, so ignores nothing as outside it, without Rails" do
        hide_const("Rails")
        expect(described_class.app_root).to be_nil
      end
    end
  end
end
