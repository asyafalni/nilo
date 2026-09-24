# An `.exists` reads the reference from either side

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

[ADR 218](218-a-row-may-carry-its-parent-its-children-or-a-sum.md) read the join out of the
child's `.references`: `partners WHERE EXISTS (partner_capabilities …)`, with
the key on the inner table pointing out at the outer one. The port's next
list screen is the same shape the other way round —
`staff WHERE EXISTS (departments WHERE name ILIKE q)` — and the key is
`staff.department_id`, on the **outer** Row. The schema declares it, on
`Staff`, and `correlation` never looked there. The Refusal it gave — *`Staff`
declares no `.references` to `Department`* — was true and was not the point,
because `Department` never will: a parent does not point at its children.

The port wrote the subquery raw, six filters beside it written twice, which
is the shape [ADR 172](172-one-condition-over-several-columns-is-one-parameter.md)
had just deleted from the row above it.

## Both sides are already declared

`correlation` now reads `foreignKeysOf` on both Rows. A column of the inner
Row that points at the outer table joins `Inner.<column> = Outer.<target>`,
as before; a column of the outer Row that points at the inner table joins
`Inner.<target> = Outer.<column>`. Neither costs the call site a word, and
neither costs a new check: `table.oneReference` has already made the target
a Row, the target column one of its columns, and the two Zig types the same.
The query from `staff` reads

```sql
EXISTS (SELECT 1 FROM "departments"
        WHERE "departments"."id" = "staff"."department_id"
        AND "departments"."name" ILIKE $1 ESCAPE '\')
```

and the `sql.given` rule inside it is unchanged: a guard drops the whole
subquery, whichever side the key is on.

## `.via` is the other end of `.on`

ADR 218's two Refusals stand — nothing declared, and declared twice — and
the second gains a coat. A Row that points at the same parent from two
columns (`home_region` and `work_region`, both at `regions`) is the
`created_by`/`updated_by` case with the key on this side, and two tables
that point at *each other* (`staff.department_id` and
`departments.head_id`) are two joins with the same shape and different
meanings: "my department" and "the department I head".

`.on` already answers the first kind, and it names a column of the **inner**
Row. Reusing it for a column of the outer Row would make `.on = .id` mean
either side depending on which Row happens to have an `id`, which is the
mistake that compiles. So the outer column has its own word:

```zig
.exists = .{
    .{ .in = Region, .via = .home_region, .where = .{ .name = q } },
}
```

`.on` is a column of the Row inside; `.via` is a column of the Row the
statement is over. Each is checked against its own Row by name, a declared
`.references` on that column wins so the far column is exact, and with none
declared the far side is the other Row's single key. Both at once is a
Refusal: a join has one key on one side.

## What was not done

**Guessing by key.** With `Staff.department_id` and `Department.head_id`
both declared, the join a caller *usually* means is the one from the outer
Row — but usually is the word ADR 218 refused, and the two queries answer
differently on every row where the head sits in another department. Named
or refused.

**A third word for the far column.** `.on = .{ .department_id, .id }` would
name both ends in one entry. It reads as a tuple of a column and a column,
and nothing in it says which Row each belongs to, which is the ambiguity
`.via` exists to close. The far column comes from the `.references` or from
the key, and a schema with neither is a schema to fix.

## Against ADR 017's four axes

Nothing. The statement is a constant the way ADR 218's was; `correlation`
reads one more list while compiling. Four Refusals, and the message the
zero-match case already had now names both tables.

## Consequences

- An `.exists` whose join is declared on the outer Row compiles, with no
  word at the call site.
- `.via = .<column>`, a column of the outer Row, beside `.on` for the inner.
- Four Refusals: two columns at the same parent, tables that point at each
  other, `.on` beside `.via`, and a `.via` naming a column the Row lacks.
- `docs/guide/sql/reading.md` shows the query from the child's side.
