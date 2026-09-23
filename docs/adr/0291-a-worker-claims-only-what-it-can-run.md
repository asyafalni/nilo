# 0291 — A worker claims only the kinds it can run

## Status

Accepted.

## Context

`job.Jobs` runs the kinds it was told about. The table it claims from is
shared: another binary — an older deploy, a sibling service, a tool — can push
a row of a kind this program has never heard of. `execute` handled that, and
the comment said what it meant to do:

> A row from a binary that knows a kind this one does not. Not ours to run and
> not ours to lose: back in the queue, where the binary that pushed it will
> find it.

The intent is right. The implementation was `store.release(id)`, which sets
the row back to `queued` with the `run_at` it already had. That row is due. It
is the most urgent due row. So the same worker claims it again on the next
turn of the loop, finds the same unknown kind, and releases it again.

Found in an engine that had dropped a kind between deploys, with one such row
left behind: 88 210 claim/release pairs, a worker never idle, `/health` timing
out because the loop never gave the pool back. The account is in
[`docs/history.md`](../history.md).

What a stuck queue looks like from the outside is worth writing down, because
it is not what it sounds like. The row is not sitting in `running` — `release`
puts it straight back to `queued`, which is the whole reason it is claimed
again. What is there to find is a **queued** row whose `attempts` climbs by
one per turn of the loop, or, once it has climbed far enough, one already
`dead` under a kind this binary never ran.

The retry ceiling makes it worse than a spin. The claim is
`"attempts" = "attempts" + 1`, so every pass counts as an attempt against a
row this binary is not even trying to run. Left alone for long enough, a row
nobody here can execute is declared dead by the binary least able to judge it
— which is exactly the row it was trying not to lose.

## Decision

The claim asks only for the kinds this program knows:

```sql
WHERE "kind" = ANY($3) AND (… due … OR … expired …)
```

`Jobs` already publishes `kind_names`, and the store's `claim` now takes it as
a comptime list. `job.Memory` filters its slots the same way, so both stores
answer the question identically.

A row of another kind is then never claimed: not touched, not leased, not
counted against its own retries. It sits `queued` for the binary that does
know it, which is what the comment promised.

The kinds are **bound**, not spelled into the statement: `kind = ANY($3)` on
Postgres, and on SQLite, which has no `ANY`, a run of placeholders as long as
the comptime list. Either way the statement keeps one shape per program, and a
kind may go on being named whatever it is named.

## Rejected alternative

**Release with a backoff** — hand the row back with `run_at = now + poll` so
the loop cannot spin on it. It is two lines and it stops the fire. It does not
stop the claim counting an attempt, so a foreign row still walks to `dead`,
just slowly; and it still spends a claim per poll per worker on a row it will
never run. Fixing the symptom and leaving the cause.

**Park the row** in a state of its own. It stops both, and it loses the thing
the original comment cared about: the binary that knows the kind would no
longer find it queued.

**Splice the names into the statement** as literals, which is what the first
draft did, holding `nilo_job` to letters, digits, `-`, `_` and `.` to keep that
safe. It is a breaking change for a name this rule did not anticipate —
`email:welcome`, `reports/nightly` — and the only way out of it is to rename
the kind, which strands every row already queued under the old name. That is
the exact loss this ADR exists to prevent, bought for nothing: binding costs a
parameter.

## Consequences

- A worker no longer sees rows it cannot run, so the `execute` fallback is a
  safety net rather than a path. It stays, and still releases.
- A program whose `kinds` shrank leaves the dropped kind's rows in the queue
  rather than churning them. They are quiet — nothing logs them, because no
  worker claims them any more. `stats` counts them among `queued`; a queue
  that wants them noticed wants a sweeper, and that is not this decision.
- `claim` takes a comptime list, so a store written outside nilo needs the
  same parameter. The two in the tree are updated.
