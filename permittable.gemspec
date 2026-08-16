require_relative "lib/permittable/version"

Gem::Specification.new do |spec|
  spec.name          = "permittable"
  spec.version       = Permittable::VERSION
  spec.authors       = ["Ethan Nguyen"]
  spec.email         = ["doctorit@gmail.com"]

  spec.summary       = "Typed, validated params contracts for Rails controllers + schema-drift guard"
  spec.description   = "Declarative per-action params contracts: strict typing/coercion, validation, " \
                       "defaults, machine-readable 422s, output reshaping (transform/finalize), and a " \
                       "boot-time schema-drift guard that fails the deploy when a permitted field's " \
                       "column was dropped. Strong parameters with types, validation, and drift detection."
  spec.homepage      = "https://github.com/VSN2015/permittable"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.files         = Dir["lib/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # activesupport only: the concern itself is plain Ruby over a params-duck.
  # actionpack (rescue_from / before_action / Parameters) and activerecord
  # (the model: schema-drift guard) are optional — every touchpoint is
  # respond_to?/defined?-guarded, so hosts bring what they already have.
  spec.add_runtime_dependency "activesupport", ">= 5.0", "< 9"

  spec.metadata = {
    "license" => "MIT",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/VSN2015/permittable",
    "changelog_uri" => "https://github.com/VSN2015/permittable/blob/master/CHANGELOG.md"
  }
end
