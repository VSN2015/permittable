# Exports every Permittable contract in the app as an OpenAPI 3.1 document —
# the docs-that-cannot-drift counterpart to the schema-drift guard. Eager
# loading makes every controller's permit_params macro run (also exercising
# the drift guard), then the route set maps documented actions onto paths.
#
#   bin/rails permittable:openapi                       # JSON to stdout
#   bin/rails "permittable:openapi[openapi/api.json]"   # write to a file
#
# OPENAPI_TITLE / OPENAPI_VERSION override the document's info block.
require "json"
require "fileutils"

namespace :permittable do
  desc "Export an OpenAPI 3.1 document generated from every Permittable contract"
  task :openapi, [:output] => :environment do |_t, task_args|
    Rails.application.eager_load!

    bases = []
    bases << ActionController::Base if defined?(ActionController::Base)
    bases << ActionController::API if defined?(ActionController::API)
    controllers = bases.flat_map(&:descendants).uniq.select do |controller|
      controller.respond_to?(:permittable_contracts) && controller.permittable_contracts.any?
    end

    document = Permittable::OpenAPI.document(
      controllers: controllers,
      routes: Permittable::OpenAPI.rails_routes(Rails.application),
      info: {
        "title" => ENV.fetch("OPENAPI_TITLE") { "#{Rails.application.class.module_parent_name} API" },
        "version" => ENV.fetch("OPENAPI_VERSION", "1.0.0")
      }
    )

    json = "#{JSON.pretty_generate(document)}\n"
    if task_args[:output]
      FileUtils.mkdir_p(File.dirname(task_args[:output]))
      File.write(task_args[:output], json)
      puts "Permittable: wrote #{task_args[:output]} " \
           "(#{controllers.length} controller#{'s' unless controllers.length == 1})"
    else
      puts json
    end
  end
end
