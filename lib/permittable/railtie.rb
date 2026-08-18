require "rails/railtie"

module Permittable
  # Boot-time integration, loaded only when Rails is present (see the
  # conditional require at the bottom of lib/permittable.rb): appends the
  # live-registry filter proc before ActiveRecord copies
  # `config.filter_parameters` into `filter_attributes` (a `+=` snapshot), so
  # `sensitive: true` params are redacted from both request logs and #inspect.
  class Railtie < Rails::Railtie
    initializer "permittable.filter_parameters",
                before: "active_record.set_filter_attributes" do |app|
      filter = ::Permittable.filter_parameter_registry.to_proc
      app.config.filter_parameters << filter unless app.config.filter_parameters.include?(filter)
    end

    rake_tasks do
      load File.expand_path("tasks/openapi.rake", __dir__)
    end
  end
end
