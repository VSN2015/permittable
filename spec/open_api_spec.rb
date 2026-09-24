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

      # `x(/:a)(/:b)` with one segment present is always matched as :a — the
      # :b-only variant is the same URL shape under another name, and OpenAPI
      # forbids two templates that differ only in their variable names.
      it "drops a variant that coincides with one already emitted" do
        app = app_with { get "x(/:a)(/:b)", to: "x#y" }
        expect(described_class.rails_routes(app).map { |r| r[:path] })
          .to eq(["/x", "/x/{a}", "/x/{a}/{b}"])
      end

      # Order is part of the contract: the operationId dedupe
      # (assign_unique_operation_ids) numbers colliding ids in route order, so
      # the path without the segment must come first to keep the plain id
      # (`/posts` is `posts_create`, not `_2`).
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
    it "matches the committed fixture exactly" do
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
      doc = described_class.document(
        controllers: [klass],
        info: { "title" => "Golden API", "version" => "1.0.0" },
        routes: [{ controller: "users", action: "create", verb: "POST", path: "/users" },
                 { controller: "users", action: "update", verb: "PATCH", path: "/users/{id}" }]
      )
      fixture = File.expand_path("fixtures/openapi.json", __dir__)
      expect("#{JSON.pretty_generate(doc)}\n").to eq(File.read(fixture))
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
