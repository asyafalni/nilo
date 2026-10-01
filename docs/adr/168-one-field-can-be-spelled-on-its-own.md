# One field can be spelled on its own

**Status:** accepted
**Topic:** [json](../design/json.md)

[ADR 148](148-a-field-name-is-a-spelling-too.md) let a struct say
`rename_all = .camelCase`, and it closed the last of the port's DTOs by making
the Row the response. It holds on every Row in the `commitment` context but
one: `commitments.estimated_cost_amount_minor` is `estimatedCostMinor` on the
wire. The frontend's schema, three screens and the generated client all say
so, and renaming the column is not on offer. No case gets from one to the
other, so `commitment.Summary` was a copy of the Row with one field spelled
differently and a `summarise(row)` beside it — a DTO and a copying function,
exactly the pair ADR 148 deleted ten of.

## `.rename`

```zig
pub const nilo_json = .{
    .rename_all = .camelCase,
    .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
};
```

A struct of names, each the field as it is written, each value the spelling
it goes out under. An entry wins over the case; every other field takes the
case, or its own name when there is none. It works on an enum's values and a
union's variants the way `rename_all` does, because they are names too.

It is the third thing the marker can say, and it is read where the other two
are: `jsonmark.wire` answers the entry first, so `json.write`, the API
description and the tagged-union reader all agree without any of them knowing
the entry exists. That is the property ADR 016 built the marker for.

## `.unknown_fields = .ignore`

```zig
const Span = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore };

    name: nilo.Str,
    start_unix_nano: u64,
};
```

A body key a struct has no field for is a 400 naming it
([ADR 016](016-the-api-description-comes-from-the-signatures.md)), and that
stays the default. This is the per-type opt-out: the struct skips the key and
its value and reads on. It is the fourth thing the marker can say.

**Why it exists.** An OTLP/HTTP JSON receiver has to ignore unknown fields, which
the OpenTelemetry specification requires so that a newer client can talk to an
older collector. photon's Rust API did the same, because serde ignores them
unless a type says `deny_unknown_fields`, and the port could not copy its
types without it. A third-party webhook grows a field the day its vendor
likes, and a 400 for it is an outage nobody on this side caused.

**Why it is the type's to say and not the route's or the App's.** A nested
type may be shared with a route that wants it strict, so a switch anywhere but
on the type would change what an endpoint nobody touched accepts.

- **It applies to that type only.** A strict parent still refuses its own
  unknown keys when a child ignores its own, and a tolerant parent still has
  its strict child refuse. Tests hold both directions.
- **On a union, it goes on the variant's payload struct**, beside the other
  markers a payload carries, and the tagged-union reader leaves that variant's
  key check out. A sibling variant that says nothing still refuses.
- **Skipping is `skipValue()` in `innerRead`**, one line, with no allocation.
  A repeated known key is still refused
  ([ADR 016](016-the-api-description-comes-from-the-signatures.md)), and a
  missing or mistyped known field is still a 400 naming it.
- **What is skipped is bounded.** A skipped value is read by no field, so the
  type does not say how deep it can go. `refuseTooDeep` already scanned bodies
  whose type can nest without bound; it now also scans a body whose type holds
  an ignoring struct anywhere, so a skipped value is held to 64 levels
  ([ADR 226](226-a-body-that-can-nest-for-ever-is-read-sixty-four-deep.md)). The scan allocates
  nothing and only those types pay for it.
- **The API document says `additionalProperties: true`** for such a type and
  nothing at all for any other. ADR 016 promises a 400 for an unknown key in a
  request, not an absence of keys in a response, and the schema is the
  response's too, which clients read ignoring keys they do not know, so
  `false` would be a claim the types never made.

**A known limitation, documented rather than refused.** A payload under an
*externally* tagged union (`{"metrics":{...}}`, no marker on the union) is read
by `std.json` itself, which cannot see the marker, so that payload stays
strict. Refusing the combination would turn a harmless declaration into a
compile error at a place the reader cannot be taught about.

## What is checked

Three things for renames, and four more for this marker, each a Refusal where the marker is written rather than a key
that quietly never applied:

- **The name has to be a field.** `.rename = .{ .estimated_cost = … }` on a
  struct with `estimated_cost_amount_minor` is a typo that would rename
  nothing, and it is refused by name.
- **The spelling has to change something.** `.rename = .{ .amount = "amount" }`
  is refused the way `.rename_all = .snake_case` is: a line that does nothing
  is a line somebody will read as doing something.
- **Two fields cannot land on one key.** `checkRenames` already held this for
  `rename_all`; it now spells every field through the whole marker, so an
  entry that spells one field the way the case spells another is caught, and
  the advice points at the entry rather than at the cases.

And the rule ADR 148 drew is unchanged: a struct that renames its fields —
by case or by entry — is a write spelling, refused on the way *in*. A body
struct is its own type, spelled the way the wire spells it.

## What was not done

**A per-field marker on the field.** Zig has no field attributes, and a
declaration beside the field (`pub const estimated_cost_amount_minor_json =
…`) is a naming convention pretending to be one. The marker is one place.

**Renaming through a function.** `.rename = renameFn` that maps names would
let a caller write any transform. The transforms the case list has are the
ones that are unambiguous from a Zig field name, and the list is short on
purpose; a function would reopen it, and the check that two fields do not
collide could no longer read the answer while compiling without calling it.

## Against ADR 017's four axes

Nothing. Every name is a comptime literal, written as part of the same
`writeAll` as the punctuation around it, exactly as under `rename_all`.
`checkRenames`'s budget grew by `renames × fields`, which is the loop it
added ([ADR 126](126-a-check-pays-for-its-own-branches.md)).

## Consequences

- `Mark.renames`, `Mark.renamesFields()`, and `.rename` in the marker.
- Three Refusals: a field the type lacks, a spelling that changes nothing,
  and an entry that lands on another field's key.
- `Mark.ignores_unknown`, `jsonmark.ignoresUnknown` and `ignoresUnknownWithin`,
  and `.unknown_fields = .ignore` in the marker, with four Refusals
  (`json_unknown_fields_*`).
- `openapi.Object.open`, written as `additionalProperties: true`.
- A tagged union that is the whole body (`Ctx.json(Union)`) gets the sentences a
  nested one gets, naming the discriminator and the variants, where it was
  a bare 400.
- `commitment.Summary` and `summarise` go, and the Row is the response.
