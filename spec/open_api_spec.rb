require "json"

RSpec.describe Permittable::OpenAPI do
  def controller_class(path: "users", &declaration)
    Class.new(FakeController) do
      include Permittable

      define_singleton_method(:controller_path) { path }
      class_eval(&declaration) if declaration
    end
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

      # Every operationId in the document, the unrouted ones included: the
      # whole document is one namespace to a client generator.
      def operation_ids(doc)
        routed = doc["paths"].values.flat_map(&:values)
        unrouted = doc.fetch("x-permittable-controllers", {}).values.flat_map(&:values)
        (routed + unrouted).filter_map { |operation| operation["operationId"] }
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

      it "numbers a verb-suffixed id that is some other operation's own id" do
        doc = described_class.document(
          controllers: [index_controller("admin/users", :index), index_controller("admin_users", :index, :index_post)],
          routes: [route("admin/users", "index", "get", "/admin/users"),
                   route("admin_users", "index", "post", "/admin_users"),
                   route("admin_users", "index_post", "post", "/admin_users/bulk")]
        )
        expect(doc["paths"]["/admin/users"]["get"]["operationId"]).to eq("admin_users_index")
        expect(doc["paths"]["/admin_users"]["post"]["operationId"]).to eq("admin_users_index_post_2")
        expect(doc["paths"]["/admin_users/bulk"]["post"]["operationId"]).to eq("admin_users_index_post")
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

    it "defaults info and omits x-permittable-controllers when everything is routed" do
      klass = controller_class { permit_params(:create) { required :name, :string } }
      doc = described_class.document(controllers: [klass],
                                     routes: [{ controller: "users", action: "create", verb: "post", path: "/users" }])
      expect(doc["info"]).to eq("title" => "Permittable contracts", "version" => Permittable::VERSION)
      expect(doc).not_to have_key("x-permittable-controllers")
    end
  end

  describe ".rails_routes" do
    it "extracts controller/action/verb/path descriptors from a Journey-shaped route set" do
      journey_route = Struct.new(:requirements, :verb, :path)
      journey_path = Struct.new(:spec)
      route_set = Struct.new(:routes).new(
        [
          journey_route.new({ controller: "users", action: "show" }, "GET", journey_path.new("/users/:id(.:format)")),
          journey_route.new({ controller: "users", action: "create" }, "POST", journey_path.new("/users(.:format)")),
          journey_route.new({}, "GET", journey_path.new("/rails/info")),                        # internal — skipped
          journey_route.new({ controller: "x", action: "y" }, "", journey_path.new("/mounted")) # no verb — skipped
        ]
      )
      app = Struct.new(:routes).new(route_set)
      expect(described_class.rails_routes(app)).to eq(
        [
          { controller: "users", action: "show", verb: "get", path: "/users/{id}" },
          { controller: "users", action: "create", verb: "post", path: "/users" }
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
          { controller: "users", action: "update", verb: "patch", path: "/users/{id}" },
          { controller: "users", action: "update", verb: "put", path: "/users/{id}" }
        ]
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
          { controller: "files", action: "show", verb: "get", path: "/files/{rest}" },
          { controller: "files", action: "nested", verb: "get", path: "/files/{bucket}/{path}" }
        ]
      )
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

      ids = doc["paths"].values.flat_map(&:values).filter_map { |operation| operation["operationId"] }
      expect(ids.tally.select { |_, count| count > 1 }).to be_empty
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
