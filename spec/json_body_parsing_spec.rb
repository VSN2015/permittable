require "spec_helper"

# Every other controller spec sends a form-encoded body (IntegrationHarness's
# `params:`) or hands Rails a pre-parsed Hash, so none of them notice when
# Rails itself cannot parse JSON. That happened: activesupport 8.1.3.1 calls
# JSON.parse(source, opts) positionally, json 3 rejects it, and every
# application/json body failed while the suite stayed green
# (https://github.com/VSN2015/permittable/issues/58). The examples here send
# the raw bytes and let ActionDispatch's own JSON parser decode them.
RSpec.describe "A raw application/json request body" do
  def json_env(raw)
    env = Rack::MockRequest.env_for("/", method: "POST", input: raw, "CONTENT_TYPE" => "application/json")
    # Without one, a parse failure is logged to $stderr, cluttering the run.
    env["action_dispatch.logger"] = Logger.new(nil)
    env
  end

  def dispatch_raw(controller, raw)
    status, _headers, body = controller.action(:create).call(json_env(raw))
    chunks = body.enum_for(:each).to_a
    body.close if body.respond_to?(:close)
    [status, JSON.parse(chunks.join)]
  end

  let(:controller) do
    IntegrationHarness.build_controller do
      include Permittable

      permit_params(:create, root: :user) do
        required :name, :string
        optional :age, :integer
        array :tags, of: :string, length: 0..10
      end

      def create
        render json: permitted_params
      end
    end
  end

  it "is decoded by ActiveSupport::JSON, which ActionDispatch's JSON parser calls" do
    expect(ActiveSupport::JSON.decode('{"user":{"name":"Jo"}}')).to eq("user" => { "name" => "Jo" })
  end

  it "is parsed by Rails and validated by the contract" do
    status, body = dispatch_raw(controller, '{"user":{"name":"Jo","age":30,"tags":["a","b"]}}')
    expect(status).to eq(200)
    expect(body).to eq("name" => "Jo", "age" => 30, "tags" => %w[a b])
  end

  it "fails on malformed JSON because the JSON is malformed, not because the parser call is broken" do
    # ActionDispatch wraps ANY parser exception in ParseError, so a broken
    # parser call looks the same as bad input from outside. The cause tells
    # them apart: with the json-3 break it was an ArgumentError.
    expect { dispatch_raw(controller, '{"user":') }
      .to raise_error(ActionDispatch::Http::Parameters::ParseError) { |e| expect(e.cause).to be_a(JSON::ParserError) }
  end
end
