# A field name is a spelling too

**Status:** accepted
**Topic:** [json](../design/json.md)

## Context

`rename_all` renamed an enum tag and a union variant. `json.zig` wrote `f.name` for a struct field, and the test at the bottom of that file said so in its own title: *a tag and a case together rename the variant but not its fields*. That was a decision, and this reverses half of it.

A Row is snake_case because Postgres is. A wire is camelCase because the browser is. Between the two, in one ported context: 10 response structs, 77 fields, 5 mapping functions written out field by field, 3 more mapped inline in handlers and 5 arena loops, and the whole job of all of it was `full_name` becoming `fullName`.

```zig
fn contactDto(row: rows.Contact) ContactDTO {
    return .{ .id = row.id, .partnerId = row.partner_id, .fullName = row.full_name, … };
}
```

**Nothing held a Row field against the DTO field carrying it**, and that is the part that is not about typing. A column added to a Row reaches the wire only if somebody remembers a second file; the response that quietly lacks it compiles, validates, and generates a client that has never heard of it.

The same port then hit the other side of the same wall: `covers`, the check that decides whether a value goes through nilo's generated writer or whole to `std.json`, answered false for any struct holding a type with its own `jsonStringify`. The reporting port has 145 `uuid` columns across 59 tables, so every response held at least one, and all ten of the structs `rename_all` was written for could not use it. They tried the change and reverted it.

## Decision

**A struct may declare `pub const nilo_json = .{ .rename_all = .camelCase };` on the marker that already existed, renaming its own fields on the write side. A type that writes its own JSON and also says, with `nilo_openapi`, that what it writes is one scalar is a leaf: `std.json` writes the value and the generated writer keeps writing the object around it, so a struct holding one can still rename its fields.**

### Rename on the write side only

```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: Uuid,
    full_name: Str,
    partner_id: Uuid,
};
```

Opt-in per struct, on the marker that already existed. `json.write` reads it and `openapi.schemaWithin` reads the same one (`mark.wireNames`), so the document promises the keys the server sends. That second half is not optional: [ADR 016](./016-the-api-description-comes-from-the-signatures.md) is this failure recorded once already, when a `Uuid` went out as 36 characters and was described as an object with a `bytes` field.

**It costs nothing per request.** The name is a comptime string either way, and it is written as part of the same `writeAll` the punctuation is in, a renamed struct writes exactly as much as a plain one, the sentence the enum arm has made since [ADR 016](./016-the-api-description-comes-from-the-signatures.md).

A struct's `rename_all` renames that struct's fields and nothing else. A union's renames its variants, and a payload struct's own marker is what renames the payload's fields, so a nested struct that says nothing keeps its own spelling. Two markers, each about its own type, is a rule that can be read off one declaration. `checkTag` compares the tag's key against the payload field's wire name, because that is the one that would collide.

### The write side only, and the read side is a Refusal

`std.json` chooses the parser for a body, so an input struct would need `jsonParseFor` of its own, and one mechanism working in one direction beats two that can disagree about one field. That leaves a way to be silently wrong, so it is closed while compiling: a struct that renames its fields, used as a request body, a form or a query string, is a compile error naming the route, because that route would document `fullName` and answer 400 to a client that sent it. The check (`renamedFieldsWithin`) walks eight deep, the same ceiling `covers` and `schemaWithin` have, so a renamed struct nested inside a body is caught too.

A union is not this and neither is an enum: both read back through `jsonParseFor`, the supported way in. Only a struct has no reader, and only a struct is refused.

The second Refusal is the collision `checkRenames` already held for enums and unions, now true of fields: `.lowercase` joins the words, so `full_name` and `fullname` land on one key, an object carries that key twice, and a reader takes whichever it met last.

### A leaf: a self-describing scalar can be carried

`covers` answers false for any struct holding a type with its own `jsonStringify` (four of nilo's own: `sql.Uuid`, `sql.Timestamp`, `sql.AsText`, and `id.Uuid`), and treated that as a wall no further question was asked of. The better question is *does it write its own JSON and say what that JSON looks like*, because a type that says so has already promised the shape this writer needs:

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`openapi.toldOf` accepts four values for `type`: `"string"`, `"integer"`, `"number"`, `"boolean"`. A marker naming one of them is a promise that the value is one scalar with nothing nested in it, which is exactly the promise needed to keep writing the punctuation on both sides of it. `writesItsOwnScalar` is the name of that check in `json.zig`: a struct carrying both declarations is a leaf, `writeValue` hands the value itself to `std.json.Stringify.value` and goes on writing the object around it, and `coversWithin` asks the question before it asks anything about what is inside the type.

`jsonStringify` alone is still a wall. A type that writes itself and never says what it wrote is a shape neither the writer nor the schema can describe, and it stays `std.json`'s whole value.

The leaf is written by `std.json.Stringify.value`, the same call the whole value used to go through, on the same value, so a leaf's output is byte-for-byte what `std.json` would have written by construction rather than by care. On a 305-byte contact row with three uuids and four strings (`spike/leaf_json/`, ReleaseFast): `std.json` on the whole value, 244–254ns; the generated writer with three leaves, 161–169ns; the same struct with the uuids already text, 102–121ns. 33% off a response that was paying `std.json`'s byte-at-a-time string escaping for every string in it because of one field, and the same finding [ADR 016](./016-the-api-description-comes-from-the-signatures.md) recorded for unions, reached from the other side: `covers` is answered for the whole value, so every type it refuses is paid for by every string beside it.

`covers`'s fallback still errs narrow on purpose: one shape it does not recognise (a tuple, an array of bytes, an untagged union, a type with its own `jsonStringify` and no leaf marker, anything nested more than eight deep) sends the whole value to `std.json`, which does not read `nilo_json`. `json.write` asks before it hands the value over: a rename-marked struct anywhere inside a value that falls back is a compile error naming the type, reusing `renamedFieldsWithin`, the same walk the incoming refusal uses, because the two questions are one question asked in two directions.

A further extension, that a self-writing type can instead name a whole type it is a document *of* rather than a scalar, is [ADR 163](./163-a-document-is-its-value.md): `sql.Json(T)` is that case, and it stays its own decision.

## What was rejected

**Reading a renamed struct back through `jsonParseFor`, so the marker worked in both directions.** `std.json` owns the parser for a body; a second, renaming reader is a second mechanism that can disagree with the writer about one field. `parseFor` on a renamed struct gets a sentence of its own saying so, because that is where somebody trying it lands.

**Treating every type with its own `jsonStringify` as a permanent wall, the position this decision shipped with first.** Reversed by the count that came back from the port it was written for: 145 `uuid` columns across 59 tables, every response holding at least one, all ten response structs the feature was requested for unable to use it. They tried the change and reverted it before the leaf carve-out existed. The line moved from *does this type write its own JSON* to *does it write its own JSON and say what that JSON looks like*, which is a question `nilo_openapi` already answers for a type that names a scalar.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0. Comptime strings; both the rename and the leaf path write into the response writer. |
| Memory per idle connection | 0 |
| Throughput and p99 | A saving where a leaf applies (33% on the row measured above); 0 otherwise. `mark.of(T)` and `writesItsOwnScalar` are answered while compiling, and the generated writer emits the same `writeAll` count as before, only the bytes in the literal differ. |
| Binary size | Unchanged for a type that says nothing. A renamed type carries the same total length of key literals it would have carried had they been written that way by hand. A type with a leaf gets a generated writer where the `std.json` reflection for it used to be, measured at ±0 on the two release binaries that carry neither. |
