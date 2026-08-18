# Permittable

[![Gem Version](https://img.shields.io/gem/v/permittable.svg)](https://rubygems.org/gems/permittable)
[![CI](https://github.com/VSN2015/permittable/actions/workflows/ci.yml/badge.svg)](https://github.com/VSN2015/permittable/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

**Strong parameters for Rails that also know types, bounds, and defaults.**

`params.permit` answers exactly one question: *which keys may pass?* Everything else — is `age` really a number, is `email` shaped like an email, what should `plan` be when the client omits it, and *why* was this request rejected — is left to you, usually as hand-written checks scattered through the action.

A Permittable contract answers those questions too. It **casts** each field to a declared type, **validates** it, applies **defaults**, optionally **reshapes** the output, and turns every failure into a machine-readable 422 that names the offending parameter.

And because a contract is *class-level data* rather than code inside the action, it can be inspected — and checked against your database when the controller loads, so a column dropped by a migration fails the deploy instead of the request.

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
    User.create!(permitted_params)   # cast, validated, defaulted
  end
end
```

A violating request never reaches your action:

```json
{ "success": false,
  "error": { "message": "Invalid parameters: user.age (inclusion)",
             "code": "invalid_parameters",
             "details": [{ "param": "user.age", "code": "inclusion" }] } }
```

---

## Contents

- [Why](#why) · [Installation](#installation) · [How a request flows](#how-a-request-flows)
- [Declaring a contract](#declaring-a-contract) · [The field DSL](#the-field-dsl) · [Field options](#field-options)
- [Types and strict coercion](#types-and-strict-coercion) · [Absence, defaults, and partial updates](#absence-defaults-and-partial-updates)
- [Violations and error responses](#violations-and-error-responses) · [Unknown parameters](#unknown-parameters)
- [Output reshaping](#output-reshaping-transform-and-finalize) · [The schema-drift guard](#the-schema-drift-guard)
- [Sensitive parameters](#sensitive-parameters-and-log-redaction) · [Instrumentation](#instrumentation)
- [Exporting OpenAPI](#exporting-openapi-docs-that-cannot-drift)
- [API reference](#api-reference) · [Errors caught at class load](#errors-caught-at-class-load) · [Compatibility](#compatibility)

---

## Why

| | `params.permit` | `params.expect` (Rails 8) | Permittable |
|---|---|---|---|
| Filters unknown keys | ✅ | ✅ | ✅ |
| Requires a root key | via `require` | ✅ | ✅ |
| Casts to a declared type | ❌ | ❌ | ✅ |
| Validates bounds, formats, sets | ❌ | ❌ | ✅ |
| Supplies defaults | ❌ | ❌ | ✅ |
| Machine-readable error details | ❌ | ❌ | ✅ |
| Reshapes output | ❌ | ❌ | ✅ |
| Checked against your schema at boot | ❌ | ❌ | ✅ |
| Exports OpenAPI / JSON Schema | ❌ | ❌ | ✅ |

The design rests on one idea: **a contract is data, not code.** It is declared once at the class level, frozen, inheritable, and introspectable. Everything else here follows from that — the drift guard can read it at boot, `finalize` can run on a bare object with no controller state, and the whole contract can be printed or tested without a request.

## Installation

```ruby
gem "permittable"
```

Then include it wherever you need it — typically once in `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  include Permittable
end
```

The **only runtime dependency is `activesupport`**. `actionpack` (for `rescue_from`, `before_action`, and `ActionController::Parameters`) and `activerecord` (for the `model:` schema-drift guard) are optional — every touchpoint is guarded with `respond_to?`/`defined?`, so your app brings whatever it already has. The concern works on a plain Ruby object that responds to `params`, which is what makes it straightforward to unit-test.

> **Naming note:** some legacy stacks (InheritedResources) define their own `permitted_params`. Don't include both on one controller.

## How a request flows

```
params
  │
  ├─ 1. unwrap root:          params[:user]        → 400 if missing or not a hash
  ├─ 2. per field:  normalize → cast → validate → transform
  ├─ 3. unknown-key check     at every nesting level
  ├─ 4. finalize              only if nothing violated
  │
  └─ permitted_params → HashWithIndifferentAccess     (or raises InvalidParameters)
```

Validation is **lazy by default**: it runs on the first `permitted_params` call, so an action that never reads params never pays for it. Pass `enforce: true` to run it in a `before_action` instead, rejecting bad requests before the action body executes. Results are **memoized per action**.

## Declaring a contract

```ruby
permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, desc: nil, &contract)
```

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the contract covers. **No actions = catch-all** for the controller |
| `root:` | `false` | Key to unwrap first (the `require(:user)` equivalent). Missing or non-hash root → **400** |
| `model:` | `nil` | Model class, or `true` to infer from `controller_name`, enabling the [drift guard](#the-schema-drift-guard) |
| `unknown:` | `:ignore` | `:ignore` / `:log` / `:error` — how to treat undeclared keys |
| `enforce:` | `false` | `false` validates lazily on first use; `true` validates in a `before_action` |
| `desc:` | `nil` | Documentation only — becomes the operation description in [exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) |

`permit_params` is **repeatable**, and **the last matching rule wins**. Contracts behave like configuration: a base controller declares a catch-all, and a subclass overrides it for specific actions.

```ruby
class ApiController < ApplicationController
  permit_params(unknown: :error) { optional :page, :integer, in: 1..1000 }   # catch-all
end

class ReportsController < ApiController
  permit_params :export, root: :report do                                    # wins for #export
    required :format, :string, in: %w[csv pdf]
  end
end
```

Rules accumulate by **reassignment, never mutation**, so subclasses inherit copy-on-write and can never corrupt a parent's contract.

## The field DSL

### Scalars

```ruby
required :name, :string          # type defaults to :string
optional :age,  :integer
```

### Nested hashes

Pass a block instead of a type. Violation paths are dotted (`user.address.zip`).

```ruby
optional :address do
  required :city, :string
  optional :zip,  :string, format: /\A\d{5}\z/
end
```

### Arrays

`of:` declares an array of scalars; a block declares an array of hashes. Arrays are **optional unless `required: true`**, `length:` constrains the element **count**, and element failures carry their index (`items[1]`).

```ruby
array :tag_names, of: :string, length: 0..10
array :line_items, required: true do
  required :sku,      :string
  required :quantity, :integer, in: 1..99
end
```

## Field options

Which options are legal depends on the field kind — anything else raises at class load.

| Option | Scalar | Array | Nested | Meaning |
|---|:---:|:---:|:---:|---|
| `in:` | ✅ | — | — | Allowed values: a `Range` (bounds-checked with `cover?`) or an `Array` |
| `format:` | ✅¹ | — | — | Regexp the value must match |
| `length:` | ✅¹ | ✅ | — | `Range` or `Integer`. Character count on strings, **element count** on arrays |
| `normalize:` | ✅¹ | — | — | `:squish`, `:strip`, `:downcase`, `:upcase`, `:email`, or a Proc. Runs **before** the cast |
| `default:` | ✅ | ✅ | — | Value used when the field is absent. Validated against the field's own contract at class load |
| `validate:` | ✅ | ✅ | — | Callable. Falsy fails as `"invalid"`; a returned `Symbol` becomes the violation code |
| `transform:` | ✅ | ✅ | — | Callable applied **after** cast and validation — see [output reshaping](#output-reshaping-transform-and-finalize) |
| `virtual:` | ✅ | ✅ | ✅ | Exempt this field from the schema-drift guard |
| `sensitive:` | ✅ | ✅ | ✅ | Register the field name for [log redaction](#sensitive-parameters-and-log-redaction) |
| `of:` | — | ✅ | — | Element type for an array of scalars (default `:string`) |
| `required:` | — | ✅ | — | Arrays are optional unless this is `true` |
| `desc:` | ✅ | ✅ | ✅ | Documentation only — the field's `description` in [exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) |
| `example:` | ✅ | ✅ | — | Documentation only, but **validated against the field's own contract at class load**, like `default:` |

¹ `format:`, `length:`, and `normalize:` reason about characters and are **only valid on `:string` fields**. On any other type they would silently apply to an already-cast value, so declaring them raises at class load.

`validate:` is the escape hatch for anything the built-ins don't cover:

```ruby
optional :slug, :string, validate: ->(v) { v.match?(/\A[a-z0-9-]+\z/) || :malformed_slug }
```

## Types and strict coercion

Coercion is **deliberately strict**, and deliberately *not* `ActiveModel::Type`. Rails' casts are lenient by design — `"abc".to_i` is `0`, `Boolean.cast("abc")` is `true` — and silently corrupting untrusted input is precisely what a contract must not do. A value the type cannot faithfully represent is a **violation, not a guess**.

| Type | Accepts | Rejects (`invalid_type`) |
|---|---|---|
| `:string` | `String`; `Numeric`/`true`/`false` are stringified | Arrays, hashes |
| `:integer` | `Integer`; whole `Float`s (`4.0`); base-10 numeric strings | `"4.5"`, `"abc"`, `4.5` |
| `:float` | `Numeric`; any `Float()`-parseable string | `"abc"` |
| `:decimal` | `Numeric` or `String` → `BigDecimal` | Unparseable strings |
| `:boolean` | `true`/`false`, `"true"`/`"false"`, `"1"`/`"0"`, `1`/`0` | `"yes"`, `"on"`, `2` |
| `:date` | `Date`; any `Date.parse`-able string | Unparseable strings |
| `:datetime` | `Time`, `DateTime`, `ActiveSupport::TimeWithZone`, `Date`, parseable strings | Unparseable strings |

Two behaviours worth committing to memory:

- **Type confusion is a violation, not a 500.** A request of `?age[]=1` against a scalar `:integer` field yields `invalid_type`. Arrays, hashes, and nested `ActionController::Parameters` can never satisfy a scalar type, so the classic "`NoMethodError` on `[]`" crash is impossible.
- **Datetimes are normalised to UTC.** A zoneless string parses as UTC regardless of the host timezone, which keeps behaviour deterministic across machines; explicit offsets are honoured and converted.

## Absence, defaults, and partial updates

`nil` and `""` are **both treated as absent** — the query-parameter convention, where an untouched form field arrives as an empty string. Boolean `false` is present.

That single rule produces the behaviour you want from a `PATCH`:

- An **absent optional field is omitted** from the result, so partial updates never nil-out columns.
- An **absent required field violates** with `missing`.
- An absent field **with a `default:` gets the default** — so a defaulted field can never report `missing`. (Declaring `required:` alongside `default:` is a class-load error, since a default implies optionality.)

Because absence and `nil` are the same thing here, **clearing a column to NULL is outside a contract's vocabulary**. Do that explicitly in the action.

Defaults are checked against the field's own contract when the class loads, so `default: "gold"` on a field declared `in: %w[free pro]` fails at boot rather than on every request.

## Violations and error responses

Every failure raises `Permittable::InvalidParameters`, carrying `details` (an array of `{ param:, code: }`) and a `status`. On a real controller it is auto-rescued into the error envelope.

| Code | Raised when |
|---|---|
| `missing` | A required field is absent, or the `root:` key is missing (this one is a **400**) |
| `invalid_type` | The value cannot be faithfully cast to the declared type |
| `inclusion` | The value is outside `in:` |
| `format` | The value doesn't match `format:` |
| `length` | A string's length, or an array's element count, is outside `length:` |
| `unknown` | An undeclared key was sent while `unknown: :error` |
| `invalid` | A `validate:` callable returned a falsy value |
| *your symbol* | A `validate:` callable returned a `Symbol`, or `violate!` was called in `finalize` |

Paths are fully qualified: `user.address.zip`, `line_items[1].sku`.

**Status codes:** a missing root key renders **400** (the request is malformed — the envelope you asked for isn't there); field-level violations render **422** (well-formed, semantically wrong).

**Custom rendering:** if your controller defines `render_error`, the envelope delegates to it as `render_error(message:, code:, status:, errors:)` — the `errors:` key is passed only when details exist, so hosts documenting a three-keyword contract keep working. Otherwise the inline JSON shape shown at the top of this README is rendered. Either way, `render_invalid_parameters` is a normal method you can override.

## Unknown parameters

`unknown:` decides what happens to keys you never declared, **at every nesting level**.

| Mode | Behaviour |
|---|---|
| `:ignore` (default) | Silently dropped, exactly like strong parameters |
| `:log` | Dropped, with a `logger.warn` naming the full paths |
| `:error` | Each undeclared key becomes an `unknown` violation |

Rails merges `controller`, `action`, and `format` into `params`; these are exempt at the top level so `unknown: :error` doesn't flag the router's own bookkeeping. Inside a `root:` or a nested hash there is no such exemption, because nothing legitimately injects keys there.

## Output reshaping (`transform:` and `finalize`)

This is the safe replacement for params-mutating `before_action`s. **Both layers operate on the validated copy — the request's `params` is never touched.**

### `transform:` — per field

A callable applied **after** cast and validation, reshaping one field's output:

```ruby
required :tags, :string, transform: ->(v) { v.split(",") }
```

It runs only on request-supplied values. Absent fields stay absent, `default:` values are authored in their final shape, and a **partially-invalid array is never transformed** — user code is never handed garbage it didn't agree to see.

### `finalize` — per contract

Declared once, at the top level only. It runs after every field has validated cleanly, receives the result hash, and must return the final `Hash`. Use it to combine parallel fields, build value objects, or drop scaffolding keys.

It executes on a **bare runner, not the controller**, so contracts stay pure data plus pure functions and can never grow a dependency on request state. Its one extra verb is `violate!(param, code)`, which records a violation and **halts the block immediately** — so the code after a `violate!` may assume the invariant it just checked. That makes `finalize` the natural home for cross-field validation (`ends_at` after `starts_at`, matching array lengths).

```ruby
permit_params :create, root: :lease_addendum_form do
  required :resident_signatures, :string, transform: ->(v) { v.split("<<delimiter>>") }
  required :signer_names,        :string, transform: ->(v) { v.split(",") }

  finalize do |p|
    unless p[:signer_names].length == p[:resident_signatures].length
      violate!("lease_addendum_form.signer_names", :length_mismatch)
    end

    p[:signatures] = p[:resident_signatures].zip(p[:signer_names]).map do |image, name|
      Signature.new(image: image, full_name: name)
    end
    p.except(:resident_signatures, :signer_names)
  end
end
```

Forgetting to return the hash raises an `ArgumentError` telling you exactly that.

## The schema-drift guard

This is why `model:` exists. Pass a model class (or `true` to infer it from `controller_name`) and **every non-virtual scalar field is checked against the model's columns when the macro runs** — that is, at controller class load.

Production eager-loads controllers, so a column dropped by a migration **fails the deploy, not the request**:

```
Permittable: 'nickname' does not exist in the database (table: users).
Add it with: bin/rails generate migration AddNicknameToUsers nickname:string
If this parameter is not backed by a column, declare it with virtual: true.
```

The error carries a ready-to-paste migration command, typed from your own field declaration.

- **Fields not backed by a column** — `password_confirmation`, terms checkboxes, search filters — opt out with `virtual: true`.
- **Nested and array fields are implicitly virtual**, since only scalars map one-to-one onto columns.
- **The check skips when the schema is unreachable** (`db:create`, a fresh `db:migrate`, `assets:precompile`, CI bootstrap), so controller classes stay loadable. Skipping is self-healing: once the migration runs and classes reload, the check happens for real. A missing column with a *reachable* schema still raises — the rescue is scoped to `ActiveRecord::ActiveRecordError` precisely so real bugs keep surfacing.

In CI, one spec calling `Rails.application.eager_load!` exercises every contract in the whole app.

## Sensitive parameters and log redaction

Mark a field `sensitive: true` and its name is registered with `Permittable.filter_parameter_registry`; `Permittable::Railtie` appends a filter proc to `config.filter_parameters` at boot.

```ruby
optional :ssn, :string, sensitive: true
```

The indirection is deliberate. Appending plain symbols to `config.filter_parameters` at class-load time misses every consumer that snapshots the list at boot — ActiveRecord's `filter_attributes` copy, lograge-style initializers, precompiled filters. A **single proc appended once at boot, consulting a live registry at filter time**, means fields registered when a controller loads later (lazy loading in development) are still redacted. The initializer runs before `active_record.set_filter_attributes`, so values are redacted from both request logs and `#inspect`.

Matching mirrors Rails' own symbol-filter semantics: case-insensitive substring match on the parameter key. The registry is fully duck-typed (`#add`, `#include?`, `#to_proc`, `#reset!`) and swappable via `Permittable.filter_parameter_registry=`, so a host gem can pool registrations into its own.

## Instrumentation

Every violation emits an `ActiveSupport::Notifications` event, so rejected requests can be dashboarded and alerted on:

```ruby
ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
  payload[:controller]  # "users"
  payload[:action]      # "create"
  payload[:details]     # [{ param: "user.age", code: "inclusion" }]
end
```

## Exporting OpenAPI (docs that cannot drift)

Because a contract is data, it has a third reader beyond the validator and the drift guard: an exporter that emits **OpenAPI 3.1** (whose request bodies are plain JSON Schema). The schema is generated from the same frozen data the server enforces, so — like the drift guard, pointed outward — the docs cannot lie:

```sh
bin/rails permittable:openapi                       # JSON to stdout
bin/rails "permittable:openapi[openapi/api.json]"   # write to a file
```

The task eager-loads the app (also exercising the drift guard), collects every controller with contracts, and maps documented actions onto `paths` via the route set. `OPENAPI_TITLE` / `OPENAPI_VERSION` override the `info` block. Pipe the output through Swagger UI, Redoc, Postman, or [`openapi-typescript`](https://github.com/openapi-ts/openapi-typescript) and your frontend gets compile-time types for every request body.

Or build fragments programmatically — no Rails required:

```ruby
Permittable::JsonSchema.rule(UsersController.permit_rule_for(:create))  # request-body schema
Permittable::OpenAPI.request_body_for(UsersController, :create)         # OpenAPI requestBody object
Permittable::OpenAPI.operations_for(UsersController)                    # { action => operation }
Permittable::OpenAPI.document(controllers: [...], info: { "title" => "My API" })
```

How contracts map:

| Contract | Emitted schema |
|---|---|
| `required` / `optional` | the object's `required:` array; required strings also get `minLength: 1` (`""` is absent) |
| `:string` `:integer` `:float` `:boolean` | `string` / `integer` / `number` / `boolean` |
| `:date` / `:datetime` | `string` + `format: date` / `date-time` |
| `:decimal` | `type: ["string", "number"]` + `format: decimal` (string is the precision-safe encoding) |
| `in:` Array / numeric Range | `enum` / `minimum` + `maximum` (exclusive ends honoured) |
| `length:` | `minLength`/`maxLength` on strings, `minItems`/`maxItems` on arrays |
| `format:` | `pattern`, with `\A`/`\z` translated to `^`/`$` |
| `default:` / `desc:` / `example:` | `default` / `description` / `examples` |
| nested block / `array` | `object` + `properties` / `array` + `items` |
| `unknown: :error` | `additionalProperties: false`, at every nesting level |
| `root:` | the wrapping object, itself required |
| `sensitive: true` | `writeOnly: true` (never echoed in responses) |

Every operation references shared components for the [error envelope](#violations-and-error-responses): a `422` response always, plus a `400` when the contract declares a `root:`. So consumers get typed *errors*, not just typed inputs.

**What is honestly unrepresentable stays visible instead of guessed.** A `format:` regexp using a Ruby-only construct (or flags) is exported as `x-permittable-pattern` rather than a mistranslated `pattern`; `validate:`/`transform:` are flagged `x-permittable-custom-validation`/`x-permittable-transformed`; actions covered only by a catch-all rule on a plain-Ruby host appear under `"*"` with `x-permittable-catch-all`; operations with no matching route land in `x-permittable-controllers` instead of being dropped. The schema documents the canonical JSON encoding — the runtime additionally accepts string-encoded scalars (`"42"`, `"true"`) for form/query payloads.

Output is deterministic (fixed key order, declaration-order properties), so the generated file can be committed and reviewed as a diff — a contract change shows up in the same PR as its documentation change.

## API reference

### Instance methods

| Method | Purpose |
|---|---|
| `permitted_params(action = action_name)` | The cast, validated, defaulted `HashWithIndifferentAccess`. Memoized per action. Raises `InvalidParameters` on violation, or `ArgumentError` when no contract covers the action |
| `enforce_params_contract` | The `before_action` entry point. Only validates rules declared `enforce: true`. Public, so hosts can `skip_before_action` it |
| `render_invalid_parameters(error)` | The `rescue_from` target. Renders via the host's `render_error` when defined, the inline envelope otherwise |

### Class methods

| Method | Purpose |
|---|---|
| `permit_params(*actions, **opts, &contract)` | Declare a contract |
| `permittable_contracts` | The frozen array of every declared rule — introspectable, testable |
| `permit_rule_for(action)` | The last rule matching `action`, or `nil` |

### Module

| | |
|---|---|
| `Permittable.filter_parameter_registry` | The live registry of `sensitive:` field names |
| `Permittable.filter_parameter_registry=` | Swap in your own duck-typed registry |
| `Permittable::InvalidParameters` | Raised on violation; carries `#details` and `#status` |
| `Permittable::JsonSchema` | Contract data → JSON Schema fragments (`.rule`, `.object`, `.field`) |
| `Permittable::OpenAPI` | OpenAPI 3.1 assembly (`.document`, `.operations_for`, `.request_body_for`, `.components`) |

## Errors caught at class load

A bad contract is a programmer error, so it fails when the class loads — never at request time. Every message names the field and explains the fix.

- A field declared twice in one contract
- An unknown option for the field's kind, listing what *is* allowed
- An unknown type, listing the supported ones
- An unknown `normalize:` preset, listing the presets
- `format:`, `length:`, or `normalize:` on a non-`:string` field
- `length:` that isn't a `Range` or `Integer`; `in:` that doesn't respond to `include?`
- `validate:` or `transform:` that isn't callable
- A `default:` or `example:` that violates its own field's contract, or an array `default:`/`example:` whose elements violate `of:`
- `required: true` combined with `default:`
- A field given both a type and a nested block; an array given both `of:` and a block
- An empty contract, or a nested block declaring no sub-fields
- `finalize` declared twice, without a block, or inside a nested block
- `permit_params` without a block, or an invalid `unknown:` mode
- A `model:` that isn't an ActiveRecord class, or `model: true` that can't be inferred

## Compatibility

| | |
|---|---|
| Ruby | >= 3.2 |
| Rails / ActiveSupport | >= 5.0, < 9 |
| Required dependency | `activesupport` only |
| Optional | `actionpack` (rendering, `before_action`), `activerecord` (drift guard) |

Using [concerns_on_rails](https://github.com/VSN2015/concerns_on_rails)? `ConcernsOnRails::Controllers::Permittable` is an alias for this module, and `sensitive:` registrations pool into that gem's shared filter registry.

## Development

```sh
bundle install
bundle exec rspec      # 104 examples
bundle exec rubocop
```

Releases are automated: bump `lib/permittable/version.rb`, add a `CHANGELOG.md` section, then push a `vX.Y.Z` tag. CI publishes to RubyGems via trusted publishing (OIDC — no API keys stored) and creates the GitHub release.

## License

[MIT](LICENSE.txt).
