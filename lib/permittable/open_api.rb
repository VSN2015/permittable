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
  # controller already claimed, which a document cannot represent twice, or
  # whose route an earlier route of the same URL shape shadows — land in
  # `x-permittable-controllers` instead of being dropped silently.
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
      routes, shadows = collapse_shapes(routes)
      targets = route_targets(routes)
      # A class listed twice would find every slot its first pass claimed and
      # land under x-permittable-controllers, colliding with itself there.
      controllers.uniq(&:object_id).each do |controller|
        operations = operations_for(controller)
        next if operations.empty?

        slots.concat(place_operations(controller, operations, targets, paths, unrouted))
      end
      note_shadows(paths, shadows)
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

    # { [controller, action] => [[path, verb, template], ...] }, in route
    # order. Built once, with each verb normalised once: matching every
    # operation against every route made placement quadratic in the size of
    # the route set. A route declared twice names one slot, so it is kept
    # once — not counted as an operation colliding with itself. `template`
    # is the route's own spelling when collapse_shapes placed it under
    # another route's, nil otherwise.
    def route_targets(routes)
      return {} if routes.nil?

      routes.group_by { |route| [route[:controller].to_s, route[:action].to_s] }
            .transform_values do |matching|
              matching.map { |route| [route[:path], verb_of(route), route[:template]] }.uniq
            end
    end

    # OpenAPI forbids two path templates that differ only in their variable
    # names: `/{locale}` and `/{slug}` are one path to it. rails_routes keeps
    # one route's own variants apart, but two routes can still spell one
    # shape two ways — `scope "(:locale)"` makes it common, its root being
    # `/{locale}` and its `get ":slug"` `/{slug}` — and so can a hand-built
    # list. Routes are read in the order given, which for rails_routes is
    # the order Rails tries them, so the route Rails reaches first wins:
    #
    # - The first spelling of a shape names its path. A later route of the
    #   shape under another verb is placed there too, since Rails picks the
    #   verb before it fills a segment (`POST /foo` reaches `post ":slug"`
    #   whatever GET route comes before it). The shared path names its
    #   variables after the first route, so the later one's own spelling
    #   rides along as `template:` and is published as `x-permittable-path`.
    # - Under a verb an earlier route of the shape already answers, a later
    #   spelling is shadowed: Rails sends the URL to the earlier route, and
    #   reaches the later one only when that route's constraints reject the
    #   request (`scope "(:locale)", locale: /en|fr/` passes `/foo` on to
    #   `:slug`). It is not emitted as a second, forbidden path, nor dropped
    #   without a trace: it is listed under `x-permittable-shadows` on the
    #   slot it shares (note_shadows), and an operation left with no slot
    #   lands in x-permittable-controllers like any whose slot is taken.
    #   Every shadowed route is listed, reachable or not: request
    #   constraints and constraint objects can let a request past the
    #   earlier route, and the descriptors do not carry them.
    #
    # A second route with the SAME spelling is not a shape collision; it is
    # the slot collision place_operations already settles. Returns the
    # routes to place and { [path, verb] => shadowed routes }.
    def collapse_shapes(routes)
      return [routes, {}] if routes.nil?

      spelling = {}
      first_at = {}
      shadows = {}
      kept = routes.filter_map do |route|
        path = route[:path].to_s
        verb = verb_of(route)
        shape = path.gsub(/\{\w+\}/, "{}")
        shared = (spelling[shape] ||= path)
        listed = Array(route[:shadows]).map { |alternate| shadow_entry(route, alternate) }
        if (first_at[[shape, verb]] ||= path) == path
          (shadows[[shared, verb]] ||= []).concat(listed) unless listed.empty?
          shared == path ? route : route.merge(path: shared, template: path)
        else
          (shadows[[shared, verb]] ||= []).push(shadow_entry(route, path), *listed)
          nil
        end
      end
      [kept, shadows]
    end

    def shadow_entry(route, path)
      { "path" => path, "controller" => route[:controller].to_s, "action" => route[:action].to_s }
    end

    # Lists, on the operation at each slot, the same-shaped routes it
    # shadows (collapse_shapes) and, from rails_routes' `shadows:`, the
    # variants of its own route that a constraint keeps reachable. A slot
    # with no documented operation has nowhere to say it; the shadowed
    # operation is not moved in, because the route set still sends that URL
    # to the slot's own, undocumented route.
    def note_shadows(paths, shadows)
      shadows.each do |(path, verb), entries|
        holder = paths[path]
        next unless holder&.key?(verb)

        # The same operation object may sit at other slots, so the note goes
        # on a copy, as an operationId rename does.
        holder[verb] = holder[verb].merge("x-permittable-shadows" => entries.uniq)
      end
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
          free.each do |path, verb, template|
            holder = (paths[path] ||= {})
            placed = with_path_parameters(operation, path)
            holder[verb] = template ? placed.merge("x-permittable-path" => template) : placed
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
    # `unconditional:` is this method's input only; it is stripped from what
    # it returns, so callers see the descriptor shape they always have. (It
    # is not `shadows:`, which names the same-shaped variants a kept path
    # stands in for and does reach the exporter; see optional_variants.)
    def drop_shadowed(descriptors)
      answered = Set.new
      descriptors.each_with_object([]) do |descriptor, kept|
        slot = descriptor.values_at(:verb, :path)
        next if answered.include?(slot)

        answered << slot if descriptor[:unconditional]
        kept << descriptor.except(:unconditional)
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
    # are required there — which, for that path, they are. The variants are
    # worked out once per route, before the verb split: they are the same
    # for every verb the route answers.
    #
    # Each descriptor also carries `route:`, the index of the route it came
    # from, so a reader counting routes rather than paths (Audit.summary) can
    # tell one route's expanded variants from a second route that happens to
    # reach the same action. The exporter ignores it.
    #
    # A variant that stands in for a same-shaped variant a constraint keeps
    # reachable (see optional_variants) also carries `shadows:`, those
    # variants' paths, which the exporter lists on the operation. Most
    # routes have none, and then the key is left out.
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

        variants = optional_variants(route.path.spec, requirements)
        # Read once per route; drop_shadowed reads it, then strips it.
        unconditional = unconditional?(route)
        # One route can answer several verbs (`match via: [:patch, :put]`, and
        # the PATCH|PUT pair resources generates); documenting only the first
        # dropped the others from the export entirely. Verb by verb, then
        # variant by variant: drop_shadowed takes the first descriptor it
        # sees for a path and verb as the route Rails dispatches it to.
        verb.split("|").flat_map do |single|
          variants.map do |path, shadows|
            descriptor = { controller: requirements[:controller], action: requirements[:action],
                           verb: single.downcase, path: path, route: index, unconditional: unconditional }
            shadows.empty? ? descriptor : descriptor.merge(shadows: shadows)
          end
        end
      end
      drop_shadowed(descriptors)
    end

    # A route parameter as optional_variants reads it: a `:name` segment or a
    # `*name` wildcard (`star`), with the regexp the route constrains it to,
    # if any.
    Param = Struct.new(:name, :constraint, :star) do
      # Journey's defaults: a segment stops at "/", "." and "?"; a wildcard
      # takes anything.
      def pattern
        constraint || (star ? /.+/m : %r{[^./?]+})
      end
    end

    # Journey's separators. A parameter never spans one, so variants are
    # compared token by token between them.
    SEPARATORS = %w[/ .].freeze

    # The optional group Rails appends to every route unless told otherwise.
    FORMAT_GROUP = "(.:format)".freeze

    # Every concrete path a route stands for, each mapped to the paths of the
    # same-shaped variants it stands in for (usually none):
    # `archive(/:year(/:month))` → `/archive`, `/archive/{year}`,
    # `/archive/{year}/{month}`.
    #
    # Rails matches a URL against the route's regexp, which tries each group
    # present before absent, left to right, and binds the URL to the first
    # variant whose segments accept it. Variants are enumerated in that
    # order, and one is dropped when an earlier variant accepts every URL it
    # would (shadowed?). So `x(/:a)(/:b)` drops `/x/{b}` (`/x/foo` is :a),
    # and `x(/:a)(/new)` drops `/x/new`, which Rails reads as :a = "new".
    # Constraints count: with `a: /\d+/`, "new" fails :a, so there `/x/new`
    # is a real URL and stays.
    #
    # The same constraint makes `/x/foo` :b in `x(/:a)(/:b)`, so `/x/{b}` is
    # real beside `/x/{a}`. OpenAPI forbids two templates that differ only in
    # variable names, so the one Rails tries first is kept and the other is
    # named in its shadows rather than emitted. Distinct shapes are both
    # kept; OpenAPI allows `/x/new` beside `/x/{a}`.
    #
    # The list is then reversed, which puts every group's ABSENT variant
    # first at every nesting level, the order the document lists them in.
    # The variants of one route share an operation, and it is the operationId
    # dedupe (assign_unique_operation_ids), not this expansion, that makes
    # their ids unique. It ranks the shallowest path first whatever order the
    # variants arrive in, so `/posts` keeps `posts_create` and
    # `/{locale}/posts` takes the suffix.
    #
    # The spec is walked as the tree Journey parsed, node by node, not as its
    # string: `to_s` prints an escaped parenthesis in a literal as a bare
    # one, which a string scan then read as a group. A Journey-shaped stand-in
    # may carry a String spec instead (string_variants).
    def optional_variants(spec, requirements = {})
      variants = if spec.respond_to?(:type)
                   tree_variants(spec, requirements)
                 else
                   string_variants(spec.to_s.sub(FORMAT_GROUP, ""), requirements).first
                 end
      variants = variants.map { |tokens| join_literals(tokens) }
      # No group, no choice: nothing for one variant to shadow.
      return { render(variants.first) => [] } if variants.one?

      kept = {}
      first_of_shape = {}
      variants.each_with_index do |tokens, index|
        next if variants.take(index).any? { |earlier| shadowed?(earlier, tokens) }

        path = render(tokens)
        twin = (first_of_shape[path.gsub(/\{\w+\}/, "{}")] ||= path)
        if twin == path
          kept[path] ||= []
        else
          kept[twin] << path
        end
      end
      kept.to_a.reverse.to_h
    end

    # A Journey tree's variants, each a list of tokens: literal text and
    # Param. A group yields its contents' variants, then the empty one —
    # present before absent, as Rails' regexp tries them — except the
    # `(.:format)` group, which is left out. The node types are the same from
    # Rails 6.1 to 8.1; OR is not reachable through the routing DSL (which
    # escapes "|") but is read as its alternatives, in order.
    def tree_variants(node, requirements)
      case node.type
      when :CAT
        tree_variants(node.left, requirements).product(tree_variants(node.right, requirements))
                                              .map { |left, right| left + right }
      when :GROUP
        node.to_s == FORMAT_GROUP ? [[]] : tree_variants(node.left, requirements) + [[]]
      when :OR then node.children.flat_map { |child| tree_variants(child, requirements) }
      when :SYMBOL then [[param(node.name, false, requirements)]]
      when :STAR then [[param(node.name, true, requirements)]]
      else [[node.left.to_s]] # LITERAL, SLASH, DOT
      end
    end

    # tree_variants for a String spec, from `pos` to the `)` closing the
    # group at `depth` (or the end); returns the variants and the position
    # after them. Journey's escapes hold: `\(`, `\)` and `\:` are literal
    # text. A parenthesis with no partner raises: the old scan stopped at an
    # unmatched `)` and returned what it had read, so `/un)matched` was
    # documented as `/un` without a word.
    def string_variants(spec, requirements, pos = 0, depth = 0)
      variants = [[]]
      while pos < spec.length
        case (char = spec[pos])
        when "("
          inner, pos = string_variants(spec, requirements, pos + 1, depth + 1)
          variants = variants.product(inner + [[]]).map { |left, right| left + right }
          next
        when ")"
          raise ArgumentError, "unbalanced \")\" in route path #{spec.inspect}" if depth.zero?

          return [variants, pos + 1]
        when "\\"
          pos += 1
          token = spec[pos].to_s
        when ":", "*"
          name = spec[(pos + 1)..][/\A\w+/]
          token = name ? param(name, char == "*", requirements) : char
          pos += name.length if name
        else
          token = char
        end
        variants.each { |variant| variant << token }
        pos += 1
      end
      raise ArgumentError, "unbalanced \"(\" in route path #{spec.inspect}" unless depth.zero?

      [variants, pos]
    end

    def param(name, star, requirements)
      constraint = requirements[name.to_sym]
      Param.new(name, constraint.is_a?(Regexp) ? constraint : nil, star)
    end

    # Adjacent literal text joined into one token per run between
    # separators, so two variants line up token by token whichever nodes or
    # characters their text came from.
    def join_literals(tokens)
      tokens.each_with_object([]) do |token, joined|
        next if token == ""

        if [token, joined.last].all? { |text| text.is_a?(String) && !SEPARATORS.include?(text) }
          joined[-1] = joined.last + token
        else
          joined << token
        end
      end
    end

    def render(tokens)
      path = tokens.map { |token| token.is_a?(Param) ? "{#{token.name}}" : token }.join
      path.empty? ? "/" : path
    end

    # Whether Rails, trying `earlier` first, leaves `later` no URL: wherever
    # `later` has a token, `earlier` accepts everything it does. Text must be
    # equal; a parameter accepts text its pattern matches whole, and another
    # parameter when it is itself unconstrained (a segment never takes a
    # wildcard's slashes) or constrained by the same regexp. Two different
    # constraints are taken to leave `later` reachable, which keeps a
    # variant rather than dropping a real one.
    def shadowed?(earlier, later)
      earlier.length == later.length && earlier.zip(later).all? { |mine, theirs| accepts?(mine, theirs) }
    end

    def accepts?(mine, theirs)
      return mine == theirs unless mine.is_a?(Param)

      pattern = mine.pattern
      return Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options).match?(theirs) if theirs.is_a?(String)
      return mine.constraint == theirs.constraint if mine.constraint

      mine.star || !theirs.star
    end

    def controller_key(controller)
      return controller.controller_path if controller.respond_to?(:controller_path)

      controller.name
    end
  end
end
