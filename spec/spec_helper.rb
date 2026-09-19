require "bundler/setup"
# Same reason as lib/permittable.rb: activerecord 6.1 is required here BEFORE
# permittable, so the suite needs the stdlib logger loaded first too.
require "logger"
# RSpec's `be_in` calls Object#in?, which activesupport does not load by
# default. Nothing else in this suite pulls it in, so on the 6.1 gemfile
# the compatibility matrix failed on a matcher rather than on the gem.
require "active_support/core_ext/object/inclusion"
require "simplecov"

SimpleCov.start do
  add_filter "/spec/"
end

require "active_record"
require "permittable"
require_relative "support/fake_controller"
require_relative "support/integration_harness"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false

# Abstract base for spec model classes (the schema-drift specs).
class TestModel < ActiveRecord::Base
  self.abstract_class = true
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
