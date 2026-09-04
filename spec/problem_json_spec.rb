RSpec.describe "RFC 9457 problem+json error format" do
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

  # Render whatever the contract raises, and hand back what was rendered.
  def render(params, action: "create", &declaration)
    c = controller(permittable_class(&declaration), params: params, action: action)
    begin
      c.permitted_params
    rescue Permittable::InvalidParameters => e
      c.render_invalid_parameters(e)
    end
    c.rendered
  end

  let(:decl) do
    proc do
      permit_params(:create, root: :user) do
        required :email, :string, format: /@/
        optional :age, :integer, in: 18..120
      end
    end
  end

  after do
    Permittable.error_format = :envelope
    Permittable.problem_base_uri = nil
  end

  it "defaults to the existing envelope, so nothing changes for apps that don't opt in" do
    expect(Permittable.error_format).to eq(:envelope)
    rendered = render({ user: { email: "nope" } }, &decl)
    expect(rendered[:json]).to eq(success: false,
                                  error: { message: "Invalid parameters: user.email (format)",
                                           code: "invalid_parameters",
                                           details: [{ param: "user.email", code: "format" }] })
    expect(rendered.key?(:content_type)).to be(false)
  end

  it "rejects an unknown format at assignment" do
    expect { Permittable.error_format = :xml }
      .to raise_error(ArgumentError, /error_format must be one of envelope, problem/)
  end

  describe "when error_format is :problem" do
    before { Permittable.error_format = :problem }

    it "renders the RFC 9457 members in order, with the numeric status and the field errors" do
      rendered = render({ user: { email: "nope", age: 9 } }, &decl)
      expect(rendered[:content_type]).to eq("application/problem+json")
      expect(rendered[:status]).to eq(:unprocessable_entity)
      expect(rendered[:json].keys).to eq(%i[type title status detail errors])
      expect(rendered[:json]).to include(
        type: "about:blank",
        title: "Invalid parameters",
        status: 422,
        detail: "Invalid parameters: user.email (format), user.age (inclusion)",
        errors: [{ param: "user.email", code: "format" }, { param: "user.age", code: "inclusion" }]
      )
    end

    it "titles a malformed envelope differently and carries its 400" do
      rendered = render({}, &decl)
      expect(rendered[:status]).to eq(:bad_request)
      expect(rendered[:json]).to include(title: "Malformed request", status: 400)
    end

    it "resolves a real type URI from problem_base_uri, per problem type" do
      Permittable.problem_base_uri = "https://api.example.com/problems/"
      expect(render({ user: { email: "nope" } }, &decl)[:json][:type])
        .to eq("https://api.example.com/problems/invalid-parameters")
      expect(render({}, &decl)[:json][:type])
        .to eq("https://api.example.com/problems/malformed-request")
    end

    it "includes instance when the controller can name the request path" do
      klass = permittable_class(&decl)
      c = controller(klass, params: {})
      c.define_singleton_method(:request) { Struct.new(:path).new("/users/7") }
      begin
        c.permitted_params
      rescue Permittable::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      expect(c.rendered[:json][:instance]).to eq("/users/7")
      expect(c.rendered[:json].keys).to eq(%i[type title status detail instance errors])
    end

    it "carries a field's custom message into the error entry, like the envelope does" do
      rendered = render({ user: { email: "nope" } }) do
        permit_params(:create, root: :user) do
          required :email, :string, format: /@/, message: "must be a valid email"
        end
      end
      expect(rendered[:json][:errors])
        .to eq([{ param: "user.email", code: "format", message: "must be a valid email" }])
    end

    it "does NOT delegate to a host's render_error — choosing the format opts out of the host envelope" do
      klass = Class.new(FakeController) do
        include Permittable

        attr_reader :delegated

        def render_error(**kwargs)
          @delegated = kwargs
        end

        permit_params(:create) { required :name, :string }
      end
      c = controller(klass, params: {})
      begin
        c.permitted_params
      rescue Permittable::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      expect(c.delegated).to be_nil
      expect(c.rendered[:content_type]).to eq("application/problem+json")
    end

    it "maps the statuses it raises without Rack, and defers to Rack for anything else" do
      expect(Permittable::ErrorEnvelope.status_code(422)).to eq(422)
      expect(Permittable::ErrorEnvelope.status_code(:bad_request)).to eq(400)
      # Rails 7.2 renamed 422; both spellings resolve.
      expect(Permittable::ErrorEnvelope.status_code(:unprocessable_entity)).to eq(422)
      expect(Permittable::ErrorEnvelope.status_code(:unprocessable_content)).to eq(422)
      expect(Permittable::ErrorEnvelope.status_code(:not_found)).to eq(404)
      # Omitted rather than guessed when nothing can resolve it — RFC 9457
      # makes `status` optional.
      expect(Permittable::ErrorEnvelope.status_code(:no_such_status)).to be_falsey
    end
  end

  describe "through the real ActionController stack", :integration do
    it "sets the application/problem+json content type on the response" do
      Permittable.error_format = :problem
      Permittable.problem_base_uri = "https://api.example.com/problems"
      controller = IntegrationHarness.build_controller do
        include Permittable

        permit_params :create, root: :user do
          required :email, :string, format: /@/
        end

        def create
          render json: { received: permitted_params }
        end
      end
      result = IntegrationHarness.dispatch(controller, :create, method: "POST",
                                                                params: { user: { email: "nope" } })
      expect(result.status).to eq(422)
      expect(result.header("Content-Type")).to start_with("application/problem+json")
      body = JSON.parse(result.body)
      expect(body["type"]).to eq("https://api.example.com/problems/invalid-parameters")
      expect(body["status"]).to eq(422)
      expect(body["instance"]).to eq("/")
      expect(body["errors"]).to eq([{ "param" => "user.email", "code" => "format" }])
    end
  end

  describe "the exported OpenAPI response" do
    it "describes the envelope shape by default" do
      components = Permittable::OpenAPI.components
      expect(components["schemas"].keys).to eq(["PermittableInvalidParameters"])
      expect(components["responses"]["PermittableUnprocessableEntity"]["content"].keys)
        .to eq(["application/json"])
    end

    it "describes the problem shape, under its own media type, when that is the configured format" do
      Permittable.error_format = :problem
      components = Permittable::OpenAPI.components
      schema = components["schemas"]["PermittableInvalidParameters"]
      expect(schema["properties"].keys).to eq(%w[type title status detail instance errors])
      expect(schema["required"]).to eq(%w[title status])
      expect(components["responses"]["PermittableUnprocessableEntity"]["content"].keys)
        .to eq(["application/problem+json"])
    end
  end
end
