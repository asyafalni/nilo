# nilo_job

What a claim costs on each store, which is the number the module's `poll_ms`
default rests on, and what a push costs a handler.

Machine: Intel Xeon Platinum 8255C @ 2.50GHz, **2 vCPUs**, 7 GiB, Ubuntu,
kernel 6.8.0. Zig 0.16.0, ReleaseFast. Commit `8714f7f` plus the module.
Postgres 17 (timescaledb-ha) in Docker, reached across a **published port** —
the same transport `bench/result/sql.md` warns halves a Postgres figure
against a unix socket. SQLite in memory, `.in_fiber`.

`zig build bench-job` is the program; `DATABASE_URL=… zig build bench-job`
adds the Postgres row.

## The numbers

Three runs, one connection, single-threaded, 1,000 rounds each. Per call.

| store | empty claim | claim that takes a row | push |
|---|---|---|---|
| `job.Memory` | 3 µs | 4 µs | 6 µs |
| `job.Table` on SQLite | 52–57 µs | 140–141 µs | 10–11 µs |
| `job.Table` on Postgres | 354–363 µs | 1,171–1,216 µs | 885–899 µs |

**Empty** is the table with no due row — what an idle worker asks every
`poll_ms`. **Taking** is the same statement finding one of a thousand due
rows and moving it to `running`. **Push** is one `INSERT` (with the unique
index in place), what a handler pays.

## What they decided

**`poll_ms = 1_000` stays.** An idle worker costs 354 µs of Postgres a second
on this box — 0.035% of one connection — or 55 µs of SQLite. Four workers are
four of those. That is cheap enough that the default is chosen for latency
rather than for load: a job pushed while every worker is asleep starts within
a second, and a program that wants faster sets it lower with a number to
weigh against.

**A claim is one statement, and it stays one.** The `UPDATE … WHERE id =
(SELECT … FOR UPDATE SKIP LOCKED) RETURNING` shape costs a round trip per
row; the alternative — claim a batch of ten and run them in turn — would cut
the per-row cost by most of the Postgres figure, at the price of ten rows held
by one worker that may die. That is a Next entry in `docs/todo.md` rather
than the default, because the number that decides it is a busy queue's
throughput under several workers, which one connection cannot measure.

**`job.Memory` scans.** 3–6 µs is a linear pass over roughly 3,800 fixed slots
under a spin lock, which is fine for the test and small-program store it is;
a heap would make it 200 ns and would be an allocation-free heap somebody has
to write. Not until a program has a memory queue big enough to notice.

## What is not here, and the ranked levers

## What the claim's index has to be, 2026-09-23

ADR 214 added `ORDER BY priority, run_at` and widened the table's index to
`(state, priority, run_at)` on the reasoning that an index matching the sort
serves it. Measured, on Postgres 16 in Docker, a `nilo_jobs`-shaped table:

| queued rows | index | buffers | time |
|---|---|---|---|
| 200 000 future-dated, 1 due | `(state, priority, run_at)` | 988 | 7.9 ms |
| 200 000 future-dated, 1 due | `(state, run_at)` | 7 | **0.065 ms** |
| the same plus 50 000 due | `(state, priority, run_at)` | 2 132 | 20.2 ms |
| the same plus 50 000 due | `(state, run_at)` | 615 | **12.4 ms** |

With `priority` in front of `run_at`, `run_at <= $1` stops being a range bound
and becomes a filter inside each priority, so the scan walks every future-dated
queued row — the scheduled next ticks, the `after_ms` pushes, the backoff
retries — before it reaches a due one. A queue holding work for later is the
normal case, not the pathological one.

The wide index does not even pay in the regime it was meant for: with a real
backlog it is still slower, because the narrow index finds the due set first
and a top-N heapsort orders it, which is cheap for `LIMIT 1`.

The index stayed `(state, run_at)`. The lesson is the ordinary one about
composite indexes — an equality column may precede a range column, a second
sort column may not — and it was not caught by reading, because the claim was
only ever run against tables whose rows were all due.

1. **Several workers against one Postgres.** Everything above is one
   connection. The claim under contention — eight workers, SKIP LOCKED doing
   its job — is the number that would decide batching, and it wants a box with
   cores (`bench/result/cache.md` is the account of what two cores cannot
   ask).
2. **A unix socket.** `sql.md` measured 133% between a Docker port and a
   socket for the same statement; the Postgres row here is the slow transport.
3. **The push through a handler**, with the JSON of the payload and the arena
   in the way, against `/health` beside it as a control — `bench/sql_server.zig`
   is the shape. Nothing above touches the request path, so the 1-allocation
   test in `http/app.zig` is what holds that number for now.

## A schedule in a time zone

What `.in("Europe/Berlin")` adds to a program and to a tick ([ADR 161](../../docs/adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

**Machine and tree.** AMD Ryzen 7 9700X, 16 threads, Linux 7.2.5, Zig 0.17.0, `-OReleaseFast -fstrip -target x86_64-linux-gnu`. The before is `git archive 2622234` extracted to a scratch directory and built the same afternoon; the after is that commit plus the change, uncommitted. Release data is tzdata 2026e, compiled `zic -b slim -r @1767225600` (zic 2026c).

**Binary size.** One program, `const r = schedule.nextWith(t, .{})` printed, with only the schedule changed.

| program | bytes |
|---|---|
| UTC schedule, before | 227,064 |
| UTC schedule, after | 227,080 (+16) |
| `.in("Europe/Berlin")` | 233,320 (+6,256 over before) |
| `.in("Asia/Jakarta")` | 233,320 |
| Berlin, Santiago and Jakarta in one program | 234,136 (+816 over one zone) |
| `bench/release` `job` program, before and after | 316,608 and 316,608 |

`strings` over the Berlin program finds `Europe/Berlin` and no other zone name, so a zone nobody names is not in the binary. The first zone pays for the walk; each later one pays its file (about 150 bytes) and the calls that read it.

**A tick.** 200,000 calls of `next` for `0 2 * * *`, the moment moved by a few seconds each call so the loop is not folded away: 907 ns in UTC and 2,569 ns in Berlin, a single run on an idle machine. A schedule is asked once a tick and once a minute at most per queue, so this is not a budget that anything spends.

**Correctness against a second source.** Every segment of every one of the 344 zones from 2026-01-02 for five years (1,408 segments) was compared with Python's `zoneinfo` at three-hour steps, 5,033,408 moments. 9,178 differed, all in `America/Winnipeg` and `America/Inuvik`, whose rules changed in tzdata 2026e and 2026d (the host's tzdata is older). Nothing else.

**Decision it moved.** A zone costs 6 KB once and 150 bytes after, so zones are compiled in for the names a program gives and not behind a build flag; and the data is a swappable module because the reason it goes stale is a government and not a bug.

**Not measured.** Instructions a tick under cachegrind (no valgrind on this machine): `bench/release/job_zoned.zig` is the program `bench/release.py` will count it with, and its row reads n/a for any tag before this change.


## The claim over a backlog: probing each priority, 2026-10-12

Whether a bulk enqueue slows every claim, and whether the index ADR 214 turned down is the wrong one for one ordering and the right one for another. The `docs/todo.md` entry asked for both shapes at a backlog of 1, 50,000 and 200,000 due rows beside 300,000 done ones.

**Machine and tree.** Intel Xeon Platinum 8255C @ 2.50GHz, **2 vCPUs**, Ubuntu, kernel 6.8.0-110. Postgres 17.10 (Ubuntu pgdg build, `shared_buffers` 1985MB) in the Docker container `nodeflux-os-db-1`, a scratch database made for the run and dropped after. Commit `1676b58`; the tree had uncommitted changes outside `job/` (`jwt/`, `sql/`, `http/`, docs) and nothing under `job/` was touched. No `zig` process was running. **pgbench ran inside the container over TCP loopback** (`-h 127.0.0.1 -M prepared`), so a statement costs no Docker-port round trip. That flatters every shape that takes more than one statement; the published port costs about 350 µs a trip (the empty-claim row at the top of this file).

**What was built.** `nilo_jobs` as `job/table.zig`'s `Row` declares it: `id bigserial` key, `kind`, `payload` (100 bytes), `state` as text, `run_at`, `lease_until`, `attempts`, `priority smallint`, `unique_key`, `last_error`, `created_at`, `finished_at`, unique on `(kind, unique_key)`. Two copies of the same rows: `jobs_a` with today's index `(state, run_at)`, `jobs_b` with `(state, priority, run_at)`. 300,000 `done` rows, then N `queued` rows due in the last hour, all shuffled together on disk, `VACUUM ANALYZE` after the load and between runs. Three kinds, and the claim names all three. Two spreads of priority: **mix** (80% normal, 10% high, 10% low) and **normal** (every due row normal, which is a queue whose kinds never say a priority, the common one). Each claim is `BEGIN; <claim>; ROLLBACK`, so the backlog does not shrink, `pgbench -n -M prepared -T 8`, 1 client and 4 clients (on 2 cores), three runs of each in a fixed rotation (A, A0, B, B0, BL for one run, then the next) with a `VACUUM` before each. 0 failed transactions in 240 runs.

**The shapes.**

- **A** today's statement, verbatim (`ORDER BY priority, run_at LIMIT 1 FOR UPDATE SKIP LOCKED`, the `kind = ANY`, and the lease arm `OR (state = 'running' AND lease_until <= $1)`), on `(state, run_at)`.
- **A0** the same without the lease arm (`state = 'queued' AND run_at <= $1` only), which is the statement ADR 214 measured.
- **B** one probe per priority on `(state, priority, run_at)`, `WHERE priority = $p … ORDER BY run_at LIMIT 1 FOR UPDATE SKIP LOCKED`, three statements stopping at the first hit, with A's whole `WHERE` including the lease arm.
- **B0** the same probes without the lease arm.
- **BL** one statement: `VALUES (0), (1), (2)` cross joined to a `LATERAL` subquery that is the B0 probe. The join stops at the first row (`LIMIT 1`), `VALUES` is the outer side so it is probed in priority order, and `SKIP LOCKED` is legal because the lock sits inside the subquery and not in a `UNION`. This is the form that is not three statements or a CTE a priority.
- **BL2** BL with the lease arm kept as its own probe per priority (six `VALUES` rows, `(0,'queued'), (0,'running'), (1,'queued') …`), 8 non-expired `running` rows in the table.

**Claim latency, ms, one client, three runs (min to max).** Beside 300,000 done rows.

| due rows | spread | A (today) | A0 | B | B0 | BL |
|---|---|---|---|---|---|---|
| 1 | mix | 0.78 to 0.81 | 0.24 to 0.25 | 0.85 to 0.89 | 0.33 to 0.35 | 0.25 |
| 50,000 | mix | 90 to 97 | 98 to 109 | 5.4 to 6.0 | 0.26 to 0.27 | 0.26 to 0.27 |
| 200,000 | mix | 344 to 369 | 432 to 445 | 20 to 22 | 0.26 to 0.27 | 0.27 |
| 1 | normal | 0.78 to 0.80 | 0.24 to 0.25 | 0.84 to 0.86 | 0.33 | 0.25 |
| 50,000 | normal | 94 to 102 | 76 to 88 | 65 to 72 | 0.35 to 0.37 | 0.27 to 0.28 |
| 200,000 | normal | 357 to 376 | 320 to 347 | 219 to 230 | 0.34 to 0.36 | 0.27 to 0.28 |

**Four clients on two cores** (latency a claim; the rows are different jobs because `SKIP LOCKED` skips the ones in flight):

| due rows | spread | A (today) | B | B0 | BL |
|---|---|---|---|---|---|
| 1 | mix | 1.7 to 1.9 | 2.4 to 2.7 | 1.5 to 1.6 | 0.88 to 1.0 |
| 50,000 | mix | 334 to 353 | 23 to 27 | 1.1 to 1.2 | 1.1 to 1.3 |
| 200,000 | mix | 1,380 to 1,610 | 77 to 91 | 1.1 to 1.2 | 1.2 to 1.3 |
| 50,000 | normal | 309 to 354 | 262 to 288 | 1.4 to 1.7 | 1.2 to 1.3 |
| 200,000 | normal | 1,510 to 1,760 | 841 to 874 | 1.4 to 1.5 | 1.1 to 1.2 |

With 200,000 *future-dated* queued rows beside the 50,000 due (mix, one client): A 88 to 110, A0 102 to 114, B 6.2 to 6.9, B0 0.26 to 0.27, BL 0.27 to 0.29. At 1 due row it is the same as with none (A 0.77, BL 0.26). BL2 with 8 running rows, 200,000 due, one client: 0.27 (mix) and 0.29 to 0.30 (normal); four clients 1.0 to 1.2. A row whose lease expired at priority 0 was claimed first in a check by hand.

**Plans (`EXPLAIN (ANALYZE, BUFFERS)`, 200,000 due, mix).**

| shape | execution | buffers | what it did |
|---|---|---|---|
| A | 393 ms | 13,257 | `BitmapOr` of the queued range and `state = 'running'`, heap-fetch all 200,000, top-N sort on `(priority, run_at)` |
| A0 | 644 ms | 201,024 | `Index Scan` of `(state, run_at)` fetching all 200,000 due rows by random heap access (the `kind` filter is applied after), then sort |
| B, one probe at priority 1 | 235 ms | about 10,600 | the same `BitmapOr`, because the `OR` stops the index giving rows in `run_at` order |
| B0, one probe at priority 1 | 0.13 ms | 23 | `Index Scan` of `(state, priority, run_at)`, the first entry |
| BL | 0.19 ms | 22 | `Values Scan` and one index probe a priority until a hit |
| BL2 | 0.38 to 0.51 ms | 32 | the same, six probes |

**What this shows.**

1. **The suspicion in the todo entry is right, and larger than it said.** Today's claim at 200,000 due rows is 344 to 376 ms on one connection and over a second with four, and it costs 0.78 ms with 1 due row. It fetches and sorts the whole due set on every claim, so a bulk enqueue slows every worker until the backlog is drained, and the slowdown grows with the backlog: at 200,000 a claim takes longer than most jobs run.
2. **The lease arm is half of the problem and the index is the other half.** B, which keeps the `OR`, is no better than A when every due row is normal (219 to 230 ms against 357 to 376) because the planner cannot give rows in `run_at` order across an `OR` of two states, so the index it was given does nothing. With the arm taken out (B0, BL) the wide index is an ordered probe that reads 23 buffers whatever the backlog is. A0 on the narrow index is not faster than A either, so dropping the arm alone is no help: it is the pair, per-priority equality and no `OR`, that makes the scan ordered.
3. **The wide index loses ADR 214's argument for the shape that probes.** ADR 214 measured the wide index with a `priority, run_at` sort and one statement, and that is still true here (the same A statement on `(state, priority, run_at)` is 373 to 402 ms against 349 to 373 on the narrow, three runs each at 200,000 normal rows with 8 running). The finding was about the ordering the statement asked for. A probe that fixes `priority` makes the index `(equality, equality, range)`, and then future-dated rows are not walked at all (the 200,000 future rows added nothing).
4. **One statement beats several.** BL costs the same as B0 when the first priority hits and saves a round trip per empty priority otherwise. With every row at `normal`, the common queue, B0 is two statements and BL one: at the 350 µs a trip the published port costs, that is the difference between 0.7 ms and 0.35 ms on top of the 0.27 ms. Not measured through the published port; computed from the trip cost above.

**Decision it moved.** The claim should be one statement with a `LATERAL` probe a priority over `VALUES (0), (1), (2)`, on an index of `(state, priority, run_at)`, with the lease arm as its own probe per priority (BL2) rather than an `OR`. It changes two things a caller sees: a `CREATE INDEX` on `(state, priority, run_at)` (and the old `(state, run_at)` dropped), and the order inside one priority, which is now every due queued row first and an expired lease second, where today the two compete on `run_at`. A queue that never loses a worker sees no difference in order. `job/table.zig` is **not** changed by this run and ADR 214 still says the rule the code holds; the todo entry, ranked P2, is the work, and the order inside a priority is the decision it waits on.

**Not measured, and how far it can be pushed.**

- **Through the published port**, which adds a round trip to B, B0 and to nothing in BL. The reasoning is above.
- **Contention that the rolled-back claim cannot make.** Every client claims the top row of the same ordered scan, and `SKIP LOCKED` hops over the in-flight ones; eight real workers on a box with cores are the todo list's other entry.
- **A `kind` filter that matches little.** A worker that handles one rare kind, with the due backlog all of another kind, walks the whole due set under the probe too (the index does not carry `kind`). The same is true of today's claim, so it is not a regression, but it is the next place this has a cliff.
- **Many running rows.** BL2 was measured with 8. The running probe reads every `running` row of a priority; a pool of thousands of workers would want `lease_until` in an index.
- **Autovacuum.** Rolled-back claims leave dead tuples, so each run was preceded by a `VACUUM`.
