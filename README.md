<h1 align="center">Permittable</h1>

<p align="center"><strong>Strong parameters for Rails that also know types, bounds, and defaults.</strong></p>

<p align="center">
  <a href="https://rubygems.org/gems/permittable"><img src="https://img.shields.io/gem/v/permittable.svg" alt="Gem Version"></a>
  <a href="https://github.com/VSN2015/permittable/actions/workflows/ci.yml"><img src="https://github.com/VSN2015/permittable/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D.svg" alt="Ruby >= 3.2"></a>
  <a href="https://rubyonrails.org/"><img src="https://img.shields.io/badge/rails-5.0%20%E2%80%93%208.x-D30001.svg" alt="Rails 5.0 - 8.x"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#guide">Guide</a> ·
  <a href="#adopting-on-a-live-api">Adopting on a live API</a> ·
  <a href="#beyond-the-controller">Beyond the controller</a> ·
  <a href="#reference">Reference</a> ·
  <a href="docs/comparison.md">Comparison</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

`params.permit` answers exactly one question: *which keys may pass?* Everything else — is `age` really a number, is `email` shaped like an email, what should `plan` be when the client omits it, and *why* was this request rejected — is left to you, usually as hand-written checks scattered through the action.

A Permittable **contract** answers those questions too. Declared once on the controller class, it **casts** each field to a declared type, **validates** it, applies **defaults**, optionally **reshapes** the output, and turns every failure into a machine-readable 422 that names the offending parameter.

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

## Why

Here is what the contract above replaces. Every Rails codebase has a version of this, and no two of them agree on the error shape:

```ruby
def create
  attrs = params.require(:user).permit(:name, :email, :age, :plan)

  if attrs[:age].present?
    age = Integer(attrs[:age], exception: false)
    return render(json: { error: "age must be a number" }, status: 422) if age.nil?
    return render(json: { error: "age must be 18..120" },  status: 422) unless (18..120).cover?(age)
    attrs[:age] = age
  end
  unless attrs[:email].to_s.match?(URI::MailTo::EMAIL_REGEXP)
    return render(json: { error: "email is invalid" }, status: 422)
  end
  attrs[:plan] = "free" if attrs[:plan].blank?

  User.create!(attrs)
end
```

A contract moves all of it out of the action and into data that the rest of your toolchain can read:

| | `params.permit` | `params.expect` (Rails 8) | Permittable |
|---|:---:|:---:|:---:|
| Filters unknown keys | ✅ | ✅ | ✅ |
| Requires a root key | via `require` | ✅ | ✅ |
| Casts to a declared type | ❌ | ❌ | ✅ |
| Validates bounds, formats, sets | ❌ | ❌ | ✅ |
| Supplies defaults | ❌ | ❌ | ✅ |
| Machine-readable error details | ❌ | ❌ | ✅ |
| Reshapes output | ❌ | ❌ | ✅ |
| Checked against your schema at boot | ❌ | ❌ | ✅ |
| Exports OpenAPI / JSON Schema | ❌ | ❌ | ✅ |
| Report-only rollout mode | ❌ | ❌ | ✅ |
| Drafts contracts from your schema | ❌ | ❌ | ✅ |
| Works outside controllers | ❌ | ❌ | ✅ |

Every option in this space is good software, and Permittable is not always the right one. A longer, honest comparison — `params.expect`, rails_param, dry-validation, typed_params, rswag, the cases where each is the better choice, benchmarks, and migration costs — lives in [docs/comparison.md](docs/comparison.md).

## One idea: a contract is data

Everything in this gem follows from a single decision. A contract is **declared once at the class level, frozen, inheritable, and introspectable**. It is not code that runs inside your action. That makes it readable by more than the validator:

```
                  ┌────────────────────────────────────────────────────┐
                  │  permit_params :create, root: :user, model: User   │
                  │    required :email, :string, format: EMAIL_REGEXP  │
                  │    optional :age,   :integer, in: 18..120          │
                  │  end                                               │
                  └──────────────────────────┬─────────────────────────┘
                             one frozen, class-level contract
                                             │
         ┌─────────────────┬─────────────────┼─────────────────┬─────────────────┐
         ▼                 ▼                 ▼                 ▼                 ▼
   Validator         Drift guard       OpenAPI           RSpec matchers    Contract
   casts, checks,    compares fields   3.1 export from   assert on the     the same DSL on
   defaults; a 422   to DB columns     the same data     rule itself, no   any Hash, no
   names the         at class load;    the server        request needed    controller
   parameter         fails the deploy  enforces                            required
```

The principles that fall out of it:

- **Strict, never lenient.** `"abc"` is never `0`. A value the type cannot faithfully represent is a violation, not a guess.
- **`nil` and `""` are absent.** Absent optionals are omitted from the result, so partial updates never nil-out columns.
- **Mistakes fail at class load.** A malformed contract, a default that violates its own field, or a column that no longer exists fails the boot, never the request.
- **The request's `params` is never mutated.** Reshaping happens on the validated copy.
- **Exports never guess.** Anything JSON Schema cannot represent stays visible as an `x-permittable-*` extension instead of being mistranslated.
- **One dependency.** `activesupport` is the only runtime requirement. Rails, ActionPack, and ActiveRecord are optional integration points.

## Quick start

**1. Add the gem**

```ruby
gem "permittable"
```

**2. Include it once**

```ruby
class ApplicationController < ActionController::Base
  include Permittable
end
```

**3. Declare a contract and read `permitted_params`**

```ruby
class OrdersController < ApplicationController
  permit_params :create, root: :order, model: Order do
    required :sku,      :string
    optional :quantity, :integer, in: 1..99, default: 1
    optional :notes,    :string,  length: 0..500
  end

  def create
    Order.create!(permitted_params)
  end
end
```

That is the whole integration. Violations render the 422 envelope automatically, `model: Order` verifies the fields against the `orders` table when the class loads, and every rejected request emits an `invalid_parameters.permittable` notification.

Adopting on an existing API with live traffic? Skip ahead to [Adopting on a live API](#adopting-on-a-live-api): the gem can draft the contracts for you, and run them in a report-only mode until you are ready to enforce.

> **Naming note:** some legacy stacks (InheritedResources) define their own `permitted_params`. Don't include both on one controller.

## Contents

- **[Guide](#guide)**
  - [How a request flows](#how-a-request-flows)
  - [Declaring a contract](#declaring-a-contract)
  - [The field DSL](#the-field-dsl)
  - [Field options](#field-options)
  - [Types and strict coercion](#types-and-strict-coercion)
  - [Free-form hashes](#free-form-hashes-json)
  - [Absence, defaults, and partial updates](#absence-defaults-and-partial-updates)
  - [Explicit nulls](#explicit-nulls-nullable)
  - [Violations and error responses](#violations-and-error-responses)
  - [Custom error messages](#custom-error-messages-message) · [Localizing with I18n](#localizing-default-messages-i18n)
  - [Unknown parameters](#unknown-parameters)
  - [Output reshaping](#output-reshaping-transform-and-finalize)
  - [The schema-drift guard](#the-schema-drift-guard)
  - [Sensitive parameters and log redaction](#sensitive-parameters-and-log-redaction)
  - [Instrumentation](#instrumentation)
- **[Adopting on a live API](#adopting-on-a-live-api)**
  - [Monitor mode](#monitor-mode-roll-out-without-rejecting)
  - [Generating draft contracts](#generating-draft-contracts-permittablegenerate)
- **[Beyond the controller](#beyond-the-controller)**
  - [Testing contracts](#testing-contracts-rspec-matchers)
  - [Standalone contracts](#standalone-contracts-no-controller)
  - [Exporting OpenAPI](#exporting-openapi-docs-that-cannot-drift)
- **[Reference](#reference)**
  - [API](#api) · [Errors caught at class load](#errors-caught-at-class-load) · [Compatibility](#compatibility)
- [Development](#development) · [License](#license)

---

## Guide

### How a request flows

```
request params
   │
   ├─ 1  unwrap root:        params[:user]                missing or not a hash → 400
   ├─ 2  each field          normalize → cast → validate → transform
   ├─ 3  unknown-key check   at every nesting level       (unknown: :ignore | :log | :error)
   ├─ 4  finalize            only when nothing violated
   │
   └─ permitted_params  →  HashWithIndifferentAccess      or raises InvalidParameters → 422
```

Validation is **lazy by default**: it runs on the first `permitted_params` call, so an action that never reads params never pays for it. Pass `enforce: true` to run it in a `before_action` instead, rejecting bad requests before the action body executes. Results are **memoized per action**.

In [monitor mode](#monitor-mode-roll-out-without-rejecting) the same flow runs, but a violation is reported instead of raised and the request proceeds with the raw params passed through.

### Declaring a contract

```ruby
permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, mode: nil, desc: nil, &contract)
```

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the contract covers. **No actions = catch-all** for the controller |
| `root:` | `false` | Key to unwrap first (the `require(:user)` equivalent). Missing or non-hash root → **400** |
| `model:` | `nil` | Model class, or `true` to infer from `controller_name`, enabling the [drift guard](#the-schema-drift-guard) |
| `unknown:` | `:ignore` | `:ignore` / `:log` / `:error` — how to treat undeclared keys |
| `enforce:` | `false` | `false` validates lazily on first use; `true` validates in a `before_action` |
| `mode:` | `nil` | `nil` follows `Permittable.mode`; `:monitor` reports violations instead of rejecting — see [monitor mode](#monitor-mode-roll-out-without-rejecting) |
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

### The field DSL

Three verbs. `required` and `optional` declare scalars (or, with a block, nested hashes); `array` declares a list.

```ruby
# Scalars — the type defaults to :string
required :name, :string
optional :age,  :integer

# Nested hashes — pass a block instead of a type. Violation paths are dotted: user.address.zip
optional :address do
  required :city, :string
  optional :zip,  :string, format: /\A\d{5}\z/
end

# Arrays — of: for scalars, a block for hashes. Element failures carry their index: items[1].sku
array :tag_names,  of: :string, length: 0..10
array :line_items, required: true do
  required :sku,      :string
  required :quantity, :integer, in: 1..99
end

# Free-form hashes — :json takes any hash, uncast and unfiltered, with bounds
optional :metadata, :json, max_depth: 3, length: 0..32
```

Arrays are **optional unless `required: true`**, and `length:` on an array constrains the element **count**.

### Field options

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
| `message:` | ✅ | ✅ | ✅ | Human-readable copy for violations on this field — a String, or a Hash of code → String. See [custom messages](#custom-error-messages-message) |
| `of:` | — | ✅ | — | Element type for an array of scalars (default `:string`) |
| `max_depth:` | — | — | — | `:json` fields only — maximum container nesting. See [free-form hashes](#free-form-hashes-json) |
| `required:` | — | ✅ | — | Arrays are optional unless this is `true` |
| `desc:` | ✅ | ✅ | ✅ | Documentation only — the field's `description` in [exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) |
| `example:` | ✅ | ✅ | — | Documentation only, but **validated against the field's own contract at class load**, like `default:` |
| `nullable:` | ✅ | ✅ | ✅ | An explicitly-sent empty value yields `nil` instead of counting as absent — see [explicit nulls](#explicit-nulls-nullable) |

¹ `format:`, `length:`, and `normalize:` reason about characters and are **only valid on `:string` fields**. On any other type they would silently apply to an already-cast value, so declaring them raises at class load.

`validate:` is the escape hatch for anything the built-ins don't cover:

```ruby
optional :slug, :string, validate: ->(v) { v.match?(/\A[a-z0-9-]+\z/) || :malformed_slug }
```

### Types and strict coercion

Coercion is **deliberately strict**, and deliberately *not* `ActiveModel::Type`. Rails' casts are lenient by design — `"abc".to_i` is `0`, `Boolean.cast("abc")` is `true` — and silently corrupting untrusted input is precisely what a contract must not do. A value the type cannot faithfully represent is a **violation, not a guess**.

| Type | Accepts | Rejects (`invalid_type`) |
|---|---|---|
| `:string` | `String`; `Numeric`/`true`/`false` are stringified | Arrays, hashes |
| `:integer` | `Integer`; whole `Float`s (`4.0`); base-10 numeric strings | `"4.5"`, `"abc"`, `4.5` |
| `:float` | `Numeric`; any `Float()`-parseable string | `"abc"` |
| `:decimal` | `Numeric` or `String` → `BigDecimal` | Unparseable strings |
| `:boolean` | `true`/`false`, `"true"`/`"false"`, `"1"`/`"0"`, `1`/`0` | `"yes"`, `"on"`, `2` |
| `:date` | `Date`; a string naming a **complete** date, in any format `Date.parse` understands (`"2026-09-05"`, `"2026/09/05"`, `"Sep 5, 2026"`) | Unparseable strings, and **incomplete** ones (`"09/2026"`, `"5th"`, `"Sept"`) |
| `:datetime` | `Time`, `DateTime`, `ActiveSupport::TimeWithZone`, `Date`; a string naming a complete date, with or without a time | Unparseable strings, and any string without a complete date (`"10:30"`) |
| `:json` | Any `Hash` — passed through uncast, see [free-form hashes](#free-form-hashes-json) | Arrays, scalars |

**Dates are parsed, never guessed.** `Date.parse` fills in what a string omits *from today* — `"09/2026"` becomes the 1st, `"5th"` becomes this month of this year — so the same request would mean different things on different days. A `:date` or `:datetime` string must therefore name all three of year, month and day; which **format** it names them in is `Date.parse`'s business, so every complete format it understands still works. A `:datetime` may omit the *time* part, which reads as midnight UTC.

Two more behaviours worth committing to memory:

- **Type confusion is a violation, not a 500.** A request of `?age[]=1` against a scalar `:integer` field yields `invalid_type`. Arrays, hashes, and nested `ActionController::Parameters` can never satisfy a scalar type, so the classic "`NoMethodError` on `[]`" crash is impossible.
- **Datetimes are normalised to UTC.** A zoneless string parses as UTC regardless of the host timezone, which keeps behaviour deterministic across machines; explicit offsets are honoured and converted.

### Free-form hashes (`:json`)

A `json`/`jsonb` column exists precisely so its contents need no schema. Every other field kind describes a shape, so until `:json` a contract had only bad options for one: declare sub-keys you don't know, or leave the key undeclared — in which case the contract **silently dropped it**, and the column never saw the data. Strong parameters has always had an answer here (`params.permit(metadata: {})`); now so does a contract.

```ruby
permit_params :create, root: :user, model: User do
  required :name,     :string
  optional :metadata, :json, max_depth: 3, length: 0..32
end
```

The hash passes through **untouched** — keys are neither filtered nor cast, nested arrays and mixed scalars survive, and `unknown:` does not descend into it. `{}` is a value, not an absence. Anything that is not a hash (an array, a string, a number) is `invalid_type`.

What you give up is the shape. What you keep:

| | |
|---|---|
| `length:` | Caps the **top-level key count** — same reading as an array's element count |
| `max_depth:` | Caps **container nesting**, counting arrays as a level: `{"a": 1}` is 1, `{"a": {"b": 1}}` and `{"a": [1, 2]}` are 2, `{"a": [{"b": 1}]}` is 3. Violation code `depth` |
| `validate:` / `transform:` | See the whole hash, so any check you can write in Ruby still applies |
| `model:` | The field maps onto a column like a scalar does, so the [drift guard](#the-schema-drift-guard) still catches a dropped `metadata` column |
| `sensitive:` / `nullable:` / `message:` / `desc:` / `default:` / `example:` | Behave as on any other field (`default:`/`example:` must be a hash, and are checked against the field's own bounds at class load) |

Bounding it matters more than it looks: an unbounded `jsonb` column is where clients put megabytes and 200-level-deep objects. `max_depth:` and `length:` are how a contract says "opaque, but not unlimited" — which is strictly more than `permit(metadata: {})` can say.

Values arrive as plain data (`HashWithIndifferentAccess`), never `ActionController::Parameters`, so assigning straight to a `jsonb` attribute is safe.

In [exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) the field is `{"type": "object"}` plus `minProperties`/`maxProperties`; JSON Schema has no nesting-depth keyword, so `max_depth:` stays visible as `x-permittable-max-depth` rather than being dropped or mistranslated.

### Absence, defaults, and partial updates

`nil` and `""` are **both treated as absent** — the query-parameter convention, where an untouched form field arrives as an empty string. Boolean `false` is present.

That single rule produces the behaviour you want from a `PATCH`:

| The field is… | Result |
|---|---|
| absent and **optional** | omitted from the result, so partial updates never nil-out columns |
| absent and **required** | a `missing` violation |
| absent with a **`default:`** | the default — a defaulted field can never report `missing` |

Declaring `required:` alongside `default:` is a class-load error, since a default implies optionality. And because absence and `nil` are the same thing here, a plain field cannot clear a column to NULL — declare it [`nullable:`](#explicit-nulls-nullable) when it should.

Defaults are checked against the field's own contract when the class loads, so `default: "gold"` on a field declared `in: %w[free pro]` fails at boot rather than on every request.

### Explicit nulls (`nullable:`)

One rule — `nil` and `""` are absent — is right for `PATCH` and wrong for the request that means *clear this*. `nullable: true` splits it in two for a single field:

```ruby
permit_params :update, root: :user, model: User do
  optional :nickname, :string, nullable: true
  optional :plan,     :string, in: %w[free pro], default: "free", nullable: true
end
```

| Request | `nickname` in the result |
|---|---|
| `{ "user": {} }` | **omitted** — the column is untouched |
| `{ "user": { "nickname": null } }` | `nil` — the column is cleared |
| `{ "user": { "nickname": "" } }` | `nil` — the form-encoded spelling of the same intent |

A key the client never sent is still **absent**: `default:` applies to it and a `required` field still violates with `missing`. Only *present-but-empty* changes meaning, and it changes it decisively — an explicit null wins over the field's `default:`, which is the behaviour a `PATCH` needs (`{ "plan": null }` clears the plan instead of silently resetting it to `"free"`).

Nothing is cast or checked for an explicit null. `in:`, `format:`, `length:`, `validate:`, and `transform:` all see a value or nothing at all — never a `nil` they never agreed to handle.

Three more readings worth knowing:

- **`required` + `nullable`** is coherent, and means what it says in SQL: the client *must* state the field, and `null` is a legal statement. A missing key still violates.
- **`default: nil`** — legal only on a nullable field — gives the `PUT` reading, where absence *also* means clear.
- **On arrays and nested blocks**, `nullable:` applies to the array or object itself, never to its contents. `{ "tags": null }` yields `nil` (distinct from `[]`, which still gets length-checked); a null *element* inside `tags` is still `invalid_type`.

Exported [OpenAPI](#exporting-openapi-docs-that-cannot-drift) tells the truth about all of this: a nullable field's `type` gains `"null"`, and a nullable `in:` set lists `null` in its `enum`.

### Violations and error responses

Every failure raises `Permittable::InvalidParameters`, carrying `details` (an array of `{ param:, code: }`, plus a `message:` when the field [declares one](#custom-error-messages-message)) and a `status`. On a real controller it is auto-rescued into the error envelope shown at the [top of this README](#permittable).

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

**Status codes.** A missing root key renders **400** — the request is malformed; the envelope you asked for isn't there. Field-level violations render **422** — well-formed, semantically wrong.

**Custom rendering.** If your controller defines `render_error`, the envelope delegates to it as `render_error(message:, code:, status:, errors:)` — the `errors:` key is passed only when details exist, so hosts documenting a three-keyword contract keep working. Otherwise the inline JSON shape is rendered. Either way, `render_invalid_parameters` is a normal method you can override. For full control over the body (RFC 9457, a different envelope), `error.details` gives you the structured violations to build from.

### Custom error messages (`message:`)

Violations stay machine-first — the `code` is the contract — but any field can attach human-readable copy with `message:`. A **String** covers every code on the field; a **Hash of code → String** targets specific codes, and codes without an entry keep the default rendering:

```ruby
permit_params :create, root: :user do
  required :email, :string, format: URI::MailTo::EMAIL_REGEXP,
                            message: { missing: "is required", format: "must be a valid email address" }
  optional :age,   :integer, in: 18..120, message: "must be between 18 and 120"
  array    :tags,  of: :string, length: 0..10, message: "must be at most ten tags"
end
```

A resolved message rides into the violation detail and replaces the `(code)` part of the exception's summary line, so both the envelope's `message` and its `details` read naturally:

```json
{ "success": false,
  "error": { "message": "Invalid parameters: user.email must be a valid email address",
             "code": "invalid_parameters",
             "details": [{ "param": "user.email", "code": "format",
                           "message": "must be a valid email address" }] } }
```

The rules:

- Messages are written to read after the param name: `"is required"`, not `"Email is required"`.
- A Hash key matches the violation code, **including Symbol codes returned by `validate:`** — `validate: ->(v) { v.even? || :must_be_even }, message: { must_be_even: "must be an even number" }`.
- An array's message covers the array's own violations (`length`, `invalid_type`, `missing`) **and** its elements' (`tags[3]`); sub-fields of a nested block resolve their own `message:` declarations.
- `violate!` in `finalize` takes the same idea as a keyword: `violate!("user.ends_at", :before_start, message: "must be after starts_at")`.
- A `message:` that is neither a String nor a code → String Hash raises at class load, like every other contract mistake.

#### Localizing default messages (I18n)

App-wide copy for a violation code — without repeating `message:` on every field — comes from I18n, under `permittable.errors.<code>`:

```yaml
# config/locales/en.yml
en:
  permittable:
    errors:
      missing: "is required"
      invalid_type: "is the wrong type"
      inclusion: "is not an allowed value"
      unknown: "is not a recognized parameter"
```

Resolution order per violation: the field's own `message:` (String, or the Hash entry for that code) → the app's `permittable.errors.<code>` translation → the bare `{ param:, code: }` shape. The lookup also covers a missing `root:`, `unknown` keys, Symbol codes returned by `validate:` (`permittable.errors.must_be_even`), and `violate!` codes in `finalize` (an explicit `violate!(..., message:)` still wins). Only a String translation counts — a missing key or a nested Hash falls back to the bare shape rather than leaking structure to clients. No I18n, no change: apps without the gem or the keys behave exactly as before.

### Unknown parameters

`unknown:` decides what happens to keys you never declared, **at every nesting level**.

| Mode | Behaviour |
|---|---|
| `:ignore` (default) | Silently dropped, exactly like strong parameters |
| `:log` | Dropped, with a `logger.warn` naming the full paths |
| `:error` | Each undeclared key becomes an `unknown` violation |

Rails merges `controller`, `action`, and `format` into `params`; these are exempt at the top level so `unknown: :error` doesn't flag the router's own bookkeeping. Inside a `root:` or a nested hash there is no such exemption, because nothing legitimately injects keys there.

### Output reshaping (`transform:` and `finalize`)

This is the safe replacement for params-mutating `before_action`s. **Both layers operate on the validated copy — the request's `params` is never touched.**

**`transform:` — per field.** A callable applied **after** cast and validation, reshaping one field's output:

```ruby
required :tags, :string, transform: ->(v) { v.split(",") }
```

It runs only on request-supplied values. Absent fields stay absent, `default:` values are authored in their final shape, and a **partially-invalid array is never transformed** — user code is never handed garbage it didn't agree to see.

**`finalize` — per contract.** Declared once, at the top level only. It runs after every field has validated cleanly, receives the result hash, and must return the final `Hash`. Use it to combine parallel fields, build value objects, or drop scaffolding keys.

It executes on a **bare runner, not the controller**, so contracts stay pure data plus pure functions and can never grow a dependency on request state. Its one extra verb is `violate!(param, code, message: nil)`, which records a violation and **halts the block immediately** — so the code after a `violate!` may assume the invariant it just checked. That makes `finalize` the natural home for cross-field validation (`ends_at` after `starts_at`, matching array lengths).

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

### The schema-drift guard

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

### Sensitive parameters and log redaction

Mark a field `sensitive: true` and its name is registered with `Permittable.filter_parameter_registry`; `Permittable::Railtie` appends a filter proc to `config.filter_parameters` at boot.

```ruby
optional :ssn, :string, sensitive: true
```

The indirection is deliberate. Appending plain symbols to `config.filter_parameters` at class-load time misses every consumer that snapshots the list at boot — ActiveRecord's `filter_attributes` copy, lograge-style initializers, precompiled filters. A **single proc appended once at boot, consulting a live registry at filter time**, means fields registered when a controller loads later (lazy loading in development) are still redacted. The initializer runs before `active_record.set_filter_attributes`, so values are redacted from both request logs and `#inspect`.

Matching mirrors Rails' own symbol-filter semantics: case-insensitive substring match on the parameter key. The registry is fully duck-typed (`#add`, `#include?`, `#to_proc`, `#names`, `#reset!`) and swappable via `Permittable.filter_parameter_registry=`, so a host gem can pool registrations into its own. `#to_proc` must return a callable of arity 2 (`key, value`) or 3 (`key, value, original_params`), matching what Rails' own parameter filtering accepts; anything that does not respond to `#to_proc` is refused at the point of the swap rather than on the next request.

**The swap works at any point**, including from `config/initializers` — which matters, because Rails runs railtie initializers *before* those, so a swap always happens after `Permittable::Railtie` has appended its filter. Two things make that safe. The appended proc (`Permittable.filter_parameter_proc`) resolves the registry at **filter time** rather than closing over whichever instance existed at boot, so whichever registry is current does the redacting. And the swap **carries the previous registry's names into the new one**, so a `sensitive:` field registered by a contract that loaded before the swap keeps being redacted afterwards. Without that, the two halves of an app would each redact only what the other did not.

### Instrumentation

Every violation emits an `ActiveSupport::Notifications` event, so rejected requests can be dashboarded and alerted on:

```ruby
ActiveSupport::Notifications.subscribe("invalid_parameters.permittable") do |*, payload|
  payload[:controller]  # "users"
  payload[:action]      # "create"
  payload[:mode]        # :enforce, or :monitor for a would-be rejection
  payload[:details]     # [{ param: "user.age", code: "inclusion" }]
end
```

---

## Adopting on a live API

Adding contracts to an API with real traffic has a chicken-and-egg problem: you cannot know what the 422s would break until you enforce them, and you dare not enforce them until you know. Old mobile app versions, third-party integrations, and forgotten cron jobs all send what they send.

Permittable's answer is an afternoon-sized recipe:

1. **Draft.** `bin/rails permittable:generate` writes a first contract for every controller from the model's columns and the `params.permit` calls already in the source. Action code stays as-is.
2. **Monitor.** Deploy with `PERMITTABLE_MODE=monitor`. Behaviour is unchanged; every would-be rejection is logged and instrumented.
3. **Watch.** Point your existing notification subscriber at a dashboard. Every entry is a real client that would have been rejected — fix the contract, or wait for that traffic to drain.
4. **Enforce.** Flip to enforce, controller by controller. Every 422 you now return is one you already counted.

The two halves of that recipe are below.

### Monitor mode (roll out without rejecting)

`mode: :monitor` runs the full pipeline — unwrap, cast, validate, defaults — but a violation is **reported instead of rejected** and the request proceeds exactly as it did before the contract existed.

```ruby
class OrdersController < ApplicationController
  permit_params :create, root: :order, mode: :monitor do
    required :sku,      :string
    optional :quantity, :integer, in: 1..99
  end

  # The action doesn't have to change while monitoring — it can keep reading
  # params the old way; the contract validates in the before_action.
end
```

Or flip the whole app at once and pin controllers to their final mode one at a time — a rule's own `mode:` always beats the global, in both directions:

```ruby
# config/initializers/permittable.rb
Permittable.mode = ENV.fetch("PERMITTABLE_MODE", "enforce").to_sym
```

On a violating request in monitor mode:

- **Nothing raises and nothing renders** — the action runs.
- The [`invalid_parameters.permittable` event](#instrumentation) fires with `mode: :monitor` in the payload (enforced violations carry `mode: :enforce`), and the logger warns with the offending paths.
- `permitted_params` returns the **raw pass-through**: exactly what the client sent, untouched — no casts, no defaults, no transforms. A missing `root:` passes an empty hash; a rootless contract drops only Rails' routing keys.
- `permittable_violations` returns the recorded details (`[]` when the request was clean), if the action wants to branch on or tag the traffic.

Monitor-mode rules validate **eagerly in the `before_action`, regardless of `enforce:`** — telemetry must not depend on the action calling `permitted_params`, since legacy actions still reading `params` directly are exactly the ones worth monitoring. (On a plain-Ruby host without `before_action`, validation stays lazy.)

[Exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) marks operations whose rule declares `mode: :monitor` with `x-permittable-mode: "monitor"` — the docs shouldn't promise a 422 the server doesn't yet send. Only the per-rule declaration is exported: the global `Permittable.mode` is runtime configuration, not contract data.

### Generating draft contracts (`permittable:generate`)

The blank-page problem, solved: the first draft of every contract is generated from what the app already knows.

```sh
bin/rails permittable:generate                      # every controller without a contract
bin/rails "permittable:generate[UsersController]"   # one controller, even if covered
```

For each controller the task infers the model from `controller_name` (columns give types, NOT NULL gives `required`), scans the controller source for `params.require(...).permit(...)` calls (permitted keys give the field list and the `root:`), and prints a paste-ready draft:

```ruby
# Drafted by permittable:generate — review the TODOs, then deploy: monitor
# mode reports violations (instrumentation + log) without rejecting requests.
permit_params :create, :update, root: :user, model: User, mode: :monitor do
  required :name, :string
  optional :age, :integer
  optional :status, :string # database default: "active"
  optional :password_confirmation, :string, virtual: true # TODO: not a database column — confirm the type
  array :tag_names, of: :string # TODO: confirm the element type
end
```

The generator's one rule is **draft, don't guess** — everything it cannot know for sure stays visible instead of silently decided:

- Drafts come out in **monitor mode**, so pasting one changes nothing until you flip it.
- A permitted key that isn't a column becomes `virtual: true` with a TODO; a column type with no scalar equivalent (`json`, `binary`) becomes a TODO comment; a permit argument the conservative parser can't read (`*dynamic_keys`) is kept verbatim in a TODO instead of dropped.
- A database default is noted in a comment but **not** copied into `default:` — a contract default is injected on every request that omits the field, which would overwrite columns on partial updates. The database already handles creation.
- `key: [:a, :b]` in a permit call drafts as a nested block, with a TODO noting it may be an array of hashes.

No Rails required for the core: `Permittable::Generator.draft(model: User)`, `.for_controller(controller, source: File.read(path))`, and `.scan(source)` are plain Ruby.

---

## Beyond the controller

Because a contract is data, it has readers other than the request validator.

### Testing contracts (RSpec matchers)

A contract can be specified without dispatching a request. `require "permittable/rspec"` (in `spec_helper.rb`) auto-includes the matchers:

```ruby
RSpec.describe UsersController do
  it "declares the create contract" do
    expect(described_class).to permit_param(:email)
      .for_action(:create).as(:string).matching(URI::MailTo::EMAIL_REGEXP).required
    expect(described_class).to permit_param(:age).for_action(:create).as(:integer).within(18..120)
    expect(described_class).to permit_param(:plan).for_action(:create).with_default("free")
    expect(described_class).to permit_param(:tag_names).for_action(:create).as_array(of: :string)
    expect(described_class).to permit_param("address.zip").for_action(:create).as(:string).optional
    expect(described_class).not_to permit_param(:admin).for_action(:create)
  end
end
```

Chains: `for_action`, `as`, `as_array(of:)`, `required` / `optional`, `within` (`in:`), `matching` (`format:`), `with_length`, `with_default`, `virtual`, `sensitive`. Dotted paths walk nested blocks and array-of-hash blocks alike (`"line_items.sku"`).

`for_action` picks the rule exactly like a request would (`permit_rule_for`), and may be omitted only when the controller declares a single contract — an ambiguous expectation raises instead of silently checking the wrong rule. Failure messages name what the contract actually declares.

### Standalone contracts (no controller)

The same DSL, callable on any Hash — webhook payloads, job arguments, service-object inputs, CSV rows:

```ruby
CreateUser = Permittable::Contract.define(root: :user) do
  required :email, :string, format: URI::MailTo::EMAIL_REGEXP
  optional :age,   :integer, in: 18..120
  optional :plan,  :string, in: %w[free pro], default: "free"
end

result = CreateUser.call(payload)     # never raises
result.valid?                          # => false
result.violations                      # => [{ param: "user.age", code: "inclusion" }]
result.params                          # validated HashWithIndifferentAccess; nil when invalid

CreateUser.call!(payload)              # params, or raises Permittable::InvalidParameters
CreateUser.json_schema                 # the contract as JSON Schema (draft 2020-12)
CreateUser.rule                        # the frozen, introspectable rule data
```

Everything carries over — strict coercion, `""`/`nil` absence, defaults, `finalize` with `violate!`, `sensitive:` log-redaction registration, `invalid_parameters.permittable` instrumentation, 400-vs-422 status semantics for a missing `root:`. Three differences, all deliberate:

- **A `Contract` always enforces.** Monitor mode is a request-rollout switch; standalone callers read the `Result` instead, so the app-wide `Permittable.mode` is ignored here.
- **No router-key exemption.** `unknown: :error` flags a stray `action` or `controller` key — standalone input has no router to excuse.
- **No memoization.** Every `#call` validates fresh, so one frozen contract is safely reusable and shareable (assign it to a constant).

### Exporting OpenAPI (docs that cannot drift)

An exporter emits **OpenAPI 3.1** (whose request bodies are plain JSON Schema) from the same frozen data the server enforces. Like the drift guard pointed outward: the docs cannot lie.

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

Every operation references shared components for the [error envelope](#violations-and-error-responses): a `422` response always, plus a `400` when the contract declares a `root:`. So consumers get typed *errors*, not just typed inputs.

**What is honestly unrepresentable stays visible instead of guessed.** A `format:` regexp using a Ruby-only construct (or flags) is exported as `x-permittable-pattern` rather than a mistranslated `pattern`; `validate:`/`transform:` are flagged `x-permittable-custom-validation`/`x-permittable-transformed`; actions covered only by a catch-all rule on a plain-Ruby host appear under `"*"` with `x-permittable-catch-all`; operations whose rule runs in [monitor mode](#monitor-mode-roll-out-without-rejecting) carry `x-permittable-mode: "monitor"`; operations with no matching route land in `x-permittable-controllers` instead of being dropped. The schema documents the canonical JSON encoding — the runtime additionally accepts string-encoded scalars (`"42"`, `"true"`) for form/query payloads.

Output is deterministic (fixed key order, declaration-order properties), so the generated file can be committed and reviewed as a diff — a contract change shows up in the same PR as its documentation change.

<details>
<summary><strong>How contracts map onto JSON Schema</strong></summary>

<br>

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

</details>

---

## Reference

### API

**Instance methods**

| Method | Purpose |
|---|---|
| `permitted_params(action = action_name)` | The cast, validated, defaulted `HashWithIndifferentAccess`. Memoized per action. Raises `InvalidParameters` on violation (in [monitor mode](#monitor-mode-roll-out-without-rejecting), returns the raw pass-through instead), or `ArgumentError` when no contract covers the action |
| `permittable_violations(action = action_name)` | The violation details recorded by validating `action` — `[]` when clean. Triggers the same memoized validation; under enforce it swallows the raise, making "would this request fail?" a one-liner |
| `enforce_params_contract` | The `before_action` entry point. Validates rules declared `enforce: true` and all [monitor-mode](#monitor-mode-roll-out-without-rejecting) rules. Public, so hosts can `skip_before_action` it |
| `render_invalid_parameters(error)` | The `rescue_from` target. Renders via the host's `render_error` when defined, the inline envelope otherwise |

**Class methods**

| Method | Purpose |
|---|---|
| `permit_params(*actions, **opts, &contract)` | Declare a contract |
| `permittable_contracts` | The frozen array of every declared rule — introspectable, testable |
| `permit_rule_for(action)` | The last rule matching `action`, or `nil` |

**Module**

| Constant | Purpose |
|---|---|
| `Permittable.filter_parameter_registry` | The live registry of `sensitive:` field names |
| `Permittable.filter_parameter_registry=` | Swap in your own duck-typed registry; entries already registered are carried across |
| `Permittable.filter_parameter_proc` | The single proc `Permittable::Railtie` appends to `config.filter_parameters`; consults the current registry at filter time |
| `Permittable.mode` / `Permittable.mode=` | App-wide default (`:enforce`) for rules that don't declare their own `mode:` |
| `Permittable::InvalidParameters` | Raised on violation; carries `#details` and `#status` |
| `Permittable::JsonSchema` | Contract data → JSON Schema fragments (`.rule`, `.object`, `.field`) |
| `Permittable::OpenAPI` | OpenAPI 3.1 assembly (`.document`, `.operations_for`, `.request_body_for`, `.components`) |
| `Permittable::Generator` | Contract drafting (`.draft`, `.for_controller`, `.scan`) — see [generating draft contracts](#generating-draft-contracts-permittablegenerate) |
| `Permittable::Contract` | [Standalone contracts](#standalone-contracts-no-controller) (`.define`, `#call`, `#call!`, `#json_schema`, `#rule`) |
| `Permittable::Matchers` | RSpec matchers via `require "permittable/rspec"` — see [testing contracts](#testing-contracts-rspec-matchers) |

### Errors caught at class load

A bad contract is a programmer error, so it fails when the class loads — never at request time. Every message names the field and explains the fix.

<details>
<summary><strong>The full list</strong></summary>

<br>

- A field declared twice in one contract
- An unknown option for the field's kind, listing what *is* allowed
- An unknown type, listing the supported ones
- An unknown `normalize:` preset, listing the presets
- `format:`, `length:`, or `normalize:` on a non-`:string` field
- `length:` that isn't a `Range` or `Integer`; `in:` that doesn't respond to `include?`
- `validate:` or `transform:` that isn't callable
- A `default:` or `example:` that violates its own field's contract, or an array `default:`/`example:` whose elements violate `of:`
- A `default: nil` or `example: nil` on a field that isn't `nullable:`
- A `:json` field's `default:`/`example:` that isn't a Hash, or that its own `length:`/`max_depth:` would reject
- A `max_depth:` that isn't a positive Integer
- `required: true` combined with `default:`
- A field given both a type and a nested block; an array given both `of:` and a block
- An empty contract, or a nested block declaring no sub-fields
- `finalize` declared twice, without a block, or inside a nested block
- `permit_params` without a block, or an invalid `unknown:` mode
- A `root:` that isn't a single key (several top-level envelopes are a rootless contract with one nested block per key)
- An invalid `mode:` (and `Permittable.mode =` rejects invalid values at assignment)
- A `model:` that isn't an ActiveRecord class, or `model: true` that can't be inferred

</details>

### Compatibility

| Requirement | Supported |
|---|---|
| Ruby | >= 3.2 |
| Rails / ActiveSupport | >= 5.0, < 9 |
| Required dependency | `activesupport` only |
| Optional | `actionpack` (rendering, `before_action`), `activerecord` (drift guard) |

`actionpack` and `activerecord` are optional because every touchpoint is guarded with `respond_to?`/`defined?` — your app brings whatever it already has. The concern works on a plain Ruby object that responds to `params`, which is what makes it straightforward to unit-test.

Using [concerns_on_rails](https://github.com/VSN2015/concerns_on_rails)? `ConcernsOnRails::Controllers::Permittable` is an alias for this module, and `sensitive:` registrations pool into that gem's shared filter registry.

## Development

```sh
bundle install
bundle exec rspec                        # the suite, with a coverage report in coverage/
bundle exec rubocop
bundle exec ruby benchmark/overhead.rb   # a full contract vs. the params.permit call it replaces
```

Releases are automated: bump `lib/permittable/version.rb`, add a `CHANGELOG.md` section, then push a `vX.Y.Z` tag. CI publishes to RubyGems via trusted publishing (OIDC — no API keys stored) and creates the GitHub release.

## License

[MIT](LICENSE.txt).
