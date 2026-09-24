# Roadmap input for nilo, from fdm

Findings from **fdm**, a download manager on `nilo_sql`, `nilo_job` and
`nilo_fetch` with no `App` and no Engine, on a plain `std.Io.Threaded`.
Sixteen `Range` connections per file, a steal from the longest running one,
resume on `ETag`, one SQLite file, a TUI on a worker thread that knows nothing
about a terminal.

This is the second round. The first was the seven items in ADRs 160, 056, 182, 183, 123, 125 and 184
closed, and every one of those has left fdm's source. What is here is what
stayed behind once they were gone, plus one thing that measuring the
workaround turned up. Each item is anchored to the lines in fdm that carry
it, at the working tree that builds against nilo `7dfa14a`.

Ordered by how much fdm's source shrinks if it ships; the last is a defect
rather than a gap.

---

## Summary

| # | Gap | Module | What it takes out of fdm | Conflicts with a stated non-goal? |
|---|-----|--------|--------------------------|-----------------------------------|
| 1 | A bound on progress, not on the call | `nilo_fetch` | the stall half of `supervise`, ~30 lines and two fields per segment | Touches ADR 056's rejection of per-read timeouts, but is not that |
| 2 | `transfer_buffer` does nothing on the `stream` path, and the buffer that does is not exposed | `nilo_fetch` | 1 MiB of stack per download that buys nothing | No |
| 3 | An `Exchange` that carries its own small transfer buffer | `nilo_fetch` | one buffer and one field on every call that is not a transfer | No, the cost stays on the caller's stack |
| 4 | "Do not follow redirects" and "forgot the buffer" are spelled the same | `nilo_fetch` | nothing today; a class of first-week bug | No |
| 5 | `head.keep(scope)`: a `Head` that survives the body | `nilo_fetch` | `Text`, 30 lines, and three `.from(...)` calls | No, the borrowed `Head` stays the default |
| 6 | `addMissingColumns` introspects on a second connection while its transaction holds the first | `nilo_sql` | a test that had to move off `cache=shared` | No, a defect |
| 7 | `Exchange.stream` said zero was the end, and over TLS it was not | `nilo_fetch` | nothing; fdm could not adopt `stream` until it was fixed | No, a defect, fixed in the same tree as this line |

---

## 1. A bound on progress, not on the call

### What is there

`timeout_ms` bounds a whole call, and since ADR 056 it fires with or
without an Engine. For a download that is the wrong shape of bound: a
segment's call *is* the transfer, and a transfer may take hours, so the only
honest value is `0`. That leaves a segment whose peer went quiet with nothing
to end it.

ADR 056 rejected per-read timeouts for the right reason: a server sending
one byte a second satisfies any per-read limit and never finishes, so an API
call needs an end-to-end bound. fdm agrees, for an API call. A transfer is
the case where the end-to-end bound cannot be set and the one-byte-a-second
server is not the failure being guarded against: that server is *slow*, and
fdm handles slow by measuring rate against the other fifteen connections and
reconnecting the outlier. The failure a download meets is a peer that sends
*nothing*, and keeps the socket open: a CDN edge that lost the origin, a NAT
that dropped the mapping, a Wi-Fi handover. What bounds that is time since
the last byte, not time since the first.

### Where fdm carries it

`src/download.zig:716-727`, in `supervise`: every 100 ms, for every running
segment, compare `seg.have()` to `seg.last_seen`; if it moved, stamp
`last_moved_ms`; if it has not moved for `settings.stall_ms` (10 s, `--stall`
on the command line at `src/main.zig:80`), `future.cancel(io)`, count a
failure, mark the segment idle so the loop restarts it. The two fields are
`src/download.zig:960-961`. The mechanism under it is the one ADR 056 now
uses: `Threaded.cancel` sends a signal into the blocking `recv` and the task
comes out with `error.Canceled`.

This is the last watchdog in fdm, and it is a watchdog for the same reason
the first one was: the thing it guards is a number nilo has and fdm has to
recount. nilo's `stream` knows exactly when a byte reached the writer; fdm
learns it by reading an atomic the segment task stores after every chunk.

### What is proposed

**`Begin.stall_ms: ?u32`**, beside `timeout_ms`: the call fails with
`error.Stalled` when no byte of the body has reached the caller for that
long. The two compose: `timeout_ms` is the ceiling on the whole call,
`stall_ms` is the ceiling on silence inside it, and a caller sets either or
both.

Under an Engine the `Bound` is re-armed at `now + stall_ms` each time a chunk
lands. Without one, ADR 056's `bounded` already runs each step as a task and
waits on a futex with the deadline as the timeout; for `stream`, `pipe` and
`readInto` the step becomes a loop of chunks, and the wait's timeout is
`stall_ms` from the last chunk rather than the call's deadline. The chunk is
whatever `reader.in.stream` hands over in one call, which on the wire is one
socket read, so nothing is split that was not already split.

`error.Stalled` rather than `error.TimedOut`, because the caller does
different things with them: a stalled segment is restarted on a fresh
connection and does not count as a failed attempt; a timed-out probe is a
server that cannot carry sixteen segments and the download fails. `blame`
names it the way it names a timeout.

With it, fdm's segment task returns `error.Stalled`, `Segment.run` records it
the way it records any error, and the supervisor's restart path, which
already exists for a failed attempt, does the rest. `last_seen`,
`last_moved_ms`, the branch at 716-727 and the `future.cancel` inside it go.
The rate sampling stays, because that is a decision across sixteen
connections and nilo sees one.

### What it costs

One `i64` on `Exchange` for the moment of the last chunk, which the padding
ADR 056 found room in may or may not still have. Without an Engine, one
futex wait per chunk instead of one per step, on the client that has a
`stall_ms` set and only there. Under an Engine, one `Bound.arm` per chunk.
No allocation.

The test is the one fdm already has: a server that sends half the body and
holds the socket open. Before, that test cannot finish without the watchdog.

---

## 2. `transfer_buffer` does nothing on the `stream` path, and the buffer that does is not exposed

### What is there

The guide says of `transfer_buffer`: "bigger is fewer trips into the
connection for a large object and more stack held per connection". fdm read
that and gave every segment 64 KiB at `src/download.zig:1017`, sixteen
segments, 1 MiB of stack per download.

`std.http.bodyReader` (`lib/std/http.zig`) says what the buffer is for. For
a body with a `content-length`, `contentLengthStream` is
`reader.in.stream(w, limit)`: straight from the connection's reader into the
caller's writer. The `transfer_buffer` is the interface's buffer, and
`stream` never fills it. It is read through only by `take`, `peek` and the
chunked path.

Measured, one segment against `mirrors.kernel.org/ubuntu/ls-lR.gz`
(38.8 MB, TLS), read syscalls counted from `/proc/<pid>/io`:

| `transfer_buffer` | `syscr`, two runs |
|---|---|
| 64 KiB | 19,860 and 14,892 |
| 0 | 18,758 and 19,032 |

About 2.5 KB a read either way, and the same hash. The number that decides
the read size is `std.http.Client.read_buffer_size`, 8 KiB by default, which
nilo's `Client.init` leaves at the default and `Settings` does not name.

### What is proposed

Two things, and the first is a sentence.

**The doc says which path the buffer serves.** "`transfer_buffer` is read
through by `take` and by a chunked body; `stream` and `pipe` on a
`content-length` body go from the connection's own buffer to your writer
and do not touch it." That sentence would have kept 1 MiB off fdm's stack.

**`Settings.read_buffer_size`**, passed through to `std.http.Client`. It is
per connection and lives on the heap with the connection, which is the right
place for a download manager's sixteen sockets and the wrong place for a
handler's one call, so the default stays at std's 8 KiB and the field says
so. Whether 64 KiB there cuts the syscalls in the table above is a
measurement fdm can make the day the field exists; it cannot make it today.

### What it costs

One field, one line in `init`. Nothing on any call.

---

## 3. An `Exchange` that carries its own small transfer buffer

### What is there

`Begin.transfer_buffer` defaults to `&.{}`, and the doc comment does not say
what an empty one does. Item 2 says: for `stream` on a `content-length`
body, nothing at all; for `take` and a chunked body, a `Reader` with no
buffer. So every caller declares one, and the ordinary call (a probe, a JSON
API, `update.zig`'s three `client.get` calls) is two lines of `var buf:
[4096]u8 = undefined;` and `.transfer_buffer = &buf` around one line of
request. fdm's probe at `src/download.zig:890-892` is three declarations
before the `begin`.

### What is proposed

**`Exchange` holds `[4096]u8` inline and uses it when `transfer_buffer` is
empty.** The caller already holds `var ex: fetch.Exchange = .idle` on its
stack for exactly the life of one call, so the cost lands where the guide
says a buffer's cost should land, and lands only while the exchange lives.
A call that wants more passes its own, through the same field, as now.
`Client.send`, which uses 4 KiB today, uses the inline one.

The probe becomes `var redirect` and `var ex`. `update.zig` becomes `get`
and nothing else, which it already is; this makes what `get` does inside
the same as what a caller can do outside.

### What it costs

`@sizeOf(Exchange)` goes from 928 to about 5 KiB. It is on the stack of a
handler that dials out, for the duration of the call, and a handler's stack
under the Engine is the number ADR 056 counted. If 4 KiB is too much there,
1 KiB covers a JSON head and the rule holds.

---

## 4. "Do not follow redirects" and "forgot the buffer" are spelled the same

### What is there

An empty `redirect_buffer` means redirects are not followed and a `302`
comes back as itself. For anything signed that is the right default, and the
doc comment says why. But the spelling for "I do not want this followed" and
for "I did not think about redirects" is the same absence, and the symptom
for the second is a `Head` with status 301 that a caller reads as
`BadStatus` and a server that is wrong. fdm did think about it, because
`mirrors.kernel.org` made it, and `src/download.zig:1019` is the buffer. The
next CLI on nilo will find it the same way.

### What is proposed

Either of two, and the first is the cleaner one:

- **`redirects: union(enum) { refuse, follow: []u8 } = .refuse`** in place
  of `redirect_buffer`. The intent has a name, the buffer goes where the
  intent that needs it is, and `head.redirected` keeps its meaning.
- Or the field stays and **a 3xx with an empty buffer is
  `error.RedirectRefused`**, with `blame` naming the field. A caller who
  wants the `302` as itself asks for it with `.redirects = .expose`, or
  whatever the spelling is; that caller exists (a signed request checking
  where an object moved) but is the rarer one.

### What it costs

The first breaks every `begin` with a `redirect_buffer` in it, which today
is fdm and nilo's own tests. The second breaks nobody and adds one error.
Nothing per call.

---

## 5. `head.keep(scope)`: a `Head` that survives the body

### What is there

Every slice in `Head` points into the connection's read buffer and the first
byte of body overwrites it. The doc says so, the bargain is the same as a
borrowed row's and it is the right default. What follows is that every
caller who needs a header *after* the body invents a copy. fdm's is `Text`,
`src/download.zig:50-73`: a `[512]u8` and a length, with `from` and `fmt`
and `slice`, used at 529, 903 and everywhere a note is posted. The `903` is
the one this item is about: `etag` or `last-modified`, taken before the body
so the next run can compare against it.

### What is proposed

**`head.keep(scope) !Head`**: the same struct with every slice copied into
the scope's arena, so a caller that needs it after `take` or `pipe` says so
once and the type that comes back reads the same. Or the narrower
**`head.headerOwned(scope, name) !?Str`** for the one header most callers
keep. `sql` already has the shape: a Borrowed row and the owned one beside
it.

### What it costs

One arena allocation the size of the header block, on the calls that ask.
Nothing on the calls that do not, which is the default and stays it.

---

## 6. `addMissingColumns` introspects on a second connection while its transaction holds the first

### What is there

`sql/migrate.zig:1226`, `addMissingColumns`: `var tx = try db.begin(scope,
.{})` takes one pooled connection, then inside the `inline for` over the
Rows, `db.liveColumns(scope, …)` takes *another* to read
`pragma_table_info`, and the `ALTER TABLE`s go through `tx`. Once the
first table's `ALTER` has run, the second table's introspection reads the
schema on a connection that is not the one holding the schema write.

On a file database SQLite lets that reader through (rollback journal or
WAL, either way), so fdm's real run, dropping `reason` from a used
database and reopening, passed. On `file:x?mode=memory&cache=shared`,
which is what fdm's migration test used and what a test reaches for when
it wants two connections to one throwaway database, shared-cache locking
answers the second connection's `prepare` with `SQLITE_LOCKED`, and
`open` fails with `QueryFailed` out of `liveColumns`. The same test
against a temp file passes; the diff between the two runs is the URI.

And on a pool of size 1 the shape is a deadlock rather than an error:
`liveColumns` waits for the connection `tx` holds until the call returns,
which is after `liveColumns` returns.

### Where fdm carries it

`src/store.zig`, the test "a file from before `headers` and `named` gets
both columns on open", which now makes a temp file with a comment saying
why it does not use shared cache. fdm's `store.open` has a pool of 2, so
the deadlock is not reached; the test is what found the lock.

### What is proposed

**Introspect through the transaction.** `tx` is a connection; give it
`liveColumns`, or have `addMissingColumns` read every table's columns
*before* it begins, which is also fewer round trips: one introspection
per Row up front, then one transaction of `ALTER`s. The second is the
smaller change and keeps `liveColumns` where it is. The test is the
migration test on `cache=shared` and on a pool of size 1, both of which
cannot finish today.

### What it costs

Nothing per call. The columns are read once either way.

---

## 7. `Exchange.stream` said zero was the end, and over TLS it was not

### What was there

ADR 056's `Exchange.stream(w, limit)`: one chunk, and "zero is the end of
the body", mapped from `error.EndOfStream`. The value it handed back
otherwise was whatever `std.Io.Reader.stream` returned, and on a TLS
connection that is zero more often than not at the start: std's
`crypto.tls.Client` returns `0` for a record that held no application data
(a post-handshake session ticket, a close alert), for a record that did not
arrive whole, and for the ordinary case of a record it decrypted *into its
own buffer* for the next call to serve. Its only test was over plain HTTP,
where a socket read is the chunk and zero never comes.

### Where fdm found it

The first run of fdm's segment loop on `ex.stream` against
`mirrors.kernel.org` over HTTPS: sixteen segments `ShortBody` inside the
first 300 KB, every attempt, because the loop took the first zero as the
end. The same loop on `ex.reader.stream` directly had been ignoring the
return value and reading until `fw.pos` reached the boundary, which is why
the zero had never been seen.

### What was done

`stream` loops until a read moves a byte or says `EndOfStream`; zero is
now only the second. One line of behaviour, no cost on the path that moves
bytes, and the reference's sentence became true.

---

## For the record: what the first round left as it should be

Three things fdm still does by hand that nilo should not take over.

- **The rate-based reconnect** (`supervise`, the 0.3× mean rule) is a
  decision across sixteen connections. nilo sees one, and should.
- **The steal** moves a segment's `end` while its request is in flight and
  reads the atomic before every chunk. That is fdm's loop over `stream`
  with a `Limit`, and the `Limit` is the right hook for it.
- **The job lease of a day** and `releaseStale` on open are what "one
  process owns this file" means, and nilo's lease default is right for a
  program that is not that.
