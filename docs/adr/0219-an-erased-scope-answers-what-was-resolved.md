# An erased Scope answers what was resolved

[ADR 0177](0177-a-scope-that-crosses-a-function-pointer.md) carried `arena`,
`str`, `entropyInto` and later `requestId` across a function pointer, and
said `resolve` was deliberately absent: generic over the type asked for, so
it cannot cross, and no `resolveInto` would mean anything. That was true of
the mechanism and wrong about the need, and it was found by exactly the
case [ADR 0165](0165-a-value-that-reaches-the-bottom.md) was written for.

Every event the port writes carries who is acting. The value is declared
with `nilo_resolve`, worked out once, and asked for by the bus on whatever
Scope it is handed — sixty commands pass nothing. The one seam that erases
— a context opening work on another's board through
`*const fn (tx, bus, c: *nilo.AnyScope, in) !Uuid`, to avoid the import —
would have written the event as a person's. Silently: nothing in a test
admits it. The workaround is a field on the seam's input, filled by whoever
still held the `*Ctx`, and it is the sixty-call-sites shape in miniature:
the next erased seam has to remember the same thing.

## The table carries a lookup by name

`AnyScope.of` knows the concrete Scope, so the table carries one more
entry, `resolved: fn (*anyopaque, type_name) ?*const anyopaque`, and the
typed `resolve(comptime V)` is written on top of it on `AnyScope`'s side —
the move `entropy` makes over `entropyInto`, and the move `Run.resolve`
already made over its own list of given values. A `Run` answers from what
it was given; a `Ctx` from what the request already resolved
(`resolvedNamed`, which `cachedResolved` now reads through); a hand-made
Scope with neither answers nothing.

**What it answers is what the Scope behind it holds, and never more.** An
erased Scope cannot run a resolver: a resolver may take services, and a
function pointer has no type to look them up by. So a `nilo_resolve` type
nobody asked for before the erasure is `error.NotGiven` — the same answer a
`Run` nobody told gives, for the same reason. In practice the value a
reaction wants is the one a middleware or the handler's own argument list
resolved on the way in, which is before anybody erased anything; and a
value nobody set has to be louder than a value nobody read.

## What was not done

**Running the resolver through the erasure.** It would need the table to
carry, per resolvable type, a function that finds that type's services on
a `*Ctx` — a table entry per type the program declares, built where the
erasure is made, for a call the erased side almost never makes. The
`NotGiven` is the honest answer and it is loud.

**A `resolveInto(type_name, buf)`.** The value's size is a property of the
type, which the erased side names; a copy into a buffer would be a second
copy of something the arena already holds, and the pointer is enough.

## Against ADR 0018's four axes

Nothing. One more function pointer in a comptime table per Scope type; a
call that was not being made. The ordinary Scope is unchanged.

## Consequences

- `AnyScope.resolve(V)`, and `resolvedNamed` on `Run` and `Ctx`.
- The seam carries nothing, and `attributionOf` is one line on every side.
