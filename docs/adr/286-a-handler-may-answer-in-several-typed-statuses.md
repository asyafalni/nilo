# A handler may answer in several typed statuses

**Status:** accepted
**Topic:** [errors](../design/errors.md)
**Extends:** [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md) (a failure mode in the return type: the signature may now name several statuses), [ADR 006](./006-failure-box-bound-to-the-fiber.md) (the 240-byte slot: a message that does not fit is kept whole in the request arena), [ADR 024](./024-every-failure-answers-as-json.md) (the body that carries it)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md) (a refusal for each mistake)
**Found by:** a port of a Rust service whose query language answers `{"error":"…","offset":12}` on a 400 beside a 200 list, and whose deploy route answers a 400 listing every problem it found

## Context

Two things a failure could not say, both met on the same port.

A failure is a status and a sentence. A search bar that underlines the token a query went wrong at needs the `offset` beside the sentence, so the handler kept a `*Ctx` and `c.sendJson(400, …)` and lost the generated description of its answer: `Status(code, T)` and `Response(T)` carry one `T`, and a second status with a different shape was a line in a body the document could not see. [`docs/decided.md`](../decided.md) had accepted that "the API description names one failure" and named what would reopen it, a shape that states a failure in the type.

And the sentence was cut at 240 bytes. The slot is a fixed buffer on purpose (ADR 006), but a route that refuses a deploy with the list of everything wrong with it lost the tail of the list, and its only way out was a 200 with the refusal inside.

## Decision

### A `union(enum)` of `Status(code, T)` arms is a handler's answer

```zig
const Search = union(enum) {
    found: nilo.Status(200, Hits),
    refused: nilo.Status(400, Invalid), // { error: []const u8, offset: u32 }
};

fn search(q: nilo.Query(Q)) !Search {
    return .{ .refused = .{ .value = .{ .@"error" = "unbalanced parenthesis", .offset = 12 } } };
}
```

**Each arm is sent as the `Status` it is.** `sendResult` switches on the tag and calls itself with the arm, so the arm's headers, trailers, JSON writer, `nilo_json` markers and fast path (ADR 278, ADR 282) are the ones a plain `Status` has, and nothing about writing a body is written a second time. A handler that does not return a union has no switch compiled into it. `renderAnswer` does the same for `Idempotent` and `Cached`, so a replay of a 409 arm is a 409. `Status(204, void)` and the other bodiless statuses follow what a bare `Status` already does. An error returned on the `!` side goes through `fail` exactly as before.

**A union is an answer with several statuses when at least one arm carries `nilo_status`**; a tagged union of anything else is still a JSON body, as it was. Recognised by `statusunion.is`, checked at the route by `statusunion.check`.

**The document writes one response per arm**, each with its status and its schema (`Answer.also`). Where nilo itself can answer the same status on the route with its failure shape (a `Query` that does not fit is a 400, a route behind a guard a 401), that response is `oneOf` the arm's schema and `Failure`, because a client meets both; where it cannot, the arm stands alone. A status an arm names is not written a second time as the generic one: a key twice in a JSON object keeps one.

**Three Refusals**, each a file in `refusals/` and a row in the framework's table:

- two arms with one status, naming both arms: one status is one shape in the document; give one a status of its own, or put a `union(enum)` in the body type of a single arm;
- an arm that is not a `Status(code, T)`, naming the arm and the form to write;
- `?Search`, the `?` around the union: it is a 404 with no arm to belong to, and the same fix as ADR 203 gives for `?Status`, put `Status(200, ?T)` on the arm.

**An arm is a `Status` and never a `Response(T)`.** A `Response(T)` chooses its status while the request runs, so the document could only write `default` for it, and two such arms would be indistinguishable: the union exists to state a response per status. A handler whose status really depends on what it found keeps `Response(T)` on its own.

### A fail message past 240 bytes is kept whole when a request holds it

`Failure.setIn` formats once, through a writer that starts in the slot. When the message does not fit **and** the fail function found a request in flight (through the fiber slot it already reads), the writer's one non-generic `drain` moves it into the request arena and keeps growing there by doubling, bounded at `max_long_message` = 16 KiB (the blocks it leaves behind stay in the arena until the request ends, which is acceptable on the failure path); a first form measured the message with a counting pass and formatted it again, so every `fail.*(fmt, args)` site instantiated three formatting paths and `example-orders` grew 51 KB (ADR 017); the slot then holds the slice (`n` is 255, and the slice lives in the slot's first sixteen bytes), so `@sizeOf(Failure)` is 256, as ADR 153 pinned it. Outside a request, which is the boot and `app.before`, and when the arena has no room, the message is cut at 240 bytes between characters, as it always was. **A message is a sentence or a list an operator reads, not a body dump**: 16 KiB is the bound, and past it the cut is the same.

`InFlight.read_request` became `request_ops`, one pointer to a pair of functions (read a part, allocate), so the slot's size is what it was. Every reader goes through `Failure.message()`: `sendFailure` builds its body in the arena when the message is long, so the stack buffer is the size it was; the shape `app.failures(T)` named gets the long message; the boot's log line and `testing.Refusals` see the slot's. **A gRPC call is told the first KiB**, because `grpc-message` is a header, percent-encoded up to three times its length, and a client's limit on a header list is commonly 8 KiB; an HTTP answer carries all of it. **`Bound.fail()` keeps its 240 bytes and its "and N more"**: its sentence is built in a stack buffer before the Failure is reached and ends in a count on purpose; a list of every field belongs to the per-field failure list below, not to a longer sentence.

### How the two pieces of the direction that are not built sit on this

The roadmap direction "A failure is a type" has two more pieces.

**A per-field failure list** (ADR 024, ADR 034) is another arm. A handler states `invalid: Status(422, Fields)` and fills `Fields` from `Bound`, which already knows every field and why; the document lists it, and nothing here stands in its way. What remains for the direction is making `Bound` and a plain argument hand that list over, and an `app.failures(T)` that can take it (its `nilo_failure(status, message)` stays the sentence). Nothing in the union keys on the shape of an arm's body.

**An App-wide error-to-status table** (`fail.statusFor`) answers an error that came from code that does not know about HTTP, on the `!` side, and this answers a value on the other. They compose: a table maps an error to a `Failure` before `sendFailure`, so the long message, the shape and the headers are the ones here; a table cannot change what a union arm answers, because an arm is a value and not an error. The document naming the statuses a handler's error set shares with the table is that piece's own open question (an inferred error set at registration), and a union does not depend on it.

## What was rejected

**`fail.with(400, Invalid{…})`, a failure that carries a value** (photon's suggestion). It is a runtime call in a body, so the document could not list it, which is the whole gap; a union states the same thing in the type and reaches the same wire. It stays possible later, written as an arm.

**Letting `app.failures(T)` take an optional extra the fail call passes.** One shape for the whole App cannot be a different shape on one route, and a field on a route's 400 is that route's.

**`Response(T)` arms**, above.

**A longer fixed slot.** 480 bytes would be +240 on a floor of 4,669 bytes an idle connection, about 5%, for a message that is long on a failure only; the arena costs nothing at rest (ADR 006).

**Allocating from the gpa, or an unbounded message.** The arena is reset with the request and is what the failure body is built in; the bound keeps one fail call from taking the request's memory.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 on the success path of every handler, a union's included: one switch on the tag, no allocation. The failure path allocates once for a message past 240 bytes and again for its body, and for nothing else |
| Memory per idle connection | 0: `@sizeOf(Failure)` is 256 (pinned by a test), the slice lives in the slot's buffer, and `request_ops` replaces the pointer it had |
| Throughput and p99 | 0 for a handler without a union (nothing is compiled in); one switch on the tag for one with |
| Binary size | A union adds one `sendResult` instantiation per arm, which is the code a bare `Status` of that type already was; a program with no union links none of it |
