# An answer with no body ends at its head

Garage answers a presigned POST form with `204 No Content`, `location`,
`etag`, `date` — and no `content-length`, which hyper is entitled to leave
off. `client.send` sat on that answer for 120 seconds. `curl` came back in
30 ms, and the object was in the bucket the whole time.

`std.http.Client.Response.reader` frames the body from `transfer_encoding`
and `content_length` alone: `.none` and `null` means *read to EOF*, and on
a keep-alive connection EOF is whenever the server reaps the idle socket.
std's `receiveHead` knows the rule — its comment says a HEAD's answer, a
1xx, a 204 and a 304 are "always terminated by the first empty line after
the header fields, regardless of the header fields present" — and records
nothing of it where the reader looks. `Request.deinit` then drains the same
body the same way, so an `Exchange` that never touched the reader would have
hung in `end` instead.

S3's own DELETE is a 204. It happened to carry a length from every store
this module had met; it is one server version away from not.

## The Exchange applies the rule std wrote down

`Exchange.begin` asks `bodiless(method, status)` — RFC 9112 §6.3's four
cases — before it asks for a reader. For those it marks the request's reader
`.ready` (the state a body read to its end leaves), hands `take` an ending
reader, and records an announced length of zero. `take` answers empty at
once, `end` finds nothing to drain, and the connection goes back to the pool
clean, which the test proves by making a second request on it and reading
the second answer as the second answer.

Everything else — a 200 with no length, chunked, a length that lies — is
framed as before.

## What was not done

**Fixing std.** `bodyReader` is std's, and the rule belongs in
`Response.reader`; a patch upstream is the right long-term shape and this
module cannot wait on it. The check here is eight lines and is what a client
that never met std would have had to write anyway.

**A deadline as the answer.** The call *would* have timed out — under a
server, where the Engine fires `timeout_ms`. The port's client ran under
`std.Io.Threaded` with `Limits.off`, where nothing fires, and the 120 s was
hyper's idle timeout rather than nilo's. That is a second finding of the
same round: `.off` disarms the per-call `.timeout_ms` as well as the
client's, and neither the field nor the guide said so. Both do now.

## Against ADR 0018's four axes

Nothing. One comparison on the status per call; no allocation, no memory
per connection, no bytes in the binary worth counting.

## Consequences

- A HEAD's answer, a 1xx, a 204 and a 304 end at the header block whatever
  their headers say, in `send` and in an `Exchange`.
- The fetch guide says what `Limits.off` does to a timeout.
- `s3/live.zig` posts its form through the Store's own Fitting rather than
  through `std.http.Client`, which hung on the same answer the moment the
  form was accepted.
