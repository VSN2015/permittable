# Proves the gemspec's central claim: activesupport is the ONLY runtime
# dependency. The spec suite cannot prove it — it bundles actionpack and
# activerecord to exercise the integration and schema-drift paths — so this
# script runs against the INSTALLED gem in an environment where those are
# absent, and exercises every controller-free surface. Each guarded touchpoint
# (`respond_to?`, `defined?`) is a promise; a missing one fails here.
#
#   gem build permittable.gemspec -o permittable-smoke.gem
#   gem install ./permittable-smoke.gem
#   ruby spec/support/runtime_deps_smoke.rb
#
# Run by the `runtime-deps` job in .github/workflows/ci.yml.

# Top-level ivars belong to `main`, which is the `self` every `check` call
# below runs against — no globals needed for a single-file script.
@failures = []

def check(what)
  yield
  puts "  ok   #{what}"
rescue StandardError, LoadError => e
  @failures << "#{what}: #{e.class}: #{e.message}"
  puts "  FAIL #{what}: #{e.class}: #{e.message}"
end

def assert(condition, message)
  raise message unless condition
end

puts "declared runtime dependencies"
check "activesupport is the only one" do
  deps = Gem::Specification.find_by_name("permittable").runtime_dependencies.map(&:name).sort
  assert deps == ["activesupport"], "expected [\"activesupport\"], got #{deps.inspect}"
end

puts "environment"
%w[action_controller action_pack active_record rails].each do |lib|
  check "#{lib} is genuinely absent" do
    require lib
    raise "#{lib} loaded — this environment is not minimal, so it proves nothing"
  rescue LoadError
    true
  end
end

require "permittable"
puts "permittable #{Permittable::VERSION} loaded"

check "no Rails constant leaked in" do
  assert !defined?(ActionController::Parameters), "ActionController::Parameters is defined"
  assert !defined?(Permittable::Railtie), "Railtie loaded without Rails"
end

puts "standalone contracts"
contract = Permittable::Contract.define(root: :user) do
  required :email, :string, format: /@/, normalize: :email
  optional :age, :integer, in: 18..120
  optional :plan, :string, in: %w[free pro], default: "free"
  array :tags, of: :string, length: 0..3
  optional :address do
    required :city, :string
    optional :zip, :string
  end
  finalize { |p| p.merge(source: "smoke") }
end

check "casts, defaults, normalizes and finalizes" do
  params = contract.call!(user: { email: " A@B.C ", age: "42", tags: %w[x y],
                                  address: { city: "Hanoi" } })
  assert params["email"] == "a@b.c", params.inspect
  assert params["age"] == 42, params.inspect
  assert params["plan"] == "free", params.inspect
  assert params["address"]["city"] == "Hanoi", params.inspect
  assert params["source"] == "smoke", params.inspect
end

check "casts a BigDecimal for :string in plain notation, not the scientific default #to_s gives" do
  # Rails patches BigDecimal#to_s to default to "F" (active_support/core_ext/
  # big_decimal/conversions, pulled in by active_record) — masking this bug
  # in the main spec suite the same way 0.8.0's TimeWithZone regression was
  # masked. This process loads only permittable, so BigDecimal#to_s is still
  # stdlib's own scientific-by-default rendering, and only an explicit
  # to_s("F") in cast_string sees it.
  priced = Permittable::Contract.define { optional :price, :string, default: BigDecimal("1.5") }
  assert priced.call!({})["price"] == "1.5", priced.call!({}).inspect
end

check "nested plain hashes convert without the Rails core extensions" do
  # The 0.5.1 regression: HashWithIndifferentAccess needs the Hash core ext
  # to convert nested plain Hashes, which Rails apps load indirectly.
  params = contract.call!(user: { email: "a@b.c", address: { city: "Hue", zip: "49000" } })
  assert params["address"]["zip"] == "49000", params.inspect
end

check "reports violations as data, with qualified paths" do
  result = contract.call(user: { email: "nope", age: 9, tags: %w[a b c d] })
  assert result.invalid?, "expected invalid"
  codes = result.violations.to_h { |v| [v[:param], v[:code]] }
  assert codes["user.email"] == "format", codes.inspect
  assert codes["user.age"] == "inclusion", codes.inspect
  assert codes["user.tags"] == "length", codes.inspect
end

check "a missing root carries 400 semantics" do
  contract.call!({})
  raise "expected InvalidParameters"
rescue Permittable::InvalidParameters => e
  assert e.status == :bad_request, e.status.inspect
end

puts "the concern on a plain params duck"
duck = Class.new do
  include Permittable

  attr_accessor :params

  def action_name = "create"

  permit_params(:create, unknown: :error) do
    required :sku, :string
    optional :qty, :integer, default: 1
    optional :secret, :string, sensitive: true
  end
end

check "validates without before_action, rescue_from, logger or render" do
  host = duck.new
  host.params = { "sku" => "A-1", "qty" => "7" }
  assert host.permitted_params.to_h == { "sku" => "A-1", "qty" => 7 }, host.permitted_params.inspect
  assert host.permittable_violations == [], host.permittable_violations.inspect
end

check "unknown: :error works with no logger to warn through" do
  host = duck.new
  host.params = { "sku" => "A-1", "nope" => "1" }
  host.permitted_params
  raise "expected InvalidParameters"
rescue Permittable::InvalidParameters => e
  assert e.details.any? { |d| d[:param] == "nope" && d[:code] == "unknown" }, e.details.inspect
end

check "sensitive: registers for redaction with no Railtie to install the filter" do
  assert Permittable.filter_parameter_registry.include?("secret"), "not registered"
  assert Permittable.filter_parameter_registry.include?("SECRET_TOKEN"), "not matched case-insensitively"
end

check "monitor mode passes raw params through with no logger" do
  monitored = Class.new do
    include Permittable

    attr_accessor :params

    def action_name = "create"

    permit_params(:create, mode: :monitor) { required :n, :integer }
  end
  host = monitored.new
  host.params = { "n" => "abc" }
  assert host.permitted_params.to_h == { "n" => "abc" }, host.permitted_params.inspect
  assert host.permittable_violations.length == 1, host.permittable_violations.inspect
end

check "instrumentation fires through activesupport alone" do
  events = []
  ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") { |*, payload| events << payload }
  contract.call(user: { email: "nope" })
  assert events.length == 1, events.inspect
  assert events.first[:controller] == "Permittable::Contract", events.inspect
end

puts "exporters"
check "JSON Schema exports from the frozen rule" do
  schema = contract.json_schema
  props = schema["properties"]["user"]["properties"]
  assert schema["required"] == ["user"], schema.inspect
  assert props["age"] == { "type" => "integer", "minimum" => 18, "maximum" => 120 }, props["age"].inspect
  assert props["tags"]["items"] == { "type" => "string" }, props["tags"].inspect
end

check "OpenAPI assembles a document without Rails routes" do
  doc = Permittable::OpenAPI.document(controllers: [duck], info: { "title" => "Smoke" })
  assert doc["openapi"] == "3.1.0", doc["openapi"].inspect
  assert doc["components"]["schemas"].key?("PermittableInvalidParameters"), doc["components"].inspect
  # No routes given, so the operation lands in the escape hatch rather than paths.
  assert doc["x-permittable-controllers"].values.first.key?("create"), doc["x-permittable-controllers"].inspect
end

puts "generator"
check "drafts a contract from a scanned permit call, with no model to read" do
  scan = Permittable::Generator.scan('params.require(:user).permit(:name, :email, tags: [])')
  draft = Permittable::Generator.draft(scan: scan)
  assert draft.include?("permit_params"), draft
  assert draft.include?("root: :user"), draft
  assert draft.include?("mode: :monitor"), draft
end

puts
if @failures.empty?
  puts "PASS — activesupport is enough."
else
  puts "FAILED (#{@failures.length}):"
  @failures.each { |f| puts "  - #{f}" }
  exit 1
end
