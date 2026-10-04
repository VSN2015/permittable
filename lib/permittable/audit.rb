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
  # What is not the app's to guard — ActiveStorage's direct uploads, a
  # catch-all 404 — is left out with Permittable.audit_ignore, and every
  # controller whose source is outside Rails.root is left out by default.
  # Either way it leaves the counts and [strict], never the report.
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

    # Why an entry is left out of the counts, keyed as Entry#ignored holds it,
    # with the heading its section of the report carries. Listed in this
    # order: what the app chose to ignore first, then what it got by default.
    IGNORE_REASONS = {
      configured: "Ignored by Permittable.audit_ignore (left out of the counts above):",
      outside_root: "Ignored as outside the app root (set Permittable.audit_ignore_outside_root = false to audit them):"
    }.freeze

    # One routed action, paired with the rule a request for it would resolve
    # through (nil when nothing covers it — including when the controller
    # never included the concern, which is exactly the case worth finding).
    #
    # `missing_action` marks a route to an action the controller does not
    # define — see Audit.missing_action?. `route` identifies the route the
    # path came from (nil for a hand-built descriptor, which is then its own
    # route); see `summary`. `ignored` is why the entry is left out of the
    # counts — a key of IGNORE_REASONS — or nil when it is audited.
    Entry = Struct.new(:controller, :action, :verb, :path, :rule, :missing_action, :route, :ignored,
                       keyword_init: true) do
      def covered?
        !rule.nil?
      end

      def missing_action?
        missing_action == true
      end

      def ignored?
        !ignored.nil?
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
    #
    # Ignored actions are returned too, marked with why (Entry#ignored):
    # `ignore:` is the Permittable.audit_ignore list, and `root:` the app
    # root a controller's source must be inside (see app_root; nil ignores
    # nothing on that ground). Both default to the app's own configuration,
    # as `mode` does.
    def entries(controllers:, routes:, ignore: Permittable.audit_ignore, root: app_root)
      routes = routes.to_a
      controllers.flat_map { |controller| controller_entries(controller, routes, ignore: ignore, root: root) }
                 .sort_by { |entry| [entry.controller, entry.path, entry.verb.to_s] }
    end

    # The app's own choice outranks the default: a controller that is both
    # configured and outside the root is reported as configured, so its entry
    # counts as matched (see unmatched_ignores) — the README's own example
    # names ActiveStorage, which the default already covers. The location is
    # looked up once per controller, not once per route.
    def controller_entries(controller, routes, ignore: Permittable.audit_ignore, root: app_root)
      key = OpenAPI.controller_key(controller) || controller.inspect
      missing = missing_lookup(controller)
      outside = :outside_root if outside_root?(controller, root)
      routes.select { |route| route[:controller].to_s == key }.map do |route|
        action = route[:action].to_s
        Entry.new(controller: key, action: action, verb: route[:verb], path: route[:path],
                  rule: rule_for(controller, action), missing_action: missing[action],
                  route: route[:route], ignored: configured_ignore(key, action, ignore) || outside)
      end
    end

    # Why `controller` — or one of its actions — is left out of the audit and
    # of permittable:generate: :configured (Permittable.audit_ignore names the
    # controller, or "controller#action"), :outside_root, or nil. The
    # generator asks per action; see Generator.targets.
    def ignore_reason(controller, action = nil, ignore: Permittable.audit_ignore, root: app_root)
      key = OpenAPI.controller_key(controller) || controller.inspect
      configured_ignore(key, action, ignore) || (:outside_root if outside_root?(controller, root))
    end

    def configured_ignore(key, action, ignore)
      :configured if ignore.include?(key) || (action && ignore.include?("#{key}##{action}"))
    end

    # The ignore entries no routed action answers to — a controller that is
    # not routed, an action it does not route, or a typo of either. Ignored
    # entries count as matches: the question is whether the entry names
    # something, not whether it was the only reason that something was
    # ignored.
    def unmatched_ignores(entries, ignore: Permittable.audit_ignore)
      ignore.reject do |item|
        key, action = item.split("#", 2)
        entries.any? { |entry| entry.controller == key && (action.nil? || entry.action == action) }
      end
    end

    # The root a controller's source must be inside to be audited:
    # Rails.root, unless Permittable.audit_ignore_outside_root is off — or nil
    # without Rails, where there is no app to be outside of.
    def app_root
      return nil unless Permittable.audit_ignore_outside_root
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:root)

      ::Rails.root&.to_s
    end

    # Whether `controller` is an engine's or a gem's rather than the app's:
    # its source is outside `root`, or inside a directory gems are installed
    # in — `bundle config path vendor/bundle`, which CI caches and Docker
    # images commonly use, puts every gem inside the app's root, and
    # ActiveStorage's controller is no more the app's for being there. A gem
    # directory that holds the root itself (a GEM_HOME set to the app, or to
    # a parent of it) says nothing about which side a file is on, so it is
    # not consulted — otherwise every app controller would read as a gem's
    # and [strict] would pass on nothing. A controller that cannot be located
    # is audited: for a gate, a false alarm beats a missed endpoint.
    def outside_root?(controller, root)
      return false if root.nil?

      path = source_path(controller)
      return false if path.nil?

      !within?(path, root) || Gem.path.any? { |dir| within?(path, dir) && !within?(root, dir) }
    end

    # Where `controller` is defined: its constant's own definition (the
    # `class` line — reopening a gem's controller in app/ does not move it),
    # or, for a class whose constant cannot be found, the first of its own
    # methods that has a location. nil when neither says.
    #
    # A constant that is registered for autoload but not loaded reports the
    # `autoload` call instead — never the case here, since only loaded
    # classes have descendants to audit.
    def source_path(controller)
      name = controller.name if controller.respond_to?(:name)
      located = begin
        # [] for a constant defined in C, so `first` is nil there too.
        Object.const_source_location(name)&.first if name.is_a?(String) && !name.empty?
      rescue NameError
        nil
      end
      located || method_source_path(controller)
    end

    def method_source_path(controller)
      return nil unless controller.is_a?(Module)

      methods = controller.instance_methods(false) + controller.private_instance_methods(false)
      methods.lazy.filter_map { |name| controller.instance_method(name).source_location&.first }.first
    end

    # Whether `path` is `dir` or inside it, compared both as written and with
    # symlinks resolved: Rails.root is a realpath, and on macOS a tmpdir under
    # /var is really under /private/var — either side alone can disagree with
    # the other, and an app controller misread as outside the root would drop
    # out of [strict]. A form that cannot be resolved (a path that does not
    # exist) is compared as written only.
    def within?(path, dir)
      [[File.expand_path(path), File.expand_path(dir)], [realpath(path), realpath(dir)]].any? do |file, base|
        file && base && (file == base || file.start_with?(File.join(base, "")))
      end
    end

    def realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
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
    #
    # Counted per route and verb rather than per row: `scope "(:locale)"`
    # expands one route into two paths, both listed in the table, and one
    # unguarded POST must not count as two. Only a route's OWN variants
    # collapse — `post "/users"` and `post "/admin/users"` are two ways into
    # users#create, two gaps if neither is covered, and `[strict]` must see
    # both.
    #
    # An action the controller does not define takes no body, and a contract
    # left on one guards nothing, so it is counted as `missing_actions` and in
    # no other bucket — the buckets stay disjoint and still add up to `actions`.
    #
    # An ignored entry (Entry#ignored) is in none of the counts, so it never
    # fails [strict]; `format` lists it in a section of its own instead.
    def summary(entries)
      entries = routed(entries.reject(&:ignored?))
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

    # One entry per route and verb, in the entries' own order. `route` is a
    # position within ONE rails_routes call, so it is keyed with the
    # controller and action: an app's list concatenated with an engine's
    # reuses the same small integers for unrelated routes. An entry with no
    # `route` (a hand-built descriptor) is its own route.
    def routed(entries)
      entries.uniq { |e| e.route.nil? ? e.object_id : [e.controller, e.action, e.route, e.verb.to_s.downcase] }
    end

    # The human-readable report: one block per controller, then the summary,
    # then anything stale. The table and the summary cover the audited
    # entries; what was ignored follows in sections of its own, then any
    # ignore entry that matched nothing — `unmatched` defaults to checking
    # Permittable.audit_ignore, the list `entries` defaults to.
    def format(entries, stale: {}, unmatched: unmatched_ignores(entries))
      return "Permittable audit: no routed actions to report.\n" if entries.empty?

      ignored, entries = entries.partition(&:ignored?)
      out = entries.group_by(&:controller).map { |key, group| controller_block(key, group) }
      out << summary_lines(summary(entries), rows: entries.length)
      out << stale_lines(stale) unless stale.empty?
      out << ignored_lines(ignored) unless ignored.empty?
      out << unmatched_lines(unmatched) unless unmatched.empty?
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

    # The table lists rows (a verb on a path) and the summary counts routes;
    # when the two numbers differ, the line gives both and names each. Rows,
    # not distinct paths: PATCH and PUT on one path are two rows. It does not
    # say WHY they differ: an optional segment's variants are the usual
    # reason, but two concatenated route lists sharing a controller, action
    # and index collapse the same way.
    def summary_lines(counts, rows: counts[:actions])
      body = counts[:uncovered_with_body]
      missing = counts[:missing_actions]
      # Its own bucket, so the head line still adds up to the route count.
      not_found = ", #{missing} not found (Rails 404s #{missing == 1 ? 'it' : 'them'})" unless missing.zero?
      listed = " in #{rows} rows" unless rows == counts[:actions]
      [
        "",
        "#{counts[:actions]} routed action#{'s' unless counts[:actions] == 1}#{listed}: " \
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

    # One section per reason, in IGNORE_REASONS order, and one line per
    # controller#action with every verb it is routed on: a `via: :all`
    # catch-all is one line rather than five rows, so what was left out stays
    # visible without crowding the table it was left out of.
    def ignored_lines(ignored)
      IGNORE_REASONS.filter_map do |reason, heading|
        group = ignored.select { |entry| entry.ignored == reason }
        next if group.empty?

        verbs = group.group_by { |entry| "#{entry.controller}##{entry.action}" }
                     .transform_values { |list| list.map { |entry| entry.verb.to_s.upcase }.uniq.join(", ") }
        width = verbs.keys.map(&:length).max
        "\n#{heading}\n#{verbs.map { |pair, list| "  #{pair.ljust(width)}  #{list}" }.join("\n")}"
      end.join("\n")
    end

    def unmatched_lines(unmatched)
      "\nPermittable.audit_ignore entries that match no routed action (a typo, or a route since removed?):\n" \
        "#{unmatched.map { |item| "  #{item}" }.join("\n")}"
    end
  end
end
