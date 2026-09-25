source "https://rubygems.org"

gemspec

gem "rake"

# Dev/test only — the gem's sole runtime dependency is activesupport.
# actionpack drives the real-ActionController integration specs, activerecord +
# sqlite3 the schema-drift specs.
gem "actionpack", ">= 6.1", "< 9"
gem "activerecord", ">= 6.1", "< 9"
gem "benchmark-ips", "~> 2.13", require: false
# activesupport 8.1.3.1 calls JSON.parse(source, opts) positionally, which json 3
# rejects, so Rails cannot parse a JSON request body. Dev-only. Dependabot
# ignores json >= 3 meanwhile, so nothing will prompt this: remove the pin (and
# that ignore) once Gemfile.lock is on an activesupport carrying
# rails/rails#58601 (8.1.4, the first such release) and
# spec/json_body_parsing_spec.rb passes on json 3.
# https://github.com/VSN2015/permittable/issues/58
gem "json", "< 3"
gem "railties", ">= 5.0", "< 9"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 1.2"
gem "sqlite3", "~> 2.9.4"

group :development, :test do
  gem 'rubocop', '~> 1.91', require: false
end
