# Layering

**One question decides which layer a module belongs to (does it need the event loop?), and a module may only import from layers below it, never from a module in the same layer.**

**Guide:** [Which module a page is about](../guide/README.md#which-page-covers-which-module) · **Reference:** [The modules](../reference/README.md#modules)

The layout table is in [`CLAUDE.md`](../../CLAUDE.md#layout), the vocabulary is in `CONTEXT.md`'s *Layer*, *Core*, *Tool module* and *Fitting* entries, and the rule is enforced by a build step: `zig build layering`, using the `Layering` struct and the `layers` table near the top of `build.zig`.

## Overview

```
Core (nilo_core)             no loop, needed by two layers, plain `zig test`
  ├─ Tool module (id, config, pw, cache, jwt)   no loop, may name Core, never a sibling
  ├─ Fitting (fetch, job)                       borrows the loop, owns no destination
  │    └─ Service (sql, s3)                     borrows the loop, holds a named system
  └─ App (http)                                 owns the loop
```

Imports only ever point down this stack. `zig build layering` goes through every `.zig` file listed under each module's row in `layers`, scans its `@import("...")` strings and rejects any that names something outside that row. `refusals/` directories are skipped, because those files import their own module by name on purpose. A file's `test` block may reach one layer up (`sql/live.zig` runs a whole request through `nilo.testing.Client`); such imports are listed under `in_tests` and not checked, because telling a test-only import from a real one would need a parser rather than a scan.

## Rules

1. **The layer question is "does it need the event loop", not "does it do IO".** Reading the clock or generating a UUID's bytes never waits, so they can sit in a layer that could not otherwise do IO at all. Needing the loop is what the layering has really always been about. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
2. **A module imports only downward, and never a module in its own layer.** Core imports nothing from nilo. A tool module may import `nilo_core` and no other tool module. A Fitting or Service may import `nilo_core`, any tool module, and its own third-party drivers. An App may import `nilo_core` and any tool module, and no Service reaches up into it. Two modules in the same layer share no files, which is what lets them be worked on separately. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
3. **For Core and for a tool module, running under a plain `zig test` is a requirement, not a nicety.** `zig test core/core.zig` and `zig test id/id.zig` (and `config/`, `pw/`, `cache/`, `jwt/`) run the whole module without `build.zig`. A module that cannot do that is in the wrong layer. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
4. **A Fitting uses the loop but owns no destination**: it is given `std.Io` and an address on every call, so it holds no connection to any named system. `fetch/` and `job/` are tested under `std.Io.Threaded` with no Engine and no module graph beyond Core, which is this layer's requirement. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
5. **A Service uses the loop and holds a connection to a named system.** `sql/` and `s3/` may import `nilo_core`, a tool module and a Fitting (`s3/` uses `nilo_fetch`), but never an App. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
6. **Core is shared vocabulary, not a place for leftovers.** A file belongs in `nilo_core` only if two layers need it, never because it has nowhere else to go. `Str`, the Scope, the clock and `percent` each got there by passing that test, not by being there from the start. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
7. **A marker on a type is an import you cannot see, so a marker lives with the module that has the opinion, not with the type.** `Uuid` is in `nilo_id`, but `pub const nilo_column = "uuid"` stays in `sql/types.zig`, because that line is a database's opinion, and a Core-layer type carrying it would mean Core quietly knowing about a layer above it. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
8. **No module is called `nilo`, and there is no umbrella module that re-exports everything.** The bare name belongs to the project (the `nilo:` Refusal prefix, `nilo_table`, `nilo_resolve`). `@import("nilo")` resolves to nothing; each module is imported by its own name (`nilo_http`, `nilo_id`, ...), so a project only links what it names. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
9. **`percent.zig` is in Core, not `http/`, because a caller below the App needs encoding.** `nilo_s3` signs URLs and cannot import `nilo_http` to reach an encoder. Core exposes `percent.decode` and `percent.encodeInto` in one namespace, since it is the one file in Core that goes both ways. `convert.zig` stayed in `http/` because it reports failures through the Bulkhead, which a Core file cannot do. [ADR 057](../adr/057-percent-is-needed-by-two-layers.md)
10. **`zig build layering` is the whole rule, enforced by a build step instead of a paragraph.** It reads the `layers` table in `build.zig`. Adding a module means adding a row there, a row in `shipped_roots`, and an entry in `build.zig.zon`'s `.paths`; a module missing from `.paths` ships a package with that directory silently missing. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)
11. **A shared module is built once per optimize mode, because two builds of the same file are two different types.** `build.zig` gives the same `nilo_id` build to `nilo_sql` and everything else in that mode. With a second build, `id.Uuid` and `sql.Uuid` would print the same but reject each other at `db.insert`, with no sign of trouble until then. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)

## Decisions

| ADR | What it decides |
|---|---|
| [038](../adr/038-a-module-sits-where-the-loop-puts-it.md) | The layer table, downward-only imports, each layer's entry requirement, and the build step that enforces them |
| [057](../adr/057-percent-is-needed-by-two-layers.md) | `percent.zig` moves to Core because a Service needs the encoding half, which a module in another layer cannot reach |

Related topics: the clock and entropy decisions that apply this same layer table are in [id-clock-entropy](id-clock-entropy.md); a Fitting used by a tool module as a type parameter instead of an import is in [jwt](jwt.md); the `sql-runtime` and `s3` topics cover what each Service does within its layer, not where the layer boundary is.

### Config, pw and build dependencies

These three topics each have a single ADR and belong to this layer.

**`nilo_config` reads settings into a struct you define and reports every bad setting at once, and the module imports nothing.** Each field is a setting read from its upper-cased name; `value()` fails closed, like binding a request; and `config.Dotenv` takes text instead of a path, so the module never opens a file itself. ADR 038 allows a tool module to use `nilo_core`, but `nilo_config` does not: sharing the pure half of `http/convert.zig` would stop `zig test config/config.zig` from running without a module graph, and that was worth more than avoiding forty duplicated lines of conversion code. [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)

**`nilo_pw` contains only the cryptography; the Gate that limits concurrent hashes lives in the Bulkhead.** Argon2id needs an allocator and a salt, which a tool module cannot provide, so both are arguments. `Ctx.hashPassword` is not just a convenience wrapper: it takes the salt from `Ctx.entropy`, gets a permit from a process-wide `Gate` and parks the fiber, because a mistake here would be invisible (13 ms is under the blocking detector's threshold), not loud. `pw.Token` is the second part: a 32-byte credential hashed with SHA-256 instead of argon2id, because what protects it is its randomness, not how hard it is to guess. [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)

**A dependency behind a build flag is only fetched when a dependent asks for it, because `.lazy = true` alone does not stop `b.lazyDependency` from running for every dependent, whatever it imports.** Before this change, `nilo_sql`'s drivers meant 11.1 MB downloaded even for a project that used no SQL. `want_sql` now defaults based on `b.pkg_hash` (empty only for the package being built), so this repository still builds everything without a flag, and a dependent opts in with `.sql = true`. `zig build fetch-check -Dnetwork` checks the number over two cold caches; it is not on `test` because it needs the internet. [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)

## Open questions

Nothing is open.
