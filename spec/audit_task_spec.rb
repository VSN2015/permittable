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
      end
    RUBY
    "app/controllers/widgets_controller.rb" => <<~RUBY,
      class WidgetsController < ApplicationController
        permit_params(:create) { required :name, :string }

        def create = head(:created)
      end
    RUBY
    # Never routed: the generator drafts from controllers, not routes.
    "app/controllers/notes_controller.rb" => <<~RUBY
      class NotesController < ApplicationController
        def create = head(:created)
        def update = head(:ok)

        private

        def note_params = params.require(:note).permit(:body)
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
    Permittable.audit_ignore = %w[application#not_found widget]
    results["ignored"] = run_task("permittable:audit", "strict")

    Permittable.audit_ignore = []
    results["unignored"] = run_task("permittable:audit", "strict")

    Permittable.audit_ignore = %w[notes#create]
    results["generate"] = run_task("permittable:generate")

    Permittable.audit_ignore_outside_root = false
    results["generate_all"] = run_task("permittable:generate")

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

    it "still fails on the catch-all once it is not ignored" do
      expect(results["unignored"]["aborted"]).to be(true)
      expect(results["unignored"]["err"]).to include("with no contract covering it")
    end
  end

  describe "permittable:generate" do
    it "drafts neither ignored controllers nor ignored actions" do
      out = results["generate"]["out"]
      expect(out).to include("NotesController")
      expect(out.scan(/permit_params :\w+/)).to eq(["permit_params :update"])
      expect(out).not_to include("GemUploadsController")
    end

    it "drafts a controller from outside Rails.root once that default is off" do
      expect(results["generate_all"]["out"]).to include("GemUploadsController")
    end
  end
end
