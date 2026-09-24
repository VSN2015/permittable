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
  # produces, plus the optional `route:` it tags each one with), so it is
  # unit-testable without Rails. Unlike the exporter it
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
    #
    # `route` identifies the route the path came from (nil for a hand-built
    # descriptor, which is then its own route); see `summary`.
    Entry = Struct.new(:controller, :action, :verb, :path, :rule, :route, keyword_init: true) do
      def covered?
        !rule.nil?
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
      routes.select { |route| route[:controller].to_s == key }.map do |route|
        action = route[:action].to_s
        Entry.new(controller: key, action: action, verb: route[:verb], path: route[:path],
                  rule: rule_for(controller, action), route: route[:route])
      end
    end

    def rule_for(controller, action)
      controller.respond_to?(:permit_rule_for) ? controller.permit_rule_for(action) : nil
    end

    # { controller => [action, ...] } for contracts declared against actions
    # no route reaches — a renamed or deleted action leaving its contract
    # behind. Catch-all rules declare no actions, so they never appear here.
    def stale(controllers:, routes:)
      routes = routes.to_a
      controllers.each_with_object({}) do |controller, found|
        next unless controller.respond_to?(:permittable_contracts)

        key = OpenAPI.controller_key(controller) || controller.inspect
        routed = routes.select { |route| route[:controller].to_s == key }.map { |route| route[:action].to_s }
        declared = controller.permittable_contracts.flat_map { |rule| rule[:actions] }.uniq
        missing = declared - routed
        found[key] = missing unless missing.empty?
      end
    end

    # The numbers worth putting in a CI log. `uncovered_with_body` is the one
    # that should be zero; `unguarded_models` counts covered actions whose
    # rule declares no `model:`, so no schema-drift guard runs for them.
    #
    # Counted per route and verb rather than per row: `scope "(:locale)"`
    # expands one route into two paths, both listed in the table, and one
    # unguarded POST must not count as two. Only a route's OWN variants
    # collapse — `post "/users"` and `post "/admin/users"` are two ways into
    # users#create, two gaps if neither is covered, and `[strict]` must see
    # both.
    def summary(entries)
      entries = routed(entries)
      {
        actions: entries.length,
        enforced: entries.count { |e| e.mode == :enforce },
        monitored: entries.count { |e| e.mode == :monitor },
        uncovered: entries.count { |e| !e.covered? },
        uncovered_with_body: entries.count { |e| !e.covered? && e.body? },
        unguarded_models: entries.count { |e| e.covered? && e.model.nil? }
      }
    end

    # One entry per route and verb, in the entries' own order. `route` is a
    # position within ONE rails_routes call, so it is keyed with the
    # controller and action: an app's list concatenated with an engine's
    # reuses the same small integers for unrelated routes. An entry with no
    # `route` (a hand-built descriptor) is its own route.
    def routed(entries)
      entries.uniq { |e| e.route.nil? ? e.object_id : [e.controller, e.action, e.route, e.verb.to_s.downcase] }
    end

    # The human-readable report: one block per controller, then the summary,
    # then anything stale.
    def format(entries, stale: {})
      return "Permittable audit: no routed actions to report.\n" if entries.empty?

      out = entries.group_by(&:controller).map { |key, group| controller_block(key, group) }
      out << summary_lines(summary(entries), rows: entries.length)
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
    # unvalidated input, not just a gap in the table).
    def status(entry)
      return "no contract#{' — ACCEPTS A BODY' if entry.body?}" unless entry.covered?

      parts = [entry.mode.to_s]
      parts << "model: #{entry.model.name}" if entry.model.respond_to?(:name) && entry.model.name
      parts << "unknown: #{entry.unknown}" unless entry.unknown == :ignore
      parts.join("  ")
    end

    # The table lists rows (a verb on a path) and the summary counts routes;
    # when the two numbers differ, the line gives both and names each. Rows,
    # not distinct paths: PATCH and PUT on one path are two rows. It does not
    # say WHY they differ: an optional segment's variants are the usual
    # reason, but two concatenated route lists sharing a controller, action
    # and index collapse the same way.
    def summary_lines(counts, rows: counts[:actions])
      body = counts[:uncovered_with_body]
      listed = " in #{rows} rows" unless rows == counts[:actions]
      [
        "",
        "#{counts[:actions]} routed action#{'s' unless counts[:actions] == 1}#{listed}: " \
        "#{counts[:enforced]} enforced, #{counts[:monitored]} in monitor mode, " \
        "#{counts[:uncovered]} without a contract",
        "  #{body} of those accept a request body#{' — untrusted input reaches the action unchecked' unless body.zero?}",
        "  #{counts[:unguarded_models]} covered action#{'s' unless counts[:unguarded_models] == 1} " \
        "declare no model:, so no schema-drift guard runs for them"
      ].join("\n")
    end

    def stale_lines(stale)
      pairs = stale.flat_map { |key, actions| actions.map { |action| "#{key}##{action}" } }
      "\nContracts declared for actions no route reaches (renamed or deleted?):\n" \
        "#{pairs.map { |pair| "  #{pair}" }.join("\n")}"
    end
  end
end
