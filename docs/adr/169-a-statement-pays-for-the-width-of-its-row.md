# A statement pays for the width of its Row

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

`rab_lines` is twenty columns and a save writes seventeen of them. Neither
typed write compiled against it:

```
sql/dialect.zig:179:13: error: evaluation exceeded 3000 backwards branches
            for (ident) |ch| {
    called at comptime here: statement.zig:778  names = names ++ D.quote(f.name);
    called at comptime here: db.zig:1669        comptime statement.insertMany(D, Row, V);
```

Nine columns compiled — the price grid batched fine — so the ceiling was
somewhere between nine and seventeen columns of a twenty-column Row, and it
was the default quota rather than anything about the table. The port could not
raise it: the `comptime` block is inside nilo's function, and a quota set at
the call site does not reach it. So the save was one raw `INSERT` per line
inside the transaction, a round trip per row on a document that saves on a
timer, where one `unnest` was the point of porting the context.

## Whose budget it is

[ADR 126](126-a-check-pays-for-its-own-branches.md) settled this for the
framework: a comptime walk nilo does is spent from the caller's evaluation,
the caller cannot see what it is for, and only nilo knows how much it is about
to spend — so nilo raises it, sized to the input, generous rather than exact.
`ddl.zig`, `migrate.zig`, `ordering.zig`, `rawcheck.zig` and `row.zig` each
open that way. The statement builders did not, and every loop in them is one a
wide Row multiplies: `hasColumn` and `ColumnType` scan the Row's fields once
per value written, `quote` walks each name a byte at a time, `columnList`
spells the whole Row for the `RETURNING`, and the placeholder goes through
`std.fmt`.

```zig
fn budget(comptime Row: type, comptime Written: type) void {
    @setEvalBranchQuota(20_000 + 4_000 * (rows + written));
}
```

Called first in every builder — `insert`, `insertMany`, `updateMany`, the
two upserts through `insert`, and the `select`, `update` and `delete` family
through `rowsOf`, `updating` and `deleting` — with `Written` the struct of
values or of options, whichever the builder walks against the Row. The
figure is `ddl.zig`'s, which has held on the same Rows since it was written.

## What was not done

**One constant at the top of `db.zig`.** It fixes the same tables and puts
the number where nobody can see what it is for; the next loop somebody adds
to a builder would silently eat it. ADR 126 rejected the same shape.

**Counting the branches exactly.** The budget is the caller's whole
evaluation and the consumption accumulates across everything it does, so an
exact figure for one builder is short by whatever the caller did before
calling it. Generous is the property.

## Against ADR 017's four axes

Nothing. A branch quota is a compile-time ceiling.

## Consequences

- `statement.budget`, called at the top of every builder.
- A comptime test over a twenty-column Row with seventeen written — `insert`,
  `insertMany`, `updateMany`, both upserts — and a live one against Postgres
  writing forty such rows in one statement, which is the shape the port
  saves. Both were missing, and the port is what found it.
- The port's per-line `INSERT` goes, and the save is one statement.
