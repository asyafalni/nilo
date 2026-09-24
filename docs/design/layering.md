# Layering

**One question decides where a module sits, does it need the event loop, and a module imports downward only, never a sibling.**
The layout table is in [`CLAUDE.md`](../../CLAUDE.md#layout), the vocabulary is `CONTEXT.md`'s *Layer*, *Core*, *Tool module* and *Fitting* entries, and the rule is a build step: `zig build layering`, the `Layering` struct and the `layers` table near the top of `build.zig`.

## How the pieces fit

```
Core (nilo_core)             no loop, needed by two layers, plain `zig test`
  ├─ Tool module (id, config, pw, cache, jwt)   no loop, may name Core, never a sibling
  ├─ Fitting (fetch, job)                       borrows the loop, owns no destination
  │    └─ Service (sql, s3)                     borrows the loop, holds a named system
  └─ App (http)                                 owns the loop
```

An arrow only ever points down this stack. `zig build layering` walks every `.zig` file under each module's row in `layers`, scans its `@import("...")` strings and refuses one that names something outside that row; `refusals/` directories are skipped because those files import their own module by name on purpose. A file's own `test` block may reach one layer up (`sql/live.zig` drives a whole request through `nilo.testing.Client`), listed under `in_tests` and not verified, since telling a test-only import from a real one needs a parser rather than a scan.

## The rule in force

1. **The layer question is "does it need the event loop", not "does it do IO".** A clock read or a UUID's bytes never wait, so they can sit below a layer that would otherwise be barred from doing IO at all; needing the loop is what the layering has always actually been asking. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
2. **A module imports downward only, and never a sibling.** Core imports nothing of nilo's; a tool module may import `nilo_core` and no other tool module; a Fitting or Service may import `nilo_core`, any tool module, and its own third-party drivers; an App may import `nilo_core` and any tool module but never a Service reaches up into it. Two modules in the same layer touch no file in common, which is what makes them separate pieces of work. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
3. **Running under a plain `zig test` is the entry condition for Core and for a tool module, not a nicety.** `zig test core/core.zig` and `zig test id/id.zig` (and `config/`, `pw/`, `cache/`, `jwt/`) run the whole of each module with no `build.zig`; a module that cannot is in the wrong layer. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
4. **A Fitting borrows the loop and owns no destination**: it is handed `std.Io` and an address on every call, so it holds no connection to any named system. `fetch/` and `job/` test under `std.Io.Threaded` with no Engine and no module graph beyond Core, its own entry condition. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
5. **A Service borrows the loop and holds a named system it dials.** `sql/` and `s3/` may import `nilo_core`, a tool module, and a Fitting (`s3/` reaches `nilo_fetch`), but never an App. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
6. **Core is the vocabulary, not a drawer.** A file earns a place in `nilo_core` by being needed by two layers, never by having nowhere else to live; `Str`, the Scope, the clock and `percent` each arrived by passing that test rather than by being there from the start. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
7. **A marker on a type is an import you cannot see, so knowledge stays at the level of the opinion, not the type.** `Uuid` sits in `nilo_id`, but `pub const nilo_column = "uuid"` stays in `sql/types.zig`, because that line is a database's opinion and a Core-layer type carrying it would be Core quietly knowing about a layer above it. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
8. **No module is named `nilo`, and there is no umbrella re-export.** The bare name belongs to the project (the `nilo:` Refusal prefix, `nilo_table`, `nilo_resolve`); `@import("nilo")` resolves to nothing, and each module is imported by its own name (`nilo_http`, `nilo_id`, ...) so a project links only the bytes of what it names. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
9. **`percent.zig` sits in Core, not in `http/`, because encoding needs a caller below the App.** `nilo_s3` signs a URL and cannot import `nilo_http` to reach an encoder there; Core exposes `percent.decode` and `percent.encodeInto` as one namespace since it is the one file in Core with two directions. `convert.zig` stayed in `http/` because it reaches the Bulkhead to report a failure, which a Core file cannot do. [ADR 057](../adr/057-percent-is-needed-by-two-layers.md)
10. **`zig build layering` is the whole rule, held by a build step rather than a paragraph.** It reads `build.zig`'s `layers` table, and adding a module means a row there, a row in `shipped_roots`, and an entry in `build.zig.zon`'s `.paths`; a module missing from that list ships a package with a directory silently absent. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
11. **A shared module is built once per optimize mode, and two builds of the same root are two distinct types.** `build.zig` hands one `nilo_id` build to `nilo_sql` and to anything else in that mode; a second build would make `id.Uuid` and `sql.Uuid` print identically and refuse each other at `db.insert`, with no symptom until that moment. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)

## Decisions

| ADR | What it decides |
|---|---|
| [038](../adr/038-a-module-sits-where-the-loop-puts-it.md) | The layer table, downward-only imports, the entry condition per layer, and the build step that holds it |
| [057](../adr/057-percent-is-needed-by-two-layers.md) | `percent.zig` moves to Core because a Service needs the encoding half a Sibling module cannot reach |

Beside this topic: the clock and entropy decisions that reasoned through this same layer table are [id-clock-entropy](id-clock-entropy.md); a Fitting used from a tool module as a type parameter rather than an import is [jwt](jwt.md); `sql/`'s and `s3/`'s own topics (`sql-runtime`, `s3`) cover what each Service does once it is in its layer, not where the layer boundary sits.

### Three single-ADR topics that live on this floor: config, pw, build-dependencies

**`nilo_config` reads settings as a struct of the caller's own and names every bad one at once, and the module imports nothing.** A Config field is a setting read from its upper-cased name, `value()` fails closed the way a request binding does, and `config.Dotenv` takes text rather than a path so the module never opens a file itself. The entry condition beat the permission here: ADR 038 lets a tool module name `nilo_core`, but `nilo_config` does not, because sharing `http/convert.zig`'s pure half would cost `zig test config/config.zig` running with no module graph, and that property was worth more than not writing forty lines of conversion twice. [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)

**`nilo_pw` holds only the cryptography, and the Gate that bounds concurrent hashes sits on the Bulkhead instead.** Argon2id needs an allocator and a salt neither of which a tool module can supply, so both are arguments; `Ctx.hashPassword` is not a convenience wrapper, it takes the salt from `Ctx.entropy`, a permit from a process-wide `Gate`, and parks the fiber, because a mistake here is invisible (13ms sits under the blocking detector's threshold) rather than loud. `pw.Token` is the second half: a 32-byte credential nilo did not anticipate, hashed with SHA-256 rather than argon2id because its entropy, not its guessability, is what protects it. [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)

**A dependency behind a build flag is fetched only when a dependent asks, because `.lazy = true` alone does not stop `b.lazyDependency` running for every dependent regardless of what it imports.** `nilo_sql`'s drivers cost 11.1 MB fetched for a project that imported no SQL at all before this shipped; `want_sql` now defaults from `b.pkg_hash` (empty only for the package being built), so this repository still builds all of itself with no flag and a dependent opts in with `.sql = true`. `zig build fetch-check -Dnetwork` is the build step that holds the number, over two cold caches, off `test` because it needs the internet. [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)

## Open

Nothing is open on the record.
