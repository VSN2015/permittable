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
  # and operations with no matching route — or whose path+verb slot another
  # controller already claimed, which a document cannot represent twice —
  # land in `x-permittable-controllers` instead of being dropped silently.
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
                    "description" => "missing / invalid_type / inclusion / format / length / depth / unknown / " \
                                     "invalid, or a contract-specific symbol"
                  },
                  # Present only when the field declares `message:` or the app
                  # has I18n copy for the code; a violation without one keeps
                  # the bare { param:, code: } shape, so this is not required.
                  "message" => {
                    "type" => "string",
                    "description" => "Human-readable copy for this violation, when the contract or I18n supplies it"
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
      # The docs must not promise a 422 the server doesn't yet send. Only
      # the rule's own declaration is contract data — the app-wide
      # Permittable.mode is runtime configuration the export can't see.
      operation["x-permittable-mode"] = "monitor" if rule[:mode] == :monitor
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
        # A path+verb pair carries exactly one operation, so a slot another
        # controller already claimed is not written over: the loser stays
        # visible under x-permittable-controllers, where an operation with no
        # route at all lands, rather than disappearing from the document.
        free = routes_for(routes, key, action).reject { |route| paths.dig(route[:path], verb_of(route)) }
        if free.empty?
          (unrouted[key] ||= {})[action] = operation
        else
          free.each { |route| (paths[route[:path]] ||= {})[verb_of(route)] = with_path_parameters(operation, route[:path]) }
        end
      end
    end

    def verb_of(route)
      route[:verb].to_s.downcase
    end

    # OpenAPI 3.1 requires every variable in a path template to be declared as
    # a path parameter — a document templating {id} without declaring it is
    # invalid, which every member route produced. The route set does not say
    # what an :id is and the exporter does not guess: a path segment arrives as
    # a string, so that is what it is documented as.
    def with_path_parameters(operation, path)
      variables = path.scan(/\{(\w+)\}/).flatten
      return operation if variables.empty?

      parameters = variables.map do |name|
        { "name" => name, "in" => "path", "required" => true, "schema" => { "type" => "string" } }
      end
      # Inserted ahead of requestBody, where a reader of the document expects
      # it; emission stays deterministic either way.
      operation.each_with_object({}) do |(key, value), out|
        out["parameters"] = parameters if key == "requestBody"
        out[key] = value
      end
    end

    def routes_for(routes, controller_key, action)
      return [] if routes.nil? || action == "*"

      routes.select { |r| r[:controller].to_s == controller_key && r[:action].to_s == action }
    end

    # { controller:, action:, verb:, path: } descriptors from a Rails
    # application's route set. Duck-typed against Journey routes (each one
    # responds to requirements / verb / path.spec) so it stays unit-testable
    # without Rails; Rails path params become OpenAPI templates — both the
    # `:id` form and the `*rest` wildcard, which is a real route shape
    # (`get "files/*path"`) and is not a valid OpenAPI template left as-is.
    def rails_routes(app)
      app.routes.routes.flat_map do |route|
        requirements = route.requirements
        verb = route.verb.to_s
        next [] if requirements[:controller].nil? || requirements[:action].nil? || verb.empty?

        path = route.path.spec.to_s.sub("(.:format)", "").gsub(/[:*](\w+)/) { "{#{Regexp.last_match(1)}}" }
        # One route can answer several verbs (`match via: [:patch, :put]`, and
        # the PATCH|PUT pair resources generates); documenting only the first
        # dropped the others from the export entirely.
        verb.split("|").map do |single|
          { controller: requirements[:controller], action: requirements[:action],
            verb: single.downcase, path: path }
        end
      end
    end

    def controller_key(controller)
      return controller.controller_path if controller.respond_to?(:controller_path)

      controller.name
    end
  end
end
