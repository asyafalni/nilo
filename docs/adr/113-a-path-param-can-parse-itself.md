# A path param can parse itself

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

## Context

A path parameter could be a number, a `nilo.Str`, a `bool` or an enum. So a uuid arrived as text, was parsed in the handler, and the generated document described it as a bare string: `{"name":"id","in":"path","required":true,"schema":{"type":"string"}}`. On a schema where 203 paths carry an `{id}` and almost every one of them is a uuid, that is one hand-written parse per endpoint and a generated client that has lost the format. The framework the caller came from declared `format: "uuid"` on the input struct, which both refused a malformed id at the router and put the format in the document.

The same question then showed up one slot over. `?actor=<uuid>` on a query field of the same type was refused outright, with `convert.zig`'s own comment saying so: "a type that parses itself is deliberately not on this list, and the gap is where it stops rather than what it is". That was an accurate account of how the code was arranged and not an argument about what a query parameter is, since `tryConvert` had handled the case since this marker arrived, ahead of its own switch in `convertible`. The port that reported it has 145 `uuid` columns and a `?owner=`-style filter on most list endpoints, about forty of its 267 operations, each carrying a `uuidOf` helper and answering 422 where a path parameter of the same type answers 400.

## Decision

**A type declares `pub fn nilo_parse(text: []const u8) ?Self`, and anywhere a value converts from text (a path param, a `Query(T)` field, a `Form(T)` field) reads it the same way a number or an enum is read.**

```zig
pub fn nilo_parse(text: []const u8) ?Self
```

Null means "that is not one of these", and becomes the same 400 a bad number gets. `nilo_id`'s `Uuid` carries the declaration, so `sql.Uuid` works with nothing to do on the caller's side.

### It is a declaration and not a shape

The obvious alternative is sniffing: a struct with a `parse` function is a path param. That would silently promote any struct with a `parse` method, a config type, a date type, somebody's domain object, into something a route argument can be, and change what an existing program means without anybody writing a line. A marker is a decision the type makes.

### It is read by name and never imported

`http/` may not import `nilo_id` or `nilo_sql`, and `zig build layering` holds that. This joins the marker protocols already read the same way, `nilo_openapi`, `nilo_form`, `nilo_query`, `nilo_resolve`, `nilo_redirect`, `nilo_bound`, `nilo_patch`, `nilo_column`, `nilo_read`, `nilo_write`, `nilo_start`, `nilo_stop`, and is the reason a module in the bottom layer can offer something to the top one at all.

A `nilo_parse` of the wrong shape is refused where the type is named, five ways: not a function, still generic, wrong arity, wrong argument, wrong return.

### The document needed nothing for the path case

`openapi.schemaWithin` already consults `nilo_openapi` for any type a signature mentions, and `Uuid` already declares `.{ .type = "string", .format = "uuid" }`. The moment a `Uuid` reached `schemaOf` as a path param's type, the document said `{"type":"string","format":"uuid"}` on its own, nothing in `openapi.zig` changed, and that is the layering paying for itself: two modules that cannot see each other agreed about a uuid, through a declaration neither of them owns.

### One arrival, one answer: the query and form slots read it too

```zig
if (comptime parsesItself(Inner)) return true;
```

`convertible` gained one clause, so a `Query(T)` field and a `Form(T)` field may be any type that parses itself, the same set a path param takes, and their refusal messages gained the case. **This does not reach the JSON body**: `std.json` fills a body, not this file, and a body field of such a type is `std.json`'s question (`jsonParse`), untouched here. `reasonFor` and `sayWhy` already word the failure with the type's own name (`Reason.not_that_type`), and `bound.canFail` answers true for such a field, so a `Bound(Query(T))` reports "did not fit" where it used to report nothing, the same sentence every other convertible field already gets.

"Where `nilo_parse` stops" was a sentence about a call graph; "one arrival cannot mean two things" is a sentence about the feature, and only the second is checkable against what the caller sees.

### It closed a second complaint

A handler written `fn update(id: sql.Uuid, body: UpdateBody)` used to get a message correct about the ambiguity of two structs by value and wrong about the fix, because `roleOf` classified every struct as `.body` without looking at whether the route had a path-param slot still unclaimed. For a `Uuid` the case is now gone, because a `Uuid` is a path param; for any other struct the message gained a third sentence, only when there is a slot to fill, naming `nilo_parse` as the way a type can be one.

## What was rejected

**Sniffing for any type with a `parse` method.** It would promote somebody's existing struct into a query or form field without asking, and change what a program that already compiles means. The declaration is written on purpose, and widening the query and form slots widens where a written one is honoured rather than widening what counts as one.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. `parsesItself` is comptime and answers false for every type that does not carry the marker, so a program with none generates nothing; the allocation budget test is unmoved. |
| Memory per idle connection | Unchanged. |
| Throughput and p99 | Unchanged: one clause in `convertible`, and the conversion path itself for a type that already parses itself is what it always was. |
| Binary size | One `@setEvalBranchQuota` raise, not optional: `operation()` was already close to the default 1,000 branches through `openapi.nameOf` walking type names, and one marker check per handler argument took `examples/orders` over it and stopped the build rather than slowing it. The quota is now 20,000 there. |

## Where it stops

**`nilo.url` cannot build a URL for one.** `url.zig` leans on `convert.convertible`, deliberately not widened: going the other way needs a counterpart declaration, a type saying how it writes itself into a path, and that is a second decision rather than the same one.

## Consequences

- Five refusal files for the marker's shape, one for the amended two-structs message, and rows in the `refusals` table.
- `Uuid` gained a `nilo_type_name` of `"Uuid"`, bare rather than qualified, because `id.Uuid` and `sql.Uuid` are both real import lines for one declaration and neither is the reader's ([ADR 148](./148-a-field-name-is-a-spelling-too.md)).
- `Reason` gained `not_that_type`, the 400 a type that parses itself answers with when it says no; the message strings and two assertions in `convert.zig`'s existing test cover the query and form cases.
- `sql.Timestamp` is usable as a query field the moment it declares `nilo_parse`, per [ADR 127](./127-what-a-server-prints-it-can-read.md).
