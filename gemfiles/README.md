# Compatibility gemfiles

The gemspec advertises a range of ActiveSupport versions; these gemfiles are how
that claim is tested rather than assumed. Each pins one `activesupport` line
(plus the `actionpack` / `activerecord` that drive the integration and
schema-drift specs, the `railties` that boots a real app for the Railtie specs,
and the `sqlite3` that version of ActiveRecord accepts). Don't drop `railties`:
the Railtie specs skip rather than fail without it, so the job would stay green
while no longer testing the `filter_parameters` wiring or the rake tasks.

Run one locally:

```sh
BUNDLE_GEMFILE=gemfiles/activesupport_7.1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/activesupport_7.1.gemfile bundle exec rspec
```

CI runs every gemfile against every supported Ruby (see `.github/workflows/ci.yml`).
The root `Gemfile` stays unpinned — it resolves to the newest release, which is
what local development and the lint job use.

`activesupport_edge.gemfile` is the exception: it tracks Rails `main`, the
unreleased next line, and is not part of the supported range. CI runs it, and
Ruby `head`, as an early warning that is reported but does not fail the build.

Lockfiles here are deliberately **not** committed: the point is to resolve the
newest patch of each line on every run, so a regression in a supported version
shows up as a CI failure rather than being frozen out by a stale lock.
