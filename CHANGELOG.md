# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.3.0 does. Each entry says what you have to change; the
account of why is in the ADR it links.

One module, `nilo_job`, and the thirty-odd shapes a real port needed and found
missing — plus the fixes it found underneath them, two of which are the reason
`zig build test` runs on a Mac at all.

### New

- **`nilo_job` — a queue in the database you already have, and a schedule**
  ([ADR 0198](./docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md),
  [ADR 0199](./docs/adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)).
  The eleventh module, the second Fitting. A job is a struct: its fields are
  the payload, `run` is the work, every pointer after the Run is a service
  handed to `open`.

  ```zig
  const SendWelcome = struct {
      pub const nilo_job = "send-welcome";
      pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } };
      pub const schedule = job.cron("0 3 * * *");   // optional; then `overlap` and `missed` have no default
      pub const overlap: job.Overlap = .skip;       // or .queue
      pub const missed: job.Missed = .drop;         // or .catch_up

      user_id: u64,
      email: Str,

      pub fn run(self: SendWelcome, scope: *nilo.Run, mail: *Mailer) !void { … }
  };

  const Jobs = job.Jobs(.{ .kinds = .{ SendWelcome }, .store = job.Table(sql.Db), .deps = struct { mail: *Mailer } });
  ```

  `jobs.push(c, …, .{})`; `jobs.pushIn(&tx, c, …)` inside the transaction that
  made the work; `.after_ms`, `.at`, `.unique`. `Jobs.Row` goes in
  `db.checking` and the migration; servers share it through `FOR UPDATE SKIP
  LOCKED`, a dead worker's row comes back when its lease ends, a failed `run`
  retries as the job said and is then dead. **At least once** — write `run` so
  running it twice is safe. `job.Memory` is the same contract in-process;
  `jobs.drain(&run)` runs everything due on the calling thread, which is the
  whole of a test. `app.provide(&jobs)` + `app.spawn(Jobs.serve, .{&jobs})`
  under a server, `jobs.serveOn(io)` for a worker process. Twelve refusals,
  [`docs/guide/jobs.md`](./docs/guide/jobs.md). Nothing changes for a program
  that does not import it.

- **`c.routeName()` — the `operationId` of the route that matched**
  ([ADR 0201](./docs/adr/0201-a-middleware-can-learn-which-route-it-is-in-front-of.md)).
  What `app.named` gave it, or the derived `getUsersId`, exactly as the document
  prints it — so an authorisation middleware can hold one table against the
  document. Null for a 404, a 405 and a static file. `app.routes().at(i).name`
  is the same word. Eight bytes on a `Ctx`, one allocation per unnamed route at
  boot.

- **`app.named("auth-login")` compiles**
  ([ADR 0200](./docs/adr/0200-a-hyphen-is-a-spelling-a-generator-can-carry.md)).
  A name may hold `-`; a space, a dot and a leading digit are still refused.

- **`nilo.Bytes` — bytes already in hand, under a content type chosen per
  request** ([ADR 0212](./docs/adr/0212-bytes-handed-on-are-an-answer.md)).
  A proxy handing on another service's download with *its* `Content-Type` and
  a `Content-Disposition` had no typed answer and took a `*Ctx`, which the
  document could not see. `!?nilo.Bytes` is `FileBody`'s shape with the bytes
  in memory: `.body`, `.content_type`, `.headers`; `?` is the 404, a wrapper's
  status is taken, nothing is copied, and the document says `format: binary`.
  One refusal.

- **`fetch` sends what it was given, whatever the method**
  ([ADR 0213](./docs/adr/0213-the-body-decides-not-the-method.md)). A DELETE
  with a body and a PATCH without one each tripped an assert inside
  `std.http.Client` — a panic in a worker thread. Now a body given is sent
  under its `content-length` on any method, and none given is `content-length:
  0` on a method std expects one from. `client.patch(c, url, body_or_null,
  .{})` beside the other four; `error.HeadTooLong` for the one head the trick
  cannot frame.

- **`.across` — one condition over several columns, and one parameter**
  ([ADR 0211](./docs/adr/0211-one-condition-over-several-columns-is-one-parameter.md)).
  A search box over the code, the name and the trademark beside a handful of
  `sql.given` filters was two `db.select` calls, because a `sql.given` inside
  `.any` is refused. `.across = .{ .columns = .{ .code, .name, .trademark },
  .icontains = sql.given(q) }` is one: the parameter is taken once and named
  on every column, and the `sql.given` guards the whole bracket the way it
  does in `.exists`. The operators are a column's own; the columns have to
  read as one Zig type. `across` is a reserved column name now, beside `any`
  and `exists`. Four refusals.

- **`sql.Ordering(Row, keys)` — an `ORDER BY` chosen per request, from a
  closed set declared while compiling**
  ([ADR 0204](./docs/adr/0204-an-order-chosen-at-run-time-from-a-closed-set.md)).

  ```zig
  const Sort = sql.Ordering(Commitment, .{
      .due = .{ .column = .due_at, .nulls = .last },
      .title = .title,
      .value = "c.value_currency, c.value_minor",   // your own SQL, for db.rawOrdered
  });
  // q: nilo.Query(struct { order: Sort = Sort.by(&.{.{ .key = .due }}) })
  // db.page(Commitment, c, .{ .order = q.value.order, .limit = 20 })
  ```

  `?order=due:desc,title` reads into the field; an undeclared key is a 400
  naming the declared ones. Column keys order `select`, `one`, `page` and
  `stream`; an expression key is for `db.rawOrdered`, which fills `{order}`.
  No run-time string reaches the statement. Costs the plan name (runs unnamed,
  ADR 0057's 12 µs) and one arena allocation. Four refusals.

- **`nilo.Within(min, max)` — a whole number inside a range, as a type**
  ([ADR 0206](./docs/adr/0206-a-whole-number-inside-a-range-is-a-type.md)).
  `limit: nilo.Within(1, 200) = .of(50)`: out of range is a 400 naming the
  range, the document says `minimum`/`maximum`, `.value` is the number. Read
  wherever a `u8` is. Two refusals.

- **A body field that parses itself is read from the text a response writes**
  ([ADR 0205](./docs/adr/0205-a-body-field-that-parses-itself.md)).
  `sql.Uuid` and `sql.Timestamp` in a JSON body went to `std.json` as the
  structs they are; they carry `jsonParse` now. A type of your own writes
  `pub const jsonParse = nilo.jsonParseFor(@This());` beside `nilo_parse` —
  forgetting it is refused. The 400 quotes what arrived; `pub const
  nilo_expects = "…"` says what was wanted. The document describes the field
  as the type said (`format: uuid`).

- **`.rename = .{ .field = "spelling" }` — one field spelled on its own**
  ([ADR 0207](./docs/adr/0207-one-field-can-be-spelled-on-its-own.md)).
  Beside `rename_all` in `nilo_json`; the entry wins. Enum values and union
  variants too. A missing field, a no-op spelling and a collision are refused.

- **`app.health("/healthz")` — a page that asks the services**
  ([ADR 0192](./docs/adr/0192-a-health-route-asks-the-services.md)).
  `200 {"status":"ok"}`; `503` naming each service not ready and why; `503
  {"status":"stopping"}` once the server was told to stop. A service joins
  with `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8`
  — null is ready. `sql.Db` sends `SELECT 1`; an `s3` Store answers whether it
  started. `c.stopping()` is public. One refusal.

- **`nilo.Idempotent(Replays, .{ .by = account })` — a route answering once per
  `Idempotency-Key`**
  ([ADR 0193](./docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).

  ```zig
  const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

  fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
  ```

  The first request runs and is kept; a retry gets it back byte for byte with
  `Idempotent-Replayed: true`. No key is a 400, still running a 409, reused on
  a different request a 422. A failure is not kept. `Replays` is a bytes Space
  provided as a service. Four refusals;
  [Answering once](./docs/guide/idempotency.md).

- **`nilo.Authorization(.bearer)` and `nilo.Authorization(.{ .basic = "realm" })`**
  ([ADR 0191](./docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).
  The header as a typed argument; absent or another scheme is a 401 carrying
  the `WWW-Authenticate` challenge. `auth.value` for Bearer; `auth.user` and
  `auth.password` for Basic. `T.refuse("…", .{})` is the same 401 after
  reading; `c.authorization(.bearer)` from a resolver. A `security` entry in
  the document. Two refusals.

- **`nilo.FromHeader("X-Staff-Id", T)` — one request header as a typed argument**
  ([ADR 0163](./docs/adr/0163-a-header-a-handler-can-be-given.md)). Converted
  like `Query(T)` and written into the document. Absent is null for a `?T`,
  else a 400 naming the header.

- **`nilo.maxBody(bytes)` — how much body a route takes**
  ([ADR 0194](./docs/adr/0194-a-route-can-say-how-much-body-it-takes.md)).
  A middleware on `with`, like `nilo.deadline(ms)`. Bounds every read into the
  arena, not `c.bodyStream()`. `maxBody(0)` is a compile error;
  `c.giveBodyLimit(bytes)` from a middleware of your own.

- **`listen(.{ .max_in_flight = 256 })` — past its limit a server says so at once**
  ([ADR 0197](./docs/adr/0197-a-server-past-its-limit-says-so-at-once.md)).
  A `503` with `Retry-After: 1` and `Connection: close` before routing. Off by
  default. Counted as `<shed>` on the metrics page; pick the number from
  `nilo_requests_in_flight`. Requests, not connections.

- **A type can write its own answer**
  ([ADR 0195](./docs/adr/0195-a-type-can-write-its-own-answer.md)).
  `pub const nilo_content_type = "application/xml";` and `pub fn nilo_write(self:
  T, w: *std.Io.Writer) !void`, returned from a handler in any wrapper. The
  document names the content type and uses the type's `nilo_openapi`. Five
  refusals. nilo does not reflect a struct into XML —
  [Not coming](./docs/roadmap.md#not-coming) says why.

- **`app.writeOpenApi(w)` — the document, with no server**
  ([ADR 0167](./docs/adr/0167-the-document-is-a-build-artefact.md)). After the
  routes, before `listen`: no port, no database, so `zig build openapi >
  openapi.json` is a build step. The served copy goes through the same call.

- **A query parameter can be a list**
  ([ADR 0164](./docs/adr/0164-a-query-parameter-that-is-a-list.md)).
  `tag: []const Str = &.{}` in a `Query(T)`, any element type a query value can
  be. Both `?tag=a,b` and `?tag=a&tag=b` are read; the document says `style:
  form, explode: false`. Absent is the empty list, never `required`.

- **A `Query(T)` or `Form(T)` field can be a type that parses itself**
  ([ADR 0158](./docs/adr/0158-one-arrival-one-answer.md)). `?actor=<uuid>`
  into a `sql.Uuid` works.

- **`rename_all` spells field names too**
  ([ADR 0181](./docs/adr/0181-a-field-name-is-a-spelling-too.md)).
  `pub const nilo_json = .{ .rename_all = .camelCase };` — `full_name` goes out
  as `fullName`, the document agrees, nothing per request. **Output only**: a
  renamed struct used as a body, form or query is a compile error naming the
  route — give what comes in a struct of its own. A renamed struct the writer
  cannot reach (a tuple, a byte array, an untagged union, its own
  `jsonStringify`, past eight deep) is refused too.

- **A type with `jsonStringify` *and* `nilo_openapi` is a leaf, not a wall**
  ([ADR 0182](./docs/adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)).
  One `sql.Uuid` in a response used to send the whole struct to `std.json`;
  now the leaf goes and the rest stays on the fast path — 250ns → 165ns on a
  305-byte row with three uuids ([`bench/result/http.md`](./bench/result/http.md)).
  `jsonStringify` with no `nilo_openapi` is still refused under `rename_all`.

- **A `sql.Json(T)` in a response is written and described as the `T` it holds**
  ([ADR 0202](./docs/adr/0202-a-document-is-its-value.md)). A type declaring
  `nilo_json_of = T` beside `value: T` is written as its value, and the
  document says `T` where it said `{}`. One refusal.

- **`scope.resolve(T)` on a `*Ctx` and a `*Run`**
  ([ADR 0165](./docs/adr/0165-a-value-that-reaches-the-bottom.md)). A resolved
  value reaches the bottom of the call stack. Under a request it is the declared
  resolver; a `Run` is told once with `run.give(T, …)` and answers
  `error.NotGiven` otherwise. Not `c.locals`; ADR 0016 stands.

- **`nilo.AnyScope` — a Scope that crosses a function pointer**
  ([ADR 0177](./docs/adr/0177-a-scope-that-crosses-a-function-pointer.md)).
  `var erased = nilo.AnyScope.of(c);` — or `.of(&run)` — passes the Scope
  check. The ordinary Scope is unchanged.

- **`nilo.Run.initIo(gpa, io)` can mint a key**
  ([ADR 0160](./docs/adr/0160-a-scope-that-can-mint-a-key.md)). `entropy`
  works on a `Run`; `Run.init(gpa)` answers `error.NoIo`.

- **`id.v7Now(scope)`, and a `Uuid` prints with `{f}`**
  ([ADR 0176](./docs/adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)).
  One call for `id.v7(try c.entropy(…), @intCast(nilo.nowMillis()))`;
  `id.v7(entropy, ms)` stays. `fail.notFound("partner {f} not found", .{id})`.

- **`entropyInto(buf)` on `Ctx` and `Run`**
  ([ADR 0166](./docs/adr/0166-entropy-a-function-pointer-can-carry.md)).
  `entropy` with the width at run time, so a function pointer can carry it.

- **`Str.blank()` and `Str.trimmed()`**
  ([ADR 0175](./docs/adr/0175-required-text-arrives-as-two-spaces.md)). The
  set is `std.ascii.whitespace`; a read of the bytes, not a validation rule.

- **`nilo_sql`: six widenings a listing page needed.** All comptime string
  concatenation; nothing on ADR 0018's axes.

  - **`contains`, `starts_with`, `ends_with`, their folding (`icontains`) and
    negated spellings**
    ([ADR 0173](./docs/adr/0173-the-database-escapes-the-pattern-it-is-going-to-match.md)).
    **Change your search boxes**: `.like` never escaped `%` and `_`; these
    build and escape the pattern inside the statement. `contains` on SQLite is
    a Refusal naming the dialect; `icontains` is what that database does.
  - **A key can span several columns**
    ([ADR 0172](./docs/adr/0172-a-key-is-as-many-columns-as-it-takes.md)).
    `.key = .{ .tenant_id, .id }`; `db.find` takes a struct naming each.
    **Breaking**: `Desc.key` became `Desc.keys`, so an older `.zon` snapshot no
    longer parses — `db generate` rewrites it.
  - **`.exists` and `.not_exists`**
    ([ADR 0171](./docs/adr/0171-a-row-over-there-is-a-condition.md)).
    `.where = .{ .exists = .{ .{ .in = PartnerCapability, .where = .{ .capability = cap } } } }`;
    the join comes from the child Row's `.references`. Both are reserved column
    names now, beside `any`.
  - **`sql.Bytes` — a `bytea` and a `BLOB`**
    ([ADR 0174](./docs/adr/0174-bytes-are-a-type-not-a-second-protocol.md)).
    `sql.AsText("bytea")` still works and costs a hex conversion each way.
  - **`.set = .{ .views = .{ .plus = 1 } }`** — atomic arithmetic on the
    column's own value. `plus` and `minus`, on a number; a nullable column is a
    Refusal.
  - **`.order = .{ .rank = .asc_nulls_last }`** and its three siblings.
    `.asc`/`.desc` still mean the database's own default, so nothing you wrote
    changes.

- **`sql.given(x)` — a filter that is absent is not a filter that is null**
  ([ADR 0183](./docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
  `.name = .{ .icontains = sql.given(filter.search) }` compiles to
  `("name" ILIKE '%' || $1 || '%' OR $1 IS NULL)`: one statement and one plan
  however the screen is set. Inside `.exists` it drops the whole subquery.
  Refused beside a fixed condition in the same `.exists`, inside `.any`, on
  `.in`, on `not_distinct_from`, on a non-optional, and in an `UPDATE` or
  `DELETE`.

- **`db.page` — a page and its total in one statement**
  ([ADR 0185](./docs/adr/0185-a-page-knows-what-it-left-out.md)).
  `db.page(Order, c, .{ .where = …, .order = .{ .id = .asc }, .limit = 20, .offset = … })`
  answers `.rows` and `.total` from one `count(*) OVER ()`, so the two cannot
  drift apart. `.limit` and `.order` are required, `.lock` is refused;
  `tx.page` too. With `sql.given` this is the ordinary list endpoint.

- **`db.rawOne` and `db.updateReturningOne`**
  ([ADR 0179](./docs/adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
  `!?T`, a 404 in the typed layer; on a `Tx` too. `rawOne` adds no `LIMIT 1`.

- **`.key` as a conflict target**
  ([ADR 0186](./docs/adr/0186-a-key-is-named-once.md)).
  `tx.insertOrIgnore(rows.StaffRole, c, row, .key)` — the Row's own key, so it
  cannot drift from the call site. A Row with a column called `key` is refused.

- **Three constraint errors named, and `sql.problem(c)`**
  ([ADR 0184](./docs/adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)).
  **Breaking if you catch `error.ConstraintViolated`**: `23503` is
  `error.ForeignKeyViolated`, `23502` is `error.NotNullViolated`, `23514` is
  `error.CheckViolated`; `error.AlreadyExists` is unchanged.
  `ForeignKeyViolated` has no default status — a 409 or a 400 depending on the
  call. `sql.problem(c)` in the `catch` says which index fired; it is bound to
  the fiber and cleared by every statement.

- **`pub const nilo_table = .projection;` — a Row that owns no table**
  ([ADR 0155](./docs/adr/0155-a-row-that-owns-no-table.md)). For `db.raw`;
  everything that writes its own SQL refuses it by name, `db.checking`
  included.

- **`.managed = false` — a table this program reads and does not build**
  ([ADR 0162](./docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
  `pub const nilo_table = .{ .name = "staff", .managed = false };` — `plan`,
  `createMissing` and `generate` skip it; `db.checking` still holds it.

- **`sql.Timestamp` reads RFC 3339 back**
  ([ADR 0159](./docs/adr/0159-what-a-server-prints-it-can-read.md)). An offset
  and fractional seconds are accepted; no zone is refused.

- **`nilo_cache`: `space.putIfAbsent(key, value)` and `space.getInto(key, buf)`.**
  Store only if the key is free, under one shard lock; read into a buffer of
  your own. `put` is unchanged.

- **`nilo.testing.show(value)`**
  ([ADR 0169](./docs/adr/0169-a-failed-assertion-that-can-be-read.md)).
  Renders as JSON under `{f}`, allocating nothing:
  `errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});`.

- **`answer.json(T, arena)` and `nilo.testing.Wired`**
  ([ADR 0180](./docs/adr/0180-a-response-is-read-back-the-way-it-was-written.md)).
  De-chunks and reads the body the way it was written; unknown fields are
  ignored. `Wired` holds an `App` and a `Client`; `wired.app` is a plain field.

- **`nilo.testing.Refusals`**
  ([ADR 0161](./docs/adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)).
  A fail function's status and sentence with no request in flight.

### Read this before deploying

- **`error.ConstraintViolated` is three errors now** — `ForeignKeyViolated`,
  `NotNullViolated`, `CheckViolated`; `AlreadyExists` is unchanged. A `catch`
  naming the old word for a foreign key has to name the new one.
- **Every `nilo_fetch` call under a request sends `X-Request-Id`.** A service
  that rejects unknown headers gets
  `fetch.Client.Settings.forward_request_id = false`.
- **`nilo_cache` forgets differently.** An entry earns its place by a second
  read, so a cache written and never read holds its first entries; `shards`
  defaults to 64. Eight threads 29–50% faster, one thread 8–10% slower.
- **A `Db` that cannot dial logs `warn`, not `err`.** A CI step grepping the
  log for `err` sees nothing now.

`max_in_flight` and `nilo.maxBody` are off until asked for; `app.health` and
`nilo.Idempotent` are routes and arguments you add. Nothing else above changes
an answer a client gets.

### Changed

- **`answer.text`, `.bytes` and `.json` refuse a stale answer with
  `error.AnswerStale`**
  ([ADR 0210](./docs/adr/0210-an-answer-knows-which-request-it-was.md)).
  `Answer.body` borrows the client's response buffer and the next request
  writes over it, while `.status` is a value — so a test could read one
  answer's status and another's body. Each answer now knows which request it
  was; read the body before the next request on that client, or copy it with
  `.json`/`.bytes` first. `.raw`, `.head`, `.body` and the header readers
  still borrow.

- **`openapi.write` takes an allocator**, because the document's named shapes
  are a list that grows rather than an array of sixty-four
  ([ADR 0209](./docs/adr/0209-a-document-names-every-shape-it-has.md)). Past
  sixty-four a shape was written out in place and a generated client lost its
  name. `app.writeOpenApi(w)` is unchanged.

- **An unsigned integer in the document says `minimum: 0`**
  ([ADR 0206](./docs/adr/0206-a-whole-number-inside-a-range-is-a-type.md)),
  in a path param, a query field and a body. A byte-for-byte document test has
  one more key.

- **A `Db` that cannot dial warns rather than errs**
  ([ADR 0178](./docs/adr/0178-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)).
  The test runner counts a logged `err` as a failure. pg.zig's own `err` is
  turned down with `std.testing.log_level`; `std_options` in a tested file is
  never consulted.

- **Every `nilo_fetch` call under a request sends `X-Request-Id`**
  ([ADR 0196](./docs/adr/0196-a-request-id-goes-out-with-the-call.md)). A
  `nilo.Run` sends nothing; `nilo.AnyScope` carries it as
  `erased.requestId()`. `Settings.forward_request_id = false` sends none, a
  call naming its own keeps it, `Exchange.begin` is untouched. One arena bump
  only on a call that passes headers of its own.

- **`nilo_cache` reads without taking the shard lock**
  ([ADR 0188](./docs/adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)):
  13% faster on eight threads, unchanged on one. `Stats.evicted` also counts a
  read a `put` overwrote mid-copy; `Store.stats()` is a sum over a moving
  target.

- **`cache.Options.shards` defaults to 64**
  ([ADR 0187](./docs/adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)):
  87.4M → 125.0M ops/s at nine reads to a write on eight cores; 5% on one
  thread.

- **`nilo_cache` admits an entry on its second read** (same ADR). Hit rate
  67.0% → 75.6% at 512 KiB on Zipf 0.99 — 2–3× less memory for the same rate.
  A cache written and never read holds its first entries.

- **The table takes a sixth of `.bytes`**, not a quarter: same entries, same
  hit rate, 7.5% faster on one thread. Set `.entries` if the split is wrong.

- **`cache.Stats.rescued`**: entries a read moved out of the write cursor's
  way. Zero means the policy is doing nothing.

- **All of it together**: one thread 8–10% slower, eight threads 29–50% faster
  — 135M reads/s against freecache's 47M and bigcache's 52M, at 64 bytes an
  entry against 132 and 149 ([`bench/result/cache.md`](./bench/result/cache.md)).

### Fixed

- **`insert`, `insertMany`, `updateMany` and the upserts compile on a Row as
  wide as a real table**
  ([ADR 0208](./docs/adr/0208-a-statement-pays-for-the-width-of-its-row.md)).
  Seventeen columns written on a twenty-column Row ran out of comptime
  branches inside nilo, where a caller cannot raise them. Every statement
  builder sizes its own budget now, the way `ddl.zig` does; a comptime test
  and a live one hold it at that width.

- **A text column type set into a nullable column from a non-optional value**
  ([ADR 0203](./docs/adr/0203-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md)).
  `.set = .{ .due_date = due }` with `due: Date` into `?Date` was a type error
  inside `forWire`. `@as(?Date, due)` can go.

- **`sql.given` runs on Postgres**
  ([ADR 0183](./docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md),
  amended). `($1 IS NULL OR …)` was `42P08` on every guard, because pg.zig
  sends no parameter types; the term comes first now. A live test per shape.

- **`rename_all` on a struct ten fields wide compiles**
  ([ADR 0157](./docs/adr/0157-a-check-pays-for-its-own-branches.md)). The
  collision check blew the branch quota; it sizes its own now. Delete the DTO
  you kept for the wide ones.

- **`sql.Bytes` can be written to Postgres, not only read.** Every bind was
  `error.CannotBindStruct` from pg.zig; both Wires open it now, a batch binds
  as `bytea[]`. Delete the `::bytea` raw statements.

- **`nilo_cache` could hand a lookup another key's bytes on ARM**
  ([ADR 0190](./docs/adr/0190-an-ordering-is-proved-on-the-processor-that-runs-it.md)).
  The lock-free read's proof held the compiler and not the hardware. A
  load-load barrier on aarch64, and the writer moves the cursor with a swap.
  No cost measured; x86 unchanged.

- **`nilo_cache` compiles on macOS.** `CLOCK_MONOTONIC_COARSE` is Linux-only;
  Darwin gets `MONOTONIC_RAW_APPROX`, anywhere else `MONOTONIC`.

- **`zig build test` on Apple Silicon no longer runs out of memory**
  ([ADR 0189](./docs/adr/0189-a-backend-is-trusted-where-it-was-measured.md)).
  The self-hosted backend took a compile past 15 GB on aarch64; it is named
  only on x86_64 now. nilo's own suite; nothing for a dependent.

- **A `db.raw` reading a text column got the wire format and kept it**
  ([ADR 0154](./docs/adr/0154-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
  A `date` came back as four characters, silently — `Decimal` too. A compile
  error now. **Cast the column**: `total::text AS "total"` on Postgres,
  `CAST(total AS TEXT)` on SQLite. A bare column and a `*` are refused; any
  expression is left alone.

- **`[]const Str` as a `db.raw` parameter**
  ([ADR 0156](./docs/adr/0156-a-list-of-str-is-a-parameter-too.md)).
  Documented, and stopped inside nilo. Works.

- **Sixteen `named` routes on one group exceeded the branch budget**
  ([ADR 0157](./docs/adr/0157-a-check-pays-for-its-own-branches.md)). Delete
  the `@setEvalBranchQuota` you added to get round it.

- **A shard count clamped off a power of two made part of `nilo_cache`'s
  budget unreachable**
  ([ADR 0187](./docs/adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)).
  Up to 78% at 192 KiB with 64 shards, and `bytesHeld()` counted it. The clamp
  floors to a power of two; a test holds it.

### Documentation

- **Every module has a guide page** under [`docs/guide/`](./docs/guide/);
  `nilo_fetch`, `nilo_s3`, `nilo_cache`, `nilo_jwt` and `nilo_id` were
  reference-only.
- **The SQL guide is a folder**, [`docs/guide/sql/`](./docs/guide/sql/README.md),
  nine pages; a link to the old path lands on the front page.
- **Five places the guide disagreed with itself are settled** — cookies
  against sessions, the handlers page's tables, the errors page's status
  table, the testing page's timings, `c.streamWith`'s arity. The badges say
  231 refusals and 190 decisions.
- **A v7 is not ordered inside one millisecond**, and the reference says so
  where a reader meets it first.
- **The transaction type is `sql.Db.Tx`**; `sql.Tx` never existed.

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
