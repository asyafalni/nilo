# 0270 — a failure body is a struct the application names

**Status:** accepted
**Amends:** [ADR 0025](./0025-every-failure-answers-with-the-same-json-body.md),
which rejected "an option on `App`" under *What was considered and refused*.
**Applies:** [ADR 0005](./0005-http-errors-via-fail-functions.md),
[ADR 0017](./0017-the-api-description-comes-from-the-signatures.md),
[ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0195](./0195-a-type-can-write-its-own-answer.md).
**Found by:** reading [actix-web](https://github.com/actix/actix-web) 4.15.0's
changelog — `Error::add_response_mapper()`, the third mechanism actix has
grown for "let the application say what an error looks like on the wire",
after `ResponseError` and `ErrorHandlers` — against nilo's one shape and no
way to change it.

## Context

Every failure nilo assembles goes out as `{"error":"…","status":404}`. ADR
0025 chose that shape over `text/plain` and over negotiating on `Accept`, and
it refused a switch on `App` with this:

> `errors: .text | .json` is two behaviours to test, two to document, and a
> decision every user has to make on their first day with nothing to base
> it on. The whole point of one shape is that there is one shape.

That is right about a switch between two shapes nilo invented, and it is not
about the case that turned up. An application that is the fourth service
behind one frontend does not get to choose its error shape; the other three
chose it, and the frontend's `catch` already reads `{"code":…,"detail":…}`
from all of them. That team has no decision to make on their first day —
they have a shape, and nilo would not send it.

What they did instead was a middleware that caught the error and wrote the
response itself, and what that loses is everything ADR 0025 built: the fail
function's sentence is in a box the middleware has to know about, the
`Allow` a 405 carries and the `WWW-Authenticate` a 401 carries are set by
the handler that failed, and the CORS headers come from a middleware that
may be outside this one. Four things to get right to change two field names.

actix took four years and three mechanisms to reach "the application can
rewrite the error body without writing a middleware". Every one of them is a
function that takes a response and returns a response, and every one of them
leaves the OpenAPI document describing a body the server does not send.

## Decision

**`app.failures(T)` names a struct, and the struct is the whole contract.**

```zig
const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) ApiError {
        return .{ .code = status, .detail = message };
    }
};

try app.failures(ApiError);
```

The fields are the JSON, the way a handler's return type is. `nilo_failure`
is the one function the type carries: given the status and the sentence,
fill the struct. nilo writes the value with the same JSON writer a handler's
answer goes through, into the same fixed buffer the default shape uses, and
sends it through the same `sendDirect` — so a 405 keeps its `Allow`, a 401
its challenge, and every failure the headers the request collected. The API
description derives `components.schemas.Failure` from the fields, written
inline under that name and not again under the type's own, so the document
and the wire cannot disagree.

**Not a writer.** The shape a type could have carried instead —
`nilo_write(status, message, w)`, ADR 0195's pair — was built first and taken
out. A writer has to be trusted about what it wrote: the document would need
a second declaration saying what the bytes look like, and the two would
drift the way ADR 0076 found a `Uuid` had. A struct needs no second
declaration. And `nilo_failure` cannot fail, by signature: the failure path
must not have a failure path of its own (ADR 0025), and a writer's `!void`
would have had one.

**The five answers before there is a request keep nilo's shape.** A
malformed head, a head too long, a head that timed out, a body under a
coding nilo cannot read, and a request shed past `max_in_flight` are
constants written in one `writeAll`, to a client that did not manage to
send a request nilo could route. ADR 0197's reason for the constant — a shed
request costs one write — is worth more than their envelope.

**Once.** A second `app.failures` is `error.FailureShapeAlreadySet`, the way
a second `app.metrics` is.

## What it costs, against ADR 0018

- **Allocations per request: none**, on either path. A request that
  succeeds never reads the field. A failure writes into the stack buffer
  the default already used, now 256 bytes larger for an envelope —
  `fail.max_message * 6 + 256` — and `test "the request path stays inside its
  allocation budget"` holds it.
- **Memory per idle connection: none.** The buffer is on `sendFailure`'s
  frame, which is `noinline` and entered only on a failure.
- **Throughput and p99: none.** One null check, on the failure path.
- **Binary size: +400 bytes on `hello`, +448 on `rest`**, stripped
  `ReleaseFast`, on an App that never calls `failures`: the branch in
  `sendFailure`, the `Failure` arm in `openapi.write`, and the field. An
  application that does call it pays its own `json.write` instantiation
  and `schemaOf`, which is what a handler returning the same struct pays.
  **The first version was +2,736, and 2,121 of it was one `std.log.warn`**
  — a warning for a shape that outgrew the buffer, with two `{d}`s in it.
  Without arguments it was 1,446; shared with the 500's format string it
  was inlined and cost the same. A log call site is a kilobyte or two of
  formatting on every App, fired or not, which ADR 0071 had found on the
  connection loop's stack and this finds in the binary. The warning is
  gone: a shape that outgrows the buffer gets nilo's own shape instead,
  sentence intact, and the first failure in development shows it.
- **Refusals: three.** Not a struct; no `nilo_failure`; a `nilo_failure`
  with the wrong signature.

## What was rejected

- **A switch between nilo's shapes.** ADR 0025's rejection stands for that;
  this is not a second shape of nilo's but the application's own, and the
  default is unchanged for everyone who does not call it.
- **RFC 7807 as the alternative shape.** The team that needs this has a
  shape already; the one that does not is served by the default. A third
  shape nilo invented would be the switch ADR 0025 refused.
- **A middleware that sees the response**, actix's `ErrorHandlers` and
  `add_response_mapper`. nilo flushes on `send` (ADR 0009), so the body
  would be rewritten after the head had gone; and it is the shape that
  loses the sentence and the headers, above.
- **The constants going through the shape too.** They would stop being
  constants. A 431 is the one of the five a real client can meet — a
  browser behind a single sign-on, ADR 0268 — and if that ever matters,
  the shape can be applied to those five at `listen()` once, into memory,
  and stay a single write. Not built until somebody meets it.
