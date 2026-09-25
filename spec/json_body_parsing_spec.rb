require "spec_helper"

# activesupport 8.1.3.1 calls JSON.parse(source, opts) positionally, json 3
# rejects it, and every application/json body failed while the suite stayed
# green: nothing sent raw JSON through Rails' own parser at the time
# (https://github.com/VSN2015/permittable/issues/58). The `raw_json:` and
# `json:` examples below pin down that IntegrationHarness hands ActionDispatch
# raw bytes, that Rails' JSON parser decodes them into what the contract
# validates, and that malformed input fails as a JSON::ParserError rather
# than as a broken parser call.
RSpec.describe "A raw application/json request body" do
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

  it "can be decoded by a bare ActiveSupport::JSON.decode call" do
    expect(ActiveSupport::JSON.decode('{"user":{"name":"Jo"}}')).to eq("user" => { "name" => "Jo" })
  end

  it "is parsed by Rails and validated by the contract" do
    result = IntegrationHarness.dispatch(controller, :create, method: "POST",
                                                              raw_json: '{"user":{"name":"Jo","age":30,"tags":["a","b"]}}')
    expect(result.status).to eq(200)
    expect(JSON.parse(result.body)).to eq("name" => "Jo", "age" => 30, "tags" => %w[a b])
  end

  it "reaches Rails' parser through the harness's json: option too, not a pre-parsed Hash" do
    parsed = nil
    allow(ActiveSupport::JSON).to receive(:decode).and_wrap_original { |m, *args| parsed = m.call(*args) }
    result = IntegrationHarness.dispatch(controller, :create, method: "POST", json: { user: { name: "Jo" } })
    expect(result.status).to eq(200)
    expect(parsed).to eq("user" => { "name" => "Jo" })
  end

  it "fails on malformed JSON because the JSON is malformed, not because the parser call is broken" do
    # ActionDispatch wraps ANY parser exception in ParseError, so a broken
    # parser call looks the same as bad input from outside. The cause tells
    # them apart: with the json-3 break it was an ArgumentError.
    expect { IntegrationHarness.dispatch(controller, :create, method: "POST", raw_json: '{"user":') }
      .to raise_error(ActionDispatch::Http::Parameters::ParseError) { |e| expect(e.cause).to be_a(JSON::ParserError) }
  end
end
