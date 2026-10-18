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
      #
      # ActiveRecord is a second sink, and a snapshot that never sees a name
      # registered after it loaded. Its `filter_attributes` is copied from
      # config.filter_parameters exactly once, when ActiveRecord::Base loads,
      # and in a real app that is BEFORE any controller registers anything: the
      # first controller's own `model: Person` loads it. So the copy holds only
      # the proc above, which cannot redact an Integer in the SQL bind log
      # (`[["pin_code", 4321]]`, where #inspect, handed an already-inspected
      # String, was fine). Each name is therefore also fed to the model base
      # class directly. on_load runs the block at once when ActiveRecord is
      # already loaded, defers it until it loads, and never fires in an app
      # without it. The setter drops the memoized inspection filter, and the
      # include? keeps the list at one entry per name however often a reloaded
      # controller registers it. A name is handed to on_load once: in an app
      # where ActiveRecord never loads, each hook would otherwise queue
      # forever, one per registration, across every code reload.
      hooked = {}
      hooked_lock = Mutex.new
      ::Permittable.on_sensitive_parameter do |name|
        filters = app.config.filter_parameters
        filters << name unless filters.include?(name)

        next unless hooked_lock.synchronize { hooked.key?(name) ? false : (hooked[name] = true) }

        ::ActiveSupport.on_load(:active_record) do
          self.filter_attributes += [name] unless filter_attributes.include?(name)
        end
      end
    end

    rake_tasks do
      load File.expand_path("tasks/openapi.rake", __dir__)
      load File.expand_path("tasks/generate.rake", __dir__)
      load File.expand_path("tasks/audit.rake", __dir__)
    end
  end
end
