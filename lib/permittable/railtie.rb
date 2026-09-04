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
      # Late-bound on purpose — see Permittable.filter_parameter_proc. This
      # initializer runs before config/initializers, so a registry swapped
      # there must still be the one consulted at filter time.
      filter = ::Permittable.filter_parameter_proc
      app.config.filter_parameters << filter unless app.config.filter_parameters.include?(filter)

      # The proc above redacts Strings, live, and survives precompilation.
      # What it cannot reach is a value that is not a String — ParameterFilter
      # mutates values in place for proc filters, and skips them entirely for
      # a Hash — so each registered name is ALSO added by name, which redacts
      # any value type. Appending later still works: precompilation `replace`s
      # this array in place and ActionDispatch reads the same object per
      # request, so a name registered when a controller loads is seen by the
      # next request. It is the array, not a snapshot, that has to be fed.
      ::Permittable.on_sensitive_parameter do |name|
        filters = app.config.filter_parameters
        filters << name unless filters.include?(name)
      end
    end

    rake_tasks do
      load File.expand_path("tasks/openapi.rake", __dir__)
      load File.expand_path("tasks/generate.rake", __dir__)
      load File.expand_path("tasks/audit.rake", __dir__)
    end
  end
end
