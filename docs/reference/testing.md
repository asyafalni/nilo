# Testing

One page of [the reference](./README.md): an App and a Client wired together, with no socket.

## Testing

| | |
|---|---|
| `testing.Client.init(gpa, .{ .response_bytes = 64 * 1024 })` | |
| `.{ .client_address = "203.0.113.7" }` | what `c.peer()` and `c.clientIp()` answer |
| `.{ .cookies = true }` | keep what the answers set and send it back — a browser's jar. Off by default |
| `client.get(&app, path)` / `post(&app, path, body)` | |
| `client.postWith(&app, path, content_type, body)` | a POST that says what its body is — what a form needs |
| `client.request(&app, method, path, body)` | |
| `client.sendRequest(&app, .{ .method, .path, .headers, .content_type, .body })` | all of it, described. Every field has a default |
| `client.setHeader(name, value)` | sent with every request from now on. Setting it again replaces it |
| `client.cookie(name)` | `?[]const u8` — what the jar holds |
| `client.send(&app, raw_request)` | the whole request, written out. Sticky headers and the jar are **not** applied |
| `answer.status` / `.head` / `.body` / `.raw` / `.chunked` / `.keep_alive` | |
| `answer.interim` | `?[]const u8` — the `100 Continue` that came first, or null. `.status` is the final one either way |
| `answer.header(name)` | case-insensitive, the first of that name |
| `answer.headerAt(name, n)` / `.headerCount(name)` | for the ones a response repeats |
| `answer.setCookie(name)` | the whole `Set-Cookie` line that sets it |
| `answer.text(&buf)` | the body with chunk framing undone, into a buffer you sized |
| `answer.bytes(arena)` | the same, into memory the arena owns |
| `answer.json(T, arena)` | `!T` — the body read back as a value ([ADR 0180](../adr/0180-a-response-is-read-back-the-way-it-was-written.md)) |
| `error.AnswerStale` | what the three above answer once the client has answered a later request: `.body` borrows the client's one buffer, `.status` is a value, and the two would otherwise disagree in silence ([ADR 0210](../adr/0210-an-answer-knows-which-request-it-was.md)) |

**`answer.json` is there because nilo already decided how the value was
written**, so a test asking what came back should not have to reach for
`std.json` and walk a `Value`:

```zig
const made = try answer.json(struct { id: []const u8 }, arena);
```

It de-chunks first, and everything is copied into `arena` so what comes back
outlives the client's response buffer and the next request on it — so read it
*before* that request: an answer asked for its body afterwards is
`error.AnswerStale`, not the later request's bytes. **Unknown
fields are ignored**, which is the opposite of the rule on the way in and
deliberately: an unknown field in a *request* is the client's typo and is a 400
naming it, while a response with more fields than the test asked about is the
ordinary case. Ask for `std.json.Value` when the shape itself is what is being
asserted.

### An App and a Client, wired together

```zig
var wired = try nilo.testing.Wired.init(testing.allocator, .{});
defer wired.deinit();

try wired.app.provide(&db);
try wired.app.post("/partners", createPartner);

const answer = try wired.post("/partners", body);
```

| | |
|---|---|
| `Wired.init(gpa, options)` | the same `Options` a `Client` takes |
| `wired.app` | a plain `App` — every registration call is the one documented above |
| `wired.get(path)` / `post(path, body)` / `postWith(…)` / `request(…)` | the `Client` calls, without the `&app` |
| `wired.sendRequest(r)` / `send(raw)` / `setHeader(n, v)` / `cookie(n)` | likewise |
| `wired.deinit()` | the client, then the App |

**The routes and the services stay yours**, which is where the line is: `app` is
a field rather than something behind methods, so nothing here is a second API and
no database is assumed. `Client` is unchanged and is still the answer when a test
needs two of them against one App — two addresses, two cookie jars.

A WebSocket route has no answer to read, so it has a driver of its own
([ADR 0113](../adr/0113-a-websocket-route-can-be-driven-from-a-test.md)):

```zig
var chat: nilo.testing.Conversation = try .init(gpa, .{});
defer chat.deinit();

try chat.text("hello");
try chat.close(1000, "bye");

const talk = try chat.open(&app, "/chat");
try testing.expectEqualStrings("hello", talk.at(0).?.bytes);
```

| | |
|---|---|
| `Conversation.init(gpa, .{ … })` | the same `Options` a `Client` takes |
| `chat.text(s)` / `binary(b)` / `ping(b)` / `pong(b)` | queue one frame, masked as a client must |
| `chat.close(code, why)` | queue a close frame |
| `chat.fragments(.text, &.{ … })` | one message split across continuations |
| `chat.raw(bytes)` | bytes framed by nobody — for what a **malformed** frame does |
| `chat.setHeader(name, value)` | sent with the handshake — an `Origin`, a cookie, a subprotocol |
| `chat.open(&app, path)` | run it. The queue is cleared, so the same conversation can open again |
| `talk.accepted()` / `.status` / `.header(name)` | the handshake |
| `talk.at(n)` / `.first(kind)` / `.messages` | the frames the server sent, decoded and in order |
| `talk.closedWith()` | the close code, or null if it never closed |

A `Message` is `.kind` (`.text`, `.binary`, `.ping`, `.pong`, `.close`),
`.bytes`, and `.code()` / `.reason()` for a close frame.

**The frames are queued before the server runs, not while it runs.** One
thread and no socket, so a test cannot read what the server said and then
decide what to send next — and a conversation between *two* sockets, a `Room`
broadcast included, needs two connections and is out of reach here.

### A failed assertion that can be read

`std.testing` prints both sides with `{any}`, and `{any}` is the specifier that
means *do not call the type's own formatter* — so a `Uuid` prints as sixteen
decimal numbers and a `[]const u8` as its bytes. On a schema with many uuid
columns nearly every row asserted on comes out as noise
([ADR 0169](../adr/0169-a-failed-assertion-that-can-be-read.md)):

```zig
errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
```

`show(value)` renders as JSON into whatever writer is formatting it — the
rendering nilo already has for the types it carries, so a `Uuid` is text, a
`Str` is a string and a `Timestamp` is RFC 3339. **Nothing is allocated**, which
is what lets it sit inside a `std.debug.print` while you are poking about. For an
actual `[]const u8`, `std.fmt.allocPrint(gpa, "{f}", .{nilo.testing.show(v)})`
needs nothing from here.

It is a renderer and not an assertion on purpose: an `expectEqual` of nilo's own
would pull `expectEqualDeep`, `expectEqualSlices` and `expectError` behind it,
and it would not have helped the failure this came from, which was an
`expectError` finding a payload rather than two values that differed. A `Json(T)`
column nests JSON inside the JSON, which reads well and is not meant to be parsed
back.

### Catching a refusal with no request in flight

A service function called from a CLI, a seed or a plain test refuses through the
same fail functions, and outside a request there is nowhere to park the status —
so four different refusals arrive at the caller as four identical
`error.Failed`. `Refusals` gives the test the status and the sentence back
([ADR 0161](../adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)):

```zig
var refusals: nilo.testing.Refusals = .{};
refusals.begin();
defer refusals.end();

try testing.expectError(error.Failed, comment.edit(&db, &run, id, someone_else, "hi"));
const said = refusals.caught().?;
try testing.expectEqual(@as(u16, 409), said.status);
```

| | |
|---|---|
| `refusals.begin()` | install the slot. Not a constructor: what goes in the slot is this struct's address |
| `refusals.end()` | put back whatever was there. Safe twice, safe on one that never began |
| `refusals.caught()` | `?Refused` — `.status` and `.message`, or null if nothing refused |
| `refusals.clear()` | forget the last one, for a test that makes a second call |

`clear` between calls matters: without it the second assertion passes on the
first call's sentence, which is the one way a test like this goes quietly wrong.
`message` is borrowed from the `Refusals`, so it lives as long as that does.
This is a test type — the slot it installs is the Bulkhead's fallback, the one a
call made off the loop already uses, and a running server has a real slot per
fiber.
