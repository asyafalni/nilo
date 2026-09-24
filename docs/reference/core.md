# Core

One page of [the reference](./README.md): `Str`, `Run`, the Scope, percent coding and the clock: `nilo_core`, which the rest share.

## `Str`

| | |
|---|---|
| `s.view()` | the bytes |
| `s.eql(other)` | compare against a `[]const u8` |
| `s.int(T)` | parse as base-10 |
| `s.len()` | |
| `s.trimmed()` | the bytes with whitespace off both ends, borrowed |
| `s.blank()` | whether there is nothing but whitespace — including nothing at all |
| `s.keep(gpa)` | a copy that outlives the request; the caller frees it |
| `Str.static(bytes)` | text that already outlives any request — what a test uses |

`{f}` prints one: `std.log.info("path={f}", .{c.path()})`. `{s}` cannot be made
to work, because Zig reserves it for byte slices and a `Str` is a struct.

**`blank()` is the check in front of a write that takes a name, a title or a
body**, because required text arrives as `"  "` in the ordinary case rather than
the rare one — a field somebody tabbed through, a paste that brought its newline
along ([ADR 142](../adr/142-required-text-arrives-as-two-spaces.md)). The set is
`std.ascii.whitespace`, which includes the `\n` a hand-written `" \t\r\n"` drops
about half the time; a comment whose entire body is a newline is required text
that renders as an empty screen.

It is a read of the bytes and not a validation rule — whether a blank title is a
422 stays yours, the same line `len()` and `eql()` already draw.

## `Run`

A [Scope](#scope) for work that is not a request: a CLI run, the tick of a
scheduled task, a test. Handed to anything that would otherwise take a `*Ctx`.

```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const rows = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

| | |
|---|---|
| `nilo.Run.init(gpa)` | |
| `nilo.Run.initIo(gpa, io)` | the same, and able to `entropy` |
| `run.deinit()` | |
| `run.arena()` | `std.mem.Allocator` — memory that lasts as long as this tick |
| `run.str(bytes)` | `Str` — text you allocated from `run.arena()`, stamped with this tick |
| `run.entropy(n)` | `![n]u8` from the operating system. `error.NoIo` on a Run built by `init` |
| `run.entropyInto(buf)` | `!void` — the same, at a width nobody said while compiling |
| `run.loop()` | `?std.Io` — the loop this Run was made on, for a job that writes a file or sleeps between attempts; null for a `Run.init(gpa)` |
| `run.give(V, value)` | hand this tick a value for something below to ask for |
| `run.resolve(V)` | `!V` — what `give` put there. `error.NotGiven` if nothing did |
| `run.reset()` | end the tick: the memory goes back, what was given goes with it, and every `Str` from it goes stale |

`entropy` is spelled the same as [`Ctx.entropy`](./ctx.md#reading), so one function body
compiles under both — which is what "pass the `*Ctx`, or a `nilo.Run` if there
is no request" has always promised, and was false of the most common function in
any program, the one that mints a key
([ADR 128](../adr/128-a-scope-that-can-mint-a-key.md)):

```zig
fn create(db: *Db, scope: anytype, title: []const u8) !Doc {
    const key = id.Uuid.v7(try scope.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    return db.insert(Doc, scope, .{ .id = key, .title = title });
}
```

`init` leaves it null rather than requiring an `Io`, because handing out memory
and stamping a lifetime need none and most Runs never mint anything; `initIo`
takes the same `Io` the pool or the `std.Io.Threaded` was started with, which a
CLI, a seed and a test all have in hand by the time they build a Run.

**`run.str` is for text you allocated; a literal wants
[`Str.static`](#str).** The two are not interchangeable and the difference is
what each one promises: `run.str` stamps the tick, so the `Str` goes stale when
the tick ends and the use-after-request trap can catch it; `Str.static` carries
no marker and is never stale, which is the right answer for a literal in the
program's own text. It matters most where a Scope is already in hand and reaching
for it is the obvious move — building a list, where `run.str` costs a call per
element and says nothing true about a literal:

<!-- compiles -->
```zig
const types: []const Str = &.{ .static("DealValueChanged"), .static("DealWon") };
```

### A value that reaches the bottom

`nilo_resolve` works a value out once per request, and it arrives as a **handler
argument** — which is the top of the call stack. What needs it is often the
bottom: an audit row assembled sixty call sites down, where every function in
between would have to carry a value it has no business knowing about
([ADR 133](../adr/133-a-value-that-reaches-the-bottom.md)).

Both scopes answer `resolve`, so one function body reaches it either way:

```zig
fn record(db: *Db, scope: anytype, what: Event) !void {
    const actor = try scope.resolve(Actor);   // a *Ctx or a *Run
    _ = try db.insert(AuditRow, scope, .{ .agent = actor.agent, … });
}
```

**Where the value comes from is what differs, and that is the point.** Under a
server, `Actor` carries `nilo_resolve` and is worked out from the request — so
"is it set?" is answered while compiling, and no middleware has to remember
anything (ADR 015). A seed or a CLI has no request to work it out from, so it
is told once at the top:

```zig
var run = nilo.Run.initIo(gpa, io);
defer run.deinit();
try run.give(Actor, .{ .agent = "nightly-import" });
```

`run.resolve` answers `error.NotGiven` rather than null, for the same reason
`entropy` answers `error.NoIo`: a value nobody set has to be louder than a value
nobody read — the failure this exists for is an audit column that is quietly
NULL. What was given is copied into the tick's arena, so `reset` clears it, and
giving the same type twice replaces it.

**Given-as-null is given.** `give` records the type whatever the value, so a
`Caller { agent: ?Uuid }` handed over with `agent = null` resolves to that, and
`error.NotGiven` means only that nobody called `give`. The three states stay
apart, which matters when one of them — nobody wired it up — is a bug and
another — no agent, an ordinary human session — is most of your traffic.

A request never needs `give`: a value read off the request is a `nilo_resolve`,
and declaring it removes the third state entirely, because the resolver does not
depend on the route and a route asking for the value does not compile without
it.

## Scope

Not a type — the two calls `arena()` and `str()` that [`Run`](#run) lists. A `Ctx` has them and a
`Run` has them, and anything asking for a Scope takes either
([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)). It is checked
while compiling, so passing something else is a Refusal naming the call rather
than an error from inside the module.

`nilo_core` is the module both live in. A project importing `nilo` never has to
name it — `nilo.Str` and `nilo.Run` are the same declarations — but a program
with no server in it can depend on `nilo_core` alone.

### `AnyScope`

A Scope with its type erased, for the one place the shape above cannot reach:
**the other side of a function pointer**
([ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)). Zig has no
closures, so a bus, a queue or a job registry stores a callback as a function
pointer — and a function pointer names one type per argument, so a reaction
cannot be generic over the Scope it runs under while still running under a
request *and* under a `Run` in a test.

```zig
const Reaction = *const fn (scope: *nilo.AnyScope, payload: []const u8) anyerror!void;

fn notify(scope: *nilo.AnyScope, payload: []const u8) !void {
    const kept = try scope.arena().dupe(u8, payload);
    _ = try db.insert(Notice, scope, .{ .body = kept });
}

var erased = nilo.AnyScope.of(c);   // or `.of(&run)` outside a request
try reaction(&erased, payload);
```

| | |
|---|---|
| `nilo.AnyScope.of(scope)` | erase a `*Ctx` or a `*Run`. Two stores, no allocation |
| `erased.arena()` | the wrapped Scope's, through the vtable |
| `erased.str(bytes)` | the same, stamped with the wrapped Scope's lifetime |
| `erased.entropy(n)` | `![n]u8` |
| `erased.entropyInto(buf)` | `!void`, and the one the vtable actually carries |
| `erased.requestId()` | `?Str` — the request's id when it was made from a `*Ctx`, `null` from a `Run` ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |
| `erased.resolve(V)` | `!V` — what the Scope behind it **already holds**: given to the `Run`, or resolved for the request before it was erased. `error.NotGiven` otherwise; an erased Scope never runs a resolver. So a type only the far side asks for is resolved in the middleware that proves it — `_ = try c.resolve(V);` before `next.run` — not at the bottom ([ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)) |

It passes the Scope check, so `db.select(Row, &erased, …)` works — a reaction can
query, and can ask who is acting.

**The same seam serves two modules that must not import each other.** A context
that opens work on another's behalf declares the function it needs as a pointer
type — `OpenWork = struct { open: *const fn (tx: *sql.Db.Tx, c: *nilo.AnyScope,
in: OpenWorkInput) anyerror!sql.Uuid }` — and the wiring file, which imports
both, fills it with a function the other context wrote against a generic Scope.
One body then runs under a `Run` in a test, a `Ctx` on the server and the erased
one across the pointer, and neither context names the other.

**It borrows.** The pointer inside is the Scope's own, so an `AnyScope` may not
outlive the `Ctx` or `Run` it was made from — in practice it is a local beside the
call. **And the ordinary Scope is unchanged**: every call in nilo and in
`nilo_sql` still takes `anytype` and still costs no indirect call. The vtable is
paid for only where somebody erases one.

## `nilo_core.percent`

RFC 3986, both directions. The server decodes every path param and query value
through it and you never call that half; the encoding half is for building a
URL or signing one, and a Service can reach it because it is in Core rather
than behind `nilo_http`
([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)).

```zig
const percent = @import("nilo_core").percent;

var buf: [256]u8 = undefined;
const key = percent.encodeInto(&buf, "holiday photos/bali.jpg", .path);
// "holiday%20photos/bali.jpg"
```

A handler reaches the same thing as **`nilo.percent`** without adding an import
— which is the other half of what ADR 057 is about, and what
`examples/outbound/` uses to put a path param into a URL it is about to fetch.

| Call | |
|---|---|
| `percent.encodedLen(raw, set)` | `usize` — exact, not an estimate: every byte becomes one or three |
| `percent.encodeInto(dst, raw, set)` | `[]u8` — the part of `dst` used. `dst` must be `encodedLen` or longer |
| `percent.encodeWrite(w, raw, set)` | straight to a `*std.Io.Writer`, for something assembled a piece at a time |
| `percent.decode(gpa, raw, plus_as_space)` | `![]const u8` — allocates only if there is something to decode, else hands `raw` back |
| `percent.decodeInto(dst, raw, plus_as_space)` | `[]u8` — the part of `dst` used |
| `percent.decodedLen(raw)` | `usize` |
| `percent.needed(raw, plus_as_space)` | `bool` — whether decoding would change anything |

`set` is `.path`, where `/` is a separator and stays, or `.unreserved`, where
`/` is data and becomes `%2F`. Everything outside RFC 3986's unreserved set —
`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~` — is escaped in both, which includes
`!`, `*`, `'`, `(` and `)` if you are arriving from `encodeURIComponent`.

Three things are not options, because each is a failure that says nothing when
it happens: **a space is always `%20` and never `+`**, **hex is uppercase**, and
**there is no allocating encoder** — measure with `encodedLen` or write with
`encodeWrite`. `decode` allocates because the request path needs it to.

`plus_as_space` is the decoder's only switch, and it is for query values:
`?q=a+b` means "a b" because HTML forms have encoded it that way since 1995. It
stays off for path params, where a `+` is a plain `+`.

## What time it is

| | |
|---|---|
| `nilo.nowMicros()` | `i64` — microseconds since the epoch. What `sql.Timestamp` counts |
| `nilo.nowMillis()` | `i64` — milliseconds. What a UUID v7 puts in its first six bytes |
| `nilo.monotonicMicros()` | `i64` — microseconds since an arbitrary point. Two of them subtracted is how long something took |

Plain functions rather than calls on a `Ctx` or a `Run`: reading the wall clock
needs no event loop and nobody owns the time, so there is nothing for a Scope to
be the holder of
([ADR 041](../adr/041-core-knows-what-time-it-is.md)). They are `nilo_core`'s,
so a program with no server in it has them too. 15ns a call.

**Use `monotonicMicros` for a duration, never the other two.** A wall clock
moves when an operator moves it or when NTP steps it, so two readings a second
apart can come back in either order. It is the clock `db.watching` times a
statement with ([ADR 108](../adr/108-a-statement-can-be-watched.md)).

A handler that waits on the operating system without going through one of these
holds the thread every other request on it is being served by. nilo notices and
says so, once a second at most:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 013).
```

A wait inside a service — `db.raw` on its socket, a pool a caller queues on —
is a park too, and the service says so through `Limits.waiting`/`waited`
([ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md)); a
slow query is not a report, a slow loop is.

It fires on the first request, with nobody else waiting, which is the point —
under `curl` the mistake is otherwise invisible. `block_warning_ms` is the
threshold and `0` turns it off. What is measured is the longest stretch the
fiber ran **without parking**, so a stream, a body reader and a WebSocket are
watched on the same terms as anything else — a blocking call inside a WebSocket
loop is where it costs the most
([ADR 013](../adr/013-handlers-must-not-block-the-thread.md)).

`spawn` starts `f` in a fiber the server owns: counted while it runs, cut off
when the shutdown grace period ends. `error.NoServer` if nothing is listening.
Two things must not travel into it, and the compiler catches neither — a `Str`,
which points into the request arena that is about to be reset, and a fail
function, which has no request to fail and so returns a bare error nobody turns
into a response. Copy what you borrow, and log instead of failing.

```zig
try nilo.spawn(flushMetrics, .{&exporter});
```

**From `main` there is no such moment**, because `listen()` does not return.
`app.spawn` registers the same work before the server and starts it once there
is one — after the port is taken, after the services and whatever `app.before`
registered, before the first connection is accepted
([ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md),
[ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md),
[the guide](../guide/background.md)):

```zig
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{});
```

The work is a loop around a wait that can say stop: `nilo.sleep` fails with
`error.Canceled` when the grace period ends, and that is the only way out.

Sending to a WebSocket somebody else's connection is holding does not need
this — see [`Room`](./streaming.md#room). It needs no fiber of its own, which is the whole
of [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md).
