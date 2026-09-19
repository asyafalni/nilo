# The standing risks, and what holds them

What could go wrong that is not a bug and not a feature, and what stands in the
way of each. Three groups. The first is held by a mechanism with a test under
it; the second cannot be held in this language and is said out loud instead,
which is the whole of what can be done about it; the third is
[still open](#open), with no mechanism under it yet, and an entry moves from
that list to the first when something is built that holds it. The open ones
are the only part of this file that is work, and [the roadmap](./roadmap.md)
points here rather than repeating them.

## Held by something

**zio is a one-person project, and it could stop when Zig 0.17 lands.** The
Bulkhead, fitted from the first stage rather than patched on later
([ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md)). It is the
entire contract nilo asks of an Engine, listed in one file's header.

**The `Str` guarantee cannot be complete.** The debug-build staleness trap, on
from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)). It
missed the case anybody would actually test it with, two separate `curl` calls
where the next connection started counting from the same number the stashed
`Str` held, until every connection was given a generation span of its own. What
it still cannot watch is a `Str` reached through something nothing walks: a
const slice, or an untagged union.

**A response could differ from what `std.json` would have written**, now that
something else usually writes it. `covers()` decides while compiling which
types the generated writer may touch, and it errs narrow. A tuple, a `[N]u8`, a
type with its own `jsonStringify`, and anything unrecognised all fall back.
Floats are handed to `std.json` field by field rather than reimplemented.

**This one has gone off, which is why it is worth reading rather than nodding
at.** `[:0]const u8` was recognised by neither and went out as a JSON array of
byte values under an `application/json` label, while the generated document
described it as a string
([ADR 0103](./adr/0103-one-file-decides-what-counts-as-text.md)). The tests did
not catch it because every value in them was a type somebody sat down and
wrote. The one case that was still open after it — a byte slice that is not valid
UTF-8 — went the same way, as the array of byte values `std.json` writes
([ADR 0121](./adr/0121-a-byte-that-is-not-text-is-not-a-string.md)).

**Deadlines are on by default, so a client on a genuinely bad link could be cut
off where it used to be served.** The numbers are generous and each bounds one
wait rather than a whole request, so nothing legitimate and slow is hurried by
any of them: not a big upload, not an hour-long stream
([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

**A WebSocket has no read limit, so a client that vanishes without a FIN holds
a fiber.** Caught by the write limit as soon as the server sends anything, and
a connection nobody writes to is caught by `.idle_ms`, 30 seconds by default,
`0` waiting forever. It is a ping rather than a deadline, because a quiet
WebSocket is a working one
([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)).

**The request head is the one thing a stranger writes directly, and every test
of it was an input somebody thought of.** `http/fuzz.zig` states properties
instead: the head boundary and the framing fields are checked against a
byte-at-a-time reference implementation, over a corpus on every `zig build
test` and over a million generated inputs on every CI run (`zig build fuzz`).
Coverage-guided fuzzing is not available, because `zig build test --fuzz` fails
to compile inside std's own test runner on Zig 0.16.0, so the generator is the
substitute and the targets are written to become coverage-guided the day that
is fixed.

**What it cannot catch is a reading both sides share**, and it did not: the
reference parser read `Transfer-Encoding: gzip` exactly as wrongly as
`http1.zig` did, so the corpus entry for it passed
([ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md)). A
differential test proves the two implementations agree, which is not the same
as either being right. Only the RFC settles that.

**Nothing bounds how many connections one process holds.**
`.max_connections`, 10,000 by default. Past it a connection is accepted and
closed at once, so the failure mode is a client that finds out immediately
rather than an OOM kill that takes every in-flight request with it.

**Nothing bounds how many requests one process answers at once, so a burst
queues on the pool and every request in it is late.** `.max_in_flight`, off by
default because the right number is the pool's and not nilo's. Past it the
request is answered with a 503, `Retry-After: 1` and a closed connection before
the router is asked, so the balancer moves on and the ones already running
finish on time ([ADR 0197](./adr/0197-a-server-past-its-limit-says-so-at-once.md)).
The gauge `nilo_requests_in_flight` is how an operator picks the number.

**A file response holds a descriptor for as long as the send takes.** One per
request in flight, so `.max_connections` bounds it, which is the same number an
operator already multiplies for memory. It is closed on every exit from
`sendfile.send` including the error ones, and a test counts `/proc/self/fd`
across a request so it stays that way
([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).

**A spilled file's ETag is its mtime and size, so two different contents could
share one.** Accepted, and argued rather than assumed. The alternative is
hashing gigabytes at startup, and a weak validator would make `If-Range`
unusable for exactly the large downloads that need resuming. It is the tag
nginx has served by default for twenty years, and a held file is unaffected,
because it keeps its content hash.

**A `<!-- compiles -->` on a page nobody listed would be silent, and would look
exactly like one that is checked.** `zig build snippets` compiles what the
`pages` list in `build.zig` names, and it also walks `README.md` and `docs/`
for the mark itself, refusing a marked page the list has left out. So a mark
cannot be written anywhere the step will not read it, which is what made this
a class rather than an oversight: the way to learn how a block is marked is to
copy a neighbouring page, and a dead mark used to copy as readily as a live
one. The instance that surfaced it, `docs/guide/openapi.md`, is on the list.

## Cannot be held, and said out loud instead

**A panic in any handler takes the whole process down, and Go people will
assume otherwise.** Cannot be fixed in Zig. Said plainly in the docs, with
`ReleaseSafe` and a supervisor recommended, and the in-flight request named in
the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)).

**A Service is shared across threads and nothing makes a user notice.**
`nilo.Mutex`, in the guide and in the example everyone copies. Nothing forces
it, because Zig has no ownership tracking to force it with
([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)).

**Spawned work can capture a `Str`, or call a fail function, and both compile.**
Neither can be caught: Zig has no ownership tracking, and `spawn` takes a plain
function that nothing marks as being outside a request. Documented at the
function, in the reference and in
[ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), and `spawn`
takes its arguments by value so the copy is at least the obvious thing to
write. A `Str` that escapes this way is the staleness trap's problem, and it is
the case that trap cannot watch.

## Open

No mechanism holds these yet. Each says what it needs; until that arrives the comment at the site is what there is.

**A fail function in spawned work is safe only because of where a threadlocal gets written.** `bulkhead.slot()` falls back to a threadlocal when a fiber has no slot, which spawned fibers never do. It is null on executor threads only because the one thing that sets it does so from inside `zio.blockInPlace`, which runs on a thread-pool worker. Both ends carry a comment saying so. Nothing enforces it, and if it broke, spawned work would write its message into an unrelated request, which is [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another route.

**Needs:** a design that makes it a rule rather than a comment.

**Nothing checks that a completion handed to the loop is given back before its frame goes.** `Wake` submitted two and never did, and the cost was a server that would not come back from a SIGTERM three runs in four ([ADR 0098](./adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)). What makes it a standing risk rather than a closed bug is that the fix is one `defer` and the next `submit` anybody writes is under no obligation to match it.

The failure gives nothing away at the place it happens: the loop writes into memory that has been handed on, and what arrives is a spinning thread somewhere else entirely, after a shutdown that has already logged success. Only the Engine may name zio, so the whole surface is one file — but one file is what the threadlocal entry above says too.

**Needs:** a design that makes it a rule rather than a `defer` somebody has to remember. This particular one is guarded — a test in the Engine parks a `Wake` and checks the queue is empty after `deinit` — but the guard names `Wake`, and the next `submit` will not be in `Wake`.

**`zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled.** Not used here, reported upstream with a standalone reproduction, and **fixed upstream** in zio `ab6873eb` with a fresh `Waiter` per receive attempt. A waiter node was pushed onto a queue it was already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`). Debug aborted 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast`, which has no such assertion, **hung 17 runs in 20** where a clean run takes 200ms. Cancellation was what reached it: the same program closing the channel and waiting was clean 5 in 5 ([zio#667](https://github.com/lalinsky/zio/issues/667)).

**Needs:** the pin to move: v0.17.0 predates the fix and is what `build.zig.zon` holds, so it arrives whenever nilo next moves it. Nothing here depends on it.
