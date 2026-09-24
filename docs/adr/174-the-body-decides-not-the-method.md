# The body decides, not the method

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

`std.http.Client` asserts that a POST, PUT or PATCH sends a body and that
every other method sends none: `sendBodyUnflushed` asserts
`method.requestHasBody()` and `sendBodilessUnflushed` asserts the opposite,
and `std.http.Method` is exhaustive. `nilo_fetch` chose between the two by
what it was given, so a DELETE with a body or a PATCH without one tripped
the assert — a panic in a worker thread, from a call that compiled.

Real APIs do both. A bulk delete takes `{ids:[…]}` in a DELETE body —
Elasticsearch, and the licence service the port was writing a client for —
and a verb endpoint is a PATCH whose whole request is its path:
`PATCH /users/{id}/full-suspend`. Go's `net/http` sends either without
comment. The port sent N single deletes and a `{}` body, which is the
application second-guessing the wire.

## Given a body, send it; given none, send none

The method says nothing about framing here. `attempt` reads
`requestHasBody()` only to choose the door std will open:

- **A body on a method std frames one for** — POST, PUT, PATCH — goes
  through `sendBody` as before.
- **No body on such a method** goes through `sendBody` with
  `content-length: 0` and `end()`, which is the bodiless request said the
  way std lets that method say it.
- **No body on any other method** is `sendBodiless`, as before.
- **A body on a method std frames none for** — a DELETE with one — goes
  through `sendBodilessUnflushed`, the one door that method may take, which
  writes the head and no `content-length`. The head's closing blank line is
  then taken back off the connection's buffer with `undo(2)` — the call
  std's own `sendHead` makes on the `accept-encoding` list — and the length
  and the blank line are written where it was, followed by the body. The
  check that the blank line is still buffered is what keeps this honest: a
  head too long to be buffered whole is `error.HeadTooLong` rather than a
  length in the wrong place.

The head std writes is std's, byte for byte, and the caller's headers keep
their order — the length lands after them, which is where a signed request
wants nothing to have moved.

## What was not done

**Writing the head ourselves for that case.** `sendHead` is private and
sixty lines of overridable-header logic; a copy is a second head to keep in
step with every std release.

**Merging `content-length` into `extra_headers`.** It needs a slice one
longer than the caller's, which is an allocation `Exchange` has no arena for
and a fixed array on a frame that ADR 062 counts per connection.

**A clean error and no send.** The port asked for at least that. A request
Go sends without comment is one this client sends; refusing it would be a
rule about the wire that the wire does not have.

## Against ADR 017's four axes

Nothing per request on the four ordinary shapes, which are the code they
were. The fifth is one `print` into the buffer already holding the head.

## Consequences

- `client.send(c, .DELETE, url, body, call)` sends the body; `send` with
  `null` on a POST sends `content-length: 0`. `client.patch(c, url,
  body_or_null, call)` beside the other four.
- `error.HeadTooLong` in `fetch.Client.Error`.
- A live test on the canned server: a DELETE carrying `{ids:[1,2,3]}` and
  a PATCH carrying nothing, both read back as sent.
