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

    # One violation, in whichever shape the app renders — the same
    # { param:, code: } entry rides in the envelope's `details` and the
    # problem document's `errors`.
    VIOLATION_SCHEMA = {
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
        # Present only when the field declares `message:` or the app has
        # I18n copy for the code; a violation without one keeps the bare
        # { param:, code: } shape, so this is not required.
        "message" => {
          "type" => "string",
          "description" => "Human-readable copy for this violation, when the contract or I18n supplies it"
        }
      },
      "required" => %w[param code]
    }.freeze

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
            "details" => { "type" => "array", "items" => VIOLATION_SCHEMA }
          },
          "required" => %w[message]
        }
      },
      "required" => %w[success error]
    }.freeze

    # RFC 9457 Problem Details, the shape rendered when
    # `Permittable.error_format = :problem`. `type` and `instance` are
    # URI-references; `errors` is the field-violation extension member.
    PROBLEM_SCHEMA = {
      "type" => "object",
      "properties" => {
        "type" => {
          "type" => "string", "format" => "uri-reference",
          "description" => "Problem type URI — \"about:blank\" unless the app sets Permittable.problem_base_uri"
        },
        "title" => { "type" => "string", "enum" => ["Invalid parameters", "Malformed request"] },
        "status" => { "type" => "integer", "enum" => [400, 422] },
        "detail" => { "type" => "string" },
        "instance" => { "type" => "string", "format" => "uri-reference" },
        "errors" => { "type" => "array", "items" => VIOLATION_SCHEMA }
      },
      "required" => %w[title status]
    }.freeze

    # Instance methods the concern itself adds to every including controller;
    # action_methods reports them as actions (they are public by design), but
    # they are never routed and must not be documented as endpoints. Resolved
    # lazily — at file-load time the concern's module body may not have run.
    def concern_methods
      @concern_methods ||= Permittable.public_instance_methods(false).map(&:to_s).freeze
    end

    # Shared `components` for any document referencing Permittable responses.
    #
    # Unlike a rule's monitor mode — which the exporter reads only from the
    # contract, never from runtime configuration — the error FORMAT has no
    # per-contract declaration to read: it is one app-wide setting, and an
    # export runs inside the app that made it. Reading it is what keeps the
    # documented response shape from drifting from the rendered one.
    def components
      {
        "schemas" => { "PermittableInvalidParameters" => error_schema },
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

    def problem_format?
      Permittable.error_format == :problem
    end

    # ERROR_SCHEMA/PROBLEM_SCHEMA are frozen, but `.freeze` is shallow — only
    # the top-level Hash is frozen, not the Hashes nested inside it — so
    # handing either constant out by reference let a caller mutate a nested
    # level of ITS document and permanently corrupt the shared constant for
    # every document generated for the rest of the process. `deep_dup` (the
    # same ActiveSupport helper the contract registry uses to copy authored
    # default:/example: values before freezing, see permittable.rb) gives
    # every caller its own independent copy instead.
    def error_schema
      (problem_format? ? PROBLEM_SCHEMA : ERROR_SCHEMA).deep_dup
    end

    def error_media_type
      problem_format? ? ErrorEnvelope::PROBLEM_MEDIA_TYPE : "application/json"
    end

    def error_response(description)
      {
        "description" => description,
        "content" => {
          error_media_type => {
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
      slots = []
      targets = route_targets(routes)
      # A class listed twice would find every slot its first pass claimed and
      # land under x-permittable-controllers, colliding with itself there.
      controllers.uniq(&:object_id).each do |controller|
        operations = operations_for(controller)
        next if operations.empty?

        slots.concat(place_operations(controller, operations, targets, paths, unrouted))
      end
      assign_unique_operation_ids(slots)
      doc = {
        "openapi" => "3.1.0",
        "info" => { "title" => "Permittable contracts", "version" => VERSION }.merge(info),
        "paths" => paths,
        "components" => components
      }
      doc["x-permittable-controllers"] = unrouted unless unrouted.empty?
      doc
    end

    # Where one operation sits in the document: a path+verb slot under
    # `paths`, or an action under x-permittable-controllers (verb and path
    # nil). `holder[field]` is the placed operation; `id` its natural
    # operationId; `owner` the [controller key, action] it documents.
    OperationSlot = Struct.new(:holder, :field, :verb, :id, :owner, :path)

    # { [controller, action] => [[path, verb], ...] }, in route order. Built
    # once, with each verb normalised once: matching every operation against
    # every route made placement quadratic in the size of the route set. A
    # route declared twice names one slot, so it is kept once — not counted
    # as an operation colliding with itself.
    def route_targets(routes)
      return {} if routes.nil?

      routes.group_by { |route| [route[:controller].to_s, route[:action].to_s] }
            .transform_values { |matching| matching.map { |route| [route[:path], verb_of(route)] }.uniq }
    end

    # Places every operation and returns the slots it filled, for
    # assign_unique_operation_ids, which ranks them by what they are: the
    # order they are returned in names nothing.
    def place_operations(controller, operations, targets, paths, unrouted)
      key = controller_key(controller) || controller.inspect
      operations.each_with_object([]) do |(action, operation), slots|
        owner = [key, action]
        # A path+verb pair carries exactly one operation, so a slot another
        # controller already claimed is not written over: the loser stays
        # visible under x-permittable-controllers, where an operation with no
        # route at all lands, rather than disappearing from the document.
        # rails_routes already drops a route that an unconstrained one ahead
        # of it answers (see drop_shadowed), so a claimed slot comes from a
        # route behind a constrained one, from two route lists concatenated,
        # or from hand-built descriptors.
        free = action == "*" ? [] : targets.fetch(owner, []).reject { |path, verb| paths.dig(path, verb) }
        if free.empty?
          holder = (unrouted[key] ||= {})
          slots << OperationSlot.new(holder, action, nil, operation["operationId"], owner) unless holder.key?(action)
          holder[action] = operation
        else
          free.each do |path, verb|
            holder = (paths[path] ||= {})
            holder[verb] = with_path_parameters(operation, path)
            slots << OperationSlot.new(holder, verb, verb, operation["operationId"], owner, path)
          end
        end
      end
    end

    # OpenAPI requires operationId to be unique across the document, and
    # client generators name a method after it — a duplicate is an invalid
    # document and, in practice, two methods with one name. One operation is
    # placed at every slot its routes reach: the separate PATCH and PUT
    # routes `resources` draws to update, or one `via: [:patch, :put]` route;
    # with the optional-segment expansion, one route's several paths; with
    # `via: :all` routes, which are documented under each verb, five verbs.
    # And `key.tr("/", "_")` folds admin/users and admin_users into one id.
    #
    # Renaming the scheme would rename every generated client method, so an
    # id that is already unique never changes. Every slot's natural id is
    # known before any is renamed and all of them are reserved, so a suffix
    # can never take a name that is another operation's own id — that
    # operation would otherwise be renamed for a collision it never had.
    # Within a colliding group the slot collision_order ranks first keeps the
    # plain id. Another takes its verb (users_update_put) when that verb
    # differs from the plain id's and the suffixed id is free; otherwise it
    # is numbered in rank order (posts_create_2 for a second POST,
    # users_update_2 for a second PATCH). The suffix names how the slot
    # differs from the plain one, so a verb the two share would say nothing
    # true.
    #
    # The rank is read off each slot's operation, path and verb, never off
    # the order the slots were found in, and groups are visited in id order
    # (so even a suffix two groups could both spell goes the same way every
    # time). Reordering routes.rb or loading a controller earlier therefore
    # renames nothing. What no scheme can avoid is a NEW collider: it takes a
    # suffix or, ranking ahead, takes the plain id from the slot that held
    # it, and every numbered slot ranked behind it moves along one. So
    # adding, removing or renaming a colliding route, action or controller
    # can still rename the other members of its group — never an id that
    # stands alone.
    #
    # Unrouted operations take part: x-permittable-controllers is in the same
    # document and feeds the same generators. They yield the plain id to a
    # routed operation, though, since `paths` is what a client calls.
    def assign_unique_operation_ids(slots)
      slots = slots.select(&:id)
      taken = slots.to_set(&:id)
      next_number = Hash.new(2)
      slots.group_by(&:id).sort_by(&:first).each do |_id, group|
        next if group.one?

        plain, *renamed = collision_order(group)
        renamed.each do |slot|
          by_verb = "#{slot.id}_#{slot.verb}"
          by_verb = nil if slot.verb.nil? || slot.verb == plain.verb || taken.include?(by_verb)
          unique = by_verb || numbered_id(slot.id, taken, next_number)
          taken << unique
          # The same operation object may sit at other slots under its own
          # id, so the rename goes on a copy; merge keeps the key order.
          slot.holder[slot.field] = slot.holder[slot.field].merge("operationId" => unique)
        end
      end
    end

    # The rank within one colliding group. Routed before unrouted. Then by
    # operation, its controller path and then its action compared as
    # strings, so one operation's slots stay together and admin/users#index
    # ranks ahead of admin_users#index whichever controller loaded first; a
    # PATCH in one operation does not take the plain id from a PUT in
    # another. Within one operation, the shallowest path first (fewest
    # segments, then the path as a string), so `/posts` ranks ahead of
    # `/{locale}/posts` and `/users/{id}` ahead of
    # `/orgs/{org_id}/users/{id}`. Then the verb, in VERB_RANK order, which
    # puts PATCH ahead of PUT: `match via: [:put, :patch]` lists PUT first
    # where `resources` lists PATCH first, and without it one pair of routes
    # would name the PATCH method two ways.
    #
    # Every key is a property of the slot itself, and no two slots share all
    # of them (an operation fills a path+verb slot once, and has at most one
    # unrouted entry), so the rank never falls back on the order the slots
    # arrived in. That order (controller load order, then route order) is
    # what used to decide, and why reordering routes.rb could rename a
    # generated client method.
    def collision_order(group)
      group.sort_by do |slot|
        path = slot.path.to_s
        [slot.verb ? 0 : 1, slot.owner, path.count("/"), path, verb_rank(slot.verb)]
      end
    end

    # The order rails_routes expands `via: :all` into, with PATCH moved ahead
    # of PUT (see collision_order). A verb a hand-built descriptor names
    # beyond these ranks after them, alphabetically.
    VERB_RANK = %w[get post patch put delete].freeze

    def verb_rank(verb)
      [VERB_RANK.index(verb) || VERB_RANK.length, verb.to_s]
    end

    # The next free "#{id}_n", n from 2. The counter per id means no number
    # is tried twice for one id, which keeps the pass linear.
    def numbered_id(id, taken, next_number)
      number = next_number[id]
      number += 1 while taken.include?("#{id}_#{number}")
      next_number[id] = number + 1
      "#{id}_#{number}"
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

    # Drops every descriptor for a verb and concrete path that an earlier,
    # unconstrained route already answers (rails_routes calls it last).
    # Journey sorts the routes matching a request by precedence, their
    # position in the route set, and dispatches to the first. So with
    # `get "hooks", to: "webhooks#index"` drawn ahead of
    # `match "hooks", to: "webhooks#receive", via: :all`, GET /hooks is
    # index's and receive answers only the other four verbs; drawn the other
    # way round, index is never reached at all. Describing the later route
    # anyway put a phantom `GET /hooks receive` row in the audit, and let the
    # export hand that slot to whichever of the two operations it placed
    # first. Both read their routes from rails_routes, so dropping it there
    # keeps them in agreement with each other and with Rails. A route drawn
    # twice folds into one the same way.
    #
    # Only a route that answers EVERY request for its path and verb hides
    # the ones behind it (see unconditional?). A constrained route answers
    # what its constraint lets through and passes the rest on, so with
    # `constraints(AdminConstraint) { post "settings", ... }` ahead of
    # `post "settings", to: "settings#update"`, every non-admin POST reaches
    # settings#update. The audit is a gate, and a hidden route there is a
    # false pass, so the conservative rule errs towards listing: a
    # constrained route is described as before but never drops anything,
    # even when its constraint happens to admit everything. In the export
    # both routes may then claim one slot, and the second takes the existing
    # fallback (see place_operations).
    #
    # Descriptors arrive in route order (then verb, then optional variant),
    # so the first one seen is the first route. Precedence is a property of
    # ONE route set, which is why this runs inside each rails_routes call and
    # not in the readers: an engine's routes are relative to its mount point,
    # and a list concatenated from an app's and an engine's must not let one
    # shadow the other.
    #
    # Two more limits, both towards listing more. Only identical templates
    # are compared, so templates that differ at all, even only in a
    # variable's name, are both kept. And only controller routes shadow: a
    # redirect or a Rack endpoint is not described at all, so a controller
    # route behind one on the same path is still listed.
    #
    # `shadows:` is this method's input only; it is stripped from what it
    # returns, so callers see the descriptor shape they always have.
    def drop_shadowed(descriptors)
      answered = Set.new
      descriptors.each_with_object([]) do |descriptor, kept|
        slot = descriptor.values_at(:verb, :path)
        next if answered.include?(slot)

        answered << slot if descriptor[:shadows]
        kept << descriptor.except(:shadows)
      end
    end

    # Rails's own non-greedy requirement on a glob segment (`*rest`), /.+?/
    # on 6.1 and /.+?/m from 7.0. It narrows nothing.
    GLOB_DEFAULTS = [/.+?/, /.+?/m].freeze

    # Whether a route answers its path and verb for every request, so that no
    # later route with the same template can be reached for them. Rails
    # records a constraint in one of three places on the Journey route, the
    # same on 6.1 and 8.1: a segment requirement (`id: /\d+/`, a
    # `scope "(:locale)", locale: /en|fr/`) in `path.requirements`; a request
    # constraint (subdomain, host) in `constraints`; and a constraint object
    # or lambda, inline or from a `constraints(...)` block, as an app wrapped
    # in Mapper::Constraints whose list is not empty. `defaults:` are not
    # constraints and land in none of these. The glob default is not counted
    # either (Journey::Route#requirements drops it the same way). A route
    # that cannot answer these questions, such as a hand-built duck, counts
    # as constrained: unsure, it hides nothing.
    def unconditional?(route)
      return false unless route.respond_to?(:constraints) && route.respond_to?(:app) &&
                          route.path.respond_to?(:requirements)

      wrapped = route.app.respond_to?(:constraints) ? route.app.constraints : []
      route.constraints.empty? && wrapped.empty? &&
        route.path.requirements.each_value.all? { |requirement| GLOB_DEFAULTS.include?(requirement) }
    end

    # What a `via: :all` route answers, in the "|"-joined form Journey uses
    # for a route with several verbs.
    ALL_VERBS = "GET|POST|PUT|PATCH|DELETE".freeze

    # { controller:, action:, verb:, path: } descriptors from a Rails
    # application's route set. Duck-typed against Journey routes (each one
    # responds to requirements / verb / path.spec) so it stays unit-testable
    # without Rails; Rails path params become OpenAPI templates — both the
    # `:id` form and the `*rest` wildcard, which is a real route shape
    # (`get "files/*path"`) and is not a valid OpenAPI template left as-is.
    #
    # An optional group is expanded into the concrete paths it stands for:
    # parentheses are not valid in an OpenAPI path template, so leaving
    # `scope "(:locale)"` as `(/{locale})/posts` made the whole document fail
    # validation. Each variant is its own descriptor, so each path's variables
    # are required there — which, for that path, they are.
    #
    # Each descriptor also carries `route:`, the index of the route it came
    # from, so a reader counting routes rather than paths (Audit.summary) can
    # tell one route's expanded variants from a second route that happens to
    # reach the same action. The exporter ignores it.
    #
    # A verb on a path that an earlier, unconstrained route already answers
    # is left out: Rails never dispatches it to the later route (see
    # drop_shadowed).
    def rails_routes(app)
      descriptors = app.routes.routes.each_with_index.flat_map do |route, index|
        requirements = route.requirements
        verb = route.verb.to_s
        next [] if requirements[:controller].nil? || requirements[:action].nil?

        # `match ..., via: :all` leaves the verb EMPTY rather than listing
        # them, and skipping it hid an action that takes POST bodies from the
        # audit entirely. Expand it into the verbs it actually answers.
        verb = ALL_VERBS if verb.empty?

        path = route.path.spec.to_s.sub("(.:format)", "").gsub(/[:*](\w+)/) { "{#{Regexp.last_match(1)}}" }
        # Read once per route; drop_shadowed reads it, then strips it.
        shadows = unconditional?(route)
        # One route can answer several verbs (`match via: [:patch, :put]`, and
        # the PATCH|PUT pair resources generates); documenting only the first
        # dropped the others from the export entirely.
        verb.split("|").map do |single|
          { controller: requirements[:controller], action: requirements[:action],
            verb: single.downcase, path: path, route: index, shadows: shadows }
        end
      end
      expanded = descriptors.flat_map do |descriptor|
        optional_variants(descriptor[:path]).map { |variant| descriptor.merge(path: variant) }
      end
      drop_shadowed(expanded)
    end

    # Every concrete path an optionally-grouped template stands for:
    # `/archive(/{year}(/{month}))` → `/archive`, `/archive/{year}`,
    # `/archive/{year}/{month}`. Rails fills groups left to right, so
    # `/x(/{a})(/{b})` with one segment present is always `/x/{a}` — the
    # `/x/{b}` variant is the same URL under another name, and OpenAPI forbids
    # two templates differing only in variable names. Variants are built with
    # each group present first, so the one Rails would match is the one kept;
    # the list is then reversed, which puts every group's ABSENT variant
    # first at every nesting level, the order the document lists them in.
    # The variants of one route share an operation, and it is the operationId
    # dedupe (assign_unique_operation_ids), not this expansion, that makes
    # their ids unique. It ranks the shallowest path first whatever order the
    # variants arrive in, so `/posts` keeps `posts_create` and
    # `/{locale}/posts` takes the suffix.
    def optional_variants(path)
      variants, = expand_optional_groups(path, 0)
      variants.map { |variant| variant.empty? ? "/" : variant }
              .uniq { |variant| variant.gsub(/\{\w+\}/, "{}") }
              .reverse
    end

    # Walks the template from `pos` to the matching `)` (or the end),
    # returning the variants of that stretch and the position after it.
    def expand_optional_groups(path, pos)
      variants = [+""]
      while pos < path.length
        char = path[pos]
        if char == "("
          inner, pos = expand_optional_groups(path, pos + 1)
          variants = variants.product(inner + [""]).map(&:join)
        elsif char == ")"
          return [variants, pos + 1]
        else
          variants.each { |variant| variant << char }
          pos += 1
        end
      end
      [variants, pos]
    end

    def controller_key(controller)
      return controller.controller_path if controller.respond_to?(:controller_path)

      controller.name
    end
  end
end
