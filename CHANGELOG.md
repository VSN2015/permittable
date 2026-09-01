<!-- CHANGELOG.md -->

## 0.4.0 (2026-08-24)
<!-- title: monitor mode -->

The rollout switch. Adopting contracts on a live API — or tightening an existing one — used to mean flipping unknown clients from "accepted" to "422" in a single deploy. A contract can now run in **monitor mode**: the full pipeline executes (unwrap, cast, validate, defaults), but a violation is **reported instead of rejected** and the request proceeds exactly as it did before the contract existed. Deploy monitoring, dashboard the would-be rejections, then enforce controller by controller — every 422 you finally return is one you already counted.

### Added
- **`mode: :monitor` on `permit_params`, and an app-wide `Permittable.mode` default** (`:enforce` unless set; a rule's own `mode:` always wins, in both directions). On a violating request in monitor mode nothing raises and nothing renders: the `invalid_parameters.permittable` event fires with `mode: :monitor`, the logger warns with the offending paths, and `permitted_params` returns the **raw pass-through** — exactly what the client sent, no casts, no defaults, no transforms (a missing `root:` passes an empty hash; a rootless contract drops only the router's bookkeeping keys). Monitor rules validate **eagerly in the `before_action` regardless of `enforce:`**, so telemetry never depends on the action calling `permitted_params` — legacy actions still reading `params` directly are exactly the ones being monitored.
- **`permittable_violations(action = nil)`** — the recorded violation details for the (memoized) validation of `action`, `[]` when the request was clean. The monitor-mode observable; under enforce it swallows its own trigger's raise, making "would this request fail?" a one-liner in tests.
- **`mode:` key on the `invalid_parameters.permittable` payload** (`:enforce` / `:monitor`), so one subscriber can dashboard enforced rejections and monitored would-be rejections side by side. Additive — existing subscribers are unaffected.
- **`x-permittable-mode: "monitor"`** on exported OpenAPI operations whose rule declares monitor mode — the docs must not promise a 422 the server doesn't yet send. Only the per-rule declaration is exported; the app-wide `Permittable.mode` is runtime configuration, not contract data.

Contracts that don't opt in are byte-for-byte unaffected: the default mode is `:enforce` and the enforce path behaves exactly as before.

## 0.3.0 (2026-08-24)
<!-- title: OpenAPI export -->

Contracts gain a third reader. The registry that already drives the validator and the schema-drift guard now also generates **OpenAPI 3.1** — because the schema is emitted from the same frozen data the server enforces, the docs cannot drift from the validation. Fully additive; no behaviour of existing contracts changes.

### Added
- **`Permittable::JsonSchema`** — converts rules and fields into JSON Schema (draft 2020-12): types map onto their canonical JSON encodings (`:decimal` as `["string", "number"]` + `format: decimal`), `in:` → `enum`/`minimum`/`maximum`, `length:` → `minLength`/`maxLength` or `minItems`/`maxItems`, `format:` → `pattern` with `\A`/`\z` translated to `^`/`$`, `default:` → `default`, `unknown: :error` → `additionalProperties: false` at every level, `root:` → a required wrapper object, `sensitive:` → `writeOnly: true`. Required strings get `minLength: 1` (`""` is absent). What has no ECMA/JSON-Schema equivalent stays visible instead of guessed: Ruby-only or flagged regexps export as `x-permittable-pattern`, `validate:`/`transform:` as `x-permittable-custom-validation`/`x-permittable-transformed`, non-numeric Ranges as `x-permittable-range`. Emission is deterministic, so generated documents are committable and diff-stable.
- **`Permittable::OpenAPI`** — assembles full OpenAPI 3.1 documents (`.document`) and fragments (`.request_body_for`, `.operations_for`, `.components`) from any set of controllers, plain Ruby, no Rails required. Operations resolve through `permit_rule_for`, so last-matching-rule-wins holds in the docs exactly as at request time; every operation references shared components typing the 422 (and, for rooted contracts, 400) error envelope. Catch-all rules expand through `action_methods` (the concern's own public methods excluded) or surface as `"*"` + `x-permittable-catch-all`; unrouted operations land in `x-permittable-controllers` rather than being dropped.
- **`bin/rails permittable:openapi[output]`** — rake task (loaded by the Railtie) that eager-loads the app, collects every controller with contracts, maps actions onto `paths` via the route set (`:id` → `{id}`), and prints or writes the document. `OPENAPI_TITLE`/`OPENAPI_VERSION` override the `info` block.
- **`desc:` and `example:` field options, `desc:` on `permit_params`** — documentation passthrough carried on the frozen contract data and ignored by the runtime. An `example:` is validated against its own field's contract at class load, exactly like `default:`, so published examples can't lie either.

## 0.2.0 (2026-08-18)
<!-- title: custom error messages -->

### Added
- `message:` field option for customizing violation messages, on every field kind (scalar, array, nested). A String covers every violation code on the field; a Hash of code → String targets specific codes — including Symbol codes returned by `validate:` — while unmatched codes keep the default rendering. A resolved message is carried in the violation detail as `message:` and replaces the `(code)` part of the `InvalidParameters` summary, so it flows into the error envelope and the `invalid_parameters.permittable` instrumentation payload unchanged. An array's message also covers its elements' violations; a malformed `message:` raises at class load like every other contract mistake.
- `violate!(param, code, message: nil)` — finalize's violation verb accepts the same optional human-readable message.

Contracts that don't opt in are byte-for-byte unaffected: details keep the bare `{ param:, code: }` shape and the summary keeps its `param (code)` rendering.

## 0.1.2 (2026-08-16)
<!-- title: gem metadata -->

Metadata-only release. `lib/` is byte-for-byte identical to 0.1.1, so upgrading changes nothing at runtime — it exists to publish the rewritten gem description, which RubyGems only refreshes on a new version.

### Changed
- Rewrote the gem summary and description. Both now open with the comparison the README already draws — strong parameters say which keys may pass, a contract says what each field should be — rather than with implementation vocabulary. The schema-drift guard is presented as a consequence of contracts being class-level data instead of as one more bullet.

### Internal
- The publish job creates the GitHub release itself, taking the title from this file's `<!-- title: ... -->` marker and the body from the matching section.
- Development dependencies: simplecov 0.22 → 1.1, `actions/checkout` 6 → 7.

## 0.1.1 (2026-08-16)
<!-- title: maintenance release -->

Maintenance release. The public API and every documented behaviour are identical to 0.1.0; upgrading is a no-op.

### Changed
- Internal style pass to satisfy the RuboCop config added in this release (hash alignment, guard clauses, anonymous block forwarding).
- `cast_datetime` folds `DateTime` into the `Time` branch whose body it already shared. Dispatch order is unchanged, so `DateTime` still matches ahead of `Date`, which it subclasses.
- Dropped `require "set"` from the filter parameter registry: `Set` has been autoloaded since Ruby 3.1 and the gemspec already floors at 3.2.

### Added
- CI on Ruby 3.2 (RuboCop + RSpec) and tag-driven publishing to RubyGems via trusted publishing. Repository tooling only — not part of the packaged gem.

## 0.1.0 (2026-08-16)
<!-- title: initial release -->

Initial extraction from [concerns_on_rails](https://github.com/VSN2015/concerns_on_rails) (developed there on `feature/permittable` as `ConcernsOnRails::Controllers::Permittable`; concerns_on_rails now depends on this gem and aliases that constant to `::Permittable`).

### Added
- **`Permittable`** — declarative, typed params contracts for Rails controllers. `permit_params *actions, root:, model:, unknown:, enforce:` declares a per-action contract (repeatable; no actions = catch-all; last matching rule wins; inherited copy-on-write) whose block DSL (`required`/`optional`/`array`, nested blocks) types every field (`:string :integer :float :decimal :boolean :date :datetime`) and validates it (`in:`, `format:`, `length:`, `normalize:` presets/Proc, `default:` — itself contract-checked at class load — and custom `validate:` with symbol violation codes). `permitted_params` returns the cast/validated/defaulted hash (lazy; `enforce: true` moves the check to a before_action); violations raise `Permittable::InvalidParameters`, auto-rescued into a JSON error envelope as 422 (400 for a missing `root:` key) with machine-readable `details:`, and instrument `invalid_parameters.permittable`.
- **Schema-drift guard**: `model:` (a class, or `true` to infer from `controller_name`) checks every non-`virtual:` scalar field against the model's columns at controller class load — a column dropped by a migration fails the deploy with a copy-paste migration hint, not the request. Skips gracefully when the schema is unreachable.
- **Strict coercion**: no ActiveModel::Type leniency — `"abc"` is never `0`, `?age[]=1` type confusion is a violation, not a 500. `nil`/`""` are ABSENT (absent optionals omitted, so partial updates never nil-out columns; `default:` fills absence).
- **Output reshaping**: per-field `transform:` (a callable applied AFTER cast + validation; defaults and absent fields untouched, partially-invalid arrays never transformed) and a once-per-contract `finalize do |p| ... end` (runs only when every field validated, on a bare runner — controller state unreachable — must return the final Hash) with `violate!(param, code)` as the cross-field validation seam. The request's `params` is never mutated.
- **`sensitive: true`** registers field names with `Permittable.filter_parameter_registry` (swappable, duck-typed), consulted at filter time by the proc `Permittable::Railtie` appends to `config.filter_parameters`.
- Sole runtime dependency: activesupport (>= 5.0, < 9). actionpack/activerecord are optional integration points.
