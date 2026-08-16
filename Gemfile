source "https://rubygems.org"

gemspec

gem "rake"

# Dev/test only — the gem's sole runtime dependency is activesupport.
# actionpack drives the real-ActionController integration specs, activerecord +
# sqlite3 the schema-drift specs.
gem "actionpack", ">= 5.0", "< 9"
gem "activerecord", ">= 5.0", "< 9"
gem "rspec", "~> 3.12"
gem "simplecov", "~> 1.1"
gem "sqlite3", "~> 2.9.4"

group :development, :test do
  gem 'rubocop', '~> 1.87', require: false
end
