# A body field that parses itself

**Status:** accepted
**Topic:** [json](../design/json.md)

[ADR 113](113-a-path-param-can-parse-itself.md)'s sentence — *one arrival has one
answer* — was written about `/deals/:id` and `?actor=`, and it said in the
same breath what it left out: the JSON body is `std.json`'s question, and
`jsonParse` is the answer there. The port reached the third arrival a round
later. `sql.Uuid` in a body struct was handed to `std.json`, which read it as
the `{bytes: [16]u8}` struct it is and answered

```
400 "dealId" has to be an object or null, not text
```

to a client sending the 36 characters the same server writes in every
response. Nine fields across four bodies in one context; 145 `uuid` columns
is 145 things a body can name. The port took them as `nilo.Str` and parsed by
hand — `uuidOf`, the helper ADR 113 deleted from `activity`, back one arrival
over — and the document said `{"type":"string"}` where the Go contract said
`format: uuid`.

## `std.json` chooses the reader, so the type hands one over

Nothing here can change which parser `std.json` uses for a struct: it asks
`std.meta.hasFn(T, "jsonParse")`, and reads the fields otherwise. That is the
same wall [ADR 016](016-the-api-description-comes-from-the-signatures.md) met for a
tagged union, and the same answer holds: **the type hands over a reader nilo
wrote.**

- `sql.Uuid` and `sql.Timestamp` carry `jsonParse` and `jsonParseFromValue`
  now: one string token, handed to the same `parse` that `nilo_parse` calls.
  Written by hand in `id/` and `sql/`, because neither may import `http/`
  (ADR 038), and both are twenty lines.
- A type of the caller's own that parses itself writes one line beside
  `nilo_parse`:

  ```zig
  pub const jsonParse = nilo.jsonParseFor(@This());
  ```

  `jsonParseFor` used to refuse a type with no `nilo_json` marker, since there
  was nothing for the reader to do differently. A type with `nilo_parse` has
  said how it is read — the one string, or a number's digits, handed to it —
  and that is what the reader does.

**And the one that forgot is refused**, where the body is registered:
*the request body on route "/lines" holds a `Sku`, which parses itself from
text and has not told `std.json` so.* A path param and a query value of the
type read one way and a body the other is the disagreement this ADR exists to
close, and it is found at `zig build` rather than by the first client to send
one. The walk goes through optionals, lists, `Patch(T)` and a tagged union's
payloads, eight deep, the way `renamedFieldsWithin` does.

## The words are the query value's

A body field that the type refused is worded the way a query value of the
type is worded, quoting what arrived: `"sku" has to be a Sku, not "abc"`. The
wrong kind of value is named by its kind, as every other field's is: `"sku"
has to be a Sku, not an object`. A binding (`Bound(T)`) records the field as
`.not_that_type` with the text, in the same words the slot uses for a query.
`ctx.zig`'s walk reads such a field itself rather than through `std.json`,
so that a type which handed over `jsonParse` and nothing more is still one
outcome among the others.

**A number is text here.** `nilo_parse` takes the digits, and a bounded
integer ([ADR 167](167-a-whole-number-inside-a-range-is-a-type.md)) is one
of these and arrives as a JSON number. The reader takes a number token as its
digits, and the walk prints one into a stack buffer to ask the type — so
`{"limit": 500}` is `"limit" has to be a whole number from 1 to 200, not
"500"`, quoted the way the query slot quotes it.

## `nilo_expects`

ADR 113 said the 400 for a type nilo did not write "names the type and stops
there — which is the whole of what it is entitled to say." A type that can
say more says it, with its article:

```zig
pub const nilo_expects = "a ticket number like T-1234";
```

and every slot — path, query, form, body — asks for it in those words. It is
what lets `sql.Ordering` say *an ordering by due, title or value* and
`nilo.Within` say *a whole number from 1 to 200* without either becoming a
special case in `convert.zig`.

## The document

A type that parses itself and says what it looks like (`nilo_openapi`) is
described as that, whether or not it writes its own JSON. `sql.Uuid` already
was, through `jsonStringify`; an `Ordering` writes nothing and would have
been described as `{terms: …, len: …}`, which is not what arrives.

## Against ADR 017's four axes

- **Allocations per request: zero** on a body that parses. A `Uuid` in a body
  is read straight into the field; `nextAllocMax` allocates only for a token
  a streaming reader had to split, which a complete body never has.
- **Memory per idle connection: zero.**
- **Throughput: nothing measurable.** One function call per such field where
  `std.json` was walking a struct.
- **Binary size: nothing** for a program whose bodies hold no such type.

## Consequences

- `sql.Uuid`, `sql.Timestamp` and `nilo.Within` read from a JSON body as the
  text (or number) a response writes them as. `[]const sql.Uuid` too.
- `nilo.jsonParseFor(T)` accepts a type with `nilo_parse` and no marker.
- One Refusal: a body holding a type that parses itself without a reader.
- `nilo_expects`, read by `convert.sayWhy` and by the body walk.
- The port's `uuidOf` goes for the second time, and the document says
  `format: uuid` on the nine fields.
