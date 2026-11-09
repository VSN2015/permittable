require "action_controller"
# Rails' own form helpers, so a spec can post exactly what a rendered
# date_select or datetime_select submits.
require "action_view"
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
  # exercise real ActionController::Parameters bodies; a String is sent as an
  # already-encoded form body, verbatim. `json:` sends the Hash
  # as an application/json body instead (what ParamsWrapper acts on), and
  # `path_params:` stands in for what the router would have matched out of
  # the URL — Rails merges both into `params` exactly as a routed request
  # would, with no route set needed. Either way the body is parsed by
  # ActionDispatch's own JSON parser, never pre-parsed. `raw_json:` sends a
  # String body verbatim, for input `json:` cannot produce (malformed JSON).
  # A request has one body, so at most one of the three may be given: with
  # `:input` set Rack::MockRequest ignores `:params`, and `json:` would
  # overwrite `raw_json:`, so a pair used to send one body and silently drop
  # the other. Put form-style fields in `query:` alongside a JSON body.
  # `multipart:` sends a multipart/form-data body built from `[name, value]`
  # or `[name, value, filename]` parts (a part with a filename is an upload,
  # which Rack::MockRequest's own builder cannot nest in an array), so an
  # upload reaches the controller exactly as the browser's multipart parser
  # hands it over.
  # `accept:` sets the request's Accept header, for specs about content
  # negotiation (respond_to picks a format from it).
  # `instance:` dispatches on that controller object instead of a fresh one
  # per request, to pin down state that must not survive from one request to
  # the next.
  def dispatch(controller_class, action, method: "GET", query: "", params: nil, json: nil, raw_json: nil,
               path_params: nil, instance: nil, accept: nil, multipart: nil)
    bodies = { params: params, json: json, raw_json: raw_json, multipart: multipart }.compact
    if bodies.size > 1
      raise ArgumentError, "IntegrationHarness.dispatch sends one request body, " \
                           "got #{bodies.keys.map { |k| "#{k}:" }.join(' and ')}"
    end

    opts = { method: method }
    opts[:params] = params if params
    raw_json = JSON.generate(json) if json
    if raw_json
      opts[:input] = raw_json
      opts["CONTENT_TYPE"] = "application/json"
    end
    if multipart
      opts[:input] = multipart_body(multipart)
      opts["CONTENT_TYPE"] = "multipart/form-data; boundary=#{MULTIPART_BOUNDARY}"
    end
    env = Rack::MockRequest.env_for("/?#{query}", **opts)
    # Without a logger, ActionDispatch logs a body it fails to parse to $stderr.
    env["action_dispatch.logger"] = Logger.new(nil) if raw_json
    env["action_dispatch.request.path_parameters"] = path_params if path_params
    env["HTTP_ACCEPT"] = accept if accept
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

  MULTIPART_BOUNDARY = "PermittableBoundary".freeze

  def multipart_body(parts)
    body = parts.map do |name, value, filename|
      disposition = %(form-data; name="#{name}") + (filename ? %(; filename="#{filename}") : "")
      type = filename ? "Content-Type: text/plain\r\n" : ""
      "--#{MULTIPART_BOUNDARY}\r\nContent-Disposition: #{disposition}\r\n#{type}\r\n#{value}\r\n"
    end
    "#{body.join}--#{MULTIPART_BOUNDARY}--\r\n"
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
