require "permittable/version"
require "permittable/json_schema"

module Permittable
  # Assembles OpenAPI 3.1 fragments and documents from Permittable contracts.
  # Plain Ruby over the frozen contract registry — Rails is not required; the
  # `permittable:openapi` rake task (loaded by the Railtie) supplies the
  # Rails-only parts: eager loading, controller discovery, and the route
  # descriptors that turn operations into real `paths` entries.
  #
  # Everything the exporter cannot know is left visible rather than guessed:
  # actions covered only by a catch-all rule on a host without
  # `action_methods` appear under the "*" key with `x-permittable-catch-all`,
  # and operations with no matching route land in `x-permittable-controllers`
  # instead of being dropped silently.
  module OpenAPI
    module_function

    # The error envelope rendered by render_invalid_parameters (see
    # ErrorEnvelope): code/details are present on every violation this gem
    # raises, message always.
    ERROR_SCHEMA = {
      "type" => "object",
      "properties" => {
        "success" => { "type" => "boolean", "enum" => [false] },
        "error" => {
          "type" => "object",
          "properties" => {
            "message" => { "type" => "string" },
            "code" => { "type" => "string", "enum" => ["invalid_parameters"] },
            "details" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "properties" => {
                  "param" => {
                    "type" => "string",
                    "description" => "Fully-qualified parameter path, e.g. user.address.zip or line_items[1].sku"
                  },
                  "code" => {
                    "type" => "string",
                    "description" => "missing / invalid_type / inclusion / format / length / unknown / invalid, " \
                                     "or a contract-specific symbol"
                  }
                },
                "required" => %w[param code]
              }
            }
          },
          "required" => %w[message]
        }
      },
      "required" => %w[success error]
    }.freeze

    # Instance methods the concern itself adds to every including controller;
    # action_methods reports them as actions (they are public by design), but
    # they are never routed and must not be documented as endpoints. Resolved
    # lazily — at file-load time the concern's module body may not have run.
    def concern_methods
      @concern_methods ||= Permittable.public_instance_methods(false).map(&:to_s).freeze
    end

    # Shared `components` for any document referencing Permittable responses.
    def components
      {
        "schemas" => { "PermittableInvalidParameters" => ERROR_SCHEMA },
        "responses" => {
          "PermittableBadRequest" => error_response(
            "The root: key is missing or not an object — the request envelope itself is malformed."
          ),
          "PermittableUnprocessableEntity" => error_response(
            "One or more parameters violated the action's contract; details names each offender."
          )
        }
      }
    end

    def error_response(description)
      {
        "description" => description,
        "content" => {
          "application/json" => {
            "schema" => { "$ref" => "#/components/schemas/PermittableInvalidParameters" }
          }
        }
      }
    end

    # OpenAPI requestBody object for the contract covering `action`, nil when
    # no contract does. `required` mirrors the runtime: a rooted contract
    # rejects a bodyless request outright (400), and so does any top-level
    # required field (missing).
    def request_body_for(controller, action)
      rule = controller.permit_rule_for(action)
      rule && rule_request_body(rule)
    end

    def rule_request_body(rule)
      {
        "required" => !!(rule[:root] || rule[:fields].any? { |f| f[:required] }),
        "content" => { "application/json" => { "schema" => JsonSchema.rule(rule) } }
      }
    end

    # { action => operation } for every action the controller's contracts
    # cover, resolved through permit_rule_for so last-matching-rule-wins holds
    # in the documentation exactly as it does at request time.
    def operations_for(controller)
      documented_actions(controller).to_h { |action| [action, operation_for(controller, action)] }
    end

    # Explicitly-declared actions in declaration order; when a catch-all rule
    # exists, the controller's remaining action_methods (sorted) follow — or
    # the literal "*" on hosts without action_methods (plain-Ruby params
    # ducks), where the covered action set is unknowable.
    def documented_actions(controller)
      contracts = controller.permittable_contracts
      explicit = contracts.flat_map { |rule| rule[:actions] }.uniq
      return explicit unless contracts.any? { |rule| rule[:actions].empty? }
      return explicit + ["*"] unless controller.respond_to?(:action_methods)

      explicit + (controller.action_methods.map(&:to_s).sort - explicit - concern_methods)
    end

    def operation_for(controller, action)
      rule = if action == "*"
               controller.permittable_contracts.reverse_each.find { |r| r[:actions].empty? }
             else
               controller.permit_rule_for(action)
             end
      operation = {}
      key = controller_key(controller)
      operation["operationId"] = "#{key.tr('/', '_')}_#{action}" if key && action != "*"
      operation["description"] = rule[:desc] if rule[:desc]
      operation["requestBody"] = rule_request_body(rule)
      operation["responses"] = responses_for(rule)
      operation["x-permittable-catch-all"] = true if action == "*"
      operation
    end

    def responses_for(rule)
      responses = {}
      responses["400"] = { "$ref" => "#/components/responses/PermittableBadRequest" } if rule[:root]
      responses["422"] = { "$ref" => "#/components/responses/PermittableUnprocessableEntity" }
      responses
    end

    # A complete OpenAPI 3.1 document. `routes:` is an optional array of
    # { controller:, action:, verb:, path: } descriptors (see rails_routes);
    # operations with a matching descriptor become `paths` entries, the rest
    # are grouped by controller under `x-permittable-controllers`.
    def document(controllers:, info: {}, routes: nil)
      paths = {}
      unrouted = {}
      controllers.each do |controller|
        operations = operations_for(controller)
        next if operations.empty?

        place_operations(controller, operations, routes, paths, unrouted)
      end
      doc = {
        "openapi" => "3.1.0",
        "info" => { "title" => "Permittable contracts", "version" => VERSION }.merge(info),
        "paths" => paths,
        "components" => components
      }
      doc["x-permittable-controllers"] = unrouted unless unrouted.empty?
      doc
    end

    def place_operations(controller, operations, routes, paths, unrouted)
      key = controller_key(controller) || controller.inspect
      operations.each do |action, operation|
        matched = routes_for(routes, key, action)
        if matched.empty?
          (unrouted[key] ||= {})[action] = operation
        else
          matched.each { |route| (paths[route[:path]] ||= {})[route[:verb].to_s.downcase] = operation }
        end
      end
    end

    def routes_for(routes, controller_key, action)
      return [] if routes.nil? || action == "*"

      routes.select { |r| r[:controller].to_s == controller_key && r[:action].to_s == action }
    end

    # { controller:, action:, verb:, path: } descriptors from a Rails
    # application's route set. Duck-typed against Journey routes (each one
    # responds to requirements / verb / path.spec) so it stays unit-testable
    # without Rails; Rails path params (:id) become OpenAPI templates ({id}).
    def rails_routes(app)
      app.routes.routes.filter_map do |route|
        requirements = route.requirements
        verb = route.verb.to_s
        next if requirements[:controller].nil? || requirements[:action].nil? || verb.empty?

        path = route.path.spec.to_s.sub("(.:format)", "").gsub(/:(\w+)/) { "{#{Regexp.last_match(1)}}" }
        { controller: requirements[:controller], action: requirements[:action],
          verb: verb.split("|").first.downcase, path: path }
      end
    end

    def controller_key(controller)
      return controller.controller_path if controller.respond_to?(:controller_path)

      controller.name
    end
  end
end
