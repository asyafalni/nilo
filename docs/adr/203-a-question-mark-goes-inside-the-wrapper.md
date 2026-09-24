# A `?` goes inside the wrapper, and outside it is refused

**Status:** accepted
**Topic:** [typed-handlers](../design/typed-handlers.md)
**Applies:** [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md)
(`?T` is a 404), [ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md)
(a mistake stops in nilo's own words)
**Extends:** [ADR 189](./189-a-version-a-handler-names-is-an-etag.md), which
refused `Versioned(?T)` for the same body one level down

## Context

A handler in an application built on 0.5.0 was written as
`!?nilo.Status(201, Receipt)`: null for the 404, `Status(201, …)` for the
receipt. It compiled. On the success path the server crashed with a general
protection fault inside `json.writeText`, called from `sendJson` at status
200, and the panic was recursive so `nilo.panic` never named the request.

The typed layer reads a return value in a fixed order: the wrappers first
(`Redirect`, `Versioned`, `Response` and `Status`), and then `sendValue`
unwraps a `?` and dispatches on what is inside. `?Status(201, T)` is an
optional of a struct, so the wrapper check saw an optional and moved on, the
`?` was unwrapped, and what was left was the `Status` struct itself, which
nothing recognised and which therefore went out as JSON. Its `headers` field
is a list whose memory was never a header list, and `writeText` read through
it.

Every other wrong shape a handler can return is a compile error naming the
route. This one was a crash that only appeared once the request succeeded,
which is the worst shape a bug here can have: the failing path worked and
the working path failed.

## Decision

**A `?` around a wrapper is refused while compiling, and the message says
where the `?` goes.**

Three messages, because the way out differs:

- `?Status(code, T)` and `?Response(T)`: "the `?` has to go inside the
  wrapper". `Status(201, ?T)` is the shape nilo reads, and it means what the
  reader meant: 201 when the value is there, and the same 404 `?T` means
  everywhere else (ADR 023). The document describes both.
- `?Redirect(code)`: "a redirect has no body for the `?` to be about". A
  redirect is an answer the handler decided on, and the thing that is not
  there is `fail.notFound`, said before it.
- `?Versioned(T)`: "a thing that is not there has no version", which is
  ADR 189's reason for refusing `Versioned(?T)`, applied one level up.

The check sits in `typed.checkAnswer`, before the `Response` unwrap, so it
runs for every route however it was registered.

## What was rejected

**Reading `?Status(201, T)` as 201-or-404.** One line in `sendResult` and
one in `answerOf` would have made it work, and it was not taken because it
is a second spelling of a shape nilo already reads. `Status(201, ?T)` and
`?Status(201, T)` would mean the same thing, the document would have to
describe both, `renderAnswer` (what `Cached` and `Idempotent` keep) would
have to read both, and the next wrapper would have to decide the question
again. One spelling, and a message that names it, is what every other
wrapper here has.

**Leaving it to the JSON writer to refuse a `Headers`.** That would have
turned the crash into a compile error inside `json.zig`, about a field the
reader never wrote, which ADR 026 is against.

## What it costs

Nothing at run time: three `hasNamedDecl` reads at the route, while
compiling. Three refusals.

## Consequences

- `http/typed.zig`: `checkOptionalInside`, called from `checkAnswer`.
- `refusals/optional_outside_a_status.zig`, `optional_outside_a_redirect.zig`,
  `optional_outside_a_versioned.zig`.
- The handlers guide carries a table of which wrapper shapes nilo reads and
  which it refuses, so the combination does not have to be tried.
