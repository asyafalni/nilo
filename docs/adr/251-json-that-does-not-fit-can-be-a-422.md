# JSON that does not fit can be a 422

**Status:** accepted
**Topic:** [json](../design/json.md)
**Extends:** [ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md) (the refusals a binding cannot collect), [ADR 168](./168-one-field-can-be-spelled-on-its-own.md) (what the marker can say, and that it is the type's to say)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md) (the document promises what the types settle)
**Found by:** the photon port, whose axum server answers 400 for a body that is not JSON and 422 for JSON of the wrong shape

## Context

A typed body that does not fit is a 400 naming what was wrong, whatever was wrong: text that is not JSON, a missing field, a number where text goes, a key the type does not know. That is the same answer a query param or a form field gets, and it is the rule the request-input topic is built on: a plain argument fails fast with a 400, and `Bound(W)` hands the failures to the handler, which answers `b.fail()` with a 422 ([ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md)).

axum's `Json` extractor draws the line in another place. A body serde cannot read as JSON (a syntax error, the input ending early) is a 400, and JSON serde read but could not turn into the type (a missing field, a value of the wrong type, a body that is a list) is a 422, which is what RFC 9110 section 15.5.21 defines 422 for: the syntax of the content is right and the server cannot process what it says. photon's clients and its contract tests read the two statuses apart, so a port of it onto nilo saw 400 where 422 was promised, and its workaround was to take the body as bytes and run `std.json` by hand, mapping the error names itself. That throws away every sentence nilo writes about which field was wrong.

**The distinction is known exactly where the status is chosen.** A body that fails to parse is read a second time as a `std.json.Value` to say what is wrong with it (`describeBadBody` in `ctx.zig`). If that second read fails, the text is not JSON. If it succeeds, the body is JSON and everything said after that point is about its shape. No guess about error names is needed.

`Bound(T)` is the mechanism nilo already has for choosing what happens when a body does not fit, and it does not reach this. It turns a missing field or a top-level value of the wrong kind into a 422, but a body that is not an object, a key the type does not know and a mistake nested inside a field stay a hard 400 by its own rule, because there is no top-level field to record them against. photon's `services: [1]`, a list holding a number where text goes, is the third.

## Decision

**A body type can say that JSON of the wrong shape is a 422, with `.misfit = 422` in its `nilo_json`.** Text that is not JSON stays a 400.

```zig
const SearchRequest = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore, .misfit = 422 };

    start_ts_nanos: nilo.Str,
    services: []const nilo.Str = &.{},
    limit: u32 = 500,
};
```

What is a 422 under the marker, carrying the same sentence the 400 carried, so only the status moves:

- a field missing, a value of the wrong kind, a number that is not a value of its field, a word that is not one of an enum's choices, a variant a tagged union does not have;
- a mistake nested inside a field, named by its path (`services[0]`), and a shape nested past the eight levels nilo follows to name one;
- a key the type does not know, for a type that refuses them;
- a key given twice;
- a body that is JSON and not an object.

What stays a 400, because none of it is a body of any shape: text that is not JSON, an empty body, and a body nested past the 64 levels a body is read to ([ADR 226](./226-a-body-that-can-nest-for-ever-is-read-sixty-four-deep.md)). That is axum's line too, where an empty body and serde's recursion limit are syntax errors. A rule a `nilo_check` reports was already a 422 and is unchanged ([ADR 193](./193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

**It holds wherever the type is read as a body**: a typed body argument, `c.json(T)`, and under `Bound(T)`, where the refusals the binding cannot collect (not an object, an unknown key, a nested mistake, a repeated key) are answered with the type's status instead of the hard 400. What the binding does collect is still the handler's to answer with `b.fail()`.

**The marker is a number, and the number is 422.** The entry says the status a client contract states, so it is written the way the contract writes it. `.misfit = 400` is refused because it is what every type already answers, the same as `.unknown_fields = .refuse`. Any other status is refused because no other one means "the syntax is right and the content does not fit": a 409 or a 403 for a missing field would be a status lying about why.

**It is read off the type the body is read into, and only that one.** The status belongs to the request, and the type the request's body is read into is the one the route names. A struct nested inside the body is answered for by the body's type, and its own `.misfit` changes nothing, the opposite of `.unknown_fields`, which is per struct because skipping a key is something each struct does to its own keys. It is a struct's or a tagged union's to say; an enum is refused, and so is a union with no `.tag`, which `std.json` reads by itself and so never says whether what it refused was JSON.

**The document says it.** A route whose body type says `.misfit = 422` lists a 422 beside its 400 ("the body is JSON that does not fit what this endpoint takes"), because the type settles it ([ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md)). A route that can also answer 422 for an `Idempotency-Key` reused on a different request lists the key once, with both reasons, since a JSON object keeps one of two equal keys. Under `Bound(T)` the document promises nothing about the body, as before, because the handler decides what the client sees.

### How it is done

Every refusal after the second read succeeds goes through one function, `misfit(T, refused)` in `ctx.zig`. Its first line is `comptime jsonmark.misfitStatus(T) orelse return refused`, so for a type that says nothing it compiles to returning what it was given. For a type that says 422 it rewrites the status of the Failure the sentence is already in, only when that status is 400 (a type's own reader that chose another status keeps it), and gives a bare `std.json` error that no walk could explain a sentence of its own, since that error's status by name is 400. The sentence is unchanged: the 240-byte Failure is filled exactly as before ([ADR 006](./006-failure-box-bound-to-the-fiber.md)).

## What was rejected

**422 for every body of the wrong shape, as the default.** The common REST reading, and the feedback's first suggestion. It would break every client and every test that reads the 400 nilo has always answered, for programs that never asked, and it would split the request-input rule in two: a query param that is not a number would stay a 400 beside a body field that is not a number answering 422, in the same program, with no type saying why. A default change is also the one that cannot be taken back by the program that disagrees with it, where an opt-in costs the program that wants it one entry.

**An App-wide setting, `app.misfit(422)` or a `listen` option.** It is how axum draws the line, once for the whole server, and it was the closest second. It loses for two reasons. The document is written from the types while compiling, and a runtime setting would need a second path to put the 422 there, or a document that does not say it. And a type shared by two programs, or by a route the setting was not meant for, would answer differently by where it was mounted rather than by what it is, which is the reason ADR 168 gave for `.unknown_fields` being the type's and not the App's. A program that wants every body to answer 422 writes the entry on each body type, which is one line on a type it already declares.

**A hook, `nilo_misfit(kind, message) u16`, on the body type.** It reads more general and is not: the only input that decides the status is whether the body was JSON, and the only two answers RFC 9110 has for the two cases are 400 and 422. A function would also be the one marker entry that is code rather than data, and a type in a module that imports nothing has to be able to write the marker ([ADR 016](./016-the-api-description-comes-from-the-signatures.md)).

**Widening `Bound(T)` so that it collects a nested mistake and a body that is not an object.** It would get photon's split only for a program that writes `orelse return b.fail()` in every handler, and it would undo the rule ADR 034 drew on purpose: a per-field failure needs a field to fail, and a nested mistake is named better by its path than by its top-level field.

**A marker on `Form(T)` too.** axum answers a form body that does not deserialize with a 422 as well, but a form has no line between syntax and shape to draw: any bytes are a form, and every refusal of one is already about its fields. Nobody has asked; a caller who does brings the line.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. The status is a comptime value and the sentence goes in the Failure every connection already carries. |
| Memory per idle connection | None. No field on the Ctx or the connection; `misfit` runs only on a request already being refused, never where a connection waits ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). |
| Throughput and p99 | None for a body that parses, and none for a type that says nothing, whose `misfit` compiles away. A type that says 422 pays one store of a `u16` on a request already refused. |
| Binary size | **+144 B on `hello` and on `rest`**, stripped `ReleaseFast`, against `0635e31`, though neither marks a type: the document writer is in every program that serves its document and reads `op.misfit` at run time, so its branch and the sentence it adds are linked whatever the types say. The three 422 descriptions are one string sliced three ways; as three literals they were +304 B. A marked type adds one `misfit` instantiation. |

## Consequences

- `.misfit = 422` in `nilo_json`; `jsonmark.Mark.misfit` and `jsonmark.misfitStatus`; `openapi.Operation.misfit`.
- Five Refusals (`json_misfit_*`): `.misfit = 400`, another status, a value that is not a number, the entry on an enum, and on a union with no `.tag`.
- ADR 034's three hard 400s under `Bound(T)` are the type's status when it says 422, except text that is not JSON.
