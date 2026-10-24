require "open3"

# The ignore list end to end: the real `permittable:audit[strict]` and
# `permittable:generate` tasks, in a booted Rails application whose routes
# reach a catch-all 404 and a controller loaded from outside Rails.root (a
# stand-in for ActiveStorage's direct uploads controller, which every app
# using ActiveStorage routes POST to). Unit specs cover Audit and Generator;
# only a boot shows the tasks read Permittable.audit_ignore, find Rails.root,
# and locate a controller's source the way they would in an app.
#
# A subprocess for the same reason as the Railtie spec: the boot mutates
# global state (Rails.application, the route set) that must not leak.
RSpec.describe "permittable:audit and permittable:generate with an ignore list", :integration do
  before(:all) do
    require "rails"
  rescue LoadError
    skip "railties is not available in this bundle"
  end

  AUDIT_TASK_APP_FILES = {
    "app/controllers/application_controller.rb" => <<~RUBY,
      class ApplicationController < ActionController::Base
        include Permittable

        def not_found = head(:not_found)

        private

        # A permit call here is what drafts the base class, whose rule every
        # controller below it would inherit.
        def filter_params = params.permit(:q)
      end
    RUBY
    "app/controllers/widgets_controller.rb" => <<~RUBY,
      class WidgetsController < ApplicationController
        permit_params(:create) { required :name, :string }

        def create = head(:created)
      end
    RUBY
    # Bare ActionController::Metal, the usual shape of a lean webhook
    # endpoint: neither Base nor API, and the tasks used to collect only
    # those two, so this unguarded POST had no row and [strict] passed.
    "app/controllers/hooks_controller.rb" => <<~RUBY,
      class HooksController < ActionController::Metal
        include ActionController::Head

        def receive = head(:accepted)
      end
    RUBY
    # Metal with a contract: enforced at runtime, so it belongs in the export.
    "app/controllers/pings_controller.rb" => <<~RUBY,
      class PingsController < ActionController::Metal
        include AbstractController::Rendering
        include ActionController::Rendering
        include ActionController::Renderers::All
        include ActionController::Head
        include AbstractController::Callbacks
        include ActionController::Rescue
        include ActionController::StrongParameters
        include Permittable

        permit_params(:create, enforce: true) { required :host, :string }

        def create = head(:created)
      end
    RUBY
    # Never routed: the generator drafts from controllers, not routes.
    "app/controllers/notes_controller.rb" => <<~RUBY,
      class NotesController < ApplicationController
        def create = head(:created)
        def update = head(:ok)

        private

        def note_params = params.require(:note).permit(:body)
      end
    RUBY
    # Controllers that define only some of the drafted actions: a draft for
    # the rest would guard nothing, and the audit would list it as stale.
    "app/controllers/sessions_controller.rb" => <<~RUBY,
      class SessionsController < ApplicationController
        def create = head(:created)
        def destroy = head(:no_content)

        private

        def session_params = params.require(:session).permit(:email)
      end
    RUBY
    "app/controllers/webhooks_controller.rb" => <<~RUBY
      class WebhooksController < ApplicationController
        def receive = head(:accepted)

        private

        def event_params = params.require(:event).permit(:kind)
      end
    RUBY
  }.freeze

  # Outside Rails.root, the way a gem's controller is — and drafted without
  # the ignore list, since its permit call gives the generator a contract.
  AUDIT_TASK_GEM_CONTROLLER = <<~RUBY.freeze
    class GemUploadsController < ActionController::Base
      def create = head(:created)

      private

      def upload_params = params.require(:upload).permit(:filename)
    end
  RUBY

  AUDIT_TASK_SCRIPT = <<~RUBY.freeze
    # Before rails, for the reason lib/permittable.rb gives: activesupport
    # <= 7.0.8.4 raises NameError on load unless logger is already loaded.
    require "logger"
    require "json"
    require "stringio"
    require "rails"
    require "action_controller/railtie"
    require "permittable"

    class ProbeApp < Rails::Application
      config.root = ENV.fetch("PERMITTABLE_PROBE_ROOT")
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = "x" * 64
    end

    ProbeApp.initialize!
    require ENV.fetch("PERMITTABLE_GEM_CONTROLLER")

    Rails.application.routes.draw do
      post "widgets", to: "widgets#create"
      post "uploads", to: "gem_uploads#create"
      post "hooks", to: "hooks#receive"
      post "pings", to: "pings#create"
      match "*path", to: "application#not_found", via: :all
    end
    Rails.application.load_tasks

    # stdout, stderr, and whether the task aborted, for one task run.
    def run_task(name, *args)
      out, err = StringIO.new, StringIO.new
      $stdout, $stderr = out, err
      aborted = false
      begin
        Rake::Task[name].reenable
        Rake::Task[name].invoke(*args)
      rescue SystemExit => e
        aborted = !e.success?
        err.puts(e.message)
      ensure
        $stdout, $stderr = STDOUT, STDERR
      end
      { "out" => out.string, "err" => err.string, "aborted" => aborted }
    end

    results = {}
    Permittable.audit_ignore = %w[application#not_found widget hooks]
    results["ignored"] = run_task("permittable:audit", "strict")

    Permittable.audit_ignore = %w[application#not_found]
    results["metal"] = run_task("permittable:audit", "strict")
    results["openapi"] = run_task("permittable:openapi")

    Permittable.audit_ignore = []
    results["unignored"] = run_task("permittable:audit", "strict")

    Permittable.audit_ignore = %w[notes#create]
    results["generate"] = run_task("permittable:generate")

    Permittable.audit_ignore_outside_root = false
    results["generate_all"] = run_task("permittable:generate")

    results["generate_sessions"] = run_task("permittable:generate", "SessionsController")
    results["generate_webhooks"] = run_task("permittable:generate", "WebhooksController")

    print JSON.generate(results)
  RUBY

  def self.results
    @results ||= Dir.mktmpdir do |dir|
      root = File.join(dir, "app")
      AUDIT_TASK_APP_FILES.each do |relative, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), source)
      end
      gem_controller = File.join(dir, "gems", "uploader", "lib", "gem_uploads_controller.rb")
      FileUtils.mkdir_p(File.dirname(gem_controller))
      File.write(gem_controller, AUDIT_TASK_GEM_CONTROLLER)

      lib = File.expand_path("../lib", __dir__)
      env = { "PERMITTABLE_PROBE_ROOT" => root, "PERMITTABLE_GEM_CONTROLLER" => gem_controller,
              "RAILS_ENV" => "test" }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", AUDIT_TASK_SCRIPT)
      raise "Rails boot failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  let(:results) { self.class.results }

  describe "permittable:audit[strict]" do
    let(:ignored) { results["ignored"] }

    it "passes when the only unguarded write actions are ignored" do
      expect(ignored["aborted"]).to be(false), ignored["err"]
      expect(ignored["out"]).not_to include("ACCEPTS A BODY")
    end

    it "lists the ignored actions with their reasons rather than dropping them" do
      expect(ignored["out"]).to match(/^Ignored by Permittable\.audit_ignore .*\n  application#not_found  .*POST/)
      expect(ignored["out"]).to match(/^Ignored as outside the app root .*\n  gem_uploads#create  POST$/)
    end

    it "lists an entry that matches nothing" do
      expect(ignored["out"]).to match(/^Permittable\.audit_ignore entries that match no routed action .*\n  widget$/)
    end

    it "audits a bare ActionController::Metal controller, and fails on its unguarded POST" do
      metal = results["metal"]
      expect(metal["out"]).to match(%r{^hooks\n  POST +/hooks +receive +no contract — ACCEPTS A BODY})
      expect(metal["out"]).to match(%r{^pings\n  POST +/pings +create +enforce})
      expect(metal["aborted"]).to be(true)
      expect(metal["err"]).to include("1 routed action accepts a request body with no contract covering it")
    end

    it "still fails on the catch-all once it is not ignored" do
      expect(results["unignored"]["aborted"]).to be(true)
      expect(results["unignored"]["err"]).to include("with no contract covering it")
    end
  end

  describe "permittable:openapi" do
    it "exports a Metal controller's contract alongside Base ones" do
      paths = JSON.parse(results["openapi"]["out"])["paths"]
      expect(paths.keys).to include("/widgets", "/pings")
      expect(paths["/pings"]["post"]["requestBody"]["content"]["application/json"]["schema"]["required"]).to eq(["host"])
    end
  end

  describe "permittable:generate" do
    # The drafts of one controller, from its "# ====" header to the next.
    def drafted(out, controller)
      out.split(/^# ==== /).find { |chunk| chunk.start_with?(controller) }.to_s
    end

    it "drafts neither ignored controllers nor ignored actions" do
      out = results["generate"]["out"]
      expect(out).to include("NotesController")
      expect(drafted(out, "NotesController").scan(/permit_params :\w+/)).to eq(["permit_params :update"])
      expect(out).not_to include("GemUploadsController")
    end

    it "drafts only the actions a controller defines" do
      out = results["generate"]["out"]
      expect(drafted(out, "SessionsController")).to include("permit_params :create, root: :session")
      expect(out).not_to include("WebhooksController")
      expect(out).not_to include("ApplicationController")
    end

    it "leaves an undefined action out of a controller named to the task" do
      out = results["generate_sessions"]["out"]
      expect(out).to include("permit_params :create, root: :session")
    end

    it "drafts a named controller that defines neither action, as it always did" do
      out = results["generate_webhooks"]["out"]
      expect(out).to include("permit_params :create, :update, root: :event")
    end

    it "drafts a controller from outside Rails.root once that default is off" do
      expect(results["generate_all"]["out"]).to include("GemUploadsController")
    end
  end
end

# An engine kept inside the app (a modular monolith's engines/ directory) and
# mounted in it. The two tasks read the app's route set, which holds only the
# mount; unless rails_routes follows it, the engine's unguarded POST passes
# `[strict]`, its covered action is reported as stale, and the export lists it
# outside `paths`. Nothing here requires the engine's controllers by hand:
# only eager_load! can find them, which is what an app relies on.
RSpec.describe "permittable:audit and permittable:openapi with a mounted engine", :integration do
  before(:all) do
    require "rails"
  rescue LoadError
    skip "railties is not available in this bundle"
  end

  MOUNTED_ENGINE_FILES = {
    "config/routes.rb" => <<~RUBY,
      Rails.application.routes.draw do
        post "widgets", to: "widgets#create"
        mount Billing::Engine, at: "/billing"
      end
    RUBY
    "app/controllers/widgets_controller.rb" => <<~RUBY,
      class WidgetsController < ActionController::Base
        include Permittable
        permit_params(:create) { required :name, :string }
        def create = head(:created)
      end
    RUBY
    "engines/billing/lib/billing/engine.rb" => <<~RUBY,
      module Billing
        class Engine < ::Rails::Engine
          isolate_namespace Billing
        end
      end
    RUBY
    "engines/billing/config/routes.rb" => <<~RUBY,
      Billing::Engine.routes.draw do
        post "invoices", to: "invoices#create"
        post "refunds", to: "refunds#create"
      end
    RUBY
    "engines/billing/app/controllers/billing/invoices_controller.rb" => <<~RUBY,
      module Billing
        class InvoicesController < ActionController::Base
          include Permittable
          permit_params(:create) { required :amount, :integer }
          def create = head(:created)
        end
      end
    RUBY
    "engines/billing/app/controllers/billing/refunds_controller.rb" => <<~RUBY
      module Billing
        class RefundsController < ActionController::Base
          def create = head(:created)
        end
      end
    RUBY
  }.freeze

  MOUNTED_ENGINE_SCRIPT = <<~RUBY.freeze
    require "logger"
    require "json"
    require "stringio"
    require "rails"
    require "action_controller/railtie"
    require "permittable"

    require File.join(ENV.fetch("PERMITTABLE_PROBE_ROOT"), "engines/billing/lib/billing/engine.rb")

    class ProbeApp < Rails::Application
      config.root = ENV.fetch("PERMITTABLE_PROBE_ROOT")
      config.load_defaults Rails::VERSION::STRING.to_f
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = "x" * 64
    end

    ProbeApp.initialize!
    Rails.application.load_tasks

    def run_task(name, *args)
      out, err = StringIO.new, StringIO.new
      $stdout, $stderr = out, err
      aborted = false
      begin
        Rake::Task[name].reenable
        Rake::Task[name].invoke(*args)
      rescue SystemExit => e
        aborted = !e.success?
        err.puts(e.message)
      ensure
        $stdout, $stderr = STDOUT, STDERR
      end
      { "out" => out.string, "err" => err.string, "aborted" => aborted }
    end

    print JSON.generate("audit" => run_task("permittable:audit", "strict"),
                        "openapi" => run_task("permittable:openapi"))
  RUBY

  def self.results
    @results ||= Dir.mktmpdir do |dir|
      root = File.join(dir, "app")
      MOUNTED_ENGINE_FILES.each do |relative, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), source)
      end
      lib = File.expand_path("../lib", __dir__)
      env = { "PERMITTABLE_PROBE_ROOT" => root, "RAILS_ENV" => "test" }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", MOUNTED_ENGINE_SCRIPT)
      raise "Rails boot failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  let(:results) { self.class.results }

  describe "permittable:audit[strict]" do
    it "fails on the engine's unguarded POST" do
      expect(results["audit"]["aborted"]).to be(true), results["audit"]["out"]
      expect(results["audit"]["err"]).to include("1 routed action accepts a request body")
      expect(results["audit"]["out"]).to match(%r{POST\s+/billing/refunds\s+create})
    end

    it "lists the engine's covered action under its mounted path, not as stale" do
      out = results["audit"]["out"]
      expect(out).to match(%r{POST\s+/billing/invoices\s+create\s+enforce})
      expect(out).not_to include("no route reaches")
    end
  end

  describe "permittable:openapi" do
    it "puts the engine's operation under its mounted path" do
      doc = JSON.parse(results["openapi"]["out"])
      expect(doc["paths"].keys).to include("/billing/invoices")
      expect(doc.fetch("x-permittable-controllers", {})).not_to have_key("billing/invoices")
    end
  end
end
