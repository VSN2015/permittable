<!-- CHANGELOG.md -->

## 0.1.0 (2026-08-16)

Initial extraction from [concerns_on_rails](https://github.com/VSN2015/concerns_on_rails) (developed there on `feature/permittable` as `ConcernsOnRails::Controllers::Permittable`; concerns_on_rails now depends on this gem and aliases that constant to `::Permittable`).

### Added
- **`Permittable`** — declarative, typed params contracts for Rails controllers. `permit_params *actions, root:, model:, unknown:, enforce:` declares a per-action contract (repeatable; no actions = catch-all; last matching rule wins; inherited copy-on-write) whose block DSL (`required`/`optional`/`array`, nested blocks) types every field (`:string :integer :float :decimal :boolean :date :datetime`) and validates it (`in:`, `format:`, `length:`, `normalize:` presets/Proc, `default:` — itself contract-checked at class load — and custom `validate:` with symbol violation codes). `permitted_params` returns the cast/validated/defaulted hash (lazy; `enforce: true` moves the check to a before_action); violations raise `Permittable::InvalidParameters`, auto-rescued into a JSON error envelope as 422 (400 for a missing `root:` key) with machine-readable `details:`, and instrument `invalid_parameters.permittable`.
- **Schema-drift guard**: `model:` (a class, or `true` to infer from `controller_name`) checks every non-`virtual:` scalar field against the model's columns at controller class load — a column dropped by a migration fails the deploy with a copy-paste migration hint, not the request. Skips gracefully when the schema is unreachable.
- **Strict coercion**: no ActiveModel::Type leniency — `"abc"` is never `0`, `?age[]=1` type confusion is a violation, not a 500. `nil`/`""` are ABSENT (absent optionals omitted, so partial updates never nil-out columns; `default:` fills absence).
- **Output reshaping**: per-field `transform:` (a callable applied AFTER cast + validation; defaults and absent fields untouched, partially-invalid arrays never transformed) and a once-per-contract `finalize do |p| ... end` (runs only when every field validated, on a bare runner — controller state unreachable — must return the final Hash) with `violate!(param, code)` as the cross-field validation seam. The request's `params` is never mutated.
- **`sensitive: true`** registers field names with `Permittable.filter_parameter_registry` (swappable, duck-typed), consulted at filter time by the proc `Permittable::Railtie` appends to `config.filter_parameters`.
- Sole runtime dependency: activesupport (>= 5.0, < 9). actionpack/activerecord are optional integration points.
