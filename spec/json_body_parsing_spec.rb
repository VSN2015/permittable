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

  it "is the harness's only body: alongside params: (or json: with raw_json:) the harness refuses the call" do
    # Rack::MockRequest ignores :params once :input is set, and json: used to
    # overwrite raw_json:, so either pair silently sent one body and dropped
    # the other — a spec could pass without the request it describes.
    form = { user: { name: "Form" } }
    [{ params: form, json: { user: { name: "Jo" } } },
     { params: form, raw_json: '{"user":{"name":"Jo"}}' },
     { json: { user: { name: "Jo" } }, raw_json: '{"user":{"name":"Jo"}}' }].each do |bodies|
      expect { IntegrationHarness.dispatch(controller, :create, method: "POST", **bodies) }
        .to raise_error(ArgumentError, /one request body/)
    end
  end
end

# Monitor mode promises "Nothing raises and nothing renders — the action
# runs", and validates monitor rules in a before_action so legacy actions
# that never call permitted_params are still observed. That before_action
# read `params`, which raises ParseError on a body Rails cannot parse: a
# webhook action reading request.raw_post itself answered 400 instead of
# running, and an exception from the contract's own code became a 500.
RSpec.describe "Monitor mode's eager check, when it cannot check" do
  let(:lines) { [] }

  let(:controller) do
    log = lines
    IntegrationHarness.build_controller do
      include Permittable

      permit_params(:create, root: :data, mode: :monitor) { required :id, :string }
      permit_params(:update, root: :data, mode: :monitor) do
        required :starts_on, :string, validate: ->(v) { Date.iso8601(v) >= Date.new(2000) }
      end
      permit_params(:destroy, root: :data, enforce: true) { required :id, :string }

      define_method(:logger) do
        Logger.new(nil).tap { |logger| logger.define_singleton_method(:warn) { |message| log << message } }
      end

      def create
        payload = JSON.parse(request.raw_post)
        render json: { ok: payload }
      rescue JSON::ParserError
        render json: { ignored: true }
      end

      def update
        render json: { ok: true }
      end

      def destroy
        render json: { ok: true }
      end
    end
  end

  it "lets the action run on a body Rails cannot parse, and says why nothing was checked" do
    result = IntegrationHarness.dispatch(controller, :create, method: "POST", raw_json: '{"data":')
    expect([result.status, JSON.parse(result.body)]).to eq([200, { "ignored" => true }])
    expect(lines.grep(/\[monitor\] #create could not be checked: ActionDispatch::Http::Parameters::ParseError/).size).to eq(1)
  end

  it "lets the action run when the contract's own code raises, and names the exception" do
    result = IntegrationHarness.dispatch(controller, :update, method: "PATCH", json: { data: { starts_on: "next tuesday" } })
    expect(result.status).to eq(200)
    expect(lines.grep(/\[monitor\] #update could not be checked: Date::Error/).size).to eq(1)
  end

  it "never logs the body it could not parse" do
    IntegrationHarness.dispatch(controller, :create, method: "POST", raw_json: '{"data":{"password":"hunter2"')
    expect(lines.join).not_to include("hunter2")
  end

  it "still lets an enforced, unmonitored rule fail on a body Rails cannot parse, as Rails would" do
    expect { IntegrationHarness.dispatch(controller, :destroy, method: "DELETE", raw_json: '{"data":') }
      .to raise_error(ActionDispatch::Http::Parameters::ParseError)
  end

  it "still checks a well-formed body" do
    result = IntegrationHarness.dispatch(controller, :create, method: "POST", json: { data: {} })
    expect(result.status).to eq(200)
    expect(lines.grep(/\[monitor\] #create would have been rejected: data\.id/).size).to eq(1)
  end
end
