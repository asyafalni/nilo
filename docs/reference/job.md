# nilo_job

One page of [the reference](./README.md): work that runs later, again, or on a schedule.

## `nilo_job`

Work that runs later, again, or on a schedule: a queue whose rows live in a
table in the database the program already has, and a worker loop the server
owns. A **Fitting**, like `nilo_fetch`: it borrows the loop and is handed
its store ([ADR 0198](../adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
**At least once**: `run` is written to be safe to call twice.

```zig
const job = @import("nilo_job");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } };

    user_id: i64,
    email: Str,

    pub fn run(self: SendWelcome, scope: *nilo.Run, db: *Db) !void { … }
};

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Table(Db), .deps = struct { db: *Db } });

try sql.migrate.createMissing(&db, &run, .{ .tables = &.{ User, Jobs.Row } });
var table = job.Table(Db).open(&db);
var jobs: Jobs = .open(gpa, &table, .{ .db = &db }, .{});
try app.provide(&jobs);
try app.spawn(Jobs.serve, .{&jobs});

fn register(c: *nilo.Ctx, jobs: *Jobs, body: SignIn) !void {
    _ = try jobs.push(c, SendWelcome{ .user_id = 7, .email = body.email }, .{});
}
```

**A job is a struct.** Its fields are the payload, written as JSON at `push`
and parsed back into the tick's own `Run`; a `Str` may sit in one because it
is copied rather than carried. Three declarations are read while compiling:

| | |
|---|---|
| `pub const nilo_job = "…"` | the name the row carries. Required; at most 64 bytes; unique across the `kinds` |
| `pub const retry: job.Retry` | required, no default: `.none`, or `.{ .times, .backoff }` with `.{ .fixed_ms }` or `.{ .exponential = .{ .from_ms, .to_ms } }` |
| `pub fn run(self, scope: *nilo.Run, …) !void` | the work: the job by value, the Run, then any service by pointer, found in `.deps` by type — and `tick: job.Tick` by value, if it wants to know which tick it is ([ADR 0246](../adr/0246-a-tick-knows-which-one-it-is-and-a-test-says-when.md)) |
| `pub const final = error{ … }` | optional: the failures that are **final**. A `run` failing with one is dead on that attempt whatever `retry` says, and the row keeps the error's name; a timeout never is. Refused on a kind whose `retry` is `.none` ([ADR 0218](../adr/0218-a-run-can-say-its-failure-is-final.md)) |
| `pub const timeout_ms` | optional, over the queue's. Also the lease |
| `pub const schedule`, `overlap`, `missed` | for a job that runs on the clock — below |

A field that is a `*T` is a Refusal naming the field; a `run` that asks for a
`*Ctx`, for a `*job.Tick`, or for a pointer type nobody put in `.deps`, is
one naming the job.

**`job.Tick`** — what a `run` that asks for one is handed:

| Field | |
|---|---|
| `id` | the row's, for `jobs.progress` and `jobs.status` |
| `attempts` | counting this one: `1` the first time |
| `run_at` | when the row was due, microseconds since the epoch |
| `last` | whether this is the last attempt `retry` allows. About the count: a failure in `final` is dead on any attempt |

**`job.Jobs(.{ … })`:**

| | |
|---|---|
| `.kinds` | a tuple of job types. A job pushed but not listed is a Refusal |
| `.store` | `job.Table(Db)`, `job.Memory`, or anything carrying the contract in `job/contract.zig` |
| `.deps` | optional: a struct of pointers a `run` may ask for by type — or `fn (comptime Jobs: type) type` answering one, for a `run` that asks for `*Jobs` to push the next job ([ADR 0245](../adr/0245-a-job-can-push-the-next-one.md)). A function of another shape is a Refusal |
| `.status` | optional: a `cache.Space` of `job.Status` kept per row, for a route to poll |

| | |
|---|---|
| `Jobs.open(gpa, &store, deps, settings)` | the queue. `openWith(…, space)` when `.status` names a Space. When `.deps` names `*Jobs`, open it once it has an address: `var jobs: Jobs = undefined; jobs = .open(…, .{ .jobs = &jobs, … }, .{})` |
| `Jobs.Deps` | the struct of pointers `open` takes: `.deps` as written, or what `.deps(Jobs)` answered |
| `Jobs.Row` | the store's table, for `createMissing` and `db.checking`; `void` for `job.Memory` |
| `jobs.push(c, value, opts)` | `!Id`; `!?Id` when `opts` has `.unique`, null when a row already carries the key |
| `jobs.pushIn(&tx, c, value, opts)` | the same inside a transaction you hold. A Refusal on `job.Memory`, and with `.within`. Wakes nobody — the row is not there until the commit — so call `wake` after it |
| `jobs.wake()` | wake every idle worker, for a row nilo did not see arrive: another process's, or one `pushIn` put under a transaction that has since committed. A `push` wakes one worker itself ([ADR 0229](../adr/0229-a-push-wakes-a-worker.md)) |
| `jobs.stats(c)` | `Stats` — `queued`, `running`, `dead` |
| `jobs.status(id)` | `?job.Status` — `state`, `attempts` and `progress`, from the Space, while it remembers |
| `jobs.progress(id, n)` | `n` into the Space's `progress` for the row, from inside a `run` with a `job.Tick` and a `*Jobs`. Reset by every change of state except `done`, which keeps it. Nothing without a Space ([ADR 0246](../adr/0246-a-tick-knows-which-one-it-is-and-a-test-says-when.md)) |
| `jobs.deadOnes(c)` | `[]Dead` — `id`, `kind`, `attempts`, `err`, newest first |
| `jobs.retryDead(c, id)` | `bool` — queued again from attempt one |
| `Jobs.serve(&jobs)` | the worker loop, for `app.spawn`. Stops with the server |
| `jobs.serveOn(io)` | the same on an `Io` of yours, for a worker process. Returns when cancelled |
| `jobs.drain(&run)` / `jobs.runOne(&run)` | run what is due on this thread, for a test, against one reading of the clock. A `*Ctx` is refused |
| `jobs.drainAt(&run, now)` / `jobs.runOneAt(&run, now)` | the same as if it were `now`, microseconds since the epoch: what is due, when a retry is, when the next tick is, all read that number. How a test moves the clock ([ADR 0246](../adr/0246-a-tick-knows-which-one-it-is-and-a-test-says-when.md)) |
| `jobs.seed(&run)` / `jobs.seedAt(&run, now)` | queue every schedule's next tick, the way `serve` does at start — for a test that drains rather than serves |
| `jobs.nilo_ready(scope)` | what `app.health` asks: the store, and whether a worker is alive |

**Push options** — `.{}` is the ordinary call:

| Field | |
|---|---|
| `after_ms` | no sooner than this many milliseconds from now |
| `at` | no sooner than this moment in microseconds since the epoch. Not with `after_ms` |
| `unique` | at most one queued-or-running row of this kind carries the key. A unique index, freed when the row finishes |
| `within` | a `cache.Space` of `job.Mark` in front of `unique`: a second push inside the Space's TTL never reaches the table. Needs `unique` |

**`job.Settings`**, given to `open`:

| Field | Default | |
|---|---|---|
| `workers` | 4 | rows running at once in this process. A fiber each, its stack held at the high-water mark ([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)) |
| `poll_ms` | 1,000 | how long an idle worker waits before asking again **when nothing wakes it first**. A `push` from this process wakes a worker, so this is the latency only of a row another process pushed, and the cost of an idle queue: one claim per worker per interval ([ADR 0229](../adr/0229-a-push-wakes-a-worker.md)) |
| `timeout_ms` | 60,000 | how long one run may take, for a kind naming no `timeout_ms`. Also the lease |

**A schedule** ([ADR 0199](../adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)):

| | |
|---|---|
| `pub const schedule = job.cron("0 3 * * *")` | `minute hour day month weekday`, UTC, parsed while compiling. `*`, lists, ranges, `*/n`; a field out of range is a Refusal naming it |
| `pub const schedule = job.every(600_000)` | every so often from when the worker started |
| `pub const overlap: job.Overlap` | required: `.skip` — a tick inside a run does not happen; `.queue` — it runs on another worker |
| `pub const missed: job.Missed` | required: `.drop` — a tick later than its own successor is forgotten; `.catch_up` — it runs once |

The next tick is a row with the unique key `"schedule"`, so several instances
seed one row and whichever claims it runs it. The first tick is the next one
the clock says; a program that wants one at start-up pushes it. Every field
of a scheduled job has a default, since nobody pushes one.

**The stores:**

| | |
|---|---|
| `job.Table(Db)` | the queue as a `nilo_table` Row named `nilo_jobs`, over your `sql.Db` or `sql.Sqlite(…)`. `open(&db)`. Claims with `FOR UPDATE SKIP LOCKED` on Postgres, and without on SQLite, where a claim is a write and `workers` is the number of them |
| `table.sweep(c, before)` | delete `done` rows finished before a moment. Nothing calls it for you |
| `job.Memory` | the same contract in this process. `open(gpa, .{ .bytes, .max_payload = 4096 })`; a full one is `error.QueueFull`, never a row written over |

**Errors worth naming.** A `run` that fails is retried by its `retry` and
then **dead**: kept in the table with the error's name, counted by `stats`,
listed by `deadOnes`. A `run` past `timeout_ms` is the attempt named
`TimedOut`. `error.Canceled` inside `run` is the shutdown: the row goes back
untouched and whoever starts next takes it. A payload this binary cannot
parse is dead at once. A row whose kind this binary has no job for is put
back, with a warning, for the binary that does.

[`docs/guide/jobs.md`](../guide/jobs.md) is the whole of it, and
[`bench/result/job.md`](../../bench/result/job.md) is what a claim and a push
cost on each store.

**What it is not**: a priority queue, a workflow engine, a rate limiter per
kind (`nilo.Gate` inside `run` is that), exactly-once, or a time zone.
