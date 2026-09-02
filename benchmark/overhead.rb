# Measures the per-request cost of a Permittable contract against the strong
# parameters call it replaces, on a representative payload (7 scalars, one
# nested hash, one array). Strong parameters only filters keys; the contract
# additionally casts, validates, and defaults — this measures what that
# extra work costs.
#
#   bundle exec ruby benchmark/overhead.rb
require "bundler/setup"
require "benchmark/ips"
require "action_controller"
require "permittable"

PAYLOAD = {
  "user" => {
    "name" => "Ada Lovelace",
    "email" => "ada@example.com",
    "age" => "36",
    "plan" => "pro",
    "bio" => "Analyst, metaphysician, founder of scientific computing.",
    "newsletter" => "true",
    "joined_on" => "2026-01-15",
    "tags" => %w[math pioneer],
    "address" => { "city" => "London", "zip" => "12345" }
  }
}.freeze

CONTRACT = Permittable::Contract.define(root: :user) do
  required :name,       :string, length: 1..80
  required :email,      :string, format: URI::MailTo::EMAIL_REGEXP
  optional :age,        :integer, in: 18..120
  optional :plan,       :string, in: %w[free pro], default: "free"
  optional :bio,        :string, length: 0..500
  optional :newsletter, :boolean
  optional :joined_on,  :date
  array    :tags,       of: :string, length: 0..10
  optional :address do
    required :city, :string
    optional :zip,  :string, format: /\A\d{5}\z/
  end
end

raise "benchmark contract must validate its own payload" unless CONTRACT.call(PAYLOAD).valid?

def strong_parameters(payload)
  ActionController::Parameters.new(payload)
                              .require(:user)
                              .permit(:name, :email, :age, :plan, :bio, :newsletter, :joined_on,
                                      tags: [], address: %i[city zip])
                              .to_h
end

Benchmark.ips do |x|
  x.report("params.permit (filter only)") { strong_parameters(PAYLOAD) }
  x.report("Permittable (cast+validate+default)") { CONTRACT.call(PAYLOAD) }
  x.compare!
end
