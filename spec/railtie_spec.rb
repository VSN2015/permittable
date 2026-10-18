require "open3"

# Everything Permittable::Railtie does happens during a Rails boot, and none of
# it was covered: the filter_parameters wiring, its position relative to
# ActiveRecord, and the rake tasks. Unit specs cannot see any of it, and the
# FakeController harness deliberately has no Rails at all.
#
# So this boots a real Rails application in a SUBPROCESS — the same approach
# the "without Rails loaded" specs use, for the same reason: the boot mutates
# global state (Rails.application is a singleton, initializers run once) and
# must not leak into the rest of the suite.
RSpec.describe "Permittable::Railtie in a booted Rails application", :integration do
  # The gem supports hosts with no Rails at all, so skip rather than fail where
  # railties is absent. Every gemfile in this repo does carry it, though, so a
  # pending example here in CI means one has lost its railties pin.
  before(:all) do
    require "rails"
  rescue LoadError
    skip "railties is not available in this bundle"
  end

  # Shared by both boots: requires, the application, and its initialization.
  BOOT_HEADER = <<~RUBY.freeze
    # Before rails, for the reason lib/permittable.rb gives: activesupport
    # <= 7.0.8.4 raises NameError on load unless logger is already loaded. A
    # real app on those versions needs this same line in config/boot.rb.
    require "logger"
    require "json"
    require "tmpdir"
    require "rails"
    require "active_record/railtie"
    require "action_controller/railtie"
    require "permittable"

    # The ActiveRecord railtie insists on a database configuration at boot.
    class ProbeApp < Rails::Application
      config.root = ENV.fetch("PERMITTABLE_PROBE_ROOT")
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = "x" * 64
      # An entry of the app's own, to prove the gem appends rather than replaces.
      config.filter_parameters += [:password]
      # What `load_defaults "7.1"` turns on, and the reason the mechanism has
      # to be a NAME rather than a live matcher object: railties REPLACES
      # config.filter_parameters with patterns joined by source, which drops
      # any object whose matching is decided at filter time. Set directly
      # rather than through load_defaults, which would raise on the older
      # Rails versions the compatibility gemfiles cover.
      config.precompile_filter_parameters = true if config.respond_to?(:precompile_filter_parameters=)
    end

    ProbeApp.initialize!
  RUBY

  # Declares LateController before ActiveRecord::Base is ever referenced, which
  # is the one order in which the copy ActiveRecord takes of
  # config.filter_parameters already contains the registered names. See
  # AR_FIRST_SCRIPT for the order a real app has.
  BOOT_SCRIPT = BOOT_HEADER + <<~RUBY
    # A controller class loading AFTER boot, which is what lazy loading does in
    # development and what the live registry exists for.
    class LateController < ActionController::Base
      include Permittable

      permit_params(:create) do
        optional :ssn, :string, sensitive: true
        optional :pin_code, :integer, sensitive: true
        optional :payment, sensitive: true do
          required :card_number, :string
        end
        optional :note, :string
      end
    end

    # What a real request does, and what triggers precompilation.
    Rails.application.env_config

    filters = Rails.application.config.filter_parameters
    redacted = ActiveSupport::ParameterFilter.new(filters).filter(
      "ssn" => "111-22-3333", "pin_code" => 1234, "payment" => { "card_number" => "4111111111111111" },
      "password" => "hunter2", "note" => "keep me"
    )

    # The documented promise is redaction from BOTH request logs and #inspect.
    # ActiveRecord copies config.filter_parameters into filter_attributes, so
    # this is the half a parameter filter alone cannot show.
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:people) { |t| t.string :ssn; t.integer :pin_code; t.string :name }
    end
    class Person < ActiveRecord::Base; end

    # A host gem or app swapping the registry to pool registrations. Rails runs
    # railtie initializers BEFORE config/initializers, so this necessarily
    # happens after the gem's filter proc was appended — and after LateController
    # already registered `ssn` on the default registry.
    pooled = Permittable::FilterParameterRegistry.new
    Permittable.filter_parameter_registry = pooled

    class PostSwapController < ActionController::Base
      include Permittable

      permit_params(:create) { optional :pin, :string, sensitive: true }
    end

    # Same filter list, unchanged since boot: the appended proc has to resolve
    # the CURRENT registry, and the swap has to have carried `ssn` across.
    after_swap = ActiveSupport::ParameterFilter.new(filters).filter(
      "ssn" => "111-22-3333", "pin" => "1234", "note" => "keep me"
    )

    Rails.application.load_tasks

    print JSON.generate(
      procs: filters.count { |f| f.is_a?(Proc) },
      symbols: filters.grep(Symbol).map(&:to_s),
      redacted: redacted,
      after_swap: after_swap,
      filter_attribute_procs: ActiveRecord::Base.filter_attributes.count { |f| f.is_a?(Proc) },
      filter_attribute_names: ActiveRecord::Base.filter_attributes.grep(String),
      model_inspect: Person.new(ssn: "111-22-3333", pin_code: 1234, name: "Ada").inspect,
      # Precompilation joins the app's own patterns into one Regexp; without
      # it the array carries no Regexp at all, so this is the signal that the
      # probe really is exercising the modern default.
      precompiled: filters.any? { |f| f.is_a?(Regexp) },
      rails_version: Rails.gem_version.to_s,
      tasks: Rake::Task.tasks.map(&:name).grep(/^permittable:/).sort
    )
  RUBY

  # The order a real app has. The first controller's own `model: Person` (or
  # any model reference, an initializer, `rails console`) loads ActiveRecord
  # BEFORE the controller body runs, and the on_load hook that copies
  # config.filter_parameters into filter_attributes runs exactly once, at that
  # point. So the sensitive names a contract registers afterwards never reach
  # the copy, unless something feeds them to ActiveRecord::Base directly.
  AR_FIRST_SCRIPT = BOOT_HEADER + <<~RUBY
    require "stringio"

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:people) { |t| t.string :ssn; t.integer :pin_code; t.date :born_on; t.string :name }
    end
    class Person < ActiveRecord::Base; end

    # Only the proc is in the copy at this point: nothing sensitive has loaded.
    names_before = ActiveRecord::Base.filter_attributes.grep(String)

    class PeopleController < ActionController::Base
      include Permittable

      permit_params(:create) do
        optional :ssn, :string, sensitive: true
        optional :pin_code, :integer, sensitive: true
        optional :born_on, :date, sensitive: true
        optional :name, :string
      end
    end

    # Code reloading re-declares the same contract; the second pass must not
    # grow the list.
    Permittable.filter_parameter_registry.names.each { |n| Permittable.register_sensitive_parameter(n) }
    class PeopleController
      permit_params(:update) { optional :pin_code, :integer, sensitive: true }
    end

    log = StringIO.new
    ActiveRecord::Base.logger = Logger.new(log)
    Person.create!(ssn: "111-22-3333", pin_code: 4321, born_on: Date.new(1984, 2, 29), name: "Ada")

    print JSON.generate(
      names_before: names_before,
      filter_attribute_names: ActiveRecord::Base.filter_attributes.grep(String),
      filter_attribute_procs: ActiveRecord::Base.filter_attributes.count { |f| f.is_a?(Proc) },
      filter_parameter_names: Rails.application.config.filter_parameters.grep(String),
      insert: log.string.lines.grep(/INSERT/).join,
      model_inspect: Person.first.inspect,
      rails_version: Rails.gem_version.to_s
    )
  RUBY

  # One boot per script, several expectations — booting Rails per example would
  # dominate the suite's runtime for no extra coverage.
  def self.run_script(script)
    # The block form removes the directory once the subprocess has exited,
    # including when the boot raises, so repeated runs leave nothing behind.
    Dir.mktmpdir do |root|
      lib = File.expand_path("../lib", __dir__)
      Dir.mkdir(File.join(root, "config"))
      File.write(File.join(root, "config", "database.yml"),
                 "test:\n  adapter: sqlite3\n  database: \":memory:\"\n")
      env = { "PERMITTABLE_PROBE_ROOT" => root, "RAILS_ENV" => "test" }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script)
      raise "Rails boot failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  def self.boot
    @boot ||= run_script(BOOT_SCRIPT)
  end

  def self.ar_first
    @ar_first ||= run_script(AR_FIRST_SCRIPT)
  end

  let(:boot) { self.class.boot }
  let(:ar_first) { self.class.ar_first }

  it "appends exactly one filter proc, which survives precompilation" do
    # Precompilation joins patterns by source but partitions procs out and
    # keeps them, so the count is still the assertion that the append is
    # idempotent across repeated initializer runs.
    # precompile_filter_parameters arrived in Rails 7.1, so on 6.1 and 7.0
    # there is no precompilation to survive; the count must hold regardless.
    if Gem::Version.new(boot["rails_version"]) >= Gem::Version.new("7.1")
      expect(boot["precompiled"]).to be(true), "the probe app is not exercising precompilation"
    end
    expect(boot["procs"]).to eq(1)
  end

  it "redacts a sensitive: value that is not a String" do
    # A proc filter can only redact Strings — it mutates in place, and
    # ParameterFilter never even calls it for a Hash value, recursing instead.
    # Registering the NAME is what covers these.
    expect(boot["redacted"]["pin_code"]).to eq("[FILTERED]")
    expect(boot["redacted"]["payment"]).to eq("[FILTERED]")
  end

  it "reaches ActiveRecord's filter_attributes, so #inspect redacts too" do
    # The initializer declares `before: "active_record.set_filter_attributes"`,
    # but that hook is a lazy on_load — it runs when ActiveRecord::Base is
    # first referenced, not at its position in the initializer list. So this
    # asserts the promise rather than the ordering that is meant to produce it.
    expect(boot["filter_attribute_procs"]).to eq(1)
    expect(boot["model_inspect"]).to include("ssn: [FILTERED]")
    expect(boot["model_inspect"]).to include("pin_code: [FILTERED]")
    expect(boot["model_inspect"]).to include('name: "Ada"')
  end

  it "redacts a sensitive: field declared by a controller loaded AFTER boot" do
    # The whole reason for a live registry rather than appending symbols: this
    # controller did not exist when filter_parameters was assembled.
    expect(boot["redacted"]["ssn"]).to eq("[FILTERED]")
  end

  it "leaves the app's own filters working and everything else untouched" do
    expect(boot["redacted"]["password"]).to eq("[FILTERED]")
    expect(boot["redacted"]["note"]).to eq("keep me")
  end

  it "keeps redacting across a registry swapped in from an initializer" do
    # Both halves: `ssn` was registered BEFORE the swap and carried across,
    # `pin` by a controller that loaded after it. Getting only one of the two
    # is the failure mode this covers.
    expect(boot["after_swap"]["ssn"]).to eq("[FILTERED]")
    expect(boot["after_swap"]["pin"]).to eq("[FILTERED]")
    expect(boot["after_swap"]["note"]).to eq("keep me")
  end

  it "registers each sensitive name once in filter_attributes" do
    # LateController loaded before ActiveRecord, so a name can reach the list
    # twice over: through the copy ActiveRecord takes of filter_parameters (as
    # a String, or folded into a Regexp when precompilation is on) and through
    # the sink. Either way each name is there, and only once.
    expect(boot["filter_attribute_names"]).to match_array(%w[ssn pin_code pin payment card_number])
  end

  context "when ActiveRecord loads before the controller declares its contract" do
    # The order a real app has, and the one the examples above do not use: a
    # controller's `model: Person` loads ActiveRecord before the controller
    # registers anything, and ActiveRecord copies filter_parameters into
    # filter_attributes only once, when it loads.
    it "feeds each sensitive name to filter_attributes after the copy was taken" do
      expect(ar_first["names_before"]).to eq([])
      expect(ar_first["filter_attribute_names"]).to match_array(%w[ssn pin_code born_on])
    end

    it "keeps the single filter proc alongside the names" do
      expect(ar_first["filter_attribute_procs"]).to eq(1)
    end

    it "does not grow filter_attributes when a name is registered again" do
      expect(ar_first["filter_attribute_names"].tally.values.uniq).to eq([1])
      expect(ar_first["filter_parameter_names"].tally.values.uniq).to eq([1])
    end

    it "redacts non-String values in the SQL bind log" do
      # Rails 6.1 logs bound values unfiltered whatever filter_attributes holds;
      # the filtering arrived in 7.0, so there is nothing for the gem to feed.
      if Gem::Version.new(ar_first["rails_version"]) < Gem::Version.new("7.0")
        skip "ActiveRecord #{ar_first['rails_version']} does not filter its SQL bind log"
      end
      # The bind log hands ActiveRecord's filter the raw bound value, so the
      # proc, which can only redact a String in place, never redacts an Integer.
      # (#inspect hands it the already-inspected String, which is why that was
      # never affected; sqlite hands a Date to the bind log serialized, as a
      # String, so the date column was covered by the proc as well.)
      expect(ar_first["insert"]).to include('["ssn", "[FILTERED]"]')
      expect(ar_first["insert"]).to include('["pin_code", "[FILTERED]"]')
      expect(ar_first["insert"]).to include('["born_on", "[FILTERED]"]')
      expect(ar_first["insert"]).to include('["name", "Ada"]')
      expect(ar_first["insert"]).not_to include("4321")
    end

    it "redacts non-String values in #inspect" do
      expect(ar_first["model_inspect"]).to include("pin_code: [FILTERED]")
      expect(ar_first["model_inspect"]).to include("born_on: [FILTERED]")
      expect(ar_first["model_inspect"]).to include('name: "Ada"')
    end
  end

  it "loads its rake tasks" do
    expect(boot["tasks"]).to include("permittable:generate", "permittable:openapi")
  end
end
