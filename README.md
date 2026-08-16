# Permittable

**Typed, validated params contracts for Rails controllers — plus a schema-drift guard.**

`Permittable` is what strong parameters would be if it also knew types, bounds, defaults, and *why* a request was bad. `params.permit` (and Rails 8's `params.expect`) only answer "which keys may pass"; a Permittable contract additionally **casts** each field, **validates** it, applies **defaults**, reshapes the output, and turns every failure into a machine-readable 422. Because the contract is class-level data rather than code inside the action, it is introspectable — and can be checked against a model's schema at boot.

```ruby
class UsersController < ApplicationController
  include Permittable

  permit_params :create, :update, root: :user, model: User do
    required :name,  :string,  length: 1..80, normalize: :squish
    required :email, :string,  format: URI::MailTo::EMAIL_REGEXP, normalize: :email
    optional :age,   :integer, in: 18..120
    optional :ssn,   :string,  sensitive: true          # auto-redacted from logs
    optional :plan,  :string,  in: %w[free pro], default: "free"
    array    :tag_names, of: :string, length: 0..10, virtual: true
    optional :address do
      required :city, :string
      optional :zip,  :string, format: /\A\d{5}\z/
    end
  end

  def create
    user = User.create!(permitted_params)   # cast, validated, defaulted
  end
end
```

A violating request renders:

```json
{ "success": false,
  "error": { "message": "Invalid parameters: user.age (inclusion)",
             "code": "invalid_parameters",
             "details": [{ "param": "user.age", "code": "inclusion" }] } }
```

## Installation

```ruby
gem "permittable"
```

The only runtime dependency is `activesupport`. `actionpack` (rescue_from / before_action / `ActionController::Parameters`) and `activerecord` (the `model:` schema-drift guard) are optional — every touchpoint is guarded, so your app brings what it already has.

## The schema-drift guard

With `model:` (a class, or `true` to infer from the controller name), every non-`virtual:` scalar field is checked against the model's columns **at controller class load**. Production eager-loads controllers, so a column dropped by a migration fails the deploy, not the request:

```
Permittable: 'nickname' does not exist in the database (table: users).
Add it with: bin/rails generate migration AddNicknameToUsers nickname:string
If this parameter is not backed by a column, declare it with virtual: true.
```

Nested and array fields are implicitly virtual. The check skips gracefully when the schema is unreachable (`db:create`, `assets:precompile`). In CI, one spec running `Rails.application.eager_load!` exercises every contract in the app.

## Configuration

### `permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, &contract)`

Repeatable; rules are inherited by subclasses copy-on-write. **No positional actions = catch-all**, and **the last matching rule wins** (contracts are configuration overrides).

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the contract covers; **none = catch-all** |
| `root:` | `false` | Key to unwrap first (`require(:user)` equivalent); missing/non-hash root → **400** |
| `model:` | `nil` | Model class (or `true` to infer from `controller_name`) enabling the schema-drift guard |
| `unknown:` | `:ignore` | `:ignore` / `:log` / `:error` — undeclared keys, at every nesting level (`controller`/`action`/`format` exempt at top level) |
| `enforce:` | `false` | `false` = validate lazily on first `permitted_params` call; `true` = validate in a `before_action` |

### Field DSL

- `required :name, :type, **opts` / `optional :name, :type, **opts` — type defaults to `:string`; types: `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime`.
- A block instead of a type declares a **nested hash**; violation paths are dotted (`user.address.zip`).
- `array :name, of: :type` (or a block for arrays of hashes) — `length:` constrains the element **count**, element failures carry the index (`items[1]`), `required: true` opts in.

Per-field options: `in:` (Range/Array), `format:` / `length:` / `normalize:` (`:squish`, `:strip`, `:downcase`, `:upcase`, `:email`, or a Proc; string fields only), `default:` (validated against the field's own contract at class load), `validate:` (Proc — falsy fails as `"invalid"`, a returned Symbol becomes the violation code), `transform:` (below), `virtual:`, `sensitive:`.

Every bad declaration raises a teaching `ArgumentError` at class load.

## Output reshaping (`transform:` / `finalize`)

The safe replacement for params-mutating before_actions — both layers operate on the validated **copy**; the request's `params` is never touched.

- **`transform:`** (scalar and array fields) — a callable applied **after** cast and validation: `transform: ->(v) { v.split(",") }` turns a validated delimited String into an Array. Absent fields stay absent, `default:` values are authored in final shape, and a partially-invalid array is never transformed.
- **`finalize do |p| … end`** (once per contract, top level only) — runs after every field validated cleanly, receives the result hash, and must return the final Hash. It executes on a bare runner, **not** the controller, so contracts stay pure; its one extra verb, `violate!(param, code)`, records a violation and halts the block immediately — the cross-field validation seam.

```ruby
permit_params :create, root: :lease_addendum_form do
  required :resident_signatures, :string, transform: ->(v) { v.split("<<delimiter>>") }
  required :signer_names,        :string, transform: ->(v) { v.split(",") }

  finalize do |p|
    violate!("lease_addendum_form.signer_names", :length_mismatch) unless p[:signer_names].length == p[:resident_signatures].length
    p[:signatures] = p[:resident_signatures].zip(p[:signer_names]).map { |image, name| Signature.new(image:, full_name: name) }
    p.except(:resident_signatures, :signer_names)
  end
end
```

## Methods

- `permitted_params(action = action_name)` — the cast/validated/defaulted `HashWithIndifferentAccess`. Absent optional fields are **omitted** (partial updates never nil-out columns). Memoized per action. Raises `Permittable::InvalidParameters` on violation; `ArgumentError` when no contract covers the action (programmer error).
- `enforce_params_contract` — the `before_action` entry point (skip with `skip_before_action`); only validates rules declared with `enforce: true`.
- `render_invalid_parameters(error)` — the `rescue_from` target; renders via the host's `render_error` when defined, the identical inline envelope otherwise.
- Class-side introspection: `permittable_contracts` and `permit_rule_for(action)`.
- `Permittable.filter_parameter_registry` — duck-typed, swappable sink for `sensitive:` field names; `Permittable::Railtie` appends its live filter proc to `config.filter_parameters`.

## Semantics worth knowing

- **Coercion is strict** — deliberately not `ActiveModel::Type` (`"abc".to_i == 0` silently corrupts untrusted input). `"4.5"` is not an integer; booleans accept only `true/false/"true"/"false"/"1"/"0"/1/0`; unparseable dates are `invalid_type`; zoneless datetime strings parse as **UTC**.
- **Type confusion is a violation, not a 500**: `?age[]=1` where a scalar is declared yields `invalid_type`.
- `nil` and `""` are both **absent**; boolean `false` is present.
- Every violation instruments `invalid_parameters.permittable` for dashboards.
- Used inside [concerns_on_rails](https://github.com/VSN2015/concerns_on_rails)? `include ConcernsOnRails::Controllers::Permittable` is an alias for this module, and `sensitive:` registrations pool into that gem's shared filter registry.

## Development

```sh
bundle install
bundle exec rspec
```

## License

MIT.
