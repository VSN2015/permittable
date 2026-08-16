require_relative "lib/permittable/version"

Gem::Specification.new do |spec|
  spec.name          = "permittable"
  spec.version       = Permittable::VERSION
  spec.authors       = ["Ethan Nguyen"]
  spec.email         = ["doctorit@gmail.com"]

  spec.summary       = "Strong parameters for Rails that also know types, bounds, and defaults"
  spec.description   = "Strong parameters answer only which keys may pass. A Permittable contract also " \
                       "says what each field should be: it casts the value to a declared type, validates " \
                       "bounds and formats, applies defaults, and renders every failure as a 422 that " \
                       "names the offending parameter. Because a contract is class-level data rather than " \
                       "code inside the action, it can also be checked against the database when the " \
                       "controller loads, so a column dropped by a migration fails the deploy instead of " \
                       "the request. activesupport is the only runtime dependency."
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
