# One field can be spelled on its own

[ADR 0181](0181-a-field-name-is-a-spelling-too.md) let a struct say
`rename_all = .camelCase`, and it closed the last of the port's DTOs by making
the Row the response. It holds on every Row in the `commitment` context but
one: `commitments.estimated_cost_amount_minor` is `estimatedCostMinor` on the
wire. The frontend's schema, three screens and the generated client all say
so, and renaming the column is not on offer. No case gets from one to the
other, so `commitment.Summary` was a copy of the Row with one field spelled
differently and a `summarise(row)` beside it — a DTO and a copying function,
exactly the pair ADR 0181 deleted ten of.

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
the entry exists. That is the property ADR 0085 built the marker for.

## What is checked

Three things, each a Refusal where the marker is written rather than a key
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

And the rule ADR 0181 drew is unchanged: a struct that renames its fields —
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

## Against ADR 0018's four axes

Nothing. Every name is a comptime literal, written as part of the same
`writeAll` as the punctuation around it, exactly as under `rename_all`.
`checkRenames`'s budget grew by `renames × fields`, which is the loop it
added ([ADR 0157](0157-a-check-pays-for-its-own-branches.md)).

## Consequences

- `Mark.renames`, `Mark.renamesFields()`, and `.rename` in the marker.
- Three Refusals: a field the type lacks, a spelling that changes nothing,
  and an entry that lands on another field's key.
- `commitment.Summary` and `summarise` go, and the Row is the response.
