# JSON

**A type's wire spelling is a marker on the type, read by the writer, the reader and the API description alike, so the three can never disagree about one field.** How to shape a response and a body is the guide ([`guide/responses.md#json-shapes-of-your-own`](../guide/responses.md#json-shapes-of-your-own)); every option is the reference ([`reference/handlers.md#json-shapes`](../reference/handlers.md#json-shapes)). The code is `http/json.zig` (`write`, `covers`, `isByteSlice`, `writesItsOwnScalar`), `http/jsonmark.zig` (`Mark`, `checkTag`, `checkRenames`, `wire`, `wireNames`, `documentOf`, `parseFor`) and `http/openapi.zig` (`schemaWithin`, `toldOf`).

## How the pieces fit

```
              nilo_json (.tag, .rename_all, .rename)
                         |
        Mark.of(T) ── checkTag, checkRenames ── comptime refusal
                         |
     write(value) ───────┼─────────── schemaWithin(T) (the document)
     covers(T)?           \
      /        \           `-- jsonmark.wire(name, mark): one answer,
  generated    std.json         read by both the writer and the schema
   writer       (fallback,
                 a leaf's
                 own value)

  a body field reads back through jsonParseFor(@This()),
  which hands the token to nilo_parse and refuses if there is none
```

A struct is covered, and gets nilo's generated writer, unless something about it stops the walk: a shape `covers` does not recognise, a type nested past eight deep, or a type that writes its own JSON and says nothing about it (a wall). A wall's whole value goes to `std.json`, which does not read `nilo_json`, so a marked struct is refused if it would fall into one. A type that writes its own JSON and says, with `nilo_openapi`, that it is one scalar is a leaf instead: `std.json.Stringify.value` writes just that value and the generated writer keeps writing the object around it. A type that says it is a document of another type (`nilo_json_of`) is written and described as that type, walked by the generated writer when the inner type is covered.

## The rule in force

1. **A struct, an enum's values or a union's variants can rename themselves for the wire**, with `.rename_all` (a case) or `.rename` (one name at a time, which wins over the case). [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md), [ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)
2. **`.lowercase` and `.UPPERCASE` join words and drop the underscore; the other four cases keep it.** There is no `.snake_case`: that is what a Zig name already is, and asking for it is a compile error, not a no-op. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
3. **Two names that would land on one wire key are refused, naming both and which cases keep them apart.** `checkRenames` checks an enum's values and a union's variants; with `.rename` in the marker it checks every field the whole marker produces. [ADR 072](../adr/072-two-renamed-names-that-collide-are-refused.md), [ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)
4. **A rename is a write spelling only.** `std.json` picks the parser for a body and reads the fields as written, so a renamed struct used as a body, a form or a query string is a compile error naming the route, checked eight deep the way `covers` is. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
5. **A type that writes its own JSON and says nothing about it is a wall**: its whole value goes to `std.json`, and a marked struct that falls into one through nesting is refused rather than silently unrenamed. [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
6. **A type that writes its own JSON and names a scalar with `nilo_openapi` is a leaf**: `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` all qualify, so a Row holding one can still rename its other fields, at a measured saving (250ns to 165ns on a three-uuid row). [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)
7. **A type that names a whole type it is a document of (`nilo_json_of`), with a `value` field of that type, is written and described as that type**, walked by the generated writer rather than handed whole to `std.json`. `sql.Json(T)` is the first of these. [ADR 163](../adr/163-a-document-is-its-value.md)
8. **A byte slice or `Str` that is not valid UTF-8 goes out as an array of byte values**, matching what `std.json` does with the same bytes; the document still calls the field a string, because the type is text even where one value is not. [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md)
9. **What counts as a byte slice is one function, `json.isByteSlice`**, read by the writer, `typed.contentTypeFor` and `openapi.schemaWithin` alike, so a `[:0]const u8` is never a string to one and a list to another. [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md)
10. **The walk that decides what a type looks like stops at eight levels**, on both sides: `coversWithin` for the writer and `schemaWithin` for the document, so the two never disagree about how deep is too deep. [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md)
11. **A body field reads back the way it was sent out.** A type with `nilo_parse` adds `pub const jsonParse = nilo.jsonParseFor(@This());` and is read from the one string or number token `nilo_parse` already takes; a body holding such a type with no reader is refused, naming the route. [ADR 166](../adr/166-a-body-field-that-parses-itself.md)
12. **A type that can say more about what it expects does, with `nilo_expects`**, read by every slot a value can arrive in (path, query, form, body); see [request-input](request-input.md) for the wider convert grammar this joins. [ADR 166](../adr/166-a-body-field-that-parses-itself.md)

## Decisions

| ADR | What it decides |
|---|---|
| [072](../adr/072-two-renamed-names-that-collide-are-refused.md) | An enum's values or a union's variants that collide under `rename_all` are refused, naming both |
| [081](../adr/081-one-file-decides-what-counts-as-text.md) | `json.isByteSlice` is the one answer to "is this text", and the walk's depth ceiling is shared |
| [096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md) | A byte slice that is not valid UTF-8 writes as an array of byte values, matching `std.json` |
| [148](../adr/148-a-field-name-is-a-spelling-too.md) | `rename_all` on a struct's fields, the wall/leaf split, and the read-side refusal |
| [163](../adr/163-a-document-is-its-value.md) | `nilo_json_of`: a type that names a document is written and described as that document |
| [166](../adr/166-a-body-field-that-parses-itself.md) | A body field reads through `jsonParseFor`, backed by `nilo_parse`; `nilo_expects` |
| [168](../adr/168-one-field-can-be-spelled-on-its-own.md) | `.rename`: one field spelled on its own, beside `.rename_all` |

Beside this topic: the tagged-union encoding itself and the API description built from the same markers are [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md); the wider grammar a value converts by, including `nilo_parse` and `nilo_expects` outside a JSON body, is [request-input](request-input.md); the response wrappers a JSON value goes out through (`?T`, `Status`, `Response`) and a type that writes something other than JSON are [responses](responses.md).

## Open

- **A byte slice that is not UTF-8 goes out as an array of byte values, matching `std.json`, but `std.json` itself only takes that path from `writeString`; `writeAll` writes a string unconditionally.** That mismatch predates this rule and is carried rather than fixed by it, noted as its own gap in [ADR 081](../adr/081-one-file-decides-what-counts-as-text.md).
- **`std.unicode.utf8ValidateSlice` costs far more on non-ASCII text** (up to 19x a short ASCII payload at a kilobyte), and nobody has needed a vectorised validator yet. On the record in [ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md) as a roadmap entry with a number behind it.
