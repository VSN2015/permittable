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
      # ActiveRecord is a second sink: see FilterAttributesFeed, which also
      # explains why it is fed here and installed by the initializer below.
      feed = filter_attributes_feed
      ::Permittable.on_sensitive_parameter do |name|
        filters = app.config.filter_parameters
        filters << name unless filters.include?(name)
        feed.add(name)
      end
    end

    # AFTER ActiveRecord's own hook, not before: both run when ActiveRecord::Base
    # loads, in the order they were registered, and that one does
    # `filter_attributes += config.filter_parameters`. Running first, the feed
    # would add each name and that copy would add it again as a String (it holds
    # Strings whenever precompile_filter_parameters is off, as on Rails 6.1).
    initializer "permittable.filter_attributes",
                after: "active_record.set_filter_attributes" do
      feed = filter_attributes_feed
      ::ActiveSupport.on_load(:active_record) { feed.attach(self) }
    end

    # The second sink for sensitive names: ActiveRecord::Base.filter_attributes.
    #
    # It is a snapshot that never sees a name registered after it loaded. Its
    # `filter_attributes` is copied from config.filter_parameters exactly once,
    # when ActiveRecord::Base loads, and in a real app that is BEFORE any
    # controller registers anything: the first controller's own `model: Person`
    # loads it. So the copy holds only the proc the initializer appended, which
    # cannot redact an Integer in the SQL bind log (`[["pin_code", 4321]]`, where
    # #inspect, handed an already-inspected String, was fine). Each name is
    # therefore also fed to the model base class directly. The setter drops the
    # memoized inspection filter, and only names that are missing are added, so
    # the list holds one entry per name however often a reloaded controller
    # registers it.
    #
    # An app that ASSIGNS `filter_attributes = [...]` (an initializer, or a
    # to_prepare block, which runs on every reload) rather than appending to it
    # discards everything fed in so far, and a name that was registered only once
    # would never come back. So every registration restores EVERY name registered
    # so far that is missing, not just its own: the next contract to load, or the
    # next reload re-declaring one, heals the list. (A to_prepare of the gem's own
    # would not help: railtie blocks run before the app's, so the app's
    # assignment would still come last.)
    #
    # The read-modify-write is done under a lock, as two threads loading
    # contracts at once would otherwise each write back a list that lacks the
    # other's name. Nothing inside the lock calls back into the sink or loads
    # ActiveRecord, so it cannot deadlock.
    #
    # ActiveRecord is hooked ONCE for the process, in #attach, rather than once
    # per name: on_load runs the block at once when ActiveRecord is already
    # loaded, waits for it otherwise, and never fires in an app without it, where
    # a hook per registration would queue forever across every code reload.
    class FilterAttributesFeed
      def initialize
        @names = {}
        @base = nil
        @lock = Mutex.new
      end

      # Called with ActiveRecord::Base once it has loaded.
      def attach(base)
        @lock.synchronize do
          @base = base
          restore
        end
      end

      def add(name)
        @lock.synchronize do
          @names[name] = true
          restore if @base
        end
      end

      private

      # The caller holds the lock.
      def restore
        missing = @names.keys - @base.filter_attributes
        @base.filter_attributes += missing unless missing.empty?
      end
    end

    # Shared by the two initializers, which Rails runs as instance_exec on this
    # one object. Memoized rather than built in the first, so the second does not
    # depend on the order Rails settles on for initializers that name no target.
    def filter_attributes_feed
      @filter_attributes_feed ||= FilterAttributesFeed.new
    end
    private :filter_attributes_feed

    rake_tasks do
      load File.expand_path("tasks/openapi.rake", __dir__)
      load File.expand_path("tasks/generate.rake", __dir__)
      load File.expand_path("tasks/audit.rake", __dir__)
    end
  end
end
