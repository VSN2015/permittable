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
  # The gem supports hosts with no Rails at all, and the compatibility gemfiles
  # do not all carry railties, so skip rather than fail where it is absent.
  before(:all) do
    require "rails"
  rescue LoadError
    skip "railties is not available in this bundle"
  end

  BOOT_SCRIPT = <<~RUBY.freeze
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
      model_inspect: Person.new(ssn: "111-22-3333", pin_code: 1234, name: "Ada").inspect,
      # Precompilation joins the app's own patterns into one Regexp; without
      # it the array carries no Regexp at all, so this is the signal that the
      # probe really is exercising the modern default.
      precompiled: filters.any? { |f| f.is_a?(Regexp) },
      tasks: Rake::Task.tasks.map(&:name).grep(/^permittable:/).sort
    )
  RUBY

  # One boot, several expectations — booting Rails per example would dominate
  # the suite's runtime for no extra coverage.
  def self.boot
    # The block form removes the directory once the subprocess has exited,
    # including when the boot raises, so repeated runs leave nothing behind.
    @boot ||= Dir.mktmpdir do |root|
      lib = File.expand_path("../lib", __dir__)
      Dir.mkdir(File.join(root, "config"))
      File.write(File.join(root, "config", "database.yml"),
                 "test:\n  adapter: sqlite3\n  database: \":memory:\"\n")
      env = { "PERMITTABLE_PROBE_ROOT" => root, "RAILS_ENV" => "test" }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", BOOT_SCRIPT)
      raise "Rails boot failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  let(:boot) { self.class.boot }

  it "appends exactly one filter proc, which survives precompilation" do
    # Precompilation joins patterns by source but partitions procs out and
    # keeps them, so the count is still the assertion that the append is
    # idempotent across repeated initializer runs.
    expect(boot["precompiled"]).to be(true), "the probe app is not exercising precompilation"
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

  it "loads its rake tasks" do
    expect(boot["tasks"]).to include("permittable:generate", "permittable:openapi")
  end
end
