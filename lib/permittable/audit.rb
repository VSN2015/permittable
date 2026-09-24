require "permittable/open_api"

module Permittable
  # Contract COVERAGE — the fourth reader of the registry, and the one that
  # answers a question none of the others can: what is *not* covered?
  #
  # A controller declaring `permit_params :create` looks adopted. If it also
  # answers PATCH, that action is validating nothing, and nothing in the gem
  # said so — the generator only notices controllers with no contract at all,
  # and the OpenAPI exporter documents what exists rather than what is
  # missing. The audit crosses the registry with the ROUTE SET, so a
  # half-covered controller is as visible as an uncovered one.
  #
  #   bin/rails permittable:audit           # the table, plus a summary
  #   bin/rails permittable:audit[strict]   # ...and exit 1 if a write action
  #                                         #    is unguarded (a CI gate)
  #
  # Plain Ruby over the frozen registry and a list of route descriptors (the
  # same `{ controller:, action:, verb:, path: }` shape OpenAPI.rails_routes
  # produces), so it is unit-testable without Rails. Unlike the exporter it
  # reports the EFFECTIVE mode: an audit runs inside the app that sets
  # `Permittable.mode`, so it can resolve what the exporter deliberately
  # cannot.
  module Audit
    module_function

    # Verbs that carry a request body — the ones where "no contract" means
    # untrusted input reaching the action unchecked. A GET without a contract
    # is usually fine; a POST without one is the finding.
    BODY_VERBS = %w[post put patch].freeze

    # One routed action, paired with the rule a request for it would resolve
    # through (nil when nothing covers it — including when the controller
    # never included the concern, which is exactly the case worth finding).
    # `missing_action` marks a route to an action the controller does not
    # define — see Audit.missing_action?.
    Entry = Struct.new(:controller, :action, :verb, :path, :rule, :missing_action, keyword_init: true) do
      def covered?
        !rule.nil?
      end

      def missing_action?
        missing_action == true
      end

      # The mode this action would actually run in, rule-level declaration
      # first and the app-wide default behind it.
      def mode
        rule && (rule[:mode] || Permittable.mode)
      end

      def model
        rule && rule[:model]
      end

      def unknown
        rule && rule[:unknown]
      end

      def body?
        BODY_VERBS.include?(verb.to_s.downcase)
      end
    end

    # Every routed action of every given controller, sorted for stable output.
    # Pass ALL controllers, not just the ones including Permittable — a
    # controller that never included it is unguarded, which is the point.
    def entries(controllers:, routes:)
      routes = routes.to_a
      controllers.flat_map { |controller| controller_entries(controller, routes) }
                 .sort_by { |entry| [entry.controller, entry.path, entry.verb.to_s] }
    end

    def controller_entries(controller, routes)
      key = OpenAPI.controller_key(controller) || controller.inspect
      missing = missing_lookup(controller)
      routes.select { |route| route[:controller].to_s == key }.map do |route|
        action = route[:action].to_s
        Entry.new(controller: key, action: action, verb: route[:verb], path: route[:path],
                  rule: rule_for(controller, action), missing_action: missing[action])
      end
    end

    # action => missing?, answered once per action: a `via: :all` route is
    # five entries for one action, and each resolver call builds a controller.
    # The action list is read once per controller, not once per route.
    def missing_lookup(controller)
      listed = listed_actions(controller)
      Hash.new { |memo, action| memo[action] = missing_action?(controller, action, listed) }
    end

    # Normalised like OpenAPI.documented_actions: a duck listing Symbols would
    # otherwise be missing every action, and strict would pass everything.
    # nil when the controller cannot list its actions.
    def listed_actions(controller)
      controller.action_methods.to_set(&:to_s) if controller.respond_to?(:action_methods)
    end

    # `resources :posts` routes all seven actions whether or not the
    # controller defines them, and Rails 404s the ones it does not — so an
    # undefined `create` is no unguarded input, and failing a strict run over
    # it was a false positive. Labelled rather than dropped, so the reader
    # still sees the route. A controller that cannot list its actions is
    # assumed to have them all.
    def missing_action?(controller, action, listed = listed_actions(controller))
      return false if listed.nil? || listed.include?(action)

      !dispatchable?(controller, action)
    end

    # action_methods is not all Rails dispatches: an `action_missing` handler
    # takes every unlisted action, and ImplicitRender renders a template with
    # no method behind it — both with the body parsed, so both are input.
    # Rather than re-derive that, ask Rails's own resolver: method_for_action
    # is nil exactly when dispatch would raise ActionNotFound (the same
    # private method, unchanged from 6.1 to 8.1). It needs no request. A
    # plain-Ruby duck has no resolver, so its action list is the answer; a
    # resolver that raises is inconclusive, so assume the action exists: for
    # a gate, a false alarm beats a missed endpoint.
    def dispatchable?(controller, action)
      return false unless controller.is_a?(Class) &&
                          (controller.method_defined?(:method_for_action) ||
                           controller.private_method_defined?(:method_for_action))

      begin
        !controller.new.send(:method_for_action, action).nil?
      rescue StandardError
        true
      end
    end

    def rule_for(controller, action)
      controller.respond_to?(:permit_rule_for) ? controller.permit_rule_for(action) : nil
    end

    # { controller => [action, ...] } for contracts declared against actions
    # no route reaches, or that a route reaches but Rails would 404 — either
    # way a renamed or deleted action leaving its contract behind. The second
    # kind is in no summary bucket, so without this it would vanish from the
    # report's conclusions. Catch-all rules declare no actions, so they never
    # appear here.
    def stale(controllers:, routes:)
      routes = routes.to_a
      controllers.each_with_object({}) do |controller, found|
        next unless controller.respond_to?(:permittable_contracts)

        key = OpenAPI.controller_key(controller) || controller.inspect
        routed = routes.select { |route| route[:controller].to_s == key }.map { |route| route[:action].to_s }
        declared = controller.permittable_contracts.flat_map { |rule| rule[:actions] }.uniq
        missing = missing_lookup(controller)
        left = declared.select { |action| !routed.include?(action) || missing[action] }
        found[key] = left unless left.empty?
      end
    end

    # The numbers worth putting in a CI log. `uncovered_with_body` is the one
    # that should be zero; `unguarded_models` counts covered actions whose
    # rule declares no `model:`, so no schema-drift guard runs for them.
    # An action the controller does not define takes no body, and a contract
    # left on one guards nothing, so it is counted as `missing_actions` and in
    # no other bucket — the buckets stay disjoint and still add up to `actions`.
    def summary(entries)
      found, missing = entries.partition { |e| !e.missing_action? }
      {
        actions: entries.length,
        enforced: found.count { |e| e.mode == :enforce },
        monitored: found.count { |e| e.mode == :monitor },
        uncovered: found.count { |e| !e.covered? },
        uncovered_with_body: found.count { |e| !e.covered? && e.body? },
        unguarded_models: found.count { |e| e.covered? && e.model.nil? },
        missing_actions: missing.length
      }
    end

    # The human-readable report: one block per controller, then the summary,
    # then anything stale.
    def format(entries, stale: {})
      return "Permittable audit: no routed actions to report.\n" if entries.empty?

      out = entries.group_by(&:controller).map { |key, group| controller_block(key, group) }
      out << summary_lines(summary(entries))
      out << stale_lines(stale) unless stale.empty?
      "#{out.join("\n")}\n"
    end

    def controller_block(key, group)
      rows = group.map do |entry|
        "  #{entry.verb.to_s.upcase.ljust(6)} #{entry.path.ljust(34)} #{entry.action.ljust(12)} #{status(entry)}"
      end
      "#{key}\n#{rows.join("\n")}"
    end

    # A covered action reads as its effective mode; an uncovered one says so,
    # and says whether that matters (a body-carrying verb with no contract is
    # unvalidated input, not just a gap in the table). A route to an action
    # the controller does not define says that instead of claiming a body.
    def status(entry)
      return ["no contract", uncovered_note(entry)].compact.join(" — ") unless entry.covered?

      parts = [entry.mode.to_s]
      parts << "model: #{entry.model.name}" if entry.model.respond_to?(:name) && entry.model.name
      parts << "unknown: #{entry.unknown}" unless entry.unknown == :ignore
      parts << not_found_note(entry)
      parts.compact.join("  ")
    end

    def uncovered_note(entry)
      not_found_note(entry) || ("ACCEPTS A BODY" if entry.body?)
    end

    # The one wording for a route Rails would 404, covered or not.
    def not_found_note(entry)
      "action not found" if entry.missing_action?
    end

    def summary_lines(counts)
      body = counts[:uncovered_with_body]
      missing = counts[:missing_actions]
      # Its own bucket, so the head line still adds up to the route count.
      not_found = ", #{missing} not found (Rails 404s #{missing == 1 ? 'it' : 'them'})" unless missing.zero?
      [
        "",
        "#{counts[:actions]} routed action#{'s' unless counts[:actions] == 1}: " \
        "#{counts[:enforced]} enforced, #{counts[:monitored]} in monitor mode, " \
        "#{counts[:uncovered]} without a contract#{not_found}",
        "  #{body} of those accept a request body#{' — untrusted input reaches the action unchecked' unless body.zero?}",
        "  #{counts[:unguarded_models]} covered action#{'s' unless counts[:unguarded_models] == 1} " \
        "declare no model:, so no schema-drift guard runs for them"
      ].join("\n")
    end

    def stale_lines(stale)
      pairs = stale.flat_map { |key, actions| actions.map { |action| "#{key}##{action}" } }
      "\nContracts declared for actions no route reaches or Rails would 404 (renamed or deleted?):\n" \
        "#{pairs.map { |pair| "  #{pair}" }.join("\n")}"
    end
  end
end
