# Choosing a params layer: an honest comparison

Every option below is good software. This page exists so you can pick the right one for your situation — including the situations where that is not Permittable.

## The one-table version

| | `params.permit` | `params.expect` (Rails 8) | rails_param | dry-validation | typed_params | **Permittable** |
|---|---|---|---|---|---|---|
| Filters unknown keys | ✅ | ✅ | — | ✅ | ✅ | ✅ |
| Shape errors are 400s, not 500s | ❌ | ✅ | ✅ | n/a | ✅ | ✅ |
| Casts to declared types | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Validates bounds / formats / sets | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Defaults | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Contract is introspectable data | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Machine-readable error details | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Checked against the DB schema at boot | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Exports OpenAPI / JSON Schema | ❌ | ❌ | ❌ | ❌² | ❌ | ✅ |
| Report-only rollout mode | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Drafts contracts from your schema | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Works outside controllers | ❌ | ❌ | ❌ | ✅ | ❌ | ✅¹ |
| Zero new runtime dependencies³ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |

¹ Via `Permittable::Contract`. ² Community adapters exist for dry-schema. ³ Relative to a Rails app: Permittable's only runtime dependency is `activesupport`, which Rails already ships.

## Against each option

### `params.permit` — the baseline

Strong parameters answers exactly one question: *which keys may pass?* If your actions never read a param without first checking its type, range, and presence — or your models happen to validate everything params can carry — you may not need more. In practice, the checks strong parameters doesn't do end up hand-written and scattered through actions, which is the problem this whole category of library exists to solve.

**Stay with `params.permit` if** your API surface is small and your models already validate everything that matters.

### `params.expect` — Rails 8's improvement

`params.expect(user: [:name, :age])` fixes a real strong-parameters wart: a request with the wrong *shape* (an array where a hash belongs) becomes a 400 instead of a `NoMethodError` 500. It is built in, and it is the right upgrade from `require().permit()` for every Rails 8 app.

What it deliberately does not do: cast `"36"` to 36, reject `age=abc`, apply a default, tell the client *which* field was wrong, or leave behind data that anything else (docs, tests, schema checks) can read. `expect` is a better filter; a contract is a different category.

**Stay with `params.expect` if** filtering plus shape-safety is all you need — it ships with Rails and has no learning curve.

### rails_param — inline validation

`param! :q, String, required: true` validates and coerces inline, per action. It is small and immediate. The trade-off is that the declaration is *code inside the action*, not data on the class: nothing can introspect it, export it, or check it against your schema, and the declarations run (and are re-declared) on every request.

**Choose rails_param if** you want per-action validation with zero structure and no interest in docs/exports.

### dry-validation — the powerhouse

dry-validation (with dry-schema underneath) is the most powerful validation toolkit in Ruby: composable schemas, a full rule DSL for cross-field logic, macros, localization, and it runs anywhere. If your domain has genuinely complex validation — multi-step dependent rules, reusable schema fragments shared across services — it is the serious tool, and Permittable does not try to compete with it.

The trade-offs are the flip side of the power: its own type system and idioms to learn, more runtime dependencies, and no controller opinion — you wire the schema call, the error rendering, and the 422 envelope yourself, and nothing ties a schema to your database or routes.

**Choose dry-validation if** validation complexity is the problem. **Choose Permittable if** the problem is untrusted controller input, and you want the controller integration (rescue, envelope, before_action), the DB drift guard, monitor-mode rollout, and OpenAPI export to come with it.

### typed_params — the close cousin

typed_params (from Keygen) is the closest design to Permittable: a typed, declarative DSL on the controller class. It is production-proven and worth your consideration. Differences that matter: Permittable contracts are frozen class-level *data* readable by other tools — which is what enables the OpenAPI exporter, the schema-drift guard, the RSpec matchers, and the generator — and monitor mode gives brownfield APIs a no-risk rollout path. typed_params has its own strengths, including formats (JSONAPI) and a mature ecosystem around Keygen.

**Either is a reasonable choice**; the pitch for Permittable is the tooling around the contract, not just the DSL.

### apipie-rails / rswag — docs-first tools

These generate or verify API documentation. rswag validates that your app matches a hand-written OpenAPI spec via request specs; apipie generates docs from annotations. Both treat documentation as a separate artifact that must be kept in sync. Permittable inverts this: the OpenAPI document is *generated from the enforcement data*, so it cannot drift — but Permittable only documents what contracts cover (request bodies), while rswag can describe your whole API surface including responses.

**They compose**: some teams enforce with Permittable and describe responses with rswag.

## What the extra work costs

`benchmark/overhead.rb` compares a full contract validation (cast + validate + default, 7 scalars, a nested hash, an array) against the bare `params.permit` filter it replaces:

```
Permittable (cast+validate+default):     5324.8 i/s  (188 μs/i)
        params.permit (filter only):     3073.1 i/s  (325 μs/i) - 1.73x slower
```

On this payload the contract is *faster* than strong parameters while doing strictly more work (Ruby 3.2, Apple Silicon; run the script on your own machine — results vary with payload shape). Validation is also lazy by default, so actions that never read params pay nothing.

## Migration cost, honestly

- **From `params.permit`:** `bin/rails permittable:generate` drafts a monitor-mode contract per controller from your schema and existing permit calls. Deploy changes nothing; the dashboard tells you when it is safe to enforce. Budget an afternoon for a mid-sized API, mostly spent reviewing TODOs.
- **From dry-validation:** there is no automated path; the rule DSLs differ too much. Migrate only if you specifically want the controller integration and contract tooling.
- **Back out:** contracts are additive. Delete the `permit_params` blocks and your `params.permit` calls still work — nothing else in your app has to know Permittable was there.
