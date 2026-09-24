# A column type can come from outside this module, and it travels as text

**Status:** accepted
**Topic:** [sql-types](../design/sql-types.md)

## Context

`nilo_sql` could not read a `numeric` column at all: `dialect.accepts` had no entry for one, so a Row carrying money either did not compile or read the column as `f64`, the mistake the column type exists to prevent, made by the code that was supposed to prevent it. The roadmap called this the one that mattered, because money in an `f64` is wrong and a service that bills anybody needs it before anything else on the list.

The fix that shipped first, `sql.Decimal`, closed that one column and left the underlying problem in place: the schema half of a column type was open (a struct or enum carrying `pub const nilo_column = "money"` was judged at startup like any other column) and the wire half was shut, a fixed list of `Str`, `Timestamp`, `Uuid`, `Decimal`, `Json(T)` and the scalars. A project could describe a column it could not read, and everything past the list, `interval`, `inet`, `cidr`, `macaddr`, `money`, `tsvector`, `xml`, every PostGIS type, every extension anybody installs, was another branch this module would have had to grow in six places.

## Decision

**A column type is a protocol, not a list, and the representation is text.** Any struct or enum carrying three things is a column type, whoever wrote it:

```zig
pub const nilo_column = "money";
pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Self
pub fn nilo_write(self: Self, arena: std.mem.Allocator) ![]const u8
```

The Dialect asks for it as `"col"::text` and binds it as `$1::money`; the type turns those bytes into a value and back. That is one branch each in `readAs`, `bindAs`, `arrayOf`, `WireRead`, `WireWrite`, `kept` and `forWire`, the same seven places a single hand-written special case for `numeric` used to occupy, which is the measure of what the general protocol cost: nothing, because the special case was already there and was renamed into a rule.

`AsText(name)` is the protocol's smallest instance, for a type that is just the text:

```zig
const Money = sql.AsText("money");
const Interval = sql.AsText("interval");   // shipped, as `sql.Interval`
const Inet = sql.AsText("inet");           // shipped, as `sql.Inet`
```

### Text rather than a binary format

Text is the one representation Postgres guarantees for every type it has, including the ones it does not ship. A binary protocol would be faster and would need this module to know the format, exactly the knowledge the closed list existed to avoid needing. The cost is honest and stated: a text column is a parse on the way in and a print on the way out, where a type the driver decodes natively is neither. For a type nobody has heard of, the alternative to text is not a faster path, it is no path.

### `Decimal` is the instance that argues for the protocol

`sql.Decimal` holds text: `total.text` is the digits exactly as Postgres printed them, with no `.add`, no `.mul` and no `.round`. **It does not calculate**, the line `sql/types.zig` already holds for `Timestamp` and holds here for the same reason: arbitrary-precision decimal arithmetic is a library, and a larger one than it looks, since rounding modes alone are a standard with named variants that disagree about money. What a database module owes is that the digits which went in are the digits that come out; whoever wants to add two of them can build on this.

**It writes itself into JSON as a string**, `{ "total": "1234.56" }`, rather than a bare JSON number. A bare number is exact on the wire, since JSON numbers have no width limit, and stops being exact one line later in the consumer: `JSON.parse` answers a `double`, so a client would silently receive the `f64` the column type was chosen to avoid, a failure that is silent and happens on the far side of the network, the worst place to put it. A string arrives intact and makes the reader decide what to do with it, and it is the only representation that can carry what Postgres allows and JSON has no syntax for: `nan`, `inf`, `-inf`. `Timestamp` writes as an RFC 3339 string for the same shape of reason: a value with a canonical text form and no native JSON type.

`Decimal` is now `AsText("numeric")`, the same struct body, the same `.text` field, the same JSON-as-a-string, with the marker that used to exist purely so the Dialect knew this column casts (`nilo_decimal`) gone, folded into the general protocol. **The hardest column type this module ships turned out to be expressible in the protocol without a special case**, which is the test a general mechanism has to pass; a protocol whose own author still needed an exception would have been a list with extra steps. A Refusal that prints a column type used to say `Decimal` and now says `types.AsText("numeric")`, which says both what it is and which column.

It stays streamable, which the shape it replaced would not have: a `Decimal` in a Borrowed row is a `[]const u8`, so the digits point into the read buffer and `db.stream` allocates nothing per row, where `Json(T)` had to be refused outright.

### Why `nilo_write` takes an allocator when nothing shipped uses one

Every text column this module ships holds its text, so `nilo_write` hands back a field and never allocates. The allocator is there for the case that makes the protocol worth having: a type holding *structure*, such as a `Cents{ value: i64 }` that renders `{d}.{d:0>2}` at write time. Without it, a project's column type could only ever be a rename of `Str`, not worth a protocol. With it, the function that gathers a row's values grew a Scope parameter and became fallible, and for a Row with no text column the inferred error set is empty and the `try` compiles to nothing, which is what makes this free for everyone not using it.

### Half a protocol is a Refusal

Two mistakes are caught while compiling rather than at the first request: `nilo_read` without `nilo_write` or the reverse, since the pair is how a value gets there and back and half of it is a column that can be written and never read; and both without `nilo_column`, since the name is what the casts on the two sides have to spell. Both are `sql/refusals/` files with rows in `build.zig`, the way every comptime check in this repository is held ([ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md)).

## What was rejected

**Reading `Decimal` through pg.zig's `Numeric`.** Fails on the write half: `Numeric.encode` takes a **float**, calling `math.isNan` and printing with `{d}`, so every value inserted would make the round trip through binary floating point the column exists to avoid. The string encoder beside it is private and takes pg.zig's own buffer type.

**Decoding the binary form in this module.** Sign, weight, scale and base-10000 limbs is a wire format, and putting one in `db.zig` would move knowledge across the seam `dialect`/`wire` exists to hold: a Dialect writes SQL, a Wire speaks a protocol, and neither is supposed to leak into the layer that fills a struct. Casting in SQL is the same conversion asked for on the side that already knows how to do it.

**`{ units: i128, scale: u8 }` for `Decimal`.** A real representation and a better one to compute with, buying nothing here because nothing here computes, and it cannot hold `nan` or `inf`, which Postgres will hand over, so it would still need a tag and would still be converting on the way in and out.

**Leaving the money column as `f64`.** The whole case against it is that it is quietly wrong: a cent per invoice is invisible in a test and a headline in an audit.

**A separate `format: decimal` in the API description with a bare number in the body.** Two things to keep in step, and the document would be promising something the body contradicts.

## What was corrected by measurement

**The read cast (`::text`) is not load-bearing for a live Postgres, and it is kept anyway.** With it removed, a live round trip still returns all twenty-nine significant digits, because pg.zig hands the column over as text already whatever its result-format logic intends. The cast was written on the assumption it would arrive binary, not checked until afterwards. It stays because what it removes is a dependency rather than a bug: without it, the correctness of every money column would rest on a driver's choice of result format, which this module does not make, did not design, and would discover was different by getting limbs where it expected digits. The write cast is load-bearing and was verified the same way.

## What is still closed

**An array of a text column.** `[]const Decimal` is not judged by `dialect.accepts` and is not read, the same boundary as before. Writing one is supported, since `arrayOf` casts through `text[]`, the same mechanism a batch insert of a `numeric` column already used; reading would mean a second allocation per row per column for a shape nobody has asked for.

**A type whose text is not what Postgres prints.** `nilo_read` is handed the output of `::text` and nothing else; a type wanting the binary form has to be built into the driver, the closed list this replaces and where the next such type should stop and argue rather than being added quietly.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | zero for a Row with no text column, since the error set is empty and the branch is comptime; one per value for a column type that builds its text, the caller's own `allocPrint`, visible in their own code. A `Decimal` copied out of the read buffer costs the same `arena().dupe` a text column has always cost, no class of allocation the row was not already paying for, and unlike `Json(T)`, none per row that a scalar would not have. |
| Memory per idle connection | none. |
| Throughput and p99 | unchanged for everything already here, one predicate for another; for a Row with no `Decimal` or text column, `readAs`/`bindAs` are comptime and return their argument unchanged. |
| Binary size | +0 stripped ReleaseFast on every example, since no example imports `nilo_sql`. |

## Consequences

- `interval` and `inet` came off the checklist as two lines of `AsText` each rather than a column type each.
- `types.isDecimal` is gone, replaced by `types.asText`, which answers *which* column rather than *whether* it is one particular column.
- A project can read a PostGIS `geometry` without this module knowing PostGIS exists.
- `numeric` comparisons are numeric: `"100.00" > "9.99"` is false as text and true as a number, and the `::numeric` on the placeholder is what settles it.
- The Dialect's `readAs`/`bindAs` are the first place the seam had to express something Postgres and another database would spell differently (SQLite would write `CAST($1 AS NUMERIC)`), evidence the seam is in the right place.
- The next column type this module is tempted to ship should be weighed against a project writing three lines; a fourth wants an argument.
