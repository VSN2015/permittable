# Drafts Permittable contracts for controllers that don't declare one yet,
# from each controller's model columns plus any params.permit calls in its
# source. Drafts go to stdout (paste-ready); the summary goes to stderr.
#
#   bin/rails permittable:generate                      # every uncovered controller
#   bin/rails "permittable:generate[UsersController]"   # one controller, even if covered
namespace :permittable do
  desc "Draft Permittable contracts from models and existing permit calls"
  task :generate, [:controller] => :environment do |_t, task_args|
    Rails.application.eager_load!

    bases = []
    bases << ActionController::Base if defined?(ActionController::Base)
    bases << ActionController::API if defined?(ActionController::API)
    controllers = bases.flat_map(&:descendants).uniq.select(&:name)

    if task_args[:controller]
      controllers = controllers.select { |c| c.name == task_args[:controller] }
      abort "Permittable: no controller named #{task_args[:controller]} was found" if controllers.empty?
    else
      controllers = controllers.reject do |c|
        c.respond_to?(:permittable_contracts) && c.permittable_contracts.any?
      end
    end

    drafted = controllers.sort_by(&:name).count do |controller|
      path = begin
        Object.const_source_location(controller.name)&.first
      rescue StandardError
        nil
      end
      source = path && File.exist?(path) ? File.read(path) : nil
      snippet = Permittable::Generator.for_controller(controller, source: source)
      next false unless snippet

      puts ["# ====", controller.name, path && "(#{path})", "===="].compact.join(" ")
      puts snippet
      puts
      true
    end

    warn "Permittable: drafted #{drafted} contract#{'s' unless drafted == 1} — " \
         "paste each into its controller and review the TODOs."
  end
end
