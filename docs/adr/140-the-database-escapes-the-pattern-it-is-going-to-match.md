# The database escapes the pattern it is going to match

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

`.email = .{ .like = text }` binds the caller's text unchanged. Nothing is
smuggled — it is a bound parameter — and it is still the wrong answer: a user
typing `%` matches far more than they should, and one typing `_` matches a
character they should not. No error, no log line, and it only shows up on the
input nobody tried.

Every caller ends up writing the same escape, and most of them do not.

## Why it stayed open for a cycle

The roadmap named the fix — `contains`, `starts_with` and `ends_with`, which
build the pattern *and* escape it — and then named the blocker:

> that means an allocation per condition in a module whose whole claim is that
> a statement costs none

That is true of building the pattern **on this side**. It is not true of the
feature, and the difference is where the work happens.

```sql
"name" ILIKE '%' || replace(replace(replace($1, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\'
```

The pattern is assembled and escaped **inside the statement**. What binds is the
caller's own text, unchanged, so this costs exactly what an `=` on the same
column costs: nothing. `replace`, `||` and `ESCAPE` are all standard, so both
Dialects write the same shape.

**The blocker was a sentence about one mechanism**, which is precisely the
failure mode [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) already
recorded: *a requirement written as one mechanism reads as a blocker; written as
what it has to catch, it reads as a choice.* Written as *the `%` in the
caller's text has to match itself*, the answer is three `replace` calls and no
allocation at all.

## The order of the three is load-bearing

The escape character is doubled **first**. Doubling `\` after putting one in
front of `%` would turn that escape into a literal backslash and let the `%`
through — which is the original bug, arrived at through the fix. There is a
test that asserts the order of the two substrings in the generated SQL, and a
live test that searches for `a\b` and gets one row.

## Twelve names out of three rows

Three shapes, `i` in front to fold case, `not_` in front to negate. The
spelling is the one `like`/`ilike`/`not_like` already set.

The negations are not padding. [ADR 052](./052-a-set-operation-over-one-table-is-a-condition.md)'s
argument that `EXCEPT` needs no mechanism rests on **every leaf having a
negation**, and an operator family arriving without its own would quietly break
a decision that is on the record. There is a test that walks all twelve names.

Both halves of a pattern comparison are checked: the column has to hold text,
because Postgres would otherwise cast a number to text and compare the digits it
happens to print; and the value has to be text, because there is nothing else to
build a pattern out of.

## SQLite refuses the case-sensitive half

Its `LIKE` folds ASCII case, and cannot be told not to by a statement —
`PRAGMA case_sensitive_like` is a property of the connection. So honouring
`contains` there would make the answer depend on how the database was opened
rather than on what the query says.

`icontains` is that database's plain `LIKE`, and `contains` is a Refusal naming
the dialect. The message names the operator that works, because the fix is one
letter. That is the seam refusing rather than lying, which is the standard
[ADR 055](./055-the-second-dialect-is-the-test-of-the-seam.md) set for
`insertMany` and `.lock`.

## What this found in the older operators

`.ilike` used to write the word `ILIKE` on both Dialects, because the operator table in `where.zig` predates the second one and spells its own SQL, and SQLite has no `ILIKE`: a runtime syntax error from a statement that compiled. The new family went through `dialect.pattern` so it did not inherit that, and the old one was fixed on its own afterwards. On a Dialect whose `LIKE` already folds case (`like_folds`, SQLite), `.ilike` is spelled `LIKE` and `.not_ilike` `NOT LIKE`, and `.like` and `.not_like` are a Refusal naming `ilike`, because a case-sensitive match that folds would match more than it was asked to on one database only ([ADR 055](./055-the-second-dialect-is-the-test-of-the-seam.md)).

## A prefix on SQLite is bound whole

**`istarts_with` on SQLite binds the finished pattern**, `"email" LIKE ?1 ESCAPE '\'`, with the caller's text escaped and ended with `%` on this side, into the Scope's arena (`db.prefixPattern`). SQLite reads an index range off `LIKE` only when the right-hand side is a literal or a parameter holding the pattern, and off `replace(…) || '%'` never. So an `istarts_with` over a column with a unique that ignores case (a `NOCASE` index) read every row: 16.5 ms against 0.012 ms a query on 200,000 rows, `SCAN` against `SEARCH … USING COVERING INDEX` ([sql.md §21](../../bench/result/sql.md#21-where-a-prefix-pattern-is-built)).

The Dialect says which way it goes (`prefix_bound`), and only a prefix that is not negated takes it: a `NOT LIKE`, a `contains` and an `ends_with` read every row whatever the parameter holds, so they keep the form that allocates nothing. A plain `.index` is a `BINARY` one on SQLite, which a folding `LIKE` cannot use either way; only a unique can ignore case today.

**Postgres keeps the escaping in the statement and folds case on the column's own expression.** A folding, non-negated prefix is `lower("email") LIKE lower(replace(…)) || '%' ESCAPE '\'`, and the unique that ignores case is built over `lower("email") text_pattern_ops` (`Dialect.foldedIndexColumn`). It was `"email" ILIKE replace(…) || '%'`, and that read no index: not the unique, which is over `lower("email")`, and not a `text_pattern_ops` index on the bare column either, since `ILIKE` over the column is `~~*` and no operator class has one. On 200,000 rows it was a `Seq Scan` at 266 ms; the lowered form over the new index is an `Index Scan` on `lower(email) ~>=~ 'abc1' AND lower(email) ~<~ 'abc2'` at 0.065 ms ([sql.md §23](../../bench/result/sql.md#23-istarts_with-on-postgres-and-the-expression-it-reads)). `text_pattern_ops` is there because a plain `lower()` index is ordered by the collation and no `LIKE` reads a range off it, whatever the collation is: the plain one was a `Seq Scan` on this database's `C.UTF-8`. Uniqueness and `.ieq` are unchanged, since that class has `=`.

On a plan made for the value the database folds `replace(…)` and `lower(…)` into a constant, so binding the pattern whole would still buy nothing; on a plan made for any value (`plan_cache_mode = force_generic_plan`) neither form can use the index, since the prefix is not known when the plan is made. A statement with a `sql.given` is sent unnamed ([ADR 149](149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)), which is what keeps that plan from being chosen for it. **A unique made before this keeps its old index**: the migrator compares `ignoring_case`, not the operator class, so the prefix reads correctly and scans until the index is dropped and made again. The negated prefix, `icontains` and `iends_with` read every row either way and keep `ILIKE`.

## Against ADR 017's four axes

- **Allocations per request: zero**, which is the entire point of the design
  and the reason it is not the design the roadmap assumed, **except one per
  `istarts_with` on SQLite**: an arena allocation of the prefix's length plus
  one, plus one a `\`, `%` or `_` in it, on a request that asked for the
  prefix. It was not timed on its own; it is a bump of a few bytes beside a
  statement that went from 16.5 ms to 12 µs.
- **Memory per idle connection: zero.**
- **Throughput and p99:** three `replace` calls per matching row, run by the
  database on a parameter rather than on a column. Unmeasured, and it is the
  database's cost rather than nilo's. A leading `%` already rules out the index
  on `contains`. A prefix uses its index on Postgres, over the lowered expression, and on
  SQLite bound whole (above).
- **Binary size: zero for a program that writes none of the twelve.**

## Consequences

- A `Dialect` owes one more declaration, `pattern`, which returns `null` for a
  combination it cannot spell.
- The roadmap entry moves from *Waiting on: a design* to gone, and its lesson —
  that the allocation was an assumption about one implementation — goes to
  `docs/history.md`.

## What was rejected

- **The prefix built inside the statement on SQLite too**, which was the rule until the plan was read: it made `istarts_with` a `SCAN` over a table with a `NOCASE` index on the column ([sql.md §18](../../bench/result/sql.md#18-the-count-a-page-reads-keyset-paging-and-a-stream-let-go-early), [§21](../../bench/result/sql.md#21-where-a-prefix-pattern-is-built)).
- **`ILIKE` over the bare column on Postgres**, the rule until the plan was read: a `Seq Scan` next to a unique built for it. §21 took the plan for a range; §23 has the one nilo's own unique gets.
- **Every pattern bound whole on both databases.** One allocation a condition for eleven operators out of twelve that no planner reads a range off, and for a Postgres plan that is the same either way.
- **A range beside the `LIKE`**, `"email" >= $1 AND "email" < $2`, which a plan for any value can use. It is right only under a collation that orders by bytes. Under Danish, `aa` sorts after `z`, so `>= 'a' AND < 'b'` leaves out `aase`, which `LIKE 'a%'` matches.
