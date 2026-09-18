# Roadmap input for nilo, from fdm

What building **fdm** on nilo at `8c2d3be` (0.4.0 plus what is under
Unreleased) asked for and did not find.

fdm is a download manager in Zig 0.16: a CLI and a TUI over one SQLite
file, sixteen HTTP connections a download, resume across a kill, and a
benchmark that puts it beside curl, aria2 and Surge. It uses `nilo_sql`
for the file, `nilo_job` for the queue of downloads, and `nilo_fetch` for
every connection. It has no `App` and no Engine: a `Db`, a `Client` and a
`Jobs` on a plain `Io.Threaded`, which is the shape every CLI on nilo will
have, and the one most of nilo's own guidance is not written for.

Every item is anchored to the place in fdm that worked around it, at
`general-improvement` commit `c6939ea`. Ordered by how much each cost fdm,
not by how hard it is to build.

---

## Summary

| # | Gap | Module | What fdm did instead |
|---|-----|--------|----------------------|
| 1 | A wake for the queue | `nilo_job` | `poll_ms = 100`, 160 idle queries a second |
| 2 | A deadline without an Engine | `nilo_fetch` | `timeout_ms = 0` and its own stall watchdog |
| 3 | Headers that std owns, routed once | `nilo_fetch` | A `Headers` struct that routes them per call |
| 4 | The URL a redirect ended at | `nilo_fetch` | Formats `ex.req.uri` before the buffer dies |
| 5 | A column a shipped table has not got | `nilo_sql` | Hand-written `ALTER TABLE` that mirrors `createMissing` |
| 6 | A scalar out of `raw` | `nilo_sql` | A one-field struct with `nilo_table = .projection` |
| 7 | Small things | — | — |

---

## 1. A wake for the queue

### What's missing

A way for the process that enqueues to wake the workers. `Jobs.serveOn`
(`job/job.zig:546`) is one `claim` per worker per `poll_ms`, then a sleep,
and nothing else moves it. Enqueueing from the same process — which is what
every CLI does — has no way to say "now".

### Why it matters

With the default `poll_ms = 1_000`, `fdm add` to the first byte was half a
second on average. fdm set it to 100 (`src/download.zig:413`), which is
sixteen workers × ten `UPDATE … RETURNING` a second against one SQLite
file while there is nothing to do. It made a 100 KB file 0.7 s → 0.2 s; the
0.06 s that still separates it from curl on the same file is the poll.

The default is also the wrong one for a queue that is fed from inside: a
program that never noticed `poll_ms` exists gets a queue that feels broken.

### Possible shape

```zig
var jobs: Jobs = .open(gpa, &table, ctx, .{ .workers = 16 });
try jobs.enqueue(&run, .fetch, payload);   // signals the wake itself
jobs.wake();                               // for a producer nilo did not see
```

An `Io`-level event that a sleeping worker waits on with `poll_ms` as its
timeout, so the poll becomes the fallback for a producer in another
process. With it, an idle backoff is safe: double the sleep to a cap when a
`claim` came back empty, reset on a wake. Sixteen idle workers then cost
nothing, and a fed queue answers in one scheduler hop.

If a single claimer is easier than a wake per worker, `claim(n)` handing
rows to workers over a channel takes fifteen writers off the SQLite lock at
the same time. fdm did not measure that lock as a cost, so it is second.

---

## 2. A deadline without an Engine

### What's missing

A per-call timeout that fires on `Io.Threaded`. `fetch.Settings.timeout_ms`
is honoured only where an Engine runs the bound
(`fetch/fetch.zig:466`, `blame` at `:299`); on a plain `Io` it arms
nothing, and a connection that stops sending is held forever.

### Why it matters

fdm sets `.timeout_ms = 0` with a comment that says why
(`src/download.zig:397`) and runs its own watchdog: a per-segment
`last_moved_ms` that `supervise` checks every 50 ms against `stall_ms`
(`src/download.zig:986`). That is a second timeout mechanism a caller wrote
because the first one is silently off. Nothing in `Begin` or `Settings`
refuses the non-zero value; it is just not true.

### Possible shape

Either of:

- A bound that can be armed on `Io.Threaded` — one `io.concurrent` task per
  in-flight call that sleeps and cancels — so `timeout_ms` means the same
  thing everywhere.
- A refusal, at `Client.init` or `nilo_start`, when `timeout_ms != 0` and
  there is no Engine: "a timeout here cannot fire; pass 0 and bound the
  call yourself". A guard that does nothing should say so
  ([ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
  is the argument, applied to the guard itself).

---

## 3. Headers that std owns, routed once

### What's missing

`Begin.headers` goes to `extra_headers` (`fetch/fetch.zig:584`), and
`std.http.Client` has its own slots for `host`, `authorization`,
`user-agent`, `accept-encoding` and `connection`. A caller who puts one of
those in `headers` gets it twice on the wire — `Begin.user_agent`, added under
Unreleased for fdm, is one slot of five made reachable.

### Why it matters

fdm takes headers from a pasted `curl` line, so it sees `authorization:
Bearer …`, `user-agent: Mozilla/…` and `host:` as strings it did not
choose. It carries a `Headers` struct (`src/download.zig:1507`) whose only
job is to pull those three out into `.authorization`, `.host`,
`.user_agent` and hand the rest to `.headers`. That is routing every nilo
user with user-supplied headers will write, and the list of what std owns
is nilo's to know, not theirs.

### Possible shape

`Begin.headers` is the whole set; nilo splits it. A header whose name
matches a std slot goes to the slot (last one wins), the rest go to
`extra_headers`. `Begin.authorization` and the like stay as the explicit
form for a caller who has the value and not a header line. One place
knows the five names, and it is `fetch.zig`.

---

## 4. The URL a redirect ended at

### What's missing

`Head` does not say where a followed redirect landed. fdm needs it — the
sixteen connections after the probe should hit the final URL, not repeat
the redirect chain — and gets it by formatting `ex.req.uri` into its own
buffer before `redirect_buffer` goes out of scope (`src/download.zig:1319`).

### Why it matters

It reaches into `std.http.Client.Request` through the `Exchange`, which
nilo does not promise, and it has to happen inside `probe` because the
buffer is a local there. The comment explaining the lifetime is longer
than the code.

### Possible shape

`head.location: ?[]const u8`, null when no redirect was followed, valid as
long as the `Exchange` is — the same lifetime `head.header()` already has.

---

## 5. A column a shipped table has not got

### What's missing

The step between `createMissing` and `migrate.apply`. `createMissing`
creates what is not there and, by design, alters nothing
(`sql/migrate.zig:1170`); `apply` wants versions and steps. A single-file
program that added a field to a Row struct wants one `ALTER TABLE … ADD
COLUMN`, typed the way `createMissing` would have typed it, and neither
gives it.

### Why it matters

fdm added `headers`, `named` and `sha256` to `downloads` after the first
release. `addMissingColumns` (`src/store.zig:90`) reads
`pragma_table_info`, then runs three `ALTER TABLE` strings written by hand,
with types copied from what `createMissing` emits. If nilo's type mapping
moves, a file made through `createMissing` and a file made through the
ALTER path will differ, and nothing will say so. `migrate.apply` would
have been the honest tool, but a CLI's own SQLite file does not want a
ledger table and version files for three columns.

### Possible shape

```zig
try sql.migrate.createMissing(&db, &run, &.{ Download, Segment });
try sql.migrate.addMissingColumns(&db, &run, &.{Download});
```

Same type mapping as `createMissing`, `pragma_table_info` on SQLite and
`information_schema.columns` on Postgres, one `ALTER` per field the table
lacks, and a refusal for a field that is `NOT NULL` without a default. The
same function is a natural `Step` for `apply`, so both paths emit the same
DDL from the same struct.

---

## 6. A scalar out of `raw`

### What's missing

`db.raw(T, …)` for a `T` that is not a struct. A `SELECT name FROM
pragma_table_info(…)` returns one text column, and reading it needs:

```zig
const Col = struct {
    pub const nilo_table = .projection;
    name: []const u8,
};
const have = try db.raw(Col, run, "SELECT name FROM pragma_table_info('downloads')", .{});
```

(`src/store.zig:96`). The marker is right for a struct that is not a table;
for one column it is ceremony, and the first attempt without it was a
compile error whose message pointed at the marker but not at why a
projection needs one.

### Possible shape

`db.raw([]const u8, …)`, `db.rawOne(u64, …)`: a slice, integer, float,
bool or optional of those reads column one and ignores the marker. Structs
keep the rule they have.

---

## 7. Small things

- **`nilo_start(io, .off)`.** `.off` is `core.Limits` with nothing set
  (`core/limits.zig:101`), but at the call site it reads as "start with
  something off", and the first guess was logging. `.unlimited` or `.none`
  says what it is.
- **`max_drain` is not the caller's decision.** `Exchange.end` decides
  whether to drain or drop from `max_drain` and the announced length
  (`dropIfDrainIsDearer`, `fetch/fetch.zig:825`), which is the right
  default. fdm's probe asks for one byte and sometimes gets 200 with the
  whole file; it set `max_drain = 4 << 10` (`src/download.zig:400`) to be
  sure that drops. An `ex.discard()` — "I will not read this body; close
  the connection" — lets a caller who knows say so, and lets `max_drain`
  stay a policy rather than a lever.
- **`build.zig` is 188 KB.** A consumer's `zig build` reads all of it.
  If the modules a consumer imports and the tooling nilo runs on itself
  (`bench/`, `stress/`, `spike/`, the examples) could be split, a
  dependent's cold build carries less it never uses. Not measured, so
  this is a hunch, not a finding.

---

## What fdm did not need

For the record, so the list above is read as the whole of it: connection
pooling and the permit gate in `Client` did exactly what sixteen
connections a download want; `Exchange` with caller-owned buffers is why
fdm's per-connection memory is two small stack arrays; `Io.File`
positional writes through `nilo_core`'s `Run` needed nothing; and the job
table's lease and `restore` after a `kill -9` recovered every download it
was tried on. The queue's polling is the one thing a user of fdm can feel.
