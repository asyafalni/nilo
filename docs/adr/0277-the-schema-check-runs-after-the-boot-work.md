# 0277 — the schema check runs after the boot work

**Status:** accepted
**Amends:** [ADR 0220](./0220-work-that-needs-the-services-runs-on-their-loop.md)
(which put the version guard in `nilo_start`),
[ADR 0144](./0144-a-check-dials-the-connection-it-needs.md)
**Applies:** [ADR 0262](./0262-a-db-with-no-schema-check-says-so-or-is-told.md)
(a `Db` is nagged to call `checking`), [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)

## Context

The guide's single-file SQLite program is two lines: `db.checking(schema)`,
and `createMissing` registered with `app.before`. ADR 0262 nags every `Db`
into the first; the migrations page recommends the second. Together they
did not boot.

`Db.nilo_start` opened the pool and ran the schema check on it. `before`
runs after every service's `nilo_start`. So on a new file the check saw no
tables, `checkSchema` listed three problems at `err`, `listen()` refused to
start, and the second boot was clean, because the first had got as far as
opening the pool and no further and the *next* boot's `before` never ran
either. The application had to write `.unchecked = true` and call
`checkSchema` by hand after `createMissing`, and had to read `db.zig` to
find out why.

The same order bit `db.expecting(version)` beside a migration in `before`: a
fresh database is behind before the migration runs, so the guard refused a
boot the next line would have brought level.

## Decision

**A service may declare `nilo_check(self, io) !void`, and the App runs it
after the work `before` registered and before the first request. `Db`'s
schema check and version guard move there.**

The boot inside `listen()` is four steps now (ADR 0040, ADR 0086, ADR 0220,
this one): every `nilo_start`, then `before`, then every `nilo_check`, then
what `spawn` registered. `app.start(io)` runs the first three on the
caller's `Io`, `before` included, which it had not done before: it is
documented as everything `listen()` does before it accepts anything, and a
test that registered `createMissing` wants its tables.

`Db.nilo_start` still dials one connection for a `Db` that has a check to
run (ADR 0144), and still says so in one line when it cannot; `nilo_check`
reads that and skips the checks it was for rather than failing them. A
`Db` no App holds calls `nilo_check(io)` itself after its own boot work, or
`checkSchema` directly, which is `pub` and now in the reference.

## What was rejected

**`db.checking(schema, .{ .after_before = true })`.** An option that is
right for every program that has boot work and wrong for none: a check that
runs before the tables exist is not a check anybody wants, so there is
nothing for the option to choose between.

**A paragraph in the migrations guide saying the two do not go together.**
The two do go together; that is the shape a single-file program has. A
paragraph would have documented the bug.

**Running `before` before `nilo_start`.** The work needs the pool.

**Leaving `app.start(io)` as it was, without `before`.** It would have kept
the old first-boot failure alive for exactly the tests the new example
writes, and its own doc comment already promised the phase.

## What it costs

One optional function pointer per registered service, eight bytes, read once
at boot. One bool on the App. Nothing on the request path. The shape check
on the hook is one refusal.

## Consequences

- `http/service.zig`: `checkHook`, `Registry.check`.
- `http/app.zig`: `checkServiceHooks`, run from `serverStarting` and from
  `start`; `start` runs `runBefore` too.
- `sql/db.zig`: `nilo_check`; `nilo_start` no longer runs `checkAtBoot` or
  `expectAtBoot`.
- `refusals/check_hook_wrong_arity.zig`.
- `examples/sqlite/` is the program that could not boot, and its tests boot
  it.
