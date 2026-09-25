require "action_controller"
require "rack/mock"

# Dispatches a single action through the REAL ActionController stack —
# callback chain, rescue_from, ActionController::Parameters — which the
# dependency-free FakeController harness cannot reproduce.
#
# ActionController::Metal.action(name) returns a Rack app, so no routes are
# needed for `render json:` / `head`.
module IntegrationHarness
  Result = Struct.new(:status, :headers, :body) do
    # Rack 3 downcases response header names; accept either spelling.
    def header(name)
      headers[name] || headers[name.downcase]
    end
  end

  module_function

  # `params:` (a Hash) is form-encoded into the request body — how the specs
  # exercise real ActionController::Parameters bodies. `json:` sends the Hash
  # as an application/json body instead (what ParamsWrapper acts on), and
  # `path_params:` stands in for what the router would have matched out of
  # the URL — Rails merges both into `params` exactly as a routed request
  # would, with no route set needed. Either way the body is parsed by
  # ActionDispatch's own JSON parser, never pre-parsed. `raw_json:` sends a
  # String body verbatim, for input `json:` cannot produce (malformed JSON).
  # `instance:` dispatches on that controller object instead of a fresh one
  # per request, to pin down state that must not survive from one request to
  # the next.
  def dispatch(controller_class, action, method: "GET", query: "", params: nil, json: nil, raw_json: nil,
               path_params: nil, instance: nil)
    opts = { method: method }
    opts[:params] = params if params
    raw_json = JSON.generate(json) if json
    if raw_json
      opts[:input] = raw_json
      opts["CONTENT_TYPE"] = "application/json"
    end
    env = Rack::MockRequest.env_for("/?#{query}", **opts)
    # Without a logger, ActionDispatch logs a body it fails to parse to $stderr.
    env["action_dispatch.logger"] = Logger.new(nil) if raw_json
    env["action_dispatch.request.path_parameters"] = path_params if path_params
    status, headers, body =
      if instance
        request = ActionDispatch::Request.new(env)
        instance.dispatch(action, request, controller_class.make_response!(request))
      else
        controller_class.action(action).call(env)
      end
    # Rack bodies only guarantee #each (RackBody has no #map).
    chunks = body.enum_for(:each).to_a
    body.close if body.respond_to?(:close)
    Result.new(status, headers, chunks.join)
  end

  # Anonymous ActionController::Base subclass with a stable controller_path
  # (some instrumentation paths ask for it and anonymous classes have no name).
  def build_controller(&block)
    Class.new(ActionController::Base) do
      def self.controller_path
        "integration_harness"
      end

      class_eval(&block) if block
    end
  end
end
