# Responses

**Most handlers answer by returning a value; this page covers what a `*Ctx` can send directly, and the rules both follow: headers, redirects, files, ETags, JSON names, keep-alive and compression.**

**Reference:** [`Ctx`: answering](../reference/ctx.md#answering), [handler returns](../reference/handlers.md#handler-returns), [JSON shapes](../reference/handlers.md#json-shapes), [`compress` options](../reference/app.md#compress-options) · **Design:** [Responses](../design/responses.md), [JSON](../design/json.md)

Returning a value is covered in [Handlers](./handlers.md#what-a-handler-returns). This page is the layer underneath.

## Sending from a `Ctx`

```zig
fn handler(c: *nilo.Ctx) !void { … }
```

| | |
|---|---|
| `c.sendText(200, "hi")` | `text/plain` |
| `c.sendJson(201, value)` | serialised and sent |
| `c.send(200, "text/csv", bytes)` | a content type of your own |
| `c.sendFile(.{ .file = f, … })` | an open file, closed here. See [Files](#files) |
| `c.stream(200, "text/csv")` | a response written in pieces. See [Streaming](./streaming.md) |
| `c.events()` | a stream of server-sent events |
| `c.upgrade(loop, state)` | turn the connection into a [WebSocket](./websocket.md) and hand it to `loop` |

Every call is listed in [the reference](../reference/ctx.md#answering).

## Headers

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | for text that already outlives the request (a literal), so nothing is copied |

**Set headers before sending.** A response is finished the moment it is sent, so nothing can change afterwards.

nilo writes `Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` itself, and setting them is refused, because a response carrying two of any of those is malformed. Pass the content type to `send` instead.

**`Set-Cookie` and `Vary` add a line instead of replacing one.** Two cookies need two lines because they cannot be folded into one. Two `Vary` lines happen because the CORS middleware and a gzipped static file each name a different part of the same response, and replacing one lost the other ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). Setting either with a name and value that is already there adds nothing.

**A value may not contain a control byte, and a name has to be a token.** A header is `name: value\r\n` with no escaping, so a value containing a newline does not make a broken header: it makes a second header, and two of them start a second response. Both are refused with a 500 naming the header ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). Watch for this with values that did not come from you, such as a `Location` read from a database or a filename from an upload. Percent-encode those, or strip them.

A handler that returns a value sets the same headers through `.headers`, which is copied rather than borrowed:

```zig
// The status is part of the signature — `!Status(201, User)` — so the API
// description names it. `Response(T)` is the same thing with the status as
// a runtime field, for when it depends on what the handler found.
return .{ .headers = .of(&.{
    .{ .name = "Location", .value = url },
}), .value = created };
```

The limit there is eight per response. A ninth is a compile error that points you to `c.setHeader`, which has no limit ([ADR 018](../adr/018-a-response-owns-its-headers.md)).

## Redirects

[`Redirect(status)`](../reference/handlers.md#handler-returns) carries its status in the type, so the API description names it and says the answer carries a `Location`:

```zig
fn shortLink(db: *Db, code: nilo.Str) !nilo.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

The only hard part is choosing the status:

| | |
|---|---|
| **301** | moved for good |
| **302** | found, temporary |
| **303** | see other. **Use this to answer a form POST**: it turns the follow-up into a GET, so the reload button re-reads the page instead of posting the form again |
| **307** | temporary, and the method is kept |
| **308** | permanent, and the method is kept |

Any other status is a compile error, because a `Location` on a status that does not carry one means nothing to a client.

A redirect can carry headers, which is how a sign-in answers:

```zig
return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
```

[`c.redirect(status, location)`](../reference/ctx.md#answering) sends the same response from a `*Ctx`, for when the status is only known while the request is running.

There is no body. Browsers follow the header and never look at it ([ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md)).

## Files

**[`FileBody`](../reference/handlers.md#handler-returns) is a file as a return value.** The handler names it, nilo opens it, and the bytes go from the disk to the socket without passing through your process ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)).

```zig
fn invoice(files: *Files, id: u32) !?nilo.FileBody {
    const name = try files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

It is a return type rather than a call for the same reason a redirect is: the signature is the contract, so the API description says the endpoint answers with bytes, and the `?` says it can answer 404, exactly as it does for a `?User`.

| | |
|---|---|
| `dir` | the directory to open the file in, a [`nilo.Dir`](../reference/streaming.md#dir) |
| `name` | the name inside it |
| `content_type` | default `"application/octet-stream"` |
| `cache_control` | empty leaves the header off |
| `headers` | up to eight, the same list a `Redirect` carries |

The `dir` matters. It is opened once, at startup, and held as a service:

```zig
var files: Files = .{ .dir = try nilo.Dir.open("uploads") };
defer files.dir.close();
try app.provide(&files);
```

A name is opened relative to that directory rather than joined onto a path, so nothing a request carries is ever resolved as a path. What is left (a `..` segment, an absolute path, a NUL byte, and on Windows a backslash or a drive letter) is refused before anything is opened. It answers the same 404 a missing file does, word for word, so a probe cannot tell the two apart. The log line says which it was.

A download's filename is a header, and goes with the other headers:

```zig
return .{
    .dir = files.dir,
    .name = name,
    .content_type = "application/pdf",
    .headers = .of(&.{.{
        .name = "Content-Disposition",
        .value = "attachment; filename=\"invoice-42.pdf\"",
    }}),
};
```

There is deliberately no `download_as` field. Quoting a filename properly is RFC 6266, not one line, and `attachment` is not the only answer: a PDF that should open in a browser tab wants `inline` with a filename.

`Range`, `If-Range`, `If-None-Match` and `HEAD` work here exactly as they do for a [static file](./static-files.md#range-requests). The API description says the body is `application/octet-stream` with `format: binary` rather than the content type you set, because that one is a runtime field and the document does not guess.

[`c.sendFile(.{ .file = f, .content_type = … })`](../reference/ctx.md#answering) sends the same response from a `*Ctx`, for a handler that already holds an open file and has its own `etag`, `size` or `cache_control` to give it. It closes the file on every way out.

### Bytes already in memory

**[`nilo.Bytes`](../reference/handlers.md#handler-returns) is `FileBody` with the bytes in memory.** Use it for a proxy that downloads a bundle from another service and hands it to the browser with *that* service's `Content-Type`: there is no file and no `Dir`, and the content type is only known per request ([ADR 173](../adr/173-bytes-handed-on-are-an-answer.md)):

<!-- compiles -->
```zig
fn bundle(licences: *Licences, c: *nilo.Ctx, number: u32) !?nilo.Bytes {
    const got = try licences.download(c, number) orelse return null;
    return .{
        .body = got.body,
        .content_type = got.content_type,
        .headers = .of(&.{.{ .name = "Content-Disposition", .value = "attachment" }}),
    };
}
```

Nothing is copied: the body belongs to the handler, in the request arena or in a response it still holds. `?Bytes` means 404, as it does everywhere else. Unlike a `FileBody` it accepts a status wrapper, so `Status(201, Bytes)` does what it says. The document describes it as `format: binary`, for the same reason as `FileBody`. Before `Bytes`, the choices were `c.send` from a `*Ctx` handler, which the document could not see, or a `nilo_write` type naming a content type it did not know.

## ETags and 304 Not Modified

**[`nilo.Versioned(T)`](../reference/handlers.md#handler-returns) is `T` with a version, sent as a weak `ETag`, so a client that already has the answer gets a 304.** A list a dashboard polls every five seconds is the same list nearly every time. A client that sends the tag back as `If-None-Match` gets a 304 and no body, and if the handler checks first, no query runs either ([ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)):

<!-- compiles -->
```zig
const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    total: i64,
    revision: i64,
};

fn listOrders(c: *nilo.Ctx, db: *Db) !nilo.Versioned([]Order) {
    const revision = try db.rawOne(i64, c, "select coalesce(max(revision), 0) from orders", .{}) orelse 0;
    const version: u64 = @intCast(revision);
    if (c.clientHas(version)) return .unchanged(version);
    return .{ .version = version, .value = try db.select(Order, c, .{ .order = .{ .id = .asc } }) };
}
```

You choose the version, because only you know what it is: a revision column, a `max(updated_at)`, a counter the writer increments. It has to be known *before* the body is built, which is what lets [`c.clientHas`](../reference/ctx.md#reading) skip the query and not just the bytes. A handler that never checks still answers 304, because nilo compares on the way out, but it has already done the work.

The version is a `u64`. A timestamp in milliseconds fits. Text, such as an `updated_at` kept as a string, is one hash away:

```zig
const version = std.hash.Wyhash.hash(0, row.updated_at.view());
```

The tag is weak, `W/"1a"`, because a version says the content is the same and promises nothing about the bytes: the same value goes out gzipped to one client and plain to another. `If-None-Match` only ever compares weakly anyway. `headers` on the value go out on both the 200 and the 304, which is where a `Cache-Control` belongs; `.unchangedWith(version, headers)` is the 304 with them. Returning `.unchanged(version)` to a client that did *not* send the version is a 500 naming the route, because the handler skipped the work without checking.

`Versioned(?T)` is a compile error, because `null` would mean both "404" and "you have it"; a missing thing is `nilo.fail.notFound`. A `Versioned` inside a `Status` or a `Response` is also a compile error, and so is one under a `Cached` or an `Idempotent`, where a 304 decided for the first client would be replayed to everyone else. The API description puts the `ETag` on the 200 and lists a 304 beside it.

## JSON field names and union tags

**A struct becomes a JSON object and an enum becomes its tag name; one declaration on a type changes how its names or union tags are written.** That default covers nearly everything. The two cases it does not cover are common in REST APIs ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)). The full list is [JSON shapes in the reference](../reference/handlers.md#json-shapes).

**A union is externally tagged by default**: `{"metrics":{…}}`, one object with one key, which is what `std.json` writes and what nilo sends if you say nothing. `.tag` asks for the other encoding, with the variant's name next to its own fields:

<!-- compiles -->
```zig
const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { metric_name: []const u8, threshold: f64 },
    logs: struct { query: []const u8, count_over: u32 = 1 },
    disabled,
};

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
    pub const jsonParse = nilo.jsonParseFor(@This());

    info,
    needs_attention,
};

const Rule = struct { id: u32, severity: Severity, condition: Condition };
```

```json
{"id":3,"severity":"NEEDS_ATTENTION","condition":{"signal":"logs","query":"level:error","count_over":5}}
```

A variant carrying nothing is just the tag: `{"signal":"disabled"}`. Read as a request body, an object with the tag key twice is a 400 naming the key, since a client that keeps the other one would mean another variant ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)).

**`rename_all` spells names the way the wire wants them**: an enum's tags, a union's variant names, and a struct's field names.

| | `not_found` becomes |
|---|---|
| `.lowercase` | `notfound` |
| `.UPPERCASE` | `NOTFOUND` |
| `.camelCase` | `notFound` |
| `.PascalCase` | `NotFound` |
| `.SCREAMING_SNAKE_CASE` | `NOT_FOUND` |
| `.@"kebab-case"` | `not-found` |

The first two join the words rather than keeping the underscore, which is what serde does and what the names literally say. `.SCREAMING_SNAKE_CASE` is the one that keeps it. There is no `.snake_case`, because a Zig field name already is snake_case. Two names that end up the same are a compile error, because they would put the same key in an object twice.

### camelCase keys

**One declaration sends snake_case fields as camelCase keys.** Your Rows are snake_case because Postgres is, and your wire is camelCase because the browser is. Declaring it once is better than a mapping function written out field by field, which is what a DTO layer is. Nothing checks such a mapping against the Row it came from, so a column added to the Row reaches the wire only if somebody remembers the second file ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)).

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description uses the same keys, so a generated client reads what the server sends. It costs nothing per request: the name is settled at compile time either way.

**A field no case rule reaches can be spelled on its own.** A column called `estimated_cost_amount_minor` that the frontend knows as `estimatedCostMinor` is one `.rename` entry, and the entry wins over the case rule for that field only ([ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)):

<!-- compiles -->
```zig
const Summary = struct {
    pub const nilo_json = .{
        .rename_all = .camelCase,
        .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
    };

    id: u32,
    estimated_cost_amount_minor: i64,   // goes out as "estimatedCostMinor"
    due_at: ?[]const u8,                // and "dueAt", by the case
};
```

`.rename` on its own, with no case rule, is fine too. Each of these is a compile error where the marker is written: a name that is not a field, a spelling that is the field's own name, and an entry that lands on a key another field already uses.

**Renaming only applies to output.** `std.json` picks the parser for a body and reads it into the field names as written. So a struct with `rename_all` or `.rename` used as a request body, a form or a query string is a compile error naming the route: that route would document `fullName` and answer 400 to a client that sent it. Give incoming data a struct of its own, spelled the way the wire spells it. One direction that works is better than two that can disagree about a field.

A renamed struct that nilo's own writer cannot handle is also refused. The writer is deliberately narrow: one shape it does not recognise (a tuple, an array of bytes, an untagged union, a type that writes its own JSON without describing it, anything more than eight levels deep) sends the whole value to `std.json`, which ignores the marker.

**A type that writes its own JSON and describes it is not one of those.** `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` all carry a `nilo_openapi` next to their `jsonStringify`, and a marker may only name a scalar. So nilo knows the value is one string or one number and keeps writing the object around it ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)). A Row holding uuids can rename its fields, which is the ordinary case and the whole reason this was reopened.

That also makes such a response faster whether or not it renames anything, by more than you might expect: the writer is chosen for the *whole* value, so a single field it could not handle used to send every string next to it to `std.json` too. **250ns → 165ns on a 305-byte row with three uuids in it.** Your own type gets the same speed by writing the same two declarations.

**The marker applies to one type and is not inherited.** A struct renames its own fields. A union renames its *variants* and leaves a payload struct's fields to that struct's own marker. A nested struct with no marker keeps its own spelling.

**Why the `jsonParse` line is needed.** Writing does not need it: nilo makes the call, so it reads the marker itself. Reading does, because `std.json` picks the parser for a type and nothing can add a declaration to a type you wrote, so the type hands over a parser nilo supplies. Leave the line off if the type is only ever sent and never received; nilo tells you if you add it to a type whose JSON spelling was never changed.

The generated API description follows either encoding, so a client generated from it reads what the server actually sends ([the API description](./openapi.md)).

## When a response is sent

**A response is written in one go, and only once.** There is no "start the response, then change your mind" state, so there are no bugs where a header set too late silently disappears. If you need to decide as you go, use [a stream](./streaming.md); even there the head goes out first and cannot change after that.

The response is on the wire before the connection next waits for the client. For a client that sends a request and waits for the answer, which is every browser, that is the moment `send` returns. A client that pipelines, sending its next request before reading this answer, gets the answers in one write instead of one each. It was not waiting, and the batch is bounded by `write_buffer` ([ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)).

Sending twice is an assertion failure, not two responses on the wire. A handler that fails *after* sending gets its connection closed, because a half-sent response cannot be taken back and the next request on that connection would read bytes of unclear origin. It is logged:

```
warning: handler GET /report failed after answering: WriteFailed
```

## Keep-alive

**nilo decides whether the connection stays open.** HTTP/1.1 keeps it open unless the client says `Connection: close`. HTTP/1.0 closes it unless the client asks otherwise. A failed stream or an unreadable body closes it. [`c.keepAlive()`](../reference/ctx.md#reading) reports what will happen. A handler never has to think about it: a 404 is a normal answer, not a reason to hang up.

The response only mentions it when there is something to say: `Connection: close` when it is closing, `Connection: keep-alive` to an HTTP/1.0 client being kept, and nothing on an HTTP/1.1 connection staying open, because that is what HTTP/1.1 means by default ([ADR 197](../adr/197-a-response-says-when-it-was-sent.md)). Every response also carries a `Date`, which a cache in front reads to decide how old the answer is.

## Compression

**Compression is off unless you turn it on.** One line turns it on:

<!-- compiles: body -->
```zig
try app.compress(.{});
```

From then on, every answer that is text, at least a kilobyte long, and going to a client whose `Accept-Encoding` accepts gzip goes out gzipped, whether it came from `sendJson`, `sendText`, `send` or a typed handler returning a value. The response carries `Content-Encoding: gzip`, `Vary: Accept-Encoding` and the compressed length. A client that sent no `Accept-Encoding`, or `gzip;q=0`, gets the body unchanged and no `Content-Encoding`.

| | Default |
|---|---|
| `min_bytes` | `1024`: shorter bodies go out as they are; compressing a hundred bytes makes them longer |
| `level` | `.default`, zlib's level 6. `.fastest` is level 1, roughly a fifth larger and a little quicker; `.best` is level 9, under one percent smaller and five to nine percent slower |

The options are in [the reference](../reference/app.md#compress-options).

Text means the same list static files use: `text/*`, JSON, JavaScript, XML, WASM, and the `+json` and `+xml` structured types. A PNG, a woff2 or an `application/octet-stream` is left alone, as is a body under `min_bytes`, a 204, and an answer whose handler set `Content-Encoding` itself: a body you gzipped is not gzipped twice. A HEAD carries the length its GET would have.

**Three things are never compressed here.** A static file, because it was gzipped once when the App was built and that copy costs nothing per request ([Static files](./static-files.md#compression)). A stream, because it has no whole body to compress and would hold a compressor across every write. An event stream, because it must never be buffered at all ([ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).

**What it costs.** One compressor per thread, about 288 KB each, allocated once when the chains are resolved and never on a connection's stack: 4.6 MB on sixteen threads. One arena allocation on a compressed request, for the compressed body, and none on a request that is not compressed. And the gzip itself: for a 4 KB JSON answer at `.default`, about 37 µs on one core, of which 6 µs is resetting the compressor. `zig build bench-compress` prints the table for your machine. Nothing per connection, and nothing on a request under the threshold, which a test checks.

## Content types

| Returned | Sent as |
|---|---|
| `void` | no body, and no `Content-Type` either |
| `Str`, `[]const u8` | `text/plain` |
| `FileBody` | its `content_type`, `application/octet-stream` by default |
| a type with `nilo_content_type` | that, and the bytes its `nilo_write` wrote. See [below](#xml-csv-and-other-formats) |
| anything else | `application/json` |

A failure is always `application/json`, whether it came from a `fail.*` function, from an error, or from nilo refusing a request. See [Errors](./errors.md).

For anything else, use `c.send(status, content_type, bytes)`, or `c.stream(status, content_type)` when the length is not known yet.

## XML, CSV and other formats

**A type of yours can write its own body under a content type it names.** nilo answers JSON, and it will not learn XML, CSV or a template language ([ADR 157](../adr/157-a-type-can-write-its-own-answer.md) says why). What it will do is send bytes your type wrote, under the label the type names. That is what a consumer that only reads XML needs, and before this a `*Ctx` handler calling `c.send` was the only way to get it:

<!-- compiles -->
```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(number: u32) ?Invoice {
    if (number == 0) return null;
    return .{ .number = number, .total = 1500 };
}
```

Return it the way you would return a struct (bare, in a `?`, in a `Status(201, …)` or a `Response(…)`) and the wrappers mean what they always mean. The difference from `c.send` is that the route is described: the document names `application/xml`, and says what the body looks like if the type adds `pub const nilo_openapi = .{ .type = "string" };`. See [the reference](../reference/handlers.md#a-type-that-writes-its-own-answer).

Write both declarations or neither: a content type with no `nilo_write`, or the other way round, is a compile error naming the route.

Static files get their type from the file extension. See [Static files](./static-files.md).
