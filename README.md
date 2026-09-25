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
  - [`format:` presets](#format-presets)
  - [Types and strict coercion](#types-and-strict-coercion)
  - [Free-form hashes](#free-form-hashes-json)
  - [Absence, defaults, and partial updates](#absence-defaults-and-partial-updates)
  - [Explicit nulls](#explicit-nulls-nullable)
  - [Violations and error responses](#violations-and-error-responses)
  - [Custom error messages](#custom-error-messages-message) · [Localizing with I18n](#localizing-default-messages-i18n)
  - [RFC 9457 problem+json](#rfc-9457-problemjson)
  - [Unknown parameters](#unknown-parameters)
  - [Output reshaping](#output-reshaping-transform-and-finalize)
  - [The schema-drift guard](#the-schema-drift-guard)
  - [Sensitive parameters and log redaction](#sensitive-parameters-and-log-redaction)
  - [Instrumentation](#instrumentation)
- **[Adopting on a live API](#adopting-on-a-live-api)**
  - [Monitor mode](#monitor-mode-roll-out-without-rejecting)
  - [Generating draft contracts](#generating-draft-contracts-permittablegenerate)
  - [Auditing coverage](#auditing-coverage-permittableaudit)
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
   ├─ 2  each field          normalize → absent? → cast → validate → transform
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
array :line_items, required: true, length: 1..50 do
  required :sku,      :string
  required :quantity, :integer, in: 1..99
end

# Free-form hashes — :json takes any hash, uncast and unfiltered, with bounds
optional :metadata, :json, max_depth: 3, length: 0..32
```

Arrays are **optional unless `required: true`**, and `length:` on an array constrains the element **count**.

`length:` is a **bound, not a report**: an array outside it is rejected without its elements being examined at all. A 200,000-element payload against `length: 0..10` is refused by its first check, so it costs one violation and a 40-byte body instead of 200,001 violations and several megabytes — milliseconds of contract work instead of seconds. There is **no default cap**: an array with no `length:` is unbounded, and every element of it is cast and checked however many arrive. Declare `length:` on every array you accept.

### Field options

Which options are legal depends on the field kind — anything else raises at class load.

| Option | Scalar | Array | Nested | Meaning |
|---|:---:|:---:|:---:|---|
| `in:` | ✅ | — | — | Allowed values: a `Range` (bounds-checked with `cover?`) or an `Array` |
| `format:` | ✅¹ | — | — | Regexp the value must match, or a [preset name](#format-presets): `:email`, `:uuid`, `:url`, `:slug`, `:hostname` |
| `length:` | ✅¹ | ✅ | — | `Range` or `Integer`. Character count on strings, **element count** on arrays, where it short-circuits — see [the field DSL](#the-field-dsl) |
| `normalize:` | ✅¹ | — | — | `:squish`, `:strip`, `:downcase`, `:upcase`, `:email`, or a Proc. Runs **first** — before the absence rule, so a value that normalizes to `""` is absent |
| `default:` | ✅ | ✅ | — | Value used when the field is absent. Validated against the field's own contract at class load, then stored normalized and frozen (each request gets its own copy) |
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

**Checks run in a fixed order**, and the first failure is the one reported:

```
normalize:  →  cast  →  length:  →  in:  →  format:  →  validate:
```

`length:` comes before `in:` and `format:` on purpose. It is an O(1) read of a string's size, while `format:` runs a regexp over the whole value and `validate:` runs your own code — so a value the length bound already excludes never pays for the expensive checks. A 5 MB string against `length: 1..80` is rejected on its length without the regexp ever seeing it, which matters most when the regexp is one with poor worst-case behaviour.

The visible consequence: a value that violates *both* its length and its format reports `length`. That is the more useful answer anyway — a client can't act on "wrong format" for a value that is also far too long.

`validate:` is the escape hatch for anything the built-ins don't cover:

```ruby
optional :slug, :string, validate: ->(v) { v.match?(/\A[a-z0-9-]+\z/) || :malformed_slug }
```

### `format:` presets

The regexps every app writes by hand, named once:

```ruby
required :email,   :string, format: :email
required :id,      :string, format: :uuid
optional :website, :string, format: :url
optional :slug,    :string, format: :slug
optional :host,    :string, format: :hostname
```

| Preset | Matches | Exported JSON Schema `format` |
|---|---|---|
| `:email` | Exactly `URI::MailTo::EMAIL_REGEXP` — the regexp Rails apps already paste in, so switching to the preset cannot change which addresses an endpoint accepts | `email` |
| `:uuid` | A canonical `8-4-4-4-12` UUID, either case | `uuid` |
| `:url` | An `http`/`https` URL. A **shape** check, not a reachability guarantee — but it does reject `javascript:` and other schemes | `uri` |
| `:slug` | Lowercase, digits, single hyphens between segments | — |
| `:hostname` | A DNS hostname (label rules, no trailing dot) | `hostname` |

A preset carries something a hand-written Regexp cannot: the JSON Schema **`format` keyword** the wider ecosystem understands, so [exported docs](#exporting-openapi-docs-that-cannot-drift) say `"format": "uuid"` rather than only a wall of `pattern`. The `pattern` is still emitted next to it — in draft 2020-12 `format` is an annotation unless a validator opts into asserting it, so the pattern is what actually enforces.

An unknown preset name fails at class load, listing the presets. Passing a `Regexp` directly works exactly as before, and the RSpec matcher speaks both spellings: `matching(:email)` asserts the preset, `matching(/re/)` the Regexp.

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

**Numbers must be finite.** `Float("1e400")` is `Infinity` and `Float("1e-400")` is `0.0` — neither represents what was sent, and neither is a value a numeric column can store, so both are `invalid_type`. A genuine zero is unaffected however it is spelled (`"0"`, `"0.0"`, `"0e10"`). `:decimal` has no exponent limit, so `"1e400"` is fine there — but `BigDecimal("NaN")` and `BigDecimal("Infinity")` *succeed* where `Float()` raises, so those literal strings are rejected explicitly.

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

`nil` and `""` are **both treated as absent** — the query-parameter convention, where an untouched form field arrives as an empty string. Boolean `false` is present. `normalize:` runs *before* this rule, so a field declared `normalize: :squish` treats `"   "` as absent too: whitespace cannot satisfy a `required` field by becoming `""`.

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
| `missing` | A required field is absent, or the `root:` key is absent (that one is a **400**) |
| `invalid_type` | The value cannot be faithfully cast to the declared type — including a `root:` key the client *did* send with the wrong shape (`{"user": "bob"}`), which is also a **400** |
| `inclusion` | The value is outside `in:` |
| `format` | The value doesn't match `format:` |
| `length` | A string's length, or an array's element count, is outside `length:` |
| `unknown` | An undeclared key was sent while `unknown: :error` |
| `invalid` | A `validate:` callable returned a falsy value |
| *your symbol* | A `validate:` callable returned a `Symbol`, or `violate!` was called in `finalize` |

Paths are fully qualified: `user.address.zip`, `line_items[1].sku`.

**`details` is complete; `message` is prose.** The `details` array names **every** offender, however many there are — it is the machine-readable channel and nothing is dropped from it. The `message` string is a sentence for a person, and it also lands in your logs and in every exception tracker, so it is bounded: at most ten offenders, each truncated past 120 characters, then a count of the rest (`…, and 49990 more`). Before that bound, a request carrying 50,000 undeclared keys against `unknown: :error` produced a **1 MB** exception message and a 1 MB log line. The 422 body still carries the complete `details`, so it stays proportional to the number of violations; the field bounds are what keep that number down.

**Status codes.** A bad root key renders **400** — the request is malformed; the envelope you asked for isn't there, or isn't an object. Field-level violations render **422** — well-formed, semantically wrong. The two root failures are told apart by their code: `missing` when the key really is absent (`{}`, `{"user": null}`, `{"user": ""}`), `invalid_type` when the client sent it with the wrong shape.

**Custom rendering.** If your controller defines `render_error`, the envelope delegates to it as `render_error(message:, code:, status:, errors:)` — the `errors:` key is passed only when details exist, so hosts documenting a three-keyword contract keep working. Otherwise the inline JSON shape is rendered. Either way, `render_invalid_parameters` is a normal method you can override, and [`Permittable.error_format = :problem`](#rfc-9457-problemjson) swaps the whole shape for RFC 9457 problem details. For full control beyond that, `error.details` gives you the structured violations to build from.

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

### RFC 9457 problem+json

For a public API, the standard shape for an error is [RFC 9457 Problem Details](https://www.rfc-editor.org/rfc/rfc9457.html). One app-wide setting renders it:

```ruby
# config/initializers/permittable.rb
Permittable.error_format = :problem
Permittable.problem_base_uri = "https://api.example.com/problems"   # optional
```

```http
HTTP/1.1 422 Unprocessable Entity
Content-Type: application/problem+json
```

```json
{
  "type": "https://api.example.com/problems/invalid-parameters",
  "title": "Invalid parameters",
  "status": 422,
  "detail": "Invalid parameters: user.email (format), user.age (inclusion)",
  "instance": "/users",
  "errors": [
    { "param": "user.email", "code": "format" },
    { "param": "user.age",   "code": "inclusion" }
  ]
}
```

- **`errors`** is the field-violation extension member, carrying the identical `{ param:, code: }` entries (plus `message:` when the field [declares one](#custom-error-messages-message)) that the default envelope puts in `details`. Nothing about violation reporting changes — only the wrapper.
- **`title`** describes the problem *type*, not the instance: a missing `root:` is `"Malformed request"` (400), a field violation is `"Invalid parameters"` (422).
- **`type`** is RFC 9457's default `"about:blank"` until you set `problem_base_uri`, at which point each problem type gets its own URI under it.
- **`instance`** is the request path, and is omitted rather than guessed when the host can't name one (a params duck, a job).
- **Setting `:problem` opts out of `render_error` delegation.** A host envelope and a problem document are two answers to the same question, and the explicit setting is the one honoured.

The setting is app-wide, not per-contract, because the error format of an API is a property of the API. [Exported OpenAPI](#exporting-openapi-docs-that-cannot-drift) follows it: with `:problem` configured, the shared response components describe the problem schema under `application/problem+json` instead of the envelope under `application/json` — an export runs inside the app that made the setting, so the documented shape can't drift from the rendered one.

### Unknown parameters

`unknown:` decides what happens to keys you never declared, **at every nesting level**.

| Mode | Behaviour |
|---|---|
| `:ignore` (default) | Silently dropped, exactly like strong parameters |
| `:log` | Dropped, with a `logger.warn` naming the full paths — at most ten of them, then a count, so one request cannot write a megabyte of log |
| `:error` | Each undeclared key becomes an `unknown` violation |

Under `:log` that bound is the whole record: nothing else names an undeclared key, so beyond the tenth only the count survives. Where you need every name — auditing what a client really sends during a rollout — use `unknown: :error` in monitor mode, which records all of them in `details` and in the instrumentation payload without rejecting the request.

Rails merges its own keys into `params`: `controller`, `action`, and `format` from the router, plus `authenticity_token`, `_method`, `utf8`, and `commit` from an ordinary form POST. All seven are exempt at the top level. So are the route's **path parameters** (`PATCH /users/1` merges `id`, which the exported OpenAPI documents as a path parameter rather than a body field); a contract that *declares* `id` has it validated as usual, since the URL really carried it. **ParamsWrapper's copy of a JSON body** under the controller's wrapper key (`user` for `UsersController`) goes further: when Rails made that copy, a rootless contract does not see the key at all, because the client never sent it. So an undeclared wrapper key is not flagged, and a scalar or array field that happens to share the wrapper's name (`optional :feedback, :string` on `FeedbackController`) is simply absent, rather than failing as `invalid_type` against Rails' copy of the whole body. The one exception is a rootless contract that declares the wrapper key as a hash container — a nested block (`required :user do ... end`) or `:json`. That contract is reading the copy on purpose, like a `root:` spelled as a field, so the copy is kept and validated as that field. A client that sends `user` itself is checked like any other key: validated if declared, flagged if not. That holds whether the wrapper name is configured as a String or as a Symbol (`wrap_parameters :user`). Either way `unknown: :error` flags what the *client* got wrong rather than what the framework added. Inside a `root:` or a nested hash there is no such exemption, because nothing legitimately injects keys there — and a standalone `Contract` exempts nothing at all, having neither a router, a form, nor a request.

All of this changes what is *checked* only. Monitor mode still hands back the form keys, the path parameters and the wrapper's copy in its raw pass-through, where behaving exactly like the pre-contract app is the whole promise and a legacy action may read `params[:id]` or `_method` itself; only the router's three are dropped there.

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

#### Checking types too (opt-in)

A dropped column fails the deploy; a **retyped** one doesn't, unless you ask:

```ruby
# config/initializers/permittable.rb
Permittable.check_column_types = true
```

```
Permittable: 'placed_at' is declared :string but the column is :datetime (table: orders).
Change the contract to match the column, migrate the column to match the contract,
or declare the field virtual: true if it is not backed by this column.
```

**It is off by default on purpose.** Every cross-type declaration has some legitimate use — a `:string` contract on a `date` column that lets ActiveRecord do the casting, a `:boolean` contract on a legacy integer column — and breaking those apps on an upgrade would cost more than the drift it catches. Turn it on and fix what it finds.

When enabled it compares **groups**, not exact types, so it fires on a genuine cross-family mismatch and stays quiet otherwise:

| Group | Column types |
|---|---|
| text | `string`, `text`, `citext`, `uuid`, `enum`, `char` |
| numeric | `integer`, `bigint`, `float`, `decimal`, **`boolean`** |
| temporal | `date`, `datetime`, `time`, `timestamp`, `timestamptz` |

`boolean` sits with the numerics because a boolean stored as an integer `0`/`1` is a real legacy pattern and ActiveRecord casts cleanly between them; the temporal types are one group because a `:date` contract on a `datetime` column is a narrowing, not drift.

Any column type **not** in that table — `json`, `jsonb`, `binary`, an adapter's own `inet` or `money` — is never checked. A contract has no faithful type for those, so whatever you improvised is left alone rather than guessed about.


- **Fields not backed by a column** — `password_confirmation`, terms checkboxes, search filters — opt out with `virtual: true`.
- **Nested and array fields are implicitly virtual**, since only scalars map one-to-one onto columns.
- **The check skips when the schema is unreachable** (`db:create`, a fresh `db:migrate`, `assets:precompile`, CI bootstrap), so controller classes stay loadable. Skipping is self-healing: once the migration runs and classes reload, the check happens for real. A missing column with a *reachable* schema still raises — the rescue is scoped to `ActiveRecord::ActiveRecordError` precisely so real bugs keep surfacing.

In CI, one spec calling `Rails.application.eager_load!` exercises every contract in the whole app.

### Sensitive parameters and log redaction

Mark a field `sensitive: true` and its name is registered with `Permittable.filter_parameter_registry`; `Permittable::Railtie` appends a filter proc to `config.filter_parameters` at boot.

```ruby
optional :ssn, :string, sensitive: true
```

**On a nested block or an array, `sensitive:` cascades to everything inside it:**

```ruby
optional :payment, sensitive: true do
  required :card_number, :string        # redacted
  optional :cvv,         :string        # redacted
  optional :id,          :string, sensitive: false   # NOT redacted — see below
end
```

It has to. Rails' parameter filtering walks into hashes and arrays itself and asks a proc filter about the **leaf values only**, handing it the leaf's own key and never the path that led there. So registering `payment` alone redacts nothing inside it: the filter descends and asks about `card_number`, which the container's name does not match.

A sub-field opts out with an explicit `sensitive: false`. That exists because matching is a case-insensitive **substring** match, so cascading a generic name like `:id` or `:name` would redact every parameter in the app that happens to contain it — occasionally a worse outcome than the leak it prevents. Only `false` opts out; `sensitive: nil` reads as "not stated" and still inherits.

The cascade is resolved onto the field when the contract loads, so everything that reads a contract agrees: the value is redacted from logs, the exported schema marks the child `writeOnly`, and `permit_param("payment.card_number").sensitive` passes.

Two mechanisms, because neither covers the ground alone.

A **single proc appended once at boot, consulting a live registry at filter time**, is what reaches consumers that snapshot `config.filter_parameters` at boot — ActiveRecord's `filter_attributes` copy, lograge-style initializers — so a field registered when a controller loads later (lazy loading in development) is still redacted there. The initializer runs before `active_record.set_filter_attributes`, so values are redacted from both request logs and `#inspect`.

But a proc filter can only redact **String** values: ActiveSupport dups the value and expects in-place mutation, and for a `Hash` value it never calls the proc at all, recursing into it instead. So each name is **also registered as a name** in `config.filter_parameters`, which redacts a value of any type — an `:integer` field, or a whole sensitive nested block. Appending later still works: Rails' `precompile_filter_parameters` replaces that array *in place*, and `ActionDispatch` reads the same object on every request, so a name registered at class-load time is seen by the next request. (This is also why the mechanism is a name and not a live matcher object: precompilation joins patterns by source, which discards anything whose matching is decided at filter time.)

Matching mirrors Rails' own symbol-filter semantics: case-insensitive substring match on the parameter key. The registry is fully duck-typed (`#add`, `#include?`, `#to_proc`, `#names`, `#reset!`) and swappable via `Permittable.filter_parameter_registry=`, so a host gem can pool registrations into its own. `#to_proc` must return a callable of arity 2 (`key, value`) or 3 (`key, value, original_params`), matching what Rails' own parameter filtering accepts; anything that does not respond to `#to_proc` is refused at the point of the swap rather than on the next request.

**The swap works at any point**, including from `config/initializers` — which matters, because Rails runs railtie initializers *before* those, so a swap always happens after `Permittable::Railtie` has appended its filter. Two things make that safe. The appended proc (`Permittable.filter_parameter_proc`) resolves the registry at **filter time** rather than closing over whichever instance existed at boot, so whichever registry is current does the redacting. And the swap **carries the previous registry's names into the new one**, so a `sensitive:` field registered by a contract that loaded before the swap keeps being redacted afterwards. Without that, the two halves of an app would each redact only what the other did not.

### Instrumentation

Every violation emits an `ActiveSupport::Notifications` event, so rejected requests can be dashboarded and alerted on — **exactly once per action per request**, however many times the action reads the params (`permitted_params` memoizes the outcome, rejections included):

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

The blank-page problem, solved: the first draft of every contract is generated from what the app already knows — the model's columns, and the params calls already sitting in the controller, in either spelling (`params.require(...).permit(...)` or Rails 8's `params.expect(...)`).

```sh
bin/rails permittable:generate                      # every controller without a contract
bin/rails "permittable:generate[UsersController]"   # one controller, even if covered
```

For each controller the task infers the model from `controller_name` (columns give types, NOT NULL gives `required`), scans the controller source for `params.require(...).permit(...)` and `params.expect(...)` calls (permitted keys give the field list and the `root:`), and prints a paste-ready draft:

```ruby
# Drafted by permittable:generate — review the TODOs, then deploy: monitor
# mode reports violations (instrumentation + log) without rejecting requests.
permit_params :create, :update, root: :user, model: User, mode: :monitor do
  required :name, :string
  optional :age, :integer
  optional :status, :string # database default: "active"
  optional :password_confirmation, :string, virtual: true # TODO: not a database column — confirm the type
  array :tag_names, of: :string # TODO: confirm the element type, and declare length: — an array without one is unbounded
end
```

The generator's one rule is **draft, don't guess** — everything it cannot know for sure stays visible instead of silently decided:

- Drafts come out in **monitor mode**, so pasting one changes nothing until you flip it.
- A permitted key that isn't a column becomes `virtual: true` with a TODO; a column type with no faithful representation (`binary`, geometry types) becomes a TODO comment; a permit argument the conservative parser can't read (`*dynamic_keys`) is kept verbatim in a TODO instead of dropped.
- **Comments are not code.** A commented-out `params.require(:admin).permit(:superuser)` kept for reference is skipped, so it can't contribute a root or a field to the draft. The source is tokenised with `Ripper` for this, because `#` is only sometimes a comment — a permit call inside `#{'#{...}'}` interpolation is live code and is still read, and quoted keys like `permit("name")` still work.
- A database default is noted in a comment but **not** copied into `default:` — a contract default is injected on every request that omits the field, which would overwrite columns on partial updates. The database already handles creation.
- `key: [:a, :b]` in a permit call drafts as a nested block, with a TODO noting it may be an array of hashes. In a `params.expect` call the two shapes are distinguishable — `key: [:a]` is a nested hash, `key: [[:a]]` is an array of hashes — so that draft carries no TODO at all.
- In a `params.expect` call, a route param sitting next to the envelope (`params.expect(:id, user: [:name])`) is **not** drafted as a field; it stays visible in a TODO, because a routing key is not body input. Neither is a second envelope, which belongs under a different `root:` than one contract can express.

No Rails required for the core: `Permittable::Generator.draft(model: User)`, `.for_controller(controller, source: File.read(path))`, and `.scan(source)` are plain Ruby.

---

### Auditing coverage (`permittable:audit`)

A controller declaring `permit_params :create` looks adopted. If it also answers `PATCH`, that action is validating **nothing** — and until now nothing in the gem said so. [`permittable:generate`](#generating-draft-contracts-permittablegenerate) only notices controllers with no contract at all, and the [OpenAPI export](#exporting-openapi-docs-that-cannot-drift) documents what exists rather than what is missing.

The audit crosses the contract registry with the **route set**, so a half-covered controller is as visible as an uncovered one:

```sh
bin/rails permittable:audit             # the table plus a summary
bin/rails "permittable:audit[strict]"   # ...and exit 1 on any unguarded write action
```

```
legacy/invoices
  POST   /legacy/invoices                   create       no contract — ACCEPTS A BODY
orders
  POST   /orders                            create       enforce
  DELETE /orders/{id}                       destroy      no contract — action not found
  PUT    /orders/{id}                       update       no contract — ACCEPTS A BODY
users
  GET    /users                             index        no contract
  POST   /users                             create       enforce  model: User  unknown: error
  DELETE /users/{id}                        destroy      monitor
  PATCH  /users/{id}                        update       enforce  model: User  unknown: error

8 routed actions: 3 enforced, 1 in monitor mode, 3 without a contract, 1 not found (Rails 404s it)
  2 of those accept a request body — untrusted input reaches the action unchecked
  2 covered actions declare no model:, so no schema-drift guard runs for them

Contracts declared for actions no route reaches or Rails would 404 (renamed or deleted?):
  users#archive
```

Three things it tells you that nothing else does:

- **Which write actions are unguarded.** A `GET` without a contract is usually fine; a `POST` without one is untrusted input reaching the action unchecked. That count is the number `[strict]` fails on, which makes the task a CI gate: *no new unguarded write endpoint*.
- **Which contracts aren't enforcing yet.** The audit runs inside the app, so unlike the exported OpenAPI it resolves the **effective** mode — a rule's own `mode:` first, then your app-wide `Permittable.mode`. This is the [monitor-mode](#monitor-mode-roll-out-without-rejecting) rollout dashboard.
- **Which contracts have gone stale.** A contract declared for an action no route reaches, or for a routed action Rails would 404, is a renamed or deleted action that left its contract behind.

A route that lists several verbs is audited once per verb. A `match ... via: :all` route is expanded into exactly GET, POST, PUT, PATCH and DELETE, and listed once for each. `resources` routes all seven actions whether or not they exist. A route that Rails would 404 reads `action not found`: no method (inherited ones count), no `action_missing`, and no template to render implicitly. It is not counted against `[strict]` or as coverage. It stays in the table rather than disappearing. The template check uses the class-level view paths and the default lookup details. So a template that is only found at request time reads `action not found`, for example one behind a `prepend_view_path` in a `before_action`, or one that exists only as a variant.

A catch-all 404 route (`match "*path", to: "application#not_found", via: :all`) shows its POST, PUT and PATCH rows as accepting a body. They do accept one: every stray body reaches the controller. Route only GET to the controller (Rails answers HEAD from it). Send the other verbs to a plain Rack endpoint, which never parses the body and which the audit does not list:

```ruby
match "*path", to: "application#not_found", via: :get
match "*path", to: ->(_env) { [404, { "content-type" => "text/plain" }, ["Not Found"]] }, via: :all
```

A `config.exceptions_app = routes` setup (`match "/404", to: "errors#not_found", via: :all`) shows the same rows. It needs only `via: :get`, because on 6.1 and later `ShowExceptions` re-dispatches the error request as a GET.

Under `[strict]` the task aborts on these rows, so the only choices today are to route the catch-all GET-only, as above, or to run the audit without `[strict]` until the ignore list ([#69](https://github.com/VSN2015/permittable/issues/69)) lands. Don't declare a contract on the catch-all to silence the gate. Under monitor mode it validates eagerly, so a malformed JSON POST answers 400 instead of 404. The OpenAPI export would also gain a fake `/{path}` endpoint.

The table lists a row for every verb on every path; the summary counts routes. A route with an optional segment, such as anything under `scope "(:locale)"`, lists each path it expands to (`/users` and `/{locale}/users`), but it is one route, so one unguarded `POST` counts once and the summary line says `N routed actions in M rows`. Rows are collapsed by controller, action, route index and verb; the index is a position within one `rails_routes` call, so audit concatenated route lists (an app's and an engine's) separately, or give them distinct `route:` values. Two separate routes to the same action (`post "/users"` and `post "/admin/users"`) count as two, because each one is a way in.

Controllers that never included `Permittable` are audited too — those are the ones worth finding. Everything is plain Ruby over the frozen registry plus route descriptors, so `Permittable::Audit.entries(controllers:, routes:)` works without Rails.

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

**What is honestly unrepresentable stays visible instead of guessed.** A `format:` regexp using a Ruby-only construct (or flags) is exported as `x-permittable-pattern` rather than a mistranslated `pattern` — including one anchored with `^`/`$`, which in Ruby anchor a **line** and in ECMA-262 anchor the whole string, so `/^\d{5}$/` accepts `"evil\n12345"` at runtime and publishing that source would promise a stricter rule than the server enforces (use `\A`/`\z`, which translate exactly); `validate:`/`transform:` are flagged `x-permittable-custom-validation`/`x-permittable-transformed`; actions covered only by a catch-all rule on a plain-Ruby host appear under `"*"` with `x-permittable-catch-all`; operations whose rule runs in [monitor mode](#monitor-mode-roll-out-without-rejecting) carry `x-permittable-mode: "monitor"`; operations with no matching route — or whose path-and-verb slot another controller already claimed, which one document cannot represent twice — land in `x-permittable-controllers` instead of being dropped. A templated path segment is declared as a path `parameter` of type `string`, because the route set doesn't say what an `:id` is and the exporter won't invent it. The schema documents the canonical JSON encoding — the runtime additionally accepts string-encoded scalars (`"42"`, `"true"`) for form/query payloads.

**Every `operationId` is unique across the document, and only a collision is ever renamed.** An operation's id is its controller path with `/` folded to `_`, then its action: `users_create`, `admin_users_index`. Client generators name a method after the id, so the scheme itself never changes. Where two places in the document would carry one id, the exporter renames all but one of them:

| Collision | Ids |
| --- | --- |
| One operation under two verbs (the separate PATCH and PUT routes `resources` draws to `update`, or one `match ..., via: [:patch, :put]` route) | `users_update` on PATCH, `users_update_put` on PUT |
| The pair again at a second path (`resources :orgs { resources :users }`) | `users_update_2` on the second PATCH, `users_update_3` on the second PUT |
| One operation under every verb (with `via: :all` routes, which the exporter documents under each verb) | `webhooks_receive` on GET, then `webhooks_receive_post`, `_put`, `_patch`, `_delete` |
| One operation at two paths under one verb (with the optional-segment expansion: `(/:locale)/posts` is documented at `/posts` and `/{locale}/posts`) | `posts_create` on the first path in route order, `posts_create_2` on the other |
| Two controllers that fold to one id (`admin/users` and `admin_users`, both GET) | `admin_users_index` on the first controller, `admin_users_index_2` on the second |

One place keeps the plain id. A routed operation comes before one under `x-permittable-controllers`, which takes part because it is in the same document. After that, controller, action and route order decide. Within one operation, PATCH comes before PUT whichever the route lists first, so `match via: [:put, :patch]` and `resources` name the PATCH method the same way. Between two operations only the order counts, whatever the verbs. Every other place gets its verb appended when that verb differs from the plain id's verb and the result is free. Otherwise it gets the next free number, from `_2`. So a second PATCH is `users_update_2`, not `users_update_patch`, and a second POST is `posts_create_2`. **The stability rule:** an id that only one operation would carry never changes, even when a suffix elsewhere would spell it; that suffix is numbered instead. So a change to routes or controllers can rename only operations that collide, never one that stands alone. A route declared twice is placed once, and a controller passed twice is documented once, so neither collides with itself.

Output is deterministic (fixed key order, declaration-order properties), so the generated file can be committed and reviewed as a diff — a contract change shows up in the same PR as its documentation change.

#### What the schema deliberately does not say

`spec/schema_conformance_spec.rb` holds the "cannot drift" claim to account: it walks canonical JSON payloads through both the contract and its own exported schema and asserts the verdicts agree.

Where they legitimately differ, the spec names the reason and asserts the **direction**, so a new divergence fails the suite instead of shipping quietly. Two cases go the safe way — the **server accepts what its docs reject**, leaving a client that follows the docs merely conservative:

- **Non-canonical encodings.** Coercion accepts `"30"` for an `:integer` and `1` for a `:string`, because form and query payloads are all strings. The schema documents the canonical JSON encoding only.
- **`null` as absence.** The runtime reads `{"age": null}` as `{}` ([absence](#absence-defaults-and-partial-updates)); JSON Schema cannot express that, so `type: integer` rejects a null the server would accept and ignore. A [`nullable:`](#explicit-nulls-nullable) field is not this case — there the null is a value, the exported `type` widens to say so, and the two agree.

One case goes the other way, and is worth knowing before you hand the document to a client:

- **Bounds JSON Schema has no keyword for.** A `:json` field's `max_depth:` is enforced by the server but cannot be written as a JSON Schema keyword, so the published document is **looser** there and an over-nested payload still earns a 422. The bound is not dropped — it is exported as `x-permittable-max-depth` — so a generator or linter that wants it can read it.

Everything else the exporter cannot translate stays visible as an `x-permittable-*` extension rather than being guessed at.


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
| `permitted_params(action = action_name)` | The cast, validated, defaulted `HashWithIndifferentAccess`. Raises `InvalidParameters` on violation (in [monitor mode](#monitor-mode-roll-out-without-rejecting), returns the raw pass-through instead), or `ArgumentError` when no contract covers the action. **Memoized per action, outcome included** — a rejection is re-raised rather than revalidated, so a contract runs (and instruments) exactly once per action per request |
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
| `Permittable.error_format` / `=` | `:envelope` (default) or `:problem` — see [RFC 9457 problem+json](#rfc-9457-problemjson) |
| `Permittable.problem_base_uri` / `=` | Base URI for problem `type` members |
| `Permittable.check_column_types` / `=` | Opt in to the [type half of the drift guard](#checking-types-too-opt-in) (default `false`) |
| `Permittable::InvalidParameters` | Raised on violation; carries `#details` and `#status` |
| `Permittable::JsonSchema` | Contract data → JSON Schema fragments (`.rule`, `.object`, `.field`) |
| `Permittable::OpenAPI` | OpenAPI 3.1 assembly (`.document`, `.operations_for`, `.request_body_for`, `.components`) |
| `Permittable::Generator` | Contract drafting (`.draft`, `.for_controller`, `.scan`) — see [generating draft contracts](#generating-draft-contracts-permittablegenerate) |
| `Permittable::Audit` | Coverage across the route set (`.entries`, `.summary`, `.stale`, `.format`) — see [auditing coverage](#auditing-coverage-permittableaudit) |
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
- An unknown `normalize:` or `format:` preset, listing the presets
- A `format:` that is neither a `Regexp` nor a preset name
- `format:`, `length:`, or `normalize:` on a non-`:string` field
- `length:` that isn't a non-negative `Integer` or a `Range`; `in:` that doesn't respond to `include?`
- A bound **no value could satisfy**: a reversed or empty `Range` (`in: 65..18`, `length: 5..2`, `length: 3...3`), an empty `in:` set, or a `length:` of 0 on a `required` field (where `""` already violates as `missing`)
- `validate:` or `transform:` that isn't callable
- A `default:` or `example:` that violates its own field's contract, or an array `default:`/`example:` whose elements violate `of:` — or, for an array declared with a **block**, an element that isn't a hash the block would accept
- A `default: nil` or `example: nil` on a field that isn't `nullable:`
- A `:json` field's `default:`/`example:` that isn't a Hash, or that its own `length:`/`max_depth:` would reject
- A `max_depth:` that isn't a positive Integer
- `required: true` combined with `default:`
- A field given both a type and a nested block; an array given both `of:` and a block
- An empty contract, or a nested block declaring no sub-fields
- `finalize` declared twice, without a block, or inside a nested block
- `permit_params` without a block, or an invalid `unknown:` mode
- A `root:` that isn't a single key (several top-level envelopes are a rootless contract with one nested block per key)
- An invalid `mode:` (and `Permittable.mode =` / `Permittable.error_format =` / `Permittable.check_column_types =` reject invalid values at assignment)
- A field whose declared type disagrees with its column's, when `Permittable.check_column_types` is on
- A `model:` that isn't an ActiveRecord class, or `model: true` that can't be inferred

</details>

### Compatibility

| Requirement | Supported |
|---|---|
| Ruby | >= 3.2 |
| Rails / ActiveSupport | >= 6.1, < 9 |
| Required dependency | `activesupport` only |
| Optional | `actionpack` (rendering, `before_action`), `activerecord` (drift guard) |

`actionpack` and `activerecord` are optional because every touchpoint is guarded with `respond_to?`/`defined?` — your app brings whatever it already has. The concern works on a plain Ruby object that responds to `params`, which is what makes it straightforward to unit-test.

Both claims are **tested rather than asserted**. CI runs the full suite against every ActiveSupport line in the range — 6.1, 7.0, 7.1, 7.2, 8.0, 8.1 — across the supported Rubies (see [`gemfiles/`](gemfiles/README.md)), and a separate job installs the built gem with *nothing but activesupport* and exercises every controller-free surface, so "activesupport is the only runtime dependency" cannot quietly stop being true.

The 6.1 floor isn't arbitrary. `class_attribute ... default:`, which declares the contract registry, arrived in Rails 5.2 — on 5.0 and 5.1 a contract cannot be declared at all — and 5.2/6.0 predate Ruby 3.x support, which this gem's own Ruby floor requires.

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
