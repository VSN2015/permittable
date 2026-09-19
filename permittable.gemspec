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
  # respond_to?/defined?-guarded, so hosts bring what they already have. The
  # `runtime-deps` CI job installs this gem with nothing else and exercises
  # every controller-free surface, so that claim is tested, not asserted.
  #
  # The 6.1 floor is the oldest activesupport the full suite is run against
  # (see gemfiles/ and the CI matrix). It is not arbitrary: `class_attribute
  # ... default:` — how the contract registry is declared — arrived in 5.2, so
  # 5.0 and 5.1 cannot declare a contract at all, and 5.2/6.0 predate Ruby 3.x
  # support, which this gem's own Ruby floor requires.
  spec.add_runtime_dependency "activesupport", ">= 6.1", "< 9"

  spec.metadata = {
    "license" => "MIT",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/VSN2015/permittable",
    "changelog_uri" => "https://github.com/VSN2015/permittable/blob/master/CHANGELOG.md"
  }
end
