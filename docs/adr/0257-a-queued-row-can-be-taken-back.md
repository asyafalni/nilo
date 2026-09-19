# 0257 — a queued row can be taken back

**Status:** accepted
**Extends:** [ADR 0198](./0198-a-queue-is-a-table-in-the-database-you-already-have.md),
whose store contract gains a third optional method beside `pushIn` and
`ready`.
**Applies:** [ADR 0229](./0229-a-push-wakes-a-worker.md).

## Context

The user closed the export dialog, or unsubscribed before the nudge went
out, and the row ran anyway: there was no way to take a queued row back.
The roadmap held it at *waiting on a caller*, and the caller is the ERP
that pushes a reminder a day ahead and then wants to move it when the date
moves.

## Decision

**`jobs.cancel(scope, id) !bool` deletes a row while it is `queued`, and
answers `false` for one that is running, finished or absent.** It is one
statement on the table — `DELETE … WHERE id = ? AND state = 'queued'` — and
one slot flip under the lock in memory, so a worker claiming the row in the
same instant either got it or did not; there is no state in which both
happened.

```zig
if (!try jobs.cancel(c, row)) return nilo.fail.conflict("already going out", .{});
_ = try jobs.push(c, SendWelcome{ … }, .{ .after_ms = day });
```

**A running row is not interrupted.** Nothing here reaches into a `run`,
and a cancel that answered `true` while the row was half done would be the
worse outcome — a mail half sent, an export half written — with nobody told.
`false` is the honest answer, and the caller who wants "stop it" writes the
check into the job's own `run`, which is where the meaning of stopping is
known.

**The `unique` key goes with the row**, because the row is deleted rather
than marked, so a cancel and a push under the same key is how "move it to
tomorrow" is written. Marking the row `cancelled` was the alternative, and
it would have needed a fifth state, a sweep to reap it, and a rule about
whether a cancelled row still holds its key.

**It is optional on the store**, the way `pushIn` and `ready` are: a
`Jobs` over a store with no `cancel` refuses the call while compiling,
naming the store, rather than faking a `false`. `job.Memory` and
`job.Table` both carry it. The `status` Space, when there is one, forgets
the row on a cancel that succeeded, so a route polling `status(id)` hears
nothing rather than `queued` until the entry expires.

## What it costs

Against ADR 0018's axes: nothing on a request that does not cancel. A
cancel is one `DELETE` on the table or one walk of the slots in memory,
paid by the route that asked. No new column, no new state, no per-row
memory.

## Alternatives

**A `cancelled` state.** Rejected above: a fifth state to explain, a sweep
to reap it, and the `unique` key held by a row nobody wants.

**Cancelling a running row** by marking it and having the worker check
between steps. The worker has no steps to check between — a `run` is one
function — and a flag the job's own `run` reads is a flag the job can
read from anywhere; nilo has nothing to add there.

**A required method on the contract.** A third store written against the
contract's table — somebody's Redis — might genuinely have no way to delete
a queued entry atomically against a claim, and a `cancel` that lied would
be worse than one that refused.

## Consequences

- `Memory.cancel`, `Table.cancel`, `Jobs.cancel`; `job/contract.zig` lists
  the third optional method.
- Tests on `job.Memory`, on a `Jobs` over it, and on SQLite in
  `job/live.zig`.
- The roadmap loses "A queued row cannot be cancelled".
