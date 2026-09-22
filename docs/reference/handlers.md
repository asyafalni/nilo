# Handlers

One page of [the reference](./README.md): what a handler's arguments mean, what it may return, and how JSON is shaped.

## Handler arguments

| Argument | Passed in |
|---|---|
| `*Ctx` | the request itself |
| `*Db`, `*const Config` | a service, by type |
| `u32`, `f64`, `Str`, `bool`, an enum | a path param, positionally |
| a type with `nilo_parse` | a path param too — `sql.Uuid` is one |
| `Within(1, 200)` | a whole number inside a range; `.value` is the number |
| `Query(T)` | the query string as a struct |
| `FromHeader("X-Staff-Id", T)` | one request header, converted like a path param |
| `Authorization(.bearer)`, `Authorization(.{ .basic = "realm" })` | the `Authorization` header as one scheme — absent or another scheme is a 401 with the challenge on it |
| `Idempotent(Replays, .{ .by = fn })` | the `Idempotency-Key` header, and with it the route answering once per key: a retry gets the kept answer back and the handler does not run |
| `Cached(Pages, .{ .ttl_s = 60 })` | the answer kept for a minute under the path and query: the next request gets it back and the handler does not run. GET and HEAD only |
| `Form(T)` | the body as an HTML form — urlencoded or multipart |
| `Bound(W)` | any of the three above, with its failures instead of a 400 |
| `Session(T)` | the session, out of its cookie |
| `std.mem.Allocator` | the request arena |
| a type with `nilo_resolve` | a resolved value |
| any other struct | the body, parsed from JSON |

A body field may be `Patch(T)`, which tells "not sent" from "sent as null":
`.absent`, `.cleared`, `.value`. Give it `= .absent` as its default;
`.orNull()` collapses the two empty cases.

**A path param may also be a type that parses itself.** Give a type
`pub fn nilo_parse(text: []const u8) ?Self` and nilo calls it with the segment,
answering 400 when it returns null — so a malformed uuid is refused at the
router instead of in every handler. `sql.Uuid` already carries it:

<!-- compiles -->
```zig
fn showDoc(db: *Db, c: *nilo.Ctx, doc_id: sql.Uuid) !?Doc {
    return db.find(Doc, c, doc_id);
}
```

on `/docs/:doc_id` is the whole of it. What the document says about the param comes
from the type as well: a `Uuid` publishes `{"type":"string","format":"uuid"}`
through its `nilo_openapi`, so a generated client gets the format rather than a
bare string. The declaration is looked for by name and never imported, which is
what lets a module in the bottom layer offer it
([ADR 0142](../adr/0142-a-path-param-can-parse-itself.md)).

**A `Query(T)` or `Form(T)` field takes one too**, and for the same reason: one
arrival has one answer, so `/deals/:id` and `?actor=<uuid>` cannot read the same
type two different ways
([ADR 0158](../adr/0158-one-arrival-one-answer.md)). So a field is a `Str`, a
number, a `bool`, an enum, **or a type with `nilo_parse`** — `sql.Uuid` and
`sql.Timestamp` both are — optionally in a `?`, and a `Form(T)` field may also
be an `Upload`.

**A body field takes one as well** — the third arrival
([ADR 0205](../adr/0205-a-body-field-that-parses-itself.md)). `std.json` reads a
body, and it picks the reader by looking for `jsonParse` on the type; `sql.Uuid`
and `sql.Timestamp` carry one, and a `[]const sql.Uuid` reads a list of them. A
type of your own that parses itself writes one line beside `nilo_parse`:

```zig
pub const jsonParse = nilo.jsonParseFor(@This());
```

A body holding a type that parses itself and has no reader is a compile error
naming the route. The 400 for text the type refused quotes it back, the way a
query value's does — `"sku" has to be a Sku, not "abc"` — and a type that can
say more than its name says it with `pub const nilo_expects = "a ticket number
like T-1234"`, which every slot then asks for in those words.

**`Within(min, max)` is a whole number inside a range**
([ADR 0206](../adr/0206-a-whole-number-inside-a-range-is-a-type.md)): a type that
parses itself, so it is read wherever a `u8` is, refused outside the range with
`?limit has to be a whole number from 1 to 200, not "500"`, and described in
the document with `minimum` and `maximum`. The number is `.value`; the default
goes through `.of`, which checks it against the range while compiling:

<!-- compiles -->
```zig
const ListQuery = struct {
    limit: nilo.Within(1, 200) = .of(50),
    offset: u32 = 0,   // refuses -1 already, and the document says `minimum: 0`
};
```

**`Text(.{ .min, .max, .check, .said })` is text with a shape**, and
**`Email`** and **`Url`** are presets of it
([ADR 0264](../adr/0264-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)):
a `Str` that parses itself, read wherever a `Str` is, refused with one
sentence in every slot, and described with `minLength`, `maxLength` and
`format`. `min` and `max` count code points; `check` is a
`fn ([]const u8) bool` of your own and wants `said`, its sentence in `must`'s
shape, beside it. A `Text` never quotes the text back — `"password" has to be
text of 10 to 72 characters, not 7` — and the presets do. The `Str` is
`.value`, with `view`, `len`, `eql` and `blank` forwarded; `.of("…")` is the
default, checked against the shape while compiling. Bounds the wrong way
round, a `Text` with no bound and no check, a check with no `said`, and a
default outside the shape are each a compile error.

**`nilo_check` is a rule about the struct, on the struct** (the same ADR):
`pub fn nilo_check(self: T, r: *nilo.Rules(T)) void`, run once every field has
bound — in a form, a query string, a JSON body, and under `Bound` — with
`r.must(field, holds, sentence)` in the shape `Bound.must` has. On a plain
slot a rule that did not hold is a 422 naming every one that did not; under
`Bound` the sentences join the other failures. It is not run over a value
with a field that did not bind, takes nothing but the value, and is a compile
error if its shape is not that one.

<!-- compiles -->
```zig
const SignUp = struct {
    email: nilo.Email,
    password: nilo.Text(.{ .min = 10, .max = 72 }),
    confirm: Str,

    pub fn nilo_check(self: SignUp, r: *nilo.Rules(SignUp)) void {
        r.must("confirm", self.password.eql(self.confirm.view()), "has to match the password");
    }
};
```

`Form(T)` and a plain struct are the same slot — a form *is* the body — so
asking for both is a compile error. A `Form(T)` field is a `Str`, a number, a
`bool`, an enum or an `Upload`, optionally in a `?`; a default is what "not
sent" means. **A field that is a slice of one of those is a list**, one
element per arrival of the name — a checkbox group, a `<select multiple>` —
in the order sent; nothing sent is the empty list and never a 400, an empty
value contributes nothing, and a comma is data because a browser never
joins a group with one, so there is no second spelling as there is for a
query. A list of `Upload` is a Refusal. Under `Bound(Form(T))` the first
value that will not convert is the one reported and the rest are still read
([ADR 0256](../adr/0256-a-form-list-is-a-repeated-name-and-nothing-else.md)).
See [Forms](../guide/forms.md#a-checkbox-group-is-a-list).

### `FromHeader(name, T)`

One request header, as an argument the signature declares
([ADR 0163](../adr/0163-a-header-a-handler-can-be-given.md)):

<!-- compiles -->
```zig
fn addComment(
    actor: nilo.FromHeader("X-Staff-Id", sql.Uuid),
    tracing: nilo.FromHeader("X-Request-Id", ?Str),
) !usize {
    _ = actor.value;
    const asked = tracing.value orelse return 0;
    return asked.len();
}
```

`.value` is the header, converted the way a path param is: a `?T` is null when
the header is not sent, anything else is a 400 saying which header is required,
and text that will not convert is the same 400 in the same words. Two of them
on one handler is ordinary — unlike `Query(T)`, which is one struct.

`c.header("X-Staff-Id")` still reads it and is not going anywhere. What the
wrapper adds is the generated document: a header parameter, so a client built
from the OpenAPI knows the endpoint needs one. The name is checked while
compiling — empty, or anything that is not a header token, is a Refusal.

**`FromHeader` and not `Header`**: `nilo.Header` is the response side, and has
been since 0.2.0.

### `Authorization(scheme)`

The `Authorization` header, read as the one scheme the endpoint takes
([ADR 0191](../adr/0191-an-authorization-header-a-handler-can-ask-for.md)):

<!-- compiles -->
```zig
fn whose(auth: nilo.Authorization(.bearer), db: *sql.Db, c: *nilo.Ctx) !User {
    return try db.one(User, c, .{ .where = .{ .email = auth.value } }) orelse
        return nilo.Authorization(.bearer).refuse("that token is not one of ours", .{});
}

fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !nilo.Status(204, void) {
    if (!std.mem.eql(u8, auth.user.view(), "root")) {
        return nilo.Authorization(.{ .basic = "admin" }).refuse("not for {s}", .{auth.user.view()});
    }
    return .{};
}
```

| | |
|---|---|
| `.bearer` | `.value` is the token as sent — the bytes after the scheme, blanks trimmed, nothing decoded |
| `.{ .basic = "realm" }` | `.user` and `.password`, base64 opened and split at the **first** colon. The realm is required (RFC 7617) and is what the browser's prompt shows |
| `T.challenge` | the `WWW-Authenticate` value — `Bearer`, or `Basic realm="…"` |
| `T.refuse(fmt, args)` | `fail.unauthorized` with `T.challenge` on it — for the refusal *after* reading, when the token did not verify or the password did not match |
| `c.authorization(scheme)` | the same read from a resolver or a middleware, which have no argument list |

The scheme is matched case-insensitively (RFC 9110 §11.1), and **every 401
carries `WWW-Authenticate`** (§15.5.2) — the two things the hand-written six
lines got wrong in both places this repository had them. Absent, another
scheme, an empty token, Basic that is not base64 or has no colon: each is a
401 saying which, before the handler runs. In the document, a `security`
entry and a 401 rather than a parameter, so a generated client signs in.

Bearer allocates nothing; Basic decodes into the request arena, once. There is
no chain that also looks in the query string or a cookie, on purpose: a token
in a query string is a token in every access log on the way here.

### `Verified(V)`

The same header, verified: the claims behind a bearer token, read through
the `jwt.Verifier` the argument names, or a 401 with the challenge before
the handler runs
([ADR 0260](../adr/0260-verified-claims-are-a-handler-argument.md)):

<!-- compiles -->
```zig
const Claims = struct { sub: []const u8, email: []const u8 };
const Google = jwt.Verifier(Claims, fetch.Client);

fn me(user: nilo.Verified(Google), db: *sql.Db, c: *nilo.Ctx) !User {
    return try db.one(User, c, .{ .where = .{ .email = user.claims.email } }) orelse
        return nilo.Verified(Google).refuse("that account is closed", .{});
}
```

| | |
|---|---|
| `V` | a `jwt.Verifier(Claims, Client)` — the ring, the client its refresh needs and the claims type, held as one service ([`jwt.Verifier`](./jwt.md#jwtverifierclaims-client)). Provided like any other; `listen()` refuses to start without it |
| `.claims` | the payload as `Claims`, strings in the request arena |
| `.token` | the token as sent, for a handler that passes it on |
| `T.challenge` | `Bearer` |
| `T.refuse(fmt, args)` | `fail.unauthorized` with the challenge on it — for the refusal *after* verifying |
| `c.verified(V)` | the same read from a middleware guarding a prefix; a handler under it that asks again verifies again |

Absent, another scheme, or a token the ring refuses — expired, wrong
audience, unknown `kid` after one bounded fetch, bad signature — is a 401
with `WWW-Authenticate: Bearer` and the reason in the body. The issuer's
keys unreachable when a refresh was needed is a 503, since the token was
never judged. In the document, the bearer scheme and a 401. Costs what
`Authorization(.bearer)` plus one `verify` cost: the claims are the one
allocation, into the arena, and the signature check is the work.

### `Idempotent(Replays, options)`

The `Idempotency-Key` header, as the argument that makes a route answer once
per key ([ADR 0193](../adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)):

<!-- compiles -->
```zig
const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

fn account(c: *nilo.Ctx) ?Str {
    return c.header("X-Account");
}

const NewOrder = struct { sku: Str, qty: u32 };
const Placed = struct { id: u64, sku: Str };

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder) !nilo.Status(201, Placed) {
    _ = key;                                 // the header as sent, if the handler wants it
    return .{ .value = .{ .id = 7, .sku = body.sku } };
}
```

The first request with a key runs the handler and **keeps what it returned** —
status, the `Response(T)` headers of its own, the body. Every later request
with that key gets the kept answer back, byte for byte, with
`Idempotent-Replayed: true` on it, and the handler does not run. What the
handler *failed* with is not kept, so a retry after a `fail.…` or an error
runs it again.

| | |
|---|---|
| `Replays` | where answers are kept: a `cache.Space` holding `[]const u8`, `app.provide`d. Any type with `getInto`, `putIfAbsent`, `put`, `del`, `max_bytes` and `Held` will do, which is what a table over Redis would carry |
| `.by` | whose key it is — a function of one `*Ctx` answering `?Str`. Two callers choosing the same key must never see each other's answer, so leave it null only on an endpoint with one caller. Null from the function is a 403 |
| `.key` | the header as sent |

Before the handler runs, and each with the header named: **400** with no
`Idempotency-Key` or one over 255 bytes; **409** when the same key is still
being answered; **422** when the key is reused on a different request — the
method, path, query and body are fingerprinted. In the document, a required
header parameter and the two extra answers. A handler that returns nothing, a
file or a redirect has no answer nilo can keep, and is a Refusal.

On the route that asks, and nowhere else: one arena allocation of the
Space's `max_bytes` to read a kept answer into, one to encode the answer being
kept, and the JSON buffer the answer was taking anyway. Nothing on the stack.

### `Cached(Pages, options)`

A kept answer served again for a time, as the argument that makes a GET say
so in its signature
([ADR 0247](../adr/0247-a-route-can-say-cache-this-answer-for-a-minute.md)):

<!-- compiles -->
```zig
const Pages = cache.Space("pages", []const u8, .{ .max_bytes = 32 << 10 });

const Front = struct { headline: Str, stories: u32 };

fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 })) !Front {
    _ = page;                                // `.key` is what the answer is kept under
    return .{ .headline = .static("Selamat pagi"), .stories = 12 };
}
```

The first request runs the handler and **keeps what it returned** — status,
the `Response(T)` headers of its own, the body — under the path and the
query. Every request for the same inside `ttl_s` gets the kept answer back,
byte for byte, with `Cache-Status: nilo; hit` on it, and the handler does not
run; a fresh answer carries `Cache-Status: nilo; fwd=miss`. What the handler
*failed* with is not kept, so the next request runs it again.

| | |
|---|---|
| `Pages` | where answers are kept: a `cache.Space` holding `[]const u8`, `app.provide`d. Any type with `getInto`, `putIfAbsent`, `putFor`, `del`, `max_bytes` and `Held` will do. A service the route needs, so `listen()` names it when it is missing |
| `.ttl_s` | how long a kept answer is served, in seconds. No default, and 0 is a Refusal |
| `.by` | what the key is made of: `.path_and_query` (the default), `.path`, or `.{ .header = "Accept-Language" }` for the path, the query and one header's value. The query is taken as it arrived — `?a=1&b=2` and `?b=2&a=1` are two entries. `Cookie` and `Authorization` are refused as keys |
| `.key` | what the answer was kept under, as `Str` |

**A request that finds the answer still being made waits for it** rather than
being told 409: it reads again every 10 ms, for at most 2 s or half of what
`nilo.deadline(ms)` left the route, and past that runs the handler itself.
**GET and HEAD only** — `app.post(…)` and the rest refuse it while compiling,
and `app.route(.POST, …)` refuses it at registration with `error.CachedWrite`.
A handler that returns nothing, a file or a redirect has no answer nilo can
keep, and is a Refusal; so is one that takes an `Idempotent(…)` too.

Costs what `Idempotent` costs, on the route that asks and nowhere else — one
more arena allocation to join the path and the query when there is one.
Nothing on the stack.

### A query field that is a list

A `Query(T)` field may be a slice, and every arrival of that name is one
element ([ADR 0164](../adr/0164-a-query-parameter-that-is-a-list.md)):

<!-- compiles -->
```zig
const Filter = struct {
    tag: []const Str = &.{},
    limit: u32 = 20,
};

fn search(q: nilo.Query(Filter)) !usize {
    return q.value.tag.len;
}
```

**Both spellings are read**: `?tag=a&tag=b&tag=c` and `?tag=a,b,c` are the same
three elements, in the order they arrived, allocated from the request arena.
`?tag=a,b` is what nilo writes into the document — `"style":"form"`,
`"explode":false` — and `?tag=a&tag=b` is what half the clients in the world
send anyway; a server that takes the first and drops the rest answers with fewer
rows, which looks exactly like a filter that worked.

An empty value contributes nothing, so `?tag=` is an empty list rather than a
list holding one empty string — which is also why a list field wants `= &.{}`
rather than being required, and why it is never `required` in the document.
That is the cost of the separator: a value with a comma in it cannot be sent.

**"Not sent" and "sent empty" cannot be told apart**, and `?[]const Str` is not
the way out: it compiles, and it answers null for both. What an optional list
changes is only what *nothing* is spelled as — null instead of `&.{}` — not
which nothing it was. Every filter written against a list has so far meant the
same thing by either, which is why there is no second spelling for it.

The element converts exactly like a scalar field would, so `[]const Kind` for an
enum refuses `?kind=nope` with the same sentence a single `kind` gets, and under
`Bound(Query(T))` it is the **first** bad value that is reported. A list of
something a query value cannot become at all is a Refusal.

### `Bound(W)`

`Bound(Form(T))`, `Bound(Query(T))`, `Bound(T)` for a JSON body. Occupies the
same slot as what it wraps.

| | |
|---|---|
| `b.value()` | `?T` — the binding, or null if **any** field failed |
| `b.fail()` | a 422 naming every field that did not bind |
| `b.failed()`, `b.failedCount()` | whether, and how many |
| `b.failures()` | an iterator of `Failure` |
| `b.given("name")` | `Str` — the text that arrived, bound or not. Name checked while compiling |
| `b.must("name", holds, "wants …")` | a rule of your own, added to the same answer → `Checked` |
| `Bound(W).ok(value)` | a binding where everything bound, for a test calling the handler directly |

A `Failure` carries `field`, `reason`, `given`, `kind`, `expected`, `said`, and
`say(w)` — nilo's own sentence for it. `reason` is one of `.missing`,
`.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`, or
**null when the failure is a rule of yours**; that is the whole list, and it is
not a validator. Nothing is allocated per failed field. See
[Forms](../guide/forms.md#when-one-field-is-wrong-and-the-rest-are-fine)
and [ADR 0036](../adr/0036-a-binding-hands-its-failures-to-the-handler.md).

`must` returns a `Checked`, which has the same `value`, `failed`,
`failedCount`, `given`, `failures` and `fail`, and one more `must` to chain.
`holds` is the rule holding, not failing. A handler that checks no rules never
builds one and pays nothing
([ADR 0082](../adr/0082-a-rule-of-your-own-joins-the-answer.md)).

## Handler returns

| Returned | Response |
|---|---|
| `void` | 200, empty, no `Content-Type` |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, **404** when null |
| `Status(code, T)` | that status — and the API description names it |
| `Response(T)` | a status chosen at runtime; the description says `default` |
| `Redirect(code)` | that status and a `Location`, no body |
| `FileBody` | a file on disk, opened and sent without being held in memory |
| `Bytes` | bytes already in hand, under a content type chosen per request — somebody else's download passed on ([ADR 0212](../adr/0212-bytes-handed-on-are-an-answer.md)) |
| `Versioned(T)` | `T` under a weak `ETag` made from a `u64` the handler names; **304** with no body when `If-None-Match` carries it ([ADR 0258](../adr/0258-a-version-a-handler-names-is-an-etag.md)) |
| a type with `nilo_content_type` and `nilo_write` | 200, the bytes `nilo_write` wrote, under that content type — [below](#a-type-that-writes-its-own-answer) |

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
Redirect(303).to("/welcome")                               // written `return .to(…)`
Redirect(303).with("/welcome", .of(&.{…}))                 // …with headers of its own
FileBody{ .dir = files.dir, .name = name }                 // `?FileBody` — null is a 404
Bytes{ .body = got.body, .content_type = got.content_type } // `?Bytes` likewise; takes a wrapper's status
Versioned([]Order){ .version = revision, .value = orders }  // `W/"…"`; `.unchanged(revision)` when `c.clientHas(revision)`
```

**A handler that also takes a `*Ctx` and returns `void` is the one case the
document cannot describe.** It sends 200 with an empty body if the handler
wrote nothing, and whatever the handler wrote if it did, and nilo has no way to
tell which from the signature — so the description says it does not know, and
`listen()` says how many routes are in that state. A handler that means "200,
empty" says so by returning `Status(200, void)` and is described like anything
else ([ADR 0150](../adr/0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).

**A `?` goes inside a wrapper, never around it.** `Status(201, ?T)` and
`Response(?T)` are the value or a 404; `?Status(201, T)`, `?Response(T)`,
`?Redirect(code)` and `?Versioned(T)` are each a compile error naming the
shape to write, since the `?` is about the body and those have none for it
to be about ([ADR 0276](../adr/0276-a-question-mark-goes-inside-the-wrapper.md)).
The [guide](../guide/handlers.md#where-the--goes) has the two tables.

`Redirect` takes 301, 302, 303, 307 or 308; anything else is a compile error.
303 is the one a form POST wants.

`FileBody` fields: `dir` (a [`Dir`](./streaming.md#dir)), `name`, `content_type`
(`"application/octet-stream"`), `cache_control` (`""`) and `headers` — a
`Content-Disposition` goes in the last of those, and there is no `download_as`.
The name is checked before it is opened: a `..` segment, an absolute path, a NUL
— and on Windows a backslash or a drive letter — answer the same 404 a missing
file does. `Range`, `If-Range`, `If-None-Match` and `HEAD` work as they do for a
static file; the API description says the body is `application/octet-stream`
with `format: binary` whatever the content type is at run time. See
[Responses](../guide/responses.md#files).

`Bytes` fields: `body`, `content_type` (`"application/octet-stream"`) and
`headers`, the same way. Nothing is copied: the body is the handler's — the
request arena, or a response it still holds — and goes out as it is. The
document says `format: binary` for the reason it does for a `FileBody`: the
label is decided while the request runs, and a document that guessed
`application/zip` would be wrong the first time upstream sent something else.
It is the answer for a proxy that downloads from one service and hands the
bytes to the browser with *their* `Content-Type` and a `Content-Disposition`,
where a `*Ctx` handler calling `c.send` was undescribed.

`Versioned(T)` fields: `version` (a `u64`), `headers` and `value` (`?T` —
null is `.unchanged(version)`, the answer for a client `c.clientHas(version)`
said already holds it; `.unchangedWith(version, headers)` when the 304 should
carry the `Cache-Control` the 200 does). The tag is `W/"<hex>"`, weak because a version says
the representation is the same and nothing about the bytes; `headers` go out
on the 200 and the 304 both. `.unchanged` to a client that did not send the
version is a 500 naming the route. `Versioned(?T)`, `Versioned(void)`, a
`Versioned` inside a `Status` or a `Response`, and one under a `Cached` or an
`Idempotent` are each a compile error saying what to write instead; a thing
that is not there is `fail.notFound`. The document puts the `ETag` on the 200
and a `304` beside it. See
[Responses](../guide/responses.md#a-body-the-client-already-holds).

`Headers` holds up to 8 by value; a ninth is a compile error.

### A type that writes its own answer

XML for a consumer that will not change, CSV for a spreadsheet, HTML from a
template of your own: a type carrying two declarations goes out as whatever it
writes, under the label it names
([ADR 0195](../adr/0195-a-type-can-write-its-own-answer.md)).

<!-- compiles -->
```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";
    pub const nilo_openapi = .{ .type = "string" };

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(number: u32) ?Invoice {
    if (number == 0) return null;
    return .{ .number = number, .total = 1500 };
}
```

Every wrapper works the way it does for JSON: `?Invoice` is a 404 when null,
`Status(201, Invoice)` is a 201, `Response(Invoice)` carries headers, and an
`Idempotent` route keeps the answer with its label. The body is written into
the request arena the way a JSON one is — one allocation, the same one — and
nothing is linked by a program with no such type.

**Both declarations or neither.** One without the other is a compile error, and
so is an empty content type, one with a control character in it, or a
`nilo_write` with any other signature. The document names the content type and
describes the body with `nilo_openapi` when the type carries one — `{}` and a
note otherwise, the way a type that writes its own JSON is described. nilo
knows nothing about XML, CSV or HTML and does not parse any of them on the way
in; a body arriving in one of those is `c.body()`.

## JSON shapes

A struct is its fields and an enum is its tag name. A type that wants something
else says so with `nilo_json`, which is plain data and is read while compiling
([ADR 0085](../adr/0085-a-type-says-how-its-json-is-spelled.md)).

<!-- compiles -->
```zig
const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .@"kebab-case" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { threshold: f64 },
    log_volume: struct { query: []const u8 },
    disabled,
};
```

| | |
|---|---|
| `.tag` | the discriminator's key. A `union(enum)` only: the variant's name goes under it, and the variant's own fields go beside it in the same object |
| `.rename_all` | how a name is spelled on the wire — an enum's tag, a union's variant, or **a struct's field names** |
| `.rename` | the names spelled one at a time — `.{ .amount_minor = "amountMinor" }` — which win over `.rename_all` ([ADR 0207](../adr/0207-one-field-can-be-spelled-on-its-own.md)) |

`.rename_all` takes `.lowercase`, `.UPPERCASE`, `.camelCase`, `.PascalCase`,
`.SCREAMING_SNAKE_CASE` and `.@"kebab-case"`. The first two join the words
(`not_found` → `notfound`); `.SCREAMING_SNAKE_CASE` keeps the underscore. There
is no `.snake_case` — that is what a Zig field name already is, and asking for
it is a compile error rather than a no-op. Two names that land on one is also a
compile error, in every shape: it would put the same key in an object twice.

### A struct that renames its fields

A Row is snake_case because Postgres is and a wire is camelCase because the
browser is. Saying so once beats a mapping function written out field by field,
which is what a DTO layer is and which nothing holds against the Row it came from
([ADR 0181](../adr/0181-a-field-name-is-a-spelling-too.md)):

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description says the same keys, so a generated client reads what the
server sends. It costs nothing per request: the name is a comptime string either
way, written as part of the same call the punctuation is in.

**One field that no case reaches is spelled on its own**, beside the case, and
the entry wins ([ADR 0207](../adr/0207-one-field-can-be-spelled-on-its-own.md)):

<!-- compiles -->
```zig
const Summary = struct {
    pub const nilo_json = .{
        .rename_all = .camelCase,
        .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
    };

    id: u32,
    estimated_cost_amount_minor: i64,   // "estimatedCostMinor"
    due_at: []const u8,                 // "dueAt", by the case
};
```

An entry naming a field the struct does not have, one that spells a field as it
is already written, and one that lands on another field's key are each a
compile error.

**It is a spelling for what goes *out*, and using one for what comes in is a
Refusal.** `std.json` chooses the parser for a body and reads it into the field
names as they are written, so such a type would document `fullName` and answer
400 to a client that sent it. A struct with `rename_all` used as a request body,
a form or a query string is a compile error naming the route. Give what comes in
a struct of its own, spelled the way the wire spells it.

A renamed struct nilo's own writer cannot reach is refused as well. One shape it
does not recognise — a tuple, an array of bytes, an untagged union, a type that
writes its own JSON and says nothing about it, anything past eight deep — sends
the whole value to `std.json`, which does not read the marker.

**A type that writes its own JSON *and says what it looks like* is a leaf rather
than one of those**, and that is the difference between a marker that can be used
here and one that cannot
([ADR 0182](../adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)). A
`nilo_openapi` may only name `"string"`, `"integer"`, `"number"` or `"boolean"`,
so a type carrying one has promised its JSON is a single scalar — which is the
promise the writer needs to keep writing the object around it. `sql.Uuid`,
`sql.Timestamp`, `sql.AsText` and `id.Uuid` are all leaves, so a Row-shaped
response holding any of them can rename its fields:

```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: sql.Uuid,            // still "id", and still 36 characters
    full_name: nilo.Str,     // goes out as "fullName"
    created_at: sql.Timestamp,  // "createdAt", still RFC 3339
};
```

It is also worth 33% of such a response whether or not anything is renamed:
`covers` is answered for the *whole* value, so one leaf used to send every string
beside it to `std.json` as well — 250ns → 165ns on a 305-byte row with three
uuids in it ([`bench/result/http.md`](../../bench/result/http.md)). Your own type
gets the same by writing the same two declarations.

**The marker is per type, not inherited.** A struct renames its own fields; a
union renames its *variants* and leaves a payload struct's fields to that
struct's own marker; a nested struct that says nothing keeps its own spelling.

`nilo.jsonParseFor(@This())` is the reader, and it is a second line because
`std.json` picks the parser for a type and nothing can add a declaration to a
type you wrote. Only needed if the type arrives in a request; sending needs
nothing. On a type with `nilo_parse` it is the reader that hands the string to
that ([ADR 0205](../adr/0205-a-body-field-that-parses-itself.md)). Adding it to a
type with neither a `nilo_json` nor a `nilo_parse` is a compile error, and so is
adding it to a struct that only renames — there is nothing for the reader to do
differently.

Without a marker a `union(enum)` is externally tagged — `{"metrics":{…}}`, what
`std.json` writes — and it is written by nilo's own writer either way. An
*untagged* union has nothing saying which arm is live and is left to `std.json`
whole. A variant carrying no payload is legal under `.tag` and is the
discriminator on its own; under the default encoding it is not covered.

The generated API description follows whichever encoding the type asked for:
`oneOf` of one-key objects for the default, and `oneOf` with `discriminator`
plus a per-arm `allOf` for a tagged one. See
[Responses](../guide/responses.md#json-shapes-of-your-own).

**A `[]const u8` or a `Str` that is not valid UTF-8 goes out as an array of
byte values** — `{"name":[255]}` — because JSON has no way to carry a byte that
is not text. That is what `std.json` does with the same value, and this writer's
whole contract is to write what `std.json` writes
([ADR 0121](../adr/0121-a-byte-that-is-not-text-is-not-a-string.md)). The
description still calls the field a string, since the type is text and only the
value is not.
