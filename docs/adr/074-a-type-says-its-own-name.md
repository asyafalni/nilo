# A type says its own name

**Status:** accepted
**Topic:** [errors](../design/errors.md)

## Context

`@typeName` spells a type with the file it was declared in, and nilo's files are not files anybody using nilo has opened.
A resolver handed back the wrong type was told it returned `str.Str`, a true sentence about a source tree the reader does not have, sending them looking for a `str` module they never imported.
Their import line says `nilo`, so `nilo.Str` is the name a message should use, and `http/names.zig` existed to rewrite it: a hand-kept table of `file.Type` substrings, checked by three files (`session.zig`, `resolve.zig`, `service.zig`) and silently skipped by four others that carried twenty-five `@typeName` calls of their own inside `@compileError` text.

The table drifted, and it drifted invisibly: the doc comment said a type missing from it would be noticed in `refusals/`, and not one of the eleven exports that had fallen behind (`Bound`, `Session`, `FileBody`, `Dir`, `Stream`, `Events`, `Body`, `Socket`, `Room`, `Limits`, `Gate`) was, because a refusal proves the one message somebody thought to write a refusal for and nothing about the twenty-four beside it.
A WebSocket loop whose first argument was wrong was told it should be `*nilo.Socket` and that what it had was a `*ctx.Ctx`, one sentence naming the same kind of thing two different ways, one of them pointing at a file the reader has never seen.

The first fix was a test that walks what the module actually exports and fails on any type the table does not cover, rather than a second hand-kept list.
It did not survive contact with its own logic: the table matched on a **name**, and a name is exactly what cannot tell nilo's file layout from a reader's.
An application with an ordinary `src/room.zig` in it, holding a `pub const Room`, was told by a nilo compile error that its type was `nilo.Room` and sent looking for a type it never imported: the same failure this file exists to prevent, running the other way round.
`@typeName` spells a type as its path from *its own module's root*, so a project rooted at `src/main.zig`, the layout nearly every Zig project has, spells a sibling's `src/room.zig` type `room.Room`, byte for byte what nilo spells its own `http/str.zig`.
No rule over the name can tell the two apart, because there is nothing left in the string to tell apart; anchoring the match at the start or on a `.` boundary fixes only the rarer layout, a project rooted at `main.zig` with everything under `src/`.

## Decision

**A nilo type carries its own name as a declaration, and a test walks every export nilo makes to hold the compiler to it.**

### The declaration

```zig
pub const Room = struct {
    pub const nilo_type_name = "nilo.Room";
    …
};
```

`names.zig`'s `of(T)` returns `T.nilo_type_name` when the type has one and `@typeName(T)` otherwise, so a reader's own type keeps the file they wrote it in and only nilo's types are rewritten.
A generic computes its own from its argument, beside the markers it already carries: `pub const nilo_type_name = "nilo.Query(" ++ naming.of(T) ++ ")";`.
**`names.zig` imports nothing but `std`.** The exact fix, comparing types rather than names (`if (T == str.Str) return "nilo.Str"`), cannot be written here: `names.zig` is read from `session.zig`, `service.zig`, `resolve.zig`, `websocket.zig`, `jsonmark.zig` and `metrics.zig`, so a table of types in `names.zig` would import those files back and analyse them while they are half-analysed.
Inverting it to a declaration removes the cycle entirely and costs one line per type; no future import can make a type unnameable here, because the file that decides what an error message says cannot itself be caught in one.

Wrappers are taken apart rather than printed whole: `?nilo.Str`, `[]const nilo.Header`, `*const nilo.Ctx` are built from the child's own name, so a wrapper around somebody else's type is left to `@typeName` untouched and `?u32` stays exactly what it was.

### The test that walks the exports

**A test at the bottom of `http.zig` walks every type the module exports and refuses one that cannot name itself.** It lives there because that is the only place that sees the exports without a second list to keep in step, and it is what makes a type added to `http.zig` and forgotten fail the suite the day it lands rather than the day somebody notices the message.

Two things it cannot see are written into it rather than left to be discovered:

- **Non-generic types only.** `Response(T)`, `Session(T)`, `Bound(T)` and the rest are functions until somebody applies them, so there is no `@typeName` to take; their base names are what the markers on their instantiations build from.
- **Exports that are somebody else's type, or cannot hold a declaration at all.** `panic` is `std.debug.FullPanic`, which `@typeName` spells `debug.FullPanic(…)` with no `std.` in front, so no prefix rule can see it for what it is; renaming it would be a lie, since it is not nilo's type to name. `Middleware`, `CtxHandler` and `Handler` are function types, and a function type has no declarations to carry a name on, so each prints its own signature, spelled with the files nilo declared its arguments in. Each sits in a short skip list with the reason next to it, stated gaps rather than silent passes.

`names.covers(T)` answers "does `T` name itself" without paying for a rewrite, which is what the test asks per export.

## What was rejected

**Adding the four uncovered files to `refusals/`.** The obvious answer, and the one that already failed once: a refusal proves one message is right, says nothing about the twenty-four beside it, and cannot notice a type added to `http.zig` tomorrow. Refusals stay for what they are good at, that a wrong program stops with nilo's own words, and the completeness question moved to something that enumerates.

**A comptime identity table inside `names.zig`**, whether hand-kept or built from `if (T == …)` comparisons. Rejected both times for the same structural reason: it would have `names.zig` import the files that import it (`session.zig`, `service.zig`, `resolve.zig`, `websocket.zig`, `jsonmark.zig`, `metrics.zig`), analysing them while they are half-analysed.

**Anchoring the substring match** at the start of the name or on a `.` boundary, rather than matching anywhere inside it.
This was the answer for months, and one twenty-line program shows why it does not work: it fixes the layout where a reader's file sits under `src/` with a module rooted at the top-level `main.zig`, and does nothing for the layout nearly every Zig project actually has, a module rooted at `src/main.zig`, which spells a sibling's type identically to nilo's own.

**Listing the module's exports in `names.zig` as a second table.** Two lists to keep in step instead of one, which is the failure mode being fixed.

## What it costs

Nothing on any of the four axes: the walk and the rewrite are comptime, live in a test in a file no binary links, and `names.covers`/`names.of` are called nowhere else.

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size | 0 bytes: comptime-only, unreachable from a compiled program |

**What it spends is compile time, and the declaration form spends less of it than the table did.** The table's own scan cost was proportional to the table's length times the name's length, and it broke three callers that had not changed a character when one table (`ours`) grew from 20 rows to 35: the branch quota was sized to the table (`64 * (name.len + 1) * ours.len + 8_000`), and the table was exactly the thing that formula did not name. Reading a declaration costs one `@hasDecl` regardless of how many types exist, so the export-walk test today runs under one fixed `@setEvalBranchQuota(200_000)`, a number that no longer needs to track anything.
