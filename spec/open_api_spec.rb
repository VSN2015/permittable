require "json"
require "action_dispatch"

RSpec.describe Permittable::OpenAPI do
  def controller_class(path: "users", &declaration)
    Class.new(FakeController) do
      include Permittable

      define_singleton_method(:controller_path) { path }
      class_eval(&declaration) if declaration
    end
  end

  # A real route set drawn from a routes.rb-style block, in the shape
  # rails_routes reads: the overlap bugs lived in what Rails generates.
  def rails_app(&draw)
    route_set = ActionDispatch::Routing::RouteSet.new
    route_set.draw(&draw)
    Struct.new(:routes).new(route_set)
  end

  # Every operationId in the document, the unrouted ones included: the
  # whole document is one namespace to a client generator.
  def operation_ids(doc)
    routed = doc["paths"].values.flat_map(&:values)
    unrouted = doc.fetch("x-permittable-controllers", {}).values.flat_map(&:values)
    (routed + unrouted).filter_map { |operation| operation["operationId"] }
  end

  after { Permittable.filter_parameter_registry.reset! }

  it "exposes the shared error components" do
    components = described_class.components
    expect(components["schemas"]["PermittableInvalidParameters"]["required"]).to eq(%w[success error])
    expect(components["responses"].keys).to eq(%w[PermittableBadRequest PermittableUnprocessableEntity])
  end

  describe ".request_body_for" do
    it "returns nil when no contract covers the action" do
      expect(described_class.request_body_for(controller_class, :create)).to be_nil
    end

    it "is required for rooted contracts and top-level required fields, optional otherwise" do
      rooted = controller_class { permit_params(:create, root: :user) { optional :name, :string } }
      expect(described_class.request_body_for(rooted, :create)["required"]).to be(true)

      required_field = controller_class { permit_params(:create) { required :name, :string } }
      expect(described_class.request_body_for(required_field, :create)["required"]).to be(true)

      all_optional = controller_class { permit_params(:create) { optional :name, :string } }
      body = described_class.request_body_for(all_optional, :create)
      expect(body["required"]).to be(false)
      expect(body["content"]["application/json"]["schema"]["properties"]).to have_key("name")
    end
  end

  describe ".operations_for" do
    it "documents explicit actions with operationId, description, and error responses" do
      klass = controller_class(path: "admin/users") do
        permit_params(:create, root: :user, desc: "Register a user") { required :name, :string }
      end
      operations = described_class.operations_for(klass)
      expect(operations.keys).to eq(["create"])
      operation = operations["create"]
      expect(operation["operationId"]).to eq("admin_users_create")
      expect(operation["description"]).to eq("Register a user")
      expect(operation["responses"].keys).to eq(%w[400 422])
    end

    it "omits the 400 response for rootless contracts (only a missing root renders 400)" do
      klass = controller_class { permit_params(:index) { optional :page, :integer } }
      expect(described_class.operations_for(klass)["index"]["responses"].keys).to eq(["422"])
    end

    it "marks monitor-mode rules with x-permittable-mode (per-rule declaration only)" do
      monitored = controller_class { permit_params(:create, mode: :monitor) { required :name, :string } }
      expect(described_class.operations_for(monitored)["create"]["x-permittable-mode"]).to eq("monitor")

      enforced = controller_class { permit_params(:create) { required :name, :string } }
      expect(described_class.operations_for(enforced)["create"]).not_to have_key("x-permittable-mode")
    end

    it "resolves each action through permit_rule_for, so the last matching rule wins" do
      klass = controller_class do
        permit_params { optional :anything, :string }
        permit_params(:create) { required :name, :string }
      end
      operations = described_class.operations_for(klass)
      expect(operations.keys).to eq(["create", "*"])
      create_schema = operations["create"]["requestBody"]["content"]["application/json"]["schema"]
      expect(create_schema["properties"].keys).to eq(["name"])
      expect(operations["*"]["x-permittable-catch-all"]).to be(true)
      expect(operations["*"]).not_to have_key("operationId")
    end

    it "expands a catch-all through action_methods on real controllers, excluding the concern's own methods",
       :integration do
      klass = IntegrationHarness.build_controller do
        include Permittable

        permit_params { optional :page, :integer }

        def index; end
        def show; end
      end
      operations = described_class.operations_for(klass)
      expect(operations.keys).to eq(%w[index show])
      expect(operations).not_to have_key("permitted_params")
      expect(operations).not_to have_key("enforce_params_contract")
    end
  end

  describe ".document" do
    it "places routed operations under paths and everything else under x-permittable-controllers" do
      klass = controller_class do
        permit_params(:create, root: :user) { required :name, :string }
        permit_params(:archive) { required :reason, :string }
      end
      doc = described_class.document(
        controllers: [klass],
        info: { "title" => "Test API", "version" => "9.9.9" },
        routes: [{ controller: "users", action: "create", verb: "POST", path: "/users" }]
      )
      expect(doc["openapi"]).to eq("3.1.0")
      expect(doc["info"]).to eq("title" => "Test API", "version" => "9.9.9")
      expect(doc["paths"]["/users"]["post"]["operationId"]).to eq("users_create")
      expect(doc["x-permittable-controllers"]["users"].keys).to eq(["archive"])
      expect(doc["components"]["schemas"]).to have_key("PermittableInvalidParameters")
    end

    it "declares a path parameter for every variable the path templates" do
      klass = controller_class { permit_params(:update, root: :user) { required :name, :string } }
      doc = described_class.document(
        controllers: [klass],
        routes: [{ controller: "users", action: "update", verb: "patch", path: "/accounts/{account_id}/users/{id}" }]
      )
      expect(doc["paths"]["/accounts/{account_id}/users/{id}"]["patch"]["parameters"]).to eq(
        [
          { "name" => "account_id", "in" => "path", "required" => true, "schema" => { "type" => "string" } },
          { "name" => "id", "in" => "path", "required" => true, "schema" => { "type" => "string" } }
        ]
      )
    end

    it "omits parameters entirely for a path that templates nothing" do
      klass = controller_class { permit_params(:create) { required :name, :string } }
      doc = described_class.document(controllers: [klass],
                                     routes: [{ controller: "users", action: "create", verb: "post", path: "/users" }])
      expect(doc["paths"]["/users"]["post"]).not_to have_key("parameters")
    end

    it "keeps a colliding operation visible instead of overwriting it" do
      users = controller_class(path: "users") { permit_params(:create) { required :name, :string } }
      clones = controller_class(path: "clones") { permit_params(:create) { required :other, :string } }
      doc = described_class.document(
        controllers: [users, clones],
        routes: [{ controller: "users", action: "create", verb: "post", path: "/users" },
                 { controller: "clones", action: "create", verb: "post", path: "/users" }]
      )
      expect(doc["paths"]["/users"]["post"]["operationId"]).to eq("users_create")
      expect(doc["x-permittable-controllers"]["clones"]).to have_key("create")
    end

    # Rails dispatches GET /hooks to the explicit route drawn ahead of the
    # `via: :all` one. Declaring `receive` first used to hand it that slot,
    # documenting a GET the server never routes to it and pushing `index`
    # out of `paths`.
    it "documents a verb on a shared path under the route Rails dispatches it to" do
      klass = controller_class(path: "webhooks") do
        permit_params(:receive) { optional :event, :string }
        permit_params(:index) { optional :page, :integer }
      end
      app = rails_app do
        get "hooks", to: "webhooks#index"
        match "hooks", to: "webhooks#receive", via: :all
      end
      doc = described_class.document(controllers: [klass], routes: described_class.rails_routes(app))

      expect(doc["paths"]["/hooks"].transform_values { |operation| operation["operationId"] }).to eq(
        "get" => "webhooks_index", "post" => "webhooks_receive", "patch" => "webhooks_receive_patch",
        "put" => "webhooks_receive_put", "delete" => "webhooks_receive_delete"
      )
      expect(doc).not_to have_key("x-permittable-controllers")
    end

    # The other way round, the `via: :all` route answers GET too, and the
    # explicit route behind it is never reached: its operation is unrouted.
    it "leaves an operation unrouted when an earlier via: :all route shadows its only route" do
      klass = controller_class(path: "webhooks") do
        permit_params(:index) { optional :page, :integer }
        permit_params(:receive) { optional :event, :string }
      end
      app = rails_app do
        match "hooks", to: "webhooks#receive", via: :all
        get "hooks", to: "webhooks#index"
      end
      doc = described_class.document(controllers: [klass], routes: described_class.rails_routes(app))

      expect(doc["paths"]["/hooks"].keys).to contain_exactly("get", "post", "put", "patch", "delete")
      expect(doc["paths"]["/hooks"]["get"]["operationId"]).to eq("webhooks_receive")
      expect(doc["x-permittable-controllers"]["webhooks"].keys).to eq(["index"])
    end

    # OpenAPI requires operationId to be unique across the document, and
    # generated clients name their methods after it. `resources` routes
    # update as PATCH and PUT, and `admin/users` and `admin_users` fold to
    # one id, so the export carried duplicates. Only a colliding id may be
    # renamed: every id is a method name in someone's generated client.
    describe "operationIds" do
      def index_controller(path, *actions)
        controller_class(path: path) { permit_params(*actions) { optional :page, :integer } }
      end

      def route(controller, action, verb, path)
        { controller: controller, action: action, verb: verb, path: path }
      end

      # { [path, verb] => id } for routed operations and
      # { [controller, action] => id } for unrouted ones: where every id sits.
      def ids_by_place(doc)
        routed = doc["paths"].flat_map { |path, operations| operations.map { |verb, op| [[path, verb], op["operationId"]] } }
        unrouted = doc.fetch("x-permittable-controllers", {}).flat_map do |key, operations|
          operations.map { |action, op| [[key, action], op["operationId"]] }
        end
        (routed + unrouted).to_h
      end

      # Every id is a method name in a generated client. Reordering routes.rb,
      # or a controller loading earlier, changes nothing Rails serves, so it
      # must not rename a method either: which collider keeps the plain id,
      # and which suffix each other one takes, is read off the operation,
      # path and verb, never off the order they were found in.
      it "names every collider the same whatever order routes and controllers arrive in" do
        controllers = [
          index_controller("admin/users", :index),
          index_controller("admin_users", :index),
          index_controller("admin", "users_index"),
          controller_class(path: "legacy") { permit_params(:create) { required :name, :string } },
          controller_class(path: "posts") { permit_params(:update) { required :title, :string } },
          controller_class(path: "webhooks") { permit_params(:receive) { optional :event, :string } }
        ]
        routes = [
          route("admin_users", "index", "get", "/admin_users"),
          route("admin/users", "index", "get", "/admin/users"),
          route("legacy", "create", "post", "/admin/legacy"),
          route("legacy", "create", "post", "/legacy"),
          route("posts", "update", "put", "/orgs/{org_id}/posts/{id}"),
          route("posts", "update", "patch", "/orgs/{org_id}/posts/{id}"),
          route("posts", "update", "put", "/posts/{id}"),
          route("posts", "update", "patch", "/posts/{id}"),
          route("webhooks", "receive", "post", "/hooks"),
          route("webhooks", "receive", "get", "/hooks")
        ]
        expected = {
          # Between operations: controller path, then action, as strings.
          ["/admin/users", "get"] => "admin_users_index",
          ["/admin_users", "get"] => "admin_users_index_2",
          %w[admin users_index] => "admin_users_index_3",
          # Within one: the shallowest path, then GET, POST, PATCH, PUT, DELETE.
          ["/legacy", "post"] => "legacy_create",
          ["/admin/legacy", "post"] => "legacy_create_2",
          ["/posts/{id}", "patch"] => "posts_update",
          ["/posts/{id}", "put"] => "posts_update_put",
          ["/orgs/{org_id}/posts/{id}", "patch"] => "posts_update_2",
          ["/orgs/{org_id}/posts/{id}", "put"] => "posts_update_3",
          ["/hooks", "get"] => "webhooks_receive",
          ["/hooks", "post"] => "webhooks_receive_post"
        }
        random = Random.new(68)
        orders = [[controllers, routes], [controllers.reverse, routes.reverse]] +
                 Array.new(8) { [controllers.shuffle(random: random), routes.shuffle(random: random)] }

        orders.each do |listed_controllers, listed_routes|
          doc = described_class.document(controllers: listed_controllers, routes: listed_routes)
          expect(ids_by_place(doc)).to eq(expected)
        end
      end

      # The same guarantee through a real route set: two routes.rb files that
      # draw the same routes in a different order, one of them listing a
      # route's verbs the other way round.
      it "keeps every id when routes.rb draws the same routes in another order" do
        controllers = [
          controller_class(path: "legacy") { permit_params(:create) { required :name, :string } },
          controller_class(path: "users") { permit_params(:update) { required :name, :string } },
          controller_class(path: "webhooks") { permit_params(:receive) { optional :event, :string } }
        ]
        one = rails_app do
          post "admin/legacy", to: "legacy#create"
          post "legacy", to: "legacy#create"
          match "hooks", to: "webhooks#receive", via: %i[post get]
          resources(:orgs, only: []) { resources :users, only: :update }
          resources :users, only: :update
        end
        other = rails_app do
          resources :users, only: :update
          resources(:orgs, only: []) { resources :users, only: :update }
          match "hooks", to: "webhooks#receive", via: %i[get post]
          post "legacy", to: "legacy#create"
          post "admin/legacy", to: "legacy#create"
        end
        ids = [one, other].map do |app|
          ids_by_place(described_class.document(controllers: controllers, routes: described_class.rails_routes(app)))
        end

        expect(ids.last).to eq(ids.first)
        expect(ids.first).to include(["/legacy", "post"] => "legacy_create", ["/hooks", "get"] => "webhooks_receive",
                                     ["/users/{id}", "patch"] => "users_update")
      end

      it "gives the second verb of a shared route its own operationId" do
        klass = controller_class { permit_params(:update, root: :user) { required :name, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("users", "update", "patch", "/users/{id}"), route("users", "update", "put", "/users/{id}")]
        )
        expect(doc["paths"]["/users/{id}"]["patch"]["operationId"]).to eq("users_update")
        expect(doc["paths"]["/users/{id}"]["put"]["operationId"]).to eq("users_update_put")
      end

      # `match via: [:put, :patch]` lists PUT first. Without the preference,
      # that route and the PATCH|PUT pair `resources` generates would give
      # the PATCH method different names.
      it "keeps the plain id on PATCH whichever order the PATCH|PUT pair arrives in" do
        klass = controller_class { permit_params(:update) { required :name, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("users", "update", "put", "/users/{id}"), route("users", "update", "patch", "/users/{id}")]
        )
        expect(doc["paths"]["/users/{id}"]["patch"]["operationId"]).to eq("users_update")
        expect(doc["paths"]["/users/{id}"]["put"]["operationId"]).to eq("users_update_put")
      end

      it "numbers a same-verb collision between two controller paths that fold to one id" do
        doc = described_class.document(
          controllers: [index_controller("admin/users", :index), index_controller("admin_users", :index)],
          routes: [route("admin/users", "index", "get", "/admin/users"), route("admin_users", "index", "get", "/admin_users")]
        )
        expect(doc["paths"]["/admin/users"]["get"]["operationId"]).to eq("admin_users_index")
        expect(doc["paths"]["/admin_users"]["get"]["operationId"]).to eq("admin_users_index_2")
      end

      # A route declared twice is one slot, not a collision with itself.
      it "leaves a unique id alone when its route is declared twice" do
        doc = described_class.document(
          controllers: [index_controller("users", :index)],
          routes: [route("users", "index", "get", "/users"), route("users", "index", "GET", "/users")]
        )
        expect(doc["paths"].keys).to eq(["/users"])
        expect(doc["paths"]["/users"].keys).to eq(["get"])
        expect(doc["paths"]["/users"]["get"]["operationId"]).to eq("users_index")
      end

      # A suffix must not take a name that is some other operation's own id:
      # that operation would then be renamed for a collision it never had.
      it "never takes a naturally unique id for a suffix" do
        doc = described_class.document(
          controllers: [index_controller("admin/users", :index), index_controller("admin_users", :index, :index_get)],
          routes: [route("admin/users", "index", "get", "/admin/users"),
                   route("admin_users", "index", "get", "/admin_users"),
                   route("admin_users", "index_get", "get", "/admin_users/all")]
        )
        expect(doc["paths"]["/admin/users"]["get"]["operationId"]).to eq("admin_users_index")
        expect(doc["paths"]["/admin_users"]["get"]["operationId"]).to eq("admin_users_index_2")
        expect(doc["paths"]["/admin_users/all"]["get"]["operationId"]).to eq("admin_users_index_get")
      end

      it "numbers a slot whose verb suffix is some other operation's own id" do
        doc = described_class.document(
          controllers: [index_controller("admin/users", :index), index_controller("admin_users", :index, :index_post)],
          routes: [route("admin/users", "index", "get", "/admin/users"),
                   route("admin_users", "index", "post", "/admin_users"),
                   route("admin_users", "index_post", "post", "/admin_users/bulk")]
        )
        expect(doc["paths"]["/admin/users"]["get"]["operationId"]).to eq("admin_users_index")
        expect(doc["paths"]["/admin_users"]["post"]["operationId"]).to eq("admin_users_index_2")
        expect(doc["paths"]["/admin_users/bulk"]["post"]["operationId"]).to eq("admin_users_index_post")
      end

      # The suffix names how a slot differs from the one holding the plain
      # id. A second POST beside a POST differs by path, not verb, so
      # `posts_create_post` would say nothing true.
      it "suffixes the verb only where it differs from the plain id's verb" do
        klass = controller_class(path: "posts") { permit_params(:create) { required :title, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("posts", "create", "post", "/posts"), route("posts", "create", "get", "/posts/new"),
                   route("posts", "create", "post", "/{locale}/posts")]
        )
        expect(doc["paths"]["/posts"]["post"]["operationId"]).to eq("posts_create")
        expect(doc["paths"]["/posts/new"]["get"]["operationId"]).to eq("posts_create_get")
        expect(doc["paths"]["/{locale}/posts"]["post"]["operationId"]).to eq("posts_create_2")
      end

      # A PATCH|PUT pair at more than one path (a member route plus its
      # nested copy): PATCH keeps the plain id at every size of group, not
      # only when the group is exactly one pair.
      it "keeps the plain id on PATCH when the PATCH|PUT pair sits at two paths, PUT first" do
        klass = controller_class { permit_params(:update) { required :name, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("users", "update", "put", "/users/{id}"),
                   route("users", "update", "patch", "/users/{id}"),
                   route("users", "update", "put", "/orgs/{org_id}/users/{id}"),
                   route("users", "update", "patch", "/orgs/{org_id}/users/{id}")]
        )
        expect(doc["paths"]["/users/{id}"]["patch"]["operationId"]).to eq("users_update")
        expect(doc["paths"]["/orgs/{org_id}/users/{id}"]["patch"]["operationId"]).to eq("users_update_2")
        expect(doc["paths"]["/users/{id}"]["put"]["operationId"]).to eq("users_update_put")
        expect(doc["paths"]["/orgs/{org_id}/users/{id}"]["put"]["operationId"]).to eq("users_update_3")
      end

      # PATCH-over-PUT is about one operation's two verbs. Between two
      # operations, their controller paths decide, whichever verbs they carry.
      it "does not let a PATCH in one operation take the plain id from a PUT in another" do
        doc = described_class.document(
          controllers: [controller_class(path: "admin/users") { permit_params(:update) { required :name, :string } },
                        controller_class(path: "admin_users") { permit_params(:update) { required :name, :string } }],
          routes: [route("admin/users", "update", "put", "/admin/users/{id}"),
                   route("admin_users", "update", "patch", "/admin_users/{id}")]
        )
        expect(doc["paths"]["/admin/users/{id}"]["put"]["operationId"]).to eq("admin_users_update")
        expect(doc["paths"]["/admin_users/{id}"]["patch"]["operationId"]).to eq("admin_users_update_patch")
      end

      # Passed twice, a controller's routes are all taken by its first pass,
      # so the second landed under x-permittable-controllers as a phantom
      # collision (users_index_2).
      it "documents a controller passed twice once" do
        klass = index_controller("users", :index)
        doc = described_class.document(controllers: [klass, klass], routes: [route("users", "index", "get", "/users")])
        expect(doc).not_to have_key("x-permittable-controllers")
        expect(operation_ids(doc)).to eq(["users_index"])
      end

      # The shapes a real app produces, through the real route set rather than
      # hand-built descriptors: `resources` routes update as PATCH and PUT, and
      # nesting it repeats the pair at a second path.
      it "assigns sensible, unique ids to the routes resources and nested resources generate" do
        route_set = ActionDispatch::Routing::RouteSet.new
        route_set.draw do
          resources :users, only: %i[create update]
          resources(:orgs, only: []) { resources :users, only: %i[update] }
        end
        klass = controller_class do
          permit_params(:create, :update) { required :name, :string }
        end
        doc = described_class.document(controllers: [klass],
                                       routes: described_class.rails_routes(Struct.new(:routes).new(route_set)))

        ids = doc["paths"].to_h { |path, operations| [path, operations.transform_values { |op| op["operationId"] }] }
        expect(ids).to eq(
          "/users" => { "post" => "users_create" },
          "/users/{id}" => { "patch" => "users_update", "put" => "users_update_put" },
          "/orgs/{org_id}/users/{id}" => { "patch" => "users_update_2", "put" => "users_update_3" }
        )
      end

      # An optional segment (`(/:locale)/posts`) documents one operation at
      # two paths under one verb.
      it "numbers one operation placed at two paths under one verb" do
        klass = controller_class(path: "posts") { permit_params(:create) { required :title, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("posts", "create", "post", "/posts"), route("posts", "create", "post", "/{locale}/posts")]
        )
        expect(doc["paths"]["/posts"]["post"]["operationId"]).to eq("posts_create")
        expect(doc["paths"]["/{locale}/posts"]["post"]["operationId"]).to eq("posts_create_2")
      end

      # `via: :all` documents one operation under every verb.
      it "suffixes each verb of an operation routed under all of them" do
        klass = controller_class(path: "webhooks") { permit_params(:receive) { optional :event, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: %w[get post put patch delete].map { |verb| route("webhooks", "receive", verb, "/webhooks") }
        )
        expect(doc["paths"]["/webhooks"].transform_values { |operation| operation["operationId"] }).to eq(
          "get" => "webhooks_receive", "post" => "webhooks_receive_post", "put" => "webhooks_receive_put",
          "patch" => "webhooks_receive_patch", "delete" => "webhooks_receive_delete"
        )
      end

      # x-permittable-controllers is in the same document and feeds the same
      # client generators. The routed operation keeps the plain id even when
      # the unrouted one comes first: `paths` is what a client calls.
      it "keeps unrouted operations unique against routed ones, without renaming the routed one" do
        doc = described_class.document(
          controllers: [index_controller("admin_users", :index), index_controller("admin/users", :index)],
          routes: [route("admin/users", "index", "get", "/admin/users")]
        )
        expect(doc["paths"]["/admin/users"]["get"]["operationId"]).to eq("admin_users_index")
        expect(doc["x-permittable-controllers"]["admin_users"]["index"]["operationId"]).to eq("admin_users_index_2")
      end

      it "leaves every naturally unique id untouched" do
        doc = described_class.document(
          controllers: [index_controller("admin/users", :index, :show), index_controller("admin_users", :index, :create)],
          routes: [route("admin/users", "index", "get", "/admin/users"),
                   route("admin/users", "show", "get", "/admin/users/{id}"),
                   route("admin_users", "index", "get", "/admin_users"),
                   route("admin_users", "create", "post", "/admin_users")]
        )
        expect(doc["paths"]["/admin/users/{id}"]["get"]["operationId"]).to eq("admin_users_show")
        expect(doc["paths"]["/admin_users"]["post"]["operationId"]).to eq("admin_users_create")
      end

      it "renames a per-slot copy, leaving the operation at the other slots untouched" do
        klass = controller_class { permit_params(:create) { required :name, :string } }
        doc = described_class.document(
          controllers: [klass],
          routes: [route("users", "create", "post", "/users"), route("users", "create", "put", "/users")]
        )
        expect(doc["paths"]["/users"]["post"]["operationId"]).to eq("users_create")
        expect(doc["paths"]["/users"]["put"]["operationId"]).to eq("users_create_put")
      end

      # The invariant, over a generated document that crowds every shape of
      # collision together, rather than over a fixture, which proves only the
      # one document it holds.
      it "never repeats an operationId anywhere in a generated document" do
        controllers = [
          index_controller("admin_users", :index, :index_get, :index_post, "index_2"),
          index_controller("admin/users", :index, :update),
          index_controller("admin/users/v2", :index),
          index_controller("admin/users_v2", :index),
          controller_class(path: "webhooks") { permit_params(:receive) { optional :event, :string } }
        ]
        controllers << controllers.first
        routes = [
          route("admin/users", "index", "get", "/admin/users"),
          route("admin/users", "index", "get", "/admin/users"),
          route("admin/users", "index", "get", "/{locale}/admin/users"),
          route("admin/users", "index", "post", "/admin/users"),
          route("admin/users", "update", "put", "/admin/users/{id}"),
          route("admin/users", "update", "patch", "/admin/users/{id}"),
          route("admin_users", "index", "get", "/admin_users"),
          route("admin_users", "index_get", "get", "/admin_users/all"),
          route("admin/users/v2", "index", "get", "/v2/admin/users"),
          *%w[get post put patch delete].map { |verb| route("webhooks", "receive", verb, "/webhooks") }
        ]
        ids = operation_ids(described_class.document(controllers: controllers, routes: routes))

        expect(ids).to include("admin_users_index", "admin_users_index_get", "admin_users_index_2",
                               "admin_users_v2_index", "webhooks_receive")
        expect(ids.tally.select { |_, count| count > 1 }).to be_empty
      end
    end

    # OpenAPI forbids two path templates that differ only in variable names.
    # One route's own variants were deduped, but two routes could still
    # spell one URL shape two ways, and `scope "(:locale)"` makes that
    # common: its root is `/{locale}` and its `get ":slug"` is `/{slug}`.
    context "with routes whose templates differ only in variable names" do
      def route_set_with(&draw)
        ActionDispatch::Routing::RouteSet.new.tap { |route_set| route_set.draw(&draw) }
      end

      def routes_of(route_set)
        described_class.rails_routes(Struct.new(:routes).new(route_set))
      end

      before do
        stub_const("HomeController", Class.new(ActionController::Metal))
        stub_const("PagesController", Class.new(ActionController::Metal))
      end

      let(:home) { controller_class(path: "home") { permit_params(:index) { optional :page, :integer } } }
      let(:pages) do
        controller_class(path: "pages") { permit_params(:show, :create) { optional :page, :integer } }
      end

      # pages is passed first: the route set, not the controller list,
      # decides who Rails dispatches `GET /foo` to.
      it "keeps the template Rails dispatches to and lists the route it shadows there" do
        route_set = route_set_with do
          scope("(:locale)") do
            root to: "home#index"
            get ":slug", to: "pages#show"
          end
        end
        expect(route_set.recognize_path("/foo")).to eq(controller: "home", action: "index", locale: "foo")

        doc = described_class.document(controllers: [pages, home], routes: routes_of(route_set))
        expect(doc["paths"].keys).to contain_exactly("/", "/{locale}", "/{locale}/{slug}")
        expect(doc["paths"]["/{locale}"]["get"]["x-permittable-shadows"])
          .to eq([{ "path" => "/{slug}", "controller" => "pages", "action" => "show" }])
      end

      # A constraint on the earlier route makes the later one reachable for
      # the values it rejects, but OpenAPI still holds one of the two.
      it "still emits one template when a constraint lets the shadowed route through" do
        route_set = route_set_with do
          scope("(:locale)", locale: /en|fr/) do
            root to: "home#index"
            get ":slug", to: "pages#show"
          end
        end
        expect(route_set.recognize_path("/en")).to eq(controller: "home", action: "index", locale: "en")
        expect(route_set.recognize_path("/foo")).to eq(controller: "pages", action: "show", slug: "foo")

        doc = described_class.document(controllers: [pages, home], routes: routes_of(route_set))
        expect(doc["paths"].keys).to contain_exactly("/", "/{locale}", "/{locale}/{slug}")
        expect(doc["paths"]["/{locale}"]["get"]["x-permittable-shadows"])
          .to eq([{ "path" => "/{slug}", "controller" => "pages", "action" => "show" }])
      end

      # Rails picks a route by verb before it fills segments, so a POST to
      # `/foo` is not shadowed by a GET root. It shares the path, under the
      # spelling of the route Rails lists first, and keeps its own.
      it "places another verb's route under the shared template, keeping its own spelling visible" do
        route_set = route_set_with do
          scope("(:locale)") do
            root to: "home#index"
            post ":slug", to: "pages#create"
          end
        end
        expect(route_set.recognize_path("/foo", method: :post)).to eq(controller: "pages", action: "create", slug: "foo")

        doc = described_class.document(controllers: [pages, home], routes: routes_of(route_set))
        expect(doc["paths"].keys).to contain_exactly("/", "/{locale}", "/{locale}/{slug}")
        create = doc["paths"]["/{locale}"]["post"]
        expect(create["operationId"]).to eq("pages_create")
        expect(create["x-permittable-path"]).to eq("/{slug}")
        expect(create["parameters"].map { |parameter| parameter["name"] }).to eq(["locale"])
        expect(doc["paths"]["/{locale}"]["get"]).not_to have_key("x-permittable-shadows")
      end

      it "collapses hand-built descriptors the same way, in the order they are given" do
        doc = described_class.document(
          controllers: [pages, home],
          routes: [{ controller: "home", action: "index", verb: "get", path: "/{a}" },
                   { controller: "pages", action: "show", verb: "get", path: "/{b}" }]
        )
        expect(doc["paths"].keys).to eq(["/{a}"])
        expect(doc["paths"]["/{a}"]["get"]["operationId"]).to eq("home_index")
        expect(doc["x-permittable-controllers"]["pages"]).to have_key("show")
      end
    end

    it "defaults info and omits x-permittable-controllers when everything is routed" do
      klass = controller_class { permit_params(:create) { required :name, :string } }
      doc = described_class.document(controllers: [klass],
                                     routes: [{ controller: "users", action: "create", verb: "post", path: "/users" }])
      expect(doc["info"]).to eq("title" => "Permittable contracts", "version" => Permittable::VERSION)
      expect(doc).not_to have_key("x-permittable-controllers")
    end
  end

  describe ".rails_routes" do
    # One GET route to e#v whose path.spec is `spec`, Journey-shaped.
    def app_with_spec(spec)
      path = Struct.new(:spec).new(spec)
      route = Struct.new(:requirements, :verb, :path).new({ controller: "e", action: "v" }, "GET", path)
      Struct.new(:routes).new(Struct.new(:routes).new([route]))
    end

    it "extracts controller/action/verb/path descriptors from a Journey-shaped route set" do
      journey_route = Struct.new(:requirements, :verb, :path)
      journey_path = Struct.new(:spec)
      route_set = Struct.new(:routes).new(
        [
          journey_route.new({ controller: "users", action: "show" }, "GET", journey_path.new("/users/:id(.:format)")),
          journey_route.new({ controller: "users", action: "create" }, "POST", journey_path.new("/users(.:format)")),
          journey_route.new({}, "GET", journey_path.new("/rails/info")), # internal — skipped
          journey_route.new({}, "", journey_path.new("/sidekiq")) # mounted engine — skipped
        ]
      )
      app = Struct.new(:routes).new(route_set)
      expect(described_class.rails_routes(app)).to eq(
        [
          { controller: "users", action: "show", verb: "get", path: "/users/{id}", route: 0 },
          { controller: "users", action: "create", verb: "post", path: "/users", route: 1 }
        ]
      )
    end

    it "emits one descriptor per verb, so a route answering several is documented for all of them" do
      journey_route = Struct.new(:requirements, :verb, :path)
      journey_path = Struct.new(:spec)
      route_set = Struct.new(:routes).new(
        [journey_route.new({ controller: "users", action: "update" }, "PATCH|PUT",
                           journey_path.new("/users/:id(.:format)"))]
      )
      app = Struct.new(:routes).new(route_set)
      expect(described_class.rails_routes(app)).to eq(
        [
          { controller: "users", action: "update", verb: "patch", path: "/users/{id}", route: 0 },
          { controller: "users", action: "update", verb: "put", path: "/users/{id}", route: 0 }
        ]
      )
    end

    it "expands a via: :all route into every verb it answers, instead of dropping it" do
      # `match "hooks", to: "webhooks#receive", via: :all` has an EMPTY verb.
      # Skipping it hid a body-accepting action from the audit entirely.
      journey_route = Struct.new(:requirements, :verb, :path)
      journey_path = Struct.new(:spec)
      route_set = Struct.new(:routes).new(
        [journey_route.new({ controller: "webhooks", action: "receive" }, "", journey_path.new("/hooks(.:format)"))]
      )
      app = Struct.new(:routes).new(route_set)
      expect(described_class.rails_routes(app)).to eq(
        %w[get post put patch delete].map do |verb|
          { controller: "webhooks", action: "receive", verb: verb, path: "/hooks", route: 0 }
        end
      )
    end

    it "templates a wildcard segment too, so the path stays a valid OpenAPI template" do
      journey_route = Struct.new(:requirements, :verb, :path)
      journey_path = Struct.new(:spec)
      route_set = Struct.new(:routes).new(
        [
          journey_route.new({ controller: "files", action: "show" }, "GET",
                            journey_path.new("/files/*rest(.:format)")),
          journey_route.new({ controller: "files", action: "nested" }, "GET",
                            journey_path.new("/files/:bucket/*path(.:format)"))
        ]
      )
      app = Struct.new(:routes).new(route_set)
      expect(described_class.rails_routes(app)).to eq(
        [
          { controller: "files", action: "show", verb: "get", path: "/files/{rest}", route: 0 },
          { controller: "files", action: "nested", verb: "get", path: "/files/{bucket}/{path}", route: 1 }
        ]
      )
    end

    # Rails hands a request to the FIRST route matching its path and verb, so
    # a later route is never reached for that pair. Describing it anyway put
    # a phantom row in the audit and let the export document an operation
    # where Rails dispatches another.
    context "when routes overlap" do
      it "leaves a via: :all route only the verbs no earlier route answers on its path" do
        app = rails_app do
          get "hooks", to: "webhooks#index"
          match "hooks", to: "webhooks#receive", via: :all
        end
        expect(described_class.rails_routes(app)).to eq(
          [{ controller: "webhooks", action: "index", verb: "get", path: "/hooks", route: 0 }] +
          %w[post put patch delete].map do |verb|
            { controller: "webhooks", action: "receive", verb: verb, path: "/hooks", route: 1 }
          end
        )
      end

      it "drops a later explicit route that an earlier via: :all route already answers" do
        app = rails_app do
          match "hooks", to: "webhooks#receive", via: :all
          get "hooks", to: "webhooks#index"
        end
        expect(described_class.rails_routes(app).map { |r| [r[:action], r[:verb]] })
          .to eq(%w[get post put patch delete].map { |verb| ["receive", verb] })
      end

      it "keeps only the first route to a path and verb, whatever action the others name" do
        app = rails_app do
          post "users", to: "users#create"
          post "users", to: "users#create"
          post "users", to: "signups#create"
        end
        expect(described_class.rails_routes(app))
          .to eq([{ controller: "users", action: "create", verb: "post", path: "/users", route: 0 }])
      end

      # `/posts` is the earlier route's; `/{locale}/posts` is still the
      # optional scope's, since no earlier route answers it.
      it "compares the concrete paths an optional segment expands to" do
        app = rails_app do
          get "posts", to: "home#index"
          scope("(:locale)") { get "posts", to: "posts#index" }
        end
        expect(described_class.rails_routes(app)).to eq(
          [{ controller: "home", action: "index", verb: "get", path: "/posts", route: 0 },
           { controller: "posts", action: "index", verb: "get", path: "/{locale}/posts", route: 1 }]
        )
      end

      # A constrained route answers only what its constraint lets through and
      # passes the rest on to the routes behind it, so it hides nothing.
      # Hiding a reachable route would be a false pass in the audit gate.
      it "keeps a route behind one with a segment constraint on the same template" do
        app = rails_app do
          get "posts/:id", to: "posts#show", constraints: { id: /\d+/ }
          get "posts/:id", to: "posts#by_slug"
        end
        expect(described_class.rails_routes(app).map { |r| [r[:action], r[:path]] })
          .to eq([%w[show /posts/{id}], %w[by_slug /posts/{id}]])
      end

      it "keeps a route behind one with a subdomain constraint" do
        app = rails_app do
          get "dashboard", to: "api/dashboards#show", constraints: { subdomain: "api" }
          get "dashboard", to: "dashboards#show"
        end
        expect(described_class.rails_routes(app).map { |r| r[:controller] }).to eq(%w[api/dashboards dashboards])
      end

      it "keeps a route behind one wrapped in a constraint object or a lambda" do
        admin = Class.new { def self.matches?(_request) = true }
        app = rails_app do
          constraints(admin) { post "settings", to: "admin/settings#update" }
          post "settings", to: "settings#update", constraints: ->(_request) { true }
          post "settings", to: "fallback#update"
        end
        expect(described_class.rails_routes(app).map { |r| r[:controller] })
          .to eq(%w[admin/settings settings fallback])
      end

      # A glob always carries Rails's own non-greedy requirement, which
      # narrows nothing: the glob route still answers every request it
      # matches, and the duplicate behind it is never reached.
      it "still lets an unconstrained glob route hide a duplicate behind it" do
        app = rails_app do
          get "files/*rest", to: "files#show"
          get "files/*rest", to: "files#download"
        end
        expect(described_class.rails_routes(app).map { |r| r[:action] }).to eq(["show"])
      end

      # Only identical templates are compared. Templates that differ, even
      # only in a variable's name, are both kept rather than guessed at.
      it "keeps both routes when their templates differ, even if one URL could reach either" do
        app = rails_app do
          get "users/:id", to: "users#show", constraints: { id: /\d+/ }
          get "users/:slug", to: "users#by_slug"
        end
        expect(described_class.rails_routes(app).map { |r| r[:action] }).to eq(%w[show by_slug])
      end
    end

    # A real route set rather than a Journey-shaped Struct: the bug was in
    # the spec strings Rails actually generates, so the test reads those.
    context "with optional segments" do
      def app_with(&draw)
        route_set = ActionDispatch::Routing::RouteSet.new
        route_set.draw(&draw)
        Struct.new(:routes).new(route_set)
      end

      it "expands an optional scope into the path without it and the path with it" do
        app = app_with { scope("(:locale)") { resources :posts, only: %i[index show] } }
        expect(described_class.rails_routes(app)).to eq(
          [
            { controller: "posts", action: "index", verb: "get", path: "/posts", route: 0 },
            { controller: "posts", action: "index", verb: "get", path: "/{locale}/posts", route: 0 },
            { controller: "posts", action: "show", verb: "get", path: "/posts/{id}", route: 1 },
            { controller: "posts", action: "show", verb: "get", path: "/{locale}/posts/{id}", route: 1 }
          ]
        )
      end

      it "expands nested optional groups recursively" do
        app = app_with { get "archive(/:year(/:month))", to: "archive#show" }
        expect(described_class.rails_routes(app).map { |r| r[:path] })
          .to eq(["/archive", "/archive/{year}", "/archive/{year}/{month}"])
      end

      it "keeps an optional root scope a valid path" do
        app = app_with { scope("(:locale)") { root to: "home#index" } }
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(["/", "/{locale}"])
      end

      # Unconstrained, `x(/:a)(/:b)` with one segment present is matched as
      # :a — the :b-only variant is the same URL shape under another name,
      # and OpenAPI forbids two templates that differ only in their variable
      # names.
      it "drops a variant that coincides with one already emitted" do
        app = app_with { get "x(/:a)(/:b)", to: "x#y" }
        expect(described_class.rails_routes(app).map { |r| r[:path] })
          .to eq(["/x", "/x/{a}", "/x/{a}/{b}"])
      end

      # Order is part of the contract: it is the order the document lists the
      # paths in. (It no longer decides operationIds: the dedupe ranks the
      # shallowest path first itself, so `/posts` is `posts_create`.)
      # Each group reads absent-before-present, outer groups before inner, and
      # the order does not change which coinciding variant survives
      # (`/p/{q}`, not `/p/{s}`).
      it "emits the path without each optional segment first, at every nesting level" do
        app = app_with { get "(:l)/p(/:q(/:r))(/:s)", to: "m#n" }
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(
          ["/p", "/p/{q}", "/p/{q}/{r}", "/p/{q}/{r}/{s}",
           "/{l}/p", "/{l}/p/{q}", "/{l}/p/{q}/{r}", "/{l}/p/{q}/{r}/{s}"]
        )
      end

      it "exports a document with no parentheses and every templated variable declared" do
        klass = controller_class(path: "posts") { permit_params(:create) { required :title, :string } }
        app = app_with do
          scope("(:locale)") { resources :posts, only: :create }
          get "archive(/:year(/:month))", to: "posts#create"
        end
        doc = described_class.document(controllers: [klass], routes: described_class.rails_routes(app))

        expect(doc["paths"].keys).to contain_exactly(
          "/posts", "/{locale}/posts", "/archive", "/archive/{year}", "/archive/{year}/{month}"
        )
        expect(doc["paths"].keys.grep(/[()]/)).to be_empty
        doc["paths"].each do |path, operations|
          variables = path.scan(/\{(\w+)\}/).flatten
          operations.each_value do |operation|
            declared = operation.fetch("parameters", []).select { |p| p["in"] == "path" }
            expect(declared.map { |p| p["name"] }).to match_array(variables), "#{path} declares #{declared.inspect}"
            expect(declared).to all(include("required" => true))
          end
        end
      end

      # What Rails dispatches is the claim, so these ask the router first.
      context "where Rails decides which variant a URL is" do
        before { stub_const("XController", Class.new(ActionController::Metal)) }

        def paths_of(app)
          described_class.rails_routes(app).map { |r| r[:path] }
        end

        # With `a: /\d+/`, `/x/foo` fails :a and Rails binds it as :b, so the
        # :b-only variant is a real URL. OpenAPI still holds one of the two
        # templates; the one Rails tries first is kept, and the other is
        # named on it rather than dropped without a trace.
        it "lists a same-shape variant that a constraint keeps reachable on the variant Rails tries first" do
          app = app_with { get "x(/:a)(/:b)", to: "x#y", constraints: { a: /\d+/ } }
          expect(app.routes.recognize_path("/x/1")).to eq(controller: "x", action: "y", a: "1")
          expect(app.routes.recognize_path("/x/foo")).to eq(controller: "x", action: "y", b: "foo")

          descriptors = described_class.rails_routes(app)
          expect(descriptors.map { |r| r[:path] }).to eq(["/x", "/x/{a}", "/x/{a}/{b}"])
          expect(descriptors.to_h { |r| [r[:path], r[:shadows]] })
            .to eq("/x" => nil, "/x/{a}" => ["/x/{b}"], "/x/{a}/{b}" => nil)

          klass = controller_class(path: "x") { permit_params(:y) { optional :page, :integer } }
          doc = described_class.document(controllers: [klass], routes: descriptors)
          expect(doc["paths"]["/x/{a}"]["get"]["x-permittable-shadows"])
            .to eq([{ "path" => "/x/{b}", "controller" => "x", "action" => "y" }])
        end

        it "lists nothing when the parameters' constraints cannot tell the variants apart" do
          app = app_with { get "x(/:a)(/:b)", to: "x#y", constraints: { a: /\d+/, b: /\d+/ } }
          expect(app.routes.recognize_path("/x/1")).to eq(controller: "x", action: "y", a: "1")
          expect(described_class.rails_routes(app)).to all(satisfy { |r| !r.key?(:shadows) })
        end

        # `/x/new` is :a = "new" to Rails: an optional parameter ahead of an
        # optional literal takes the literal's text, so the literal-only
        # variant documented a URL that never reaches the action that way.
        it "drops a literal variant that Rails binds to an earlier optional parameter" do
          app = app_with { get "x(/:a)(/new)", to: "x#y" }
          expect(app.routes.recognize_path("/x/new")).to eq(controller: "x", action: "y", a: "new")
          expect(paths_of(app)).to eq(["/x", "/x/{a}", "/x/{a}/new"])
        end

        it "keeps that literal variant when the parameter's constraint rejects the literal" do
          app = app_with { get "x(/:a)(/new)", to: "x#y", constraints: { a: /\d+/ } }
          expect(app.routes.recognize_path("/x/new")).to eq(controller: "x", action: "y")
          expect(paths_of(app)).to eq(["/x", "/x/new", "/x/{a}", "/x/{a}/new"])
        end

        # The literal first: Rails tries it before the parameter, so both
        # variants are reachable and both are distinct OpenAPI templates.
        it "keeps a literal variant that comes before the parameter" do
          app = app_with { get "x(/new)(/:a)", to: "x#y" }
          expect(app.routes.recognize_path("/x/new")).to eq(controller: "x", action: "y")
          expect(app.routes.recognize_path("/x/foo")).to eq(controller: "x", action: "y", a: "foo")
          expect(paths_of(app)).to eq(["/x", "/x/{a}", "/x/new", "/x/new/{a}"])
        end
      end

      # Reading `route.path.spec.to_s` back as a string threw away what
      # Journey had parsed: an escaped parenthesis is part of a literal in
      # the tree, but prints as a bare one. Rails' own DSL escapes a
      # backslash before parsing, so `get "esc\\(v\\)"` is a group to Rails
      # too; the parser reaches the literal form for any route built from a
      # Journey pattern directly.
      it "reads an escaped parenthesis in the parsed route as a literal, not a group" do
        app = app_with_spec(ActionDispatch::Journey::Parser.parse("/esc\\(v\\)(.:format)"))
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(["/esc(v)"])
      end

      # The DSL escapes "|", so only a parsed pattern has one; Journey allows
      # it only inside a group, which still may be absent.
      it "reads an alternation in the parsed route as its alternatives, in order" do
        app = app_with_spec(ActionDispatch::Journey::Parser.parse("/x/(a|b)(.:format)"))
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(["/x/", "/x/b", "/x/a"])
      end

      it "templates a wildcard inside an optional group" do
        app = app_with { get "files(/*path)", to: "files#show" }
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(["/files", "/files/{path}"])
      end

      it "follows Rails' own reading of a backslash drawn through the DSL" do
        stub_const("EController", Class.new(ActionController::Metal))
        app = app_with { get "esc\\(v\\)", to: "e#v" }
        expect(app.routes.recognize_path("/esc%5C")).to eq(controller: "e", action: "v")
        expect(described_class.rails_routes(app).map { |r| r[:path] }).to eq(["/esc%5C", "/esc%5Cv%5C"])
      end

      # One route, two verbs: the variants are the same for both, so they are
      # worked out once. The order is verb by verb, as before, because
      # operationId numbering follows it.
      it "expands each route once, before splitting it by verb" do
        app = app_with { match "x(/:a)", to: "x#y", via: %i[patch put] }
        expect(described_class).to receive(:optional_variants).once.and_call_original
        expect(described_class.rails_routes(app).map { |r| [r[:verb], r[:path]] })
          .to eq([%w[patch /x], %w[patch /x/{a}], %w[put /x], %w[put /x/{a}]])
      end
    end

    # A Journey-shaped Struct may carry its spec as a plain string. It is
    # read with Journey's escapes, and a parenthesis with no partner is an
    # error rather than a silently truncated path.
    context "with a spec given as a string" do
      def paths_for(spec)
        described_class.rails_routes(app_with_spec(spec)).map { |r| r[:path] }
      end

      it "expands groups and honours escaped parentheses" do
        expect(paths_for("/a(/:b)(.:format)")).to eq(["/a", "/a/{b}"])
        expect(paths_for("/esc\\(v\\)(.:format)")).to eq(["/esc(v)"])
      end

      it "refuses an unbalanced parenthesis instead of truncating the path" do
        expect { paths_for("/un)matched(.:format)") }.to raise_error(ArgumentError, %r{/un\)matched})
        expect { paths_for("/un(matched(.:format)") }.to raise_error(ArgumentError, %r{/un\(matched})
      end
    end

    # An engine mounted in the app answers requests under its mount point, so
    # its routes are the app's. Real Rails::Engine classes and real route
    # sets, as `mount` builds them.
    describe "mounted engines" do
      # A named engine class (a mount needs a railtie name) whose routes are
      # drawn from `draw`. The root is pinned so Rails does not go looking.
      def engine(name, &draw)
        klass = Class.new(Rails::Engine) { def self.find_root(_from) = Pathname.new(Dir.tmpdir) }
        stub_const(name, klass)
        klass.routes.draw(&draw)
        klass
      end

      def paths_of(app, **options)
        described_class.rails_routes(app, **options).map { |r| [r[:controller], r[:action], r[:verb], r[:path]] }
      end

      before(:all) do
        require "rails/engine"
      rescue LoadError
        skip "railties is not available in this bundle"
      end

      it "prefixes the engine's paths with the mount's" do
        billing = engine("BillingEngine") { post "refunds", to: "refunds#create" }
        app = rails_app { mount billing => "/billing" }
        expect(paths_of(app)).to eq([["refunds", "create", "post", "/billing/refunds"]])
      end

      it "tags a route reached through a mount with [mount, route], an app route with its index" do
        billing = engine("BillingEngine") do
          get "a", to: "a#index"
          get "b", to: "b#index"
        end
        app = rails_app do
          get "x", to: "x#index"
          mount billing => "/billing"
        end
        expect(described_class.rails_routes(app).map { |r| r[:route] }).to eq([0, [1, 0], [1, 1]])
      end

      it "keeps an engine mounted twice apart" do
        billing = engine("BillingEngine") { post "refunds", to: "refunds#create" }
        app = rails_app do
          mount billing => "/billing", as: :one
          mount billing => "/invoicing", as: :two
        end
        found = described_class.rails_routes(app)
        expect(found.map { |r| r[:path] }).to eq(%w[/billing/refunds /invoicing/refunds])
        expect(found.map { |r| r[:route] }.uniq.length).to eq(2)
      end

      it "joins an engine mounted at / without doubling the slash" do
        billing = engine("BillingEngine") do
          root to: "home#index"
          get "refunds", to: "refunds#index"
        end
        app = rails_app { mount billing => "/" }
        expect(paths_of(app).map(&:last)).to eq(%w[/ /refunds])
      end

      it "gives an engine's root route the mount's own path" do
        billing = engine("BillingEngine") { root to: "home#index" }
        app = rails_app { mount billing => "/billing" }
        expect(paths_of(app).map(&:last)).to eq(["/billing"])
      end

      it "expands a mount under an optional scope like any route" do
        billing = engine("BillingEngine") { post "refunds", to: "refunds#create" }
        app = rails_app { scope("(:locale)") { mount billing => "/billing" } }
        expect(paths_of(app).map(&:last)).to eq(%w[/billing/refunds /{locale}/billing/refunds])
      end

      it "templates a dynamic mount point and keeps its constraint" do
        billing = engine("BillingEngine") { get "refunds", to: "refunds#index" }
        app = rails_app { mount billing => ":tenant", constraints: { tenant: /\d+/ } }
        expect(paths_of(app).map(&:last)).to eq(["/{tenant}/refunds"])
      end

      it "follows an engine mounted in an engine, with a nested route id" do
        inner = engine("InnerEngine") { get "deep", to: "deep#index" }
        outer = engine("OuterEngine") do
          get "shallow", to: "shallow#index"
          mount inner => "/inner"
        end
        app = rails_app do
          get "x", to: "x#index"
          mount outer => "/outer"
        end
        found = described_class.rails_routes(app)
        expect(found.map { |r| r[:path] }).to eq(%w[/x /outer/shallow /outer/inner/deep])
        expect(found.last[:route]).to eq([1, 1, 0])
      end

      it "stops at an engine that mounts itself" do
        cyclic = engine("CyclicEngine") { get "ping", to: "ping#index" }
        cyclic.routes.draw do
          get "ping", to: "ping#index"
          mount CyclicEngine => "/again", as: :again
        end
        app = rails_app { mount cyclic => "/c" }
        expect(paths_of(app).map(&:last)).to eq(["/c/ping"])
      end

      # Rails tries the routes in order with the mount standing where it is
      # drawn: an app route ahead of the mount answers before the engine is
      # asked, and an engine route that matches answers the request, so an app
      # route behind it is never reached. Only an engine with no route for the
      # request passes it on (X-Cascade).
      describe "shadowing across the app and a mounted engine" do
        let(:billing_engine) { engine("BillingEngine") { post "refunds", to: "refunds#create" } }

        it "lets an app route ahead of the mount answer, and the engine's behind it be dropped" do
          billing = billing_engine
          app = rails_app do
            post "billing/refunds", to: "legacy#create"
            mount billing => "/billing"
          end
          expect(paths_of(app)).to eq([%w[legacy create post /billing/refunds]])
        end

        it "lets an engine route answer, and an app route behind the mount be dropped" do
          billing = billing_engine
          app = rails_app do
            mount billing => "/billing"
            post "billing/refunds", to: "late#create"
          end
          expect(paths_of(app)).to eq([%w[refunds create post /billing/refunds]])
        end

        it "keeps an app route behind the mount when the engine has no route for its path" do
          billing = billing_engine
          app = rails_app do
            mount billing => "/billing"
            post "billing/other", to: "late#create"
          end
          expect(paths_of(app).map(&:last)).to eq(%w[/billing/refunds /billing/other])
        end

        it "keeps both when the mount is constrained and so passes some requests on" do
          billing = billing_engine
          app = rails_app do
            mount billing => "/billing", constraints: { subdomain: "api" }
            post "billing/refunds", to: "late#create"
          end
          expect(paths_of(app)).to eq([%w[refunds create post /billing/refunds],
                                       %w[late create post /billing/refunds]])
        end

        it "keeps both when the engine's own route is constrained" do
          constrained = engine("ConstrainedEngine") { post "refunds", to: "refunds#create", constraints: { subdomain: "api" } }
          app = rails_app do
            mount constrained => "/billing"
            post "billing/refunds", to: "late#create"
          end
          expect(paths_of(app).map(&:first)).to eq(%w[refunds late])
        end

        # The export placed the slot by the order of `controllers:`, which is
        # load order, so the document named whichever controller came first.
        describe "in the export" do
          let(:engine_controller) do
            controller_class(path: "refunds") { permit_params(:create) { optional :amount, :integer } }
          end
          let(:app_controller) do
            controller_class(path: "legacy") { permit_params(:create) { optional :note, :string } }
          end

          def operation_at_slot(app, controllers)
            doc = described_class.document(controllers: controllers, routes: described_class.rails_routes(app))
            doc["paths"]["/billing/refunds"]["post"]["operationId"]
          end

          it "names the app route that comes first, whichever controller is listed first" do
            billing = billing_engine
            app = rails_app do
              post "billing/refunds", to: "legacy#create"
              mount billing => "/billing"
            end
            expect(operation_at_slot(app, [engine_controller, app_controller])).to eq("legacy_create")
            expect(operation_at_slot(app, [app_controller, engine_controller])).to eq("legacy_create")
          end

          it "names the engine route that comes first, whichever controller is listed first" do
            billing = billing_engine
            app = rails_app do
              mount billing => "/billing"
              post "billing/refunds", to: "legacy#create"
            end
            expect(operation_at_slot(app, [engine_controller, app_controller])).to eq("refunds_create")
            expect(operation_at_slot(app, [app_controller, engine_controller])).to eq("refunds_create")
          end
        end
      end

      # The mount's own path is matched first, unanchored, and the first
      # variant of an optional segment that fits wins; Rails never goes back
      # into the mount for another variant when the engine has no route. So
      # under `scope "(:locale)"` a mount at "/" takes /posts as the locale
      # "posts", and the engine's /posts is never reached without a locale.
      describe "a mount that ends in an optional segment" do
        let(:blog_engine) do
          engine("BlogEngine") do
            root to: "posts#home"
            get "posts", to: "posts#index"
            post "posts", to: "posts#create"
            get "archive(/:year)", to: "posts#archive"
            get "posts/:id", to: "posts#show"
          end
        end

        def listed(app)
          described_class.rails_routes(app).map { |r| "#{r[:verb]} #{r[:path]} #{r[:action]}" }
        end

        it "documents only the paths that carry the segment, but still the engine's root" do
          blog = blog_engine
          app = rails_app { scope("(:locale)") { mount blog => "/" } }
          expect(listed(app)).to eq(
            ["get / home", "get /{locale} home",
             "get /{locale}/posts index", "post /{locale}/posts create",
             "get /{locale}/archive archive", "get /{locale}/archive/{year} archive",
             "get /{locale}/posts/{id} show"]
          )
        end

        it "does the same for a mount point that ends in a group" do
          blog = blog_engine
          app = rails_app { mount blog => "/m(/:slug)", as: :m }
          expect(listed(app)).to eq(
            ["get /m home", "get /m/{slug} home",
             "get /m/{slug}/posts index", "post /m/{slug}/posts create",
             "get /m/{slug}/archive archive", "get /m/{slug}/archive/{year} archive",
             "get /m/{slug}/posts/{id} show"]
          )
        end

        it "keeps both variants when the segment is not the mount's last" do
          blog = blog_engine
          app = rails_app { scope("(:locale)") { mount blog => "/blog" } }
          expect(listed(app)).to include("get /blog/posts index", "get /{locale}/blog/posts index",
                                         "get /blog/posts/{id} show", "get /{locale}/blog/posts/{id} show")
        end

        it "keeps both variants when a constraint stops the segment taking an engine's path" do
          blog = blog_engine
          app = rails_app { scope("(:locale)", locale: /en|fr/) { mount blog => "/" } }
          expect(listed(app)).to include("get /posts index", "get /{locale}/posts index",
                                         "post /posts create", "get /posts/{id} show")
        end

        it "judges each mount of a nest against the mounts above it" do
          inner = engine("DeepEngine") { get "deep", to: "deep#index" }
          outer = engine("WrapEngine") { mount inner => "/inner(/:slug)", as: :inner }
          app = rails_app { scope("(:locale)") { mount outer => "/" } }
          expect(listed(app)).to eq(["get /{locale}/inner/{slug}/deep index"])
        end
      end

      # A mount's `via:` limits the verbs it hands to the engine: another verb
      # is a 404 at the mount, never the engine's route.
      describe "a mount with via:" do
        let(:shop_engine) do
          engine("ShopEngine") do
            get "orders", to: "orders#index"
            post "orders", to: "orders#create"
            match "ping", to: "orders#ping", via: :all
          end
        end

        it "documents only the verbs the mount allows" do
          shop = shop_engine
          app = rails_app { mount shop, at: "/g", via: :get }
          expect(paths_of(app).map { |r| r.values_at(2, 3) }).to eq([%w[get /g/orders], %w[get /g/ping]])
        end

        it "takes a list of verbs" do
          shop = shop_engine
          app = rails_app { mount shop, at: "/g", via: %i[post put] }
          expect(paths_of(app).map { |r| r.values_at(2, 3) }).to eq([%w[post /g/orders], %w[post /g/ping], %w[put /g/ping]])
        end

        it "applies at every level of a nest" do
          shop_engine # defines ShopEngine, which the wrapper mounts
          wrap = engine("WrapEngine") { mount ShopEngine, at: "/s", via: %i[get post] }
          app = rails_app { mount wrap, at: "/w", via: :post }
          expect(paths_of(app).map { |r| r.values_at(2, 3) }).to eq([%w[post /w/s/orders], %w[post /w/s/ping]])
        end

        it "documents every verb of a mount with no via:" do
          shop = shop_engine
          app = rails_app { mount shop, at: "/g" }
          expect(paths_of(app).map(&:last).tally).to eq("/g/orders" => 2, "/g/ping" => 5)
        end
      end

      it "skips a Rack mount that is not an engine" do
        app = rails_app do
          mount ->(_env) { [200, {}, []] } => "/sidekiq"
          get "x", to: "x#index"
        end
        expect(paths_of(app).map(&:last)).to eq(["/x"])
      end

      it "restores the single route set with engines: false" do
        billing = engine("BillingEngine") { post "refunds", to: "refunds#create" }
        app = rails_app do
          get "x", to: "x#index"
          mount billing => "/billing"
        end
        expect(paths_of(app, engines: false).map(&:last)).to eq(["/x"])
      end

      it "places the engine's operations under paths in the export" do
        billing = engine("BillingEngine") { post "refunds", to: "refunds#create" }
        klass = controller_class(path: "refunds") { permit_params(:create) { required :amount, :integer } }
        app = rails_app { mount billing => "/billing" }
        doc = described_class.document(controllers: [klass], routes: described_class.rails_routes(app))
        expect(doc["paths"].keys).to eq(["/billing/refunds"])
        expect(doc).not_to have_key("x-permittable-controllers")
      end
    end
  end

  describe "the documented error shape" do
    # ERROR_SCHEMA is the one part of the export that is hand-written rather
    # than derived from a contract, so it is the one part that can drift from
    # what the server actually renders. Render a real violation and hold the
    # schema to it.
    def rendered_envelope(&declaration)
      klass = controller_class(&declaration)
      c = klass.new(params: {})
      c.define_singleton_method(:action_name) { "create" }
      begin
        c.permitted_params
      rescue Permittable::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      c.rendered[:json]
    end

    it "describes every key the envelope actually carries" do
      body = rendered_envelope { permit_params(:create) { required :email, :string, message: "must be an email" } }
      error_schema = described_class::ERROR_SCHEMA

      expect(body.keys.map(&:to_s)).to match_array(error_schema["properties"].keys)
      expect(body[:error].keys.map(&:to_s))
        .to all(be_in(error_schema["properties"]["error"]["properties"].keys))

      detail_schema = error_schema["properties"]["error"]["properties"]["details"]["items"]
      body[:error][:details].each do |entry|
        expect(entry.keys.map(&:to_s)).to all(be_in(detail_schema["properties"].keys))
        expect(detail_schema["required"]).to all(be_in(entry.keys.map(&:to_s)))
      end
    end

    it "lists every violation code the gem can emit" do
      description = described_class::ERROR_SCHEMA
                    .dig("properties", "error", "properties", "details", "items", "properties", "code", "description")
      %w[missing invalid_type inclusion format length depth unknown invalid].each do |code|
        expect(description).to include(code)
      end
    end

    # ERROR_SCHEMA/PROBLEM_SCHEMA are frozen, but only shallowly (Ruby's
    # #freeze never recurses), so a caller mutating a nested level of a
    # document's components — an easy mistake, since the rest of the
    # document is caller-owned data — was silently corrupting the shared
    # constant itself, for every document generated for the rest of the
    # process.
    it "hands out an independent copy of the error schema, not the frozen constant by reference" do
      klass = controller_class { permit_params(:create) { required :name, :string } }
      doc = described_class.document(controllers: [klass])
      message_schema = doc["components"]["schemas"]["PermittableInvalidParameters"]["properties"]["error"]["properties"]["message"]

      expect { message_schema["description"] = "MUTATED" }.not_to raise_error

      fresh = described_class.document(controllers: [klass])
      fresh_message_schema = fresh["components"]["schemas"]["PermittableInvalidParameters"]["properties"]["error"]["properties"]["message"]
      expect(fresh_message_schema).not_to have_key("description")
      expect(described_class::ERROR_SCHEMA["properties"]["error"]["properties"]["message"]).not_to have_key("description")
    end
  end

  describe "the golden document" do
    # The full pipeline over the README's kitchen-sink contract, compared
    # byte-for-byte against a committed fixture — this is the determinism
    # guarantee that makes generated documents committable and diff-stable.
    def golden_document
      klass = controller_class do
        permit_params :create, :update, root: :user, unknown: :error, desc: "Create or update a user" do
          required :name,  :string,  length: 1..80, desc: "Display name"
          required :email, :string,  format: /\A[^@\s]+@[^@\s]+\z/, example: "jo@example.com"
          optional :age,   :integer, in: 18..120
          optional :ssn,   :string,  sensitive: true
          optional :plan,  :string,  in: %w[free pro], default: "free"
          array    :tag_names, of: :string, length: 0..10
          optional :address do
            required :city, :string
            optional :zip,  :string, format: /\A\d{5}\z/
          end
        end
      end
      described_class.document(
        controllers: [klass],
        info: { "title" => "Golden API", "version" => "1.0.0" },
        routes: [{ controller: "users", action: "create", verb: "POST", path: "/users" },
                 { controller: "users", action: "update", verb: "PATCH", path: "/users/{id}" },
                 { controller: "users", action: "update", verb: "PUT", path: "/users/{id}" }]
      )
    end

    it "matches the committed fixture exactly" do
      fixture = File.expand_path("fixtures/openapi.json", __dir__)
      expect("#{JSON.pretty_generate(golden_document)}\n").to eq(File.read(fixture))
    end

    # OpenAPI requires operationId to be unique across the document; a
    # duplicate makes it invalid and makes client generators emit two
    # methods with one name. Asserted over the generated document, not the
    # fixture, so it holds the exporter to account rather than a file. The
    # wider collision shapes are covered under .document.
    it "never repeats an operationId" do
      doc = golden_document
      verbs = doc["paths"].values.flat_map(&:keys)
      expect(verbs).to include("patch", "put"), "golden document no longer exercises a PATCH|PUT pair"

      expect(operation_ids(doc).tally.select { |_, count| count > 1 }).to be_empty
    end

    # OpenAPI 3.1 requires a path-template variable to be declared as a path
    # parameter; a document that templates {id} without declaring it is
    # invalid, and every member route produced one. Asserted as an invariant
    # over the whole document rather than per-operation, so it also covers
    # operations added later.
    it "declares every variable it templates, everywhere" do
      fixture = JSON.parse(File.read(File.expand_path("fixtures/openapi.json", __dir__)))
      templated = fixture["paths"].keys.grep(/\{/)
      expect(templated).not_to be_empty, "fixture no longer exercises a templated path"

      fixture["paths"].each do |path, operations|
        variables = path.scan(/\{(\w+)\}/).flatten
        operations.each_value do |operation|
          declared = operation.fetch("parameters", []).select { |p| p["in"] == "path" }
          expect(declared.map { |p| p["name"] }).to match_array(variables), "#{path} declares #{declared.inspect}"
          expect(declared).to all(include("required" => true))
        end
      end
    end
  end
end
