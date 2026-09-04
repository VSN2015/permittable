# Reports contract coverage across the whole route set: which routed actions
# validate their input, in which mode, guarded by which model — and which do
# not. The gap that matters is a POST/PUT/PATCH action with no contract, where
# untrusted input reaches the action unchecked.
#
#   bin/rails permittable:audit           # the table plus a summary
#   bin/rails "permittable:audit[strict]" # ...and exit 1 on any unguarded
#                                         #    write action, as a CI gate
namespace :permittable do
  desc "Report contract coverage across the route set (pass [strict] to fail on unguarded write actions)"
  task :audit, [:strict] => :environment do |_t, task_args|
    Rails.application.eager_load!

    bases = []
    bases << ActionController::Base if defined?(ActionController::Base)
    bases << ActionController::API if defined?(ActionController::API)
    # Every controller, not just the ones including Permittable — a controller
    # that never included it is unguarded, which is exactly the finding.
    controllers = bases.flat_map(&:descendants).uniq.select(&:name)
    routes = Permittable::OpenAPI.rails_routes(Rails.application)

    entries = Permittable::Audit.entries(controllers: controllers, routes: routes)
    stale = Permittable::Audit.stale(controllers: controllers, routes: routes)
    print Permittable::Audit.format(entries, stale: stale)

    next unless task_args[:strict]

    gap = Permittable::Audit.summary(entries)[:uncovered_with_body]
    next if gap.zero?

    abort "\nPermittable: #{gap} routed action#{'s' unless gap == 1} " \
          "accept#{'s' if gap == 1} a request body with no contract covering it."
  end
end
