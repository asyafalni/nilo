# A value coerces into a nullable column, and an error union does not

**Status:** accepted
**Topic:** [sql-types](../design/sql-types.md)

`due_date` is `?sql.AsText("date")` on the Row. Setting it from a `Date` —
not a `?Date` — is the ordinary act of filling in a date that was empty:

```zig
try tx.updateReturning(rows.Commitment, c, .{ .set = .{ .due_date = due }, .where = .{ .id = id } });
```

and it stopped inside `forWire`, three frames below the call site:

```
error: expected type '…!?[]const u8', found '…![]const u8'
        return V.nilo_write(value, c.arena());
```

Every other type in that function takes the non-optional into the optional
slot for free — a `Uuid` into `?uuid`, a `Str` into `?text` — because those
branches return a value, and Zig coerces a `T` into a `?T` on the way out. A
text column's `nilo_write` answers `![]const u8`, and **an error union does
not coerce into an error union of an optional**: `!T` into `!?T` stops at the
error union, whatever the payload would have done. The port wrote
`@as(?Date, due)` at three sites.

## One word

```zig
return try V.nilo_write(value, c.arena());
```

`try` unwraps the payload, and the payload coerces the way every other branch's
value does. The optional branch above it already had its `try`, which is why
`?Date` into `?date` worked and `Date` into `?date` did not — the two branches
were one keyword apart, and the one without it was the one the ordinary write
takes.

**The rule this leaves behind**, for anybody adding a branch to `forWire`:
a branch that calls something fallible returns `try` of it, not the error
union itself. The function's own error set is inferred, so nothing is lost;
what is gained is that the payload is a value again, and a value coerces.

## Against ADR 017's four axes

Nothing. The same call, one unwrap earlier.

## Consequences

- `AsText` into a nullable column works from a non-optional value, on every
  statement that writes one. The live test writes an `Interval` into
  `?interval` and reads it back.
- `@as(?Date, due)` at the port's three sites can go.
