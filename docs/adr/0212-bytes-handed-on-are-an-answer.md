# Bytes handed on are an answer

A proxy endpoint downloads a bundle from a licence service and streams it to
the browser with the upstream's `Content-Type` and a
`Content-Disposition: attachment`. A typed handler had four ways to answer
and none of them was this one: a value is JSON, bytes are `text/plain`, a
`FileBody` needs a `Dir` and a name on disk, and a type with `nilo_write`
names its content type while compiling
([ADR 0195](0195-a-type-can-write-its-own-answer.md)). So the port took a
`*Ctx` and called `c.send(status, ct, bytes)` — and the generated document
said the route wrote something it could not read
([ADR 0150](0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)),
which for a route a frontend client is generated from is the route not
existing.

## `nilo.Bytes`

```zig
fn bundle(licences: *Licences, c: *nilo.Ctx, id: u32) !?nilo.Bytes {
    const got = try licences.download(c, id) orelse return null;
    return .{ .body = got.body, .content_type = got.content_type, .headers = … };
}
```

`FileBody`'s shape with the bytes in memory instead of a `Dir`: the body,
the label, the headers a download wants. Dispatched where `FileBody` is —
after every wrapper is taken apart — so `?Bytes` is the 404, and unlike a
`FileBody` it takes the wrapper's status, because nothing about bytes in
hand decides between a 200 and a 206.

**The document says bytes.** `application/octet-stream` with `format:
binary`, exactly as a `FileBody` is described and for the same reason: the
content type is a field the handler fills in while the request is running,
and a document that named `application/zip` would be wrong the first time
upstream sent an SVG. What the signature settles is that the route answers
with bytes; that is what the document promises.

**Nothing is copied.** The body is the handler's — the request arena, or a
response the handler still holds — and goes out through `c.send` as it is.

**An idempotent route keeps one** the way it keeps a written answer: the
label is the value's and its headers go into the record beside the
wrapper's, so a replay carries the `Content-Disposition`.

## What was not done

**A runtime `content_type` on the `nilo_write` protocol.** A type that
writes its own answer is a *type* — an invoice, a CSV — and its label is a
fact about the type. Bytes handed on have no type of their own; the label
belongs to the value.

**`c.send` described by convention.** A `*Ctx` handler that returns nothing
may have written anything, and ADR 0150 is why the document declines to
guess. This adds an answer the signature can see rather than a note the
document takes on trust.

## Against ADR 0018's four axes

Nothing. The bytes were the handler's and go out once; `Bytes` is a struct
of three slices on the handler's stack, the size a `FileBody` already is.
A program that returns none links none of it.

## Consequences

- `nilo.Bytes { body, content_type, headers }`; `bytebody.zig`.
- One Refusal: a `Bytes` in the argument list, the way a `FileBody` there is.
- The port's proxy route is a typed handler, and its document has a body.
