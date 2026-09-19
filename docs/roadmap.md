# Roadmap

What is next, what is known and waiting for somebody to need it, and what nobody has decided. Nothing else. Once something is built its entry leaves this file: what shipped is in [`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in [`history.md`](./history.md), and the decisions that are binding are in [`adr/`](./adr/). What nilo has decided *not* to do, and the questions that have been answered so they are not asked again, are in [`decided.md`](./decided.md). The risks that have no mechanism under them yet are in [`risks.md`](./risks.md#open).

What this document is measured against is [ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md): **the signature is the whole contract**, on a server whose memory you can put a number on. A feature that does not serve one of those two is not automatically refused, but it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it is the part to read before adding to it.

## How to read this

Five sections, and an entry is in exactly one of them by what it is waiting for:

| Section | What is in it | Ends with |
|---|---|---|
| [**Next**](#next) | work somebody could start. The mechanism is known; what is missing is a decision, and the entry says which | `Needs:` the decision |
| [**Known, waiting for a caller**](#known-waiting-for-a-caller) | the design is known and nobody has needed it yet. Bring the use case, not the patch | `Needs:` the caller |
| [**Open questions**](#open-questions) | a question nobody has answered. Not a backlog item | `What would settle it:` |
| [**Measurements outstanding**](#measurements-outstanding) | a decision waiting on a number, and the run that would produce it | the table's last column |
| [**Waiting on upstream**](#waiting-on-upstream) | the change is in somebody else's repository, with the pin it was last checked at | the table's last column |

Inside the first three, entries are grouped by module, because **two modules touch no file in common** ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)): two entries under different modules can be worked at the same time, by two people or by one person on two days.

**A `Waiting on upstream` row is the line to distrust.** This repository has been wrong about a blocker five times, and four of those were somebody else's code that turned out to already do the thing ([history](./history.md)) — the latest being the standard library it pins, which had been reading a bound port back the whole time. Nothing downstream ever re-tests a blocker, so re-test it before repeating it.

**0.5.0 needs Zig 0.16.** The latest stable release only, on one branch: the people this is aimed at download Zig, run `zig build`, and give up if it fails, and they are not going to go hunting for the right branch. Every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

---

## Next

### `nilo_pw`

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything under 7 MiB, which is OWASP's weakest published configuration. But that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib * passes` would catch it, and would also refuse this repository's own test Cost, which is how the suite affords two optimize modes ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**Needs:** a way of being cheap in a test suite that is not also a way of being cheap in production.

**A password longer than a page costs what it is.** Argon2 hashes the whole input, so a client posting a megabyte gets a megabyte hashed. `max_body` bounds it at one megabyte by default and the Gate bounds how many at once, so it is not an opening. But everybody else truncates at 72 bytes or pre-hashes with SHA-512, and nilo does neither.

**Needs:** which of the two.

### `nilo_cache`

**There is no `getOrPut`.** Every caller writes the miss, the compute and the put, which is three lines rather than one and, more to the point, lets two threads compute the same value at once. A cache stampede is a real thing and this module has no answer to it. Holding the lock across the caller's computation is the one thing this module may never do ([ADR 0138](./adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)), so the shape that fits is a claim rather than a lock: `putIfAbsent` a marker, and whoever got it computes while everybody else either computes too or waits *outside this module*, where there is an `Io` to wait on. That is what `nilo.Idempotent`'s `in_flight` marker already does for a POST, and the route cache in `nilo_http` is where a GET would get the same.

**Needs:** whether a `getOrPut` with no `Io` should exist at all, or whether the answer is "the module hands out the claim and the layer with a loop does the waiting".

**Counting a read costs 4.2% on eight threads and 7.0% on one.** The increment has to be atomic now that a read holds no lock, and there is no cheaper exact version: per-thread counter lanes were built with a thread-local and with a lane hashed off the stack address, and measured 1.5% better on eight threads and 3% worse on one ([`bench/result/cache.md`](../bench/result/cache.md)). quick_cache's answer is to put its counters behind a cargo feature that is off by default. Doing the same here is a build flag and a documented default, not a measurement.

**Needs:** whether `Stats` may be absent.

### `nilo_job`

**A schedule is UTC.** `0 3 * * *` is three in the morning in Greenwich, and a program in Jakarta writes `0 20 * * *` with a comment. A time zone is a table of rules that changes twice a year and a dependency to carry it.

**Needs:** tzdata without a dependency, or a caller for whom the comment is not enough.

### `nilo_http`

**A response body is never compressed, and only a held file is.** Static files under the spill threshold are gzipped once while the App is built, which is the shape that costs nothing per request ([static files](./guide/static-files.md#compression)). A file over it is opened per request and so has no "once" to be compressed in ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)), and a handler returning JSON gets no such thing either. A deflate compressor needs a 64 KB window, so one per connection would multiply the 4,669 bytes an idle connection holds, and one per request would break the allocation budget ([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). **The shape that fits is a pool of compressors sized to the thread count rather than the connection count**: four cores, 256 KB, and a request borrows one for as long as it is writing. The inbound direction closed without the pool ([ADR 0251](./adr/0251-a-gzipped-body-is-inflated-into-the-buffer-that-holds-it.md)); what is left inbound is `c.bodyStream()`, which has no buffer to be the window, and every coding but gzip.

**Needs:** what happens when the pool is empty, what it does to a stream, and what it does to SSE, which is the one thing that must never be buffered. A proxy in front does this today and does it well, in both directions.

**A handler that reads a body nilo does not know takes a `*Ctx`, and the document says nothing about it.** [ADR 0195](./adr/0195-a-type-can-write-its-own-answer.md) closed this on the way out: a type carrying `nilo_content_type` and `nilo_write` goes out as whatever it writes, under its own label, and the description names it. On the way in there is no third answer yet — a body is JSON, a form, or `c.body()` — so a route receiving protobuf, MsgPack or a vendor's binary takes a `*Ctx`, decodes by hand, and the API description cannot say what the route reads. The mirror is one declaration on the type: the same `nilo_content_type`, and a reader from the body's bytes into `Self`, checked and refused where the type is named the way `nilo_parse` is ([ADR 0142](./adr/0142-a-path-param-can-parse-itself.md)). nilo supplies the door and the caller brings the codec, which is what "no protobuf" ([decided](./decided.md#not-coming)) should cost.

**Needs:** two things. The name — `nilo_read(text, arena) !Self` is already the column protocol ([ADR 0055](./adr/0055-a-column-type-can-come-from-outside-this-module.md)) with the same shape, and a type can legitimately be both a column and a body. And what the document says for a body with no JSON schema: the content type and a bare description, the way [ADR 0076](./adr/0076-a-type-that-writes-its-own-json-says-so.md) words a type that writes its own body, or a `nilo_openapi` the type declares.

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a shutdown or from one of the deadlines the Engine sets; a client closing its connection in the middle of a handler produces neither, so the work runs to the end and the response is written into a socket nobody is reading. The other half of this — cutting a slow handler off — is `nilo.deadline(ms)` ([ADR 0133](./adr/0133-a-route-can-say-how-long-it-has.md)). This half is not simply unbuilt: **the obvious implementation is wrong.** A read-side EOF is not "the client left" — a client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its response, so answering "peer gone" from it would abandon correct requests. Gin gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Needs:** two named signals rather than one flag — "the client half-closed and is waiting" and "the socket is gone". What is already real is a write that fails, and a handler sees that today.

### `nilo_sql`

**`reset` and `squash` are missing from the migrations, and they are the debt that forward-only creates.** `generate`, `check`, `status`, `migrate` and `verify` ship ([ADR 0153](./adr/0153-a-migration-is-a-diff-against-a-snapshot.md)); `push` and `pull` — the SQLite and the rescue cases — are the other two that do not. There is no `down`, so a developer whose laptop database is in a state no version describes has nothing to type, and a project three years in has four hundred version files every CI run reads. Skipping them does not remove that pain, it moves it onto somebody's laptop and into somebody's build. `squash` is the harder half: it has to leave the ledger of every database that already ran the old versions alone, which means writing a new first version that is only ever applied to a database that has applied nothing.

**Needs:** what `squash` writes into the ledger of a database that is already past it. Rewriting rows is out — that is the thing `verify` exists to catch.

**Nothing reports how the pool is doing.** `app.metrics` counts requests, statuses and durations ([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)); a `Db` counts nothing. Connections in use, how long a caller waited for one, statements run, and how many the pool threw away are the questions an operator asks first when a service slows down, and the last of them is already reachable — `postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is marked test-facing because nothing else reveals it.

**Needs:** a shape that does not become a second metrics registry. `app.metrics` is the shape and a `Db` is a Service, which knows nothing about an App — so where the numbers meet is the question, not how to count them.

**A watched statement cannot say which request it came from.** `db.watching` shows the text, the plan, the duration and the rows ([ADR 0137](./adr/0137-a-statement-can-be-watched.md)), so *which statement is slow* is answerable. *Slow on which page* is not: a `Sent` carries no request id and no route, and the one thing that knows both is the fiber the statement is running on.

**Needs:** a decision between two shapes. `fail`'s message box is bound to the fiber ([ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)) and reaching the same threadlocal from a Service is the arrangement [the open risk about `bulkhead.slot()`](./risks.md#open) is already about; handing the watcher the Scope is the other answer and costs the plain function pointer.

**A Row over an attached SQLite database has nowhere to `ATTACH` it.** A schema in `nilo_table` means an attached database there ([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)), and `ATTACH` is per connection — but the Wire holds a writer and a pool of readers, opens them itself, and `db.exec("ATTACH …")` reaches the writer alone. The introspection then asks a reader that has never heard the name, which is how the test for the schema-qualified `sqlite_master` found this: it attaches on every `conns[i].handle` by hand, and a program cannot.

**Needs:** a statement list run on every connection at open — which is also where a `PRAGMA` of the caller's own would go.

**The SQLite half has no live test against contention.** The Wire's own tests run one process, so the case the reader and writer split exists for has a design and no test: two writers meeting, `busy_timeout` expiring, `Locked` coming back.

**Needs:** a harness — a build step that stands up a second writer, which here is a second process on the same file rather than a socket.

---

## Known, waiting for a caller

The design is known and priced; what is missing is somebody who needs it. Bring the deployment or the workload, not the patch — every marker and every module here had to pass that test, and the entries below say what passing it looks like.

### `nilo_core`

**A per-thread entropy pool, if a number ever justifies one.** `c.entropy` reaches the operating system on every call: 56ns on a kernel serving `getrandom` from a vDSO and roughly twenty times that on one that does not ([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). A CSPRNG seeded once per thread would remove it, and costs stored state, a fork hazard and a seeding moment.

**Needs:** a workload where it shows.

### `nilo_id`

**A v7 is not sortable within a millisecond.** Two made in the same one come back in random order relative to each other. RFC 9562 allows a counter in `rand_a` and this has none, on the grounds that it buys ordering nobody asked for at the price of a threadlocal.

**Needs:** a service inserting a batch in a tight loop that has noticed.

### `nilo_config`

**A name that is not the field's own.** `database_url` reads `DATABASE_URL` and there is no way to say otherwise, so a platform that already owns a name — `PGURL`, or `PORT` meaning something else in the same container — has to be met by renaming the field. A marker in the reader's own struct is the shape the rest of nilo uses (`nilo_table`, `nilo_resolve`), and the work is one comptime lookup.

**Needs:** a caller who cannot rename the field.

**A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })` has to be written at each call, so two places reading one Config can disagree about it. Making the prefix part of the type would fix that and cost `Read(T)` its one-type-per-`T` property.

**Needs:** a caller who has actually disagreed with themselves.

### `nilo_cache`

**A value of `[]const u8` is the only shape that is not flat.** A struct with a `[]const u8` field in it is refused by name, and the caller encodes it. The shape that would fix it — writing the slices' bytes after the fixed part and pointing them back into the caller's buffer on the way out — is known and is maybe 120 lines of comptime.

**Needs:** a caller for whom JSON into a bytes Space is not enough.

### `nilo_jwt`

**Only 2048, 3072 and 4096 bits of RSA, and only P-256 of EC.** A key size with no branch is `error.KeySizeNotSupported` and a curve with none is `error.CurveNotSupported`, rather than a best effort. ES384 is the same twenty lines over `EcdsaP384Sha384`; ES512 wants P-521, which std does not carry; Ed25519 (`EdDSA`) is a different key type again.

**Needs:** an issuer that publishes one, which none in the comparison does.

**HS256 is absent on purpose and that is not free.** A shared-secret token is what a service issues to itself, and a module verifying both algorithms has to be careful about the confusion attack that a module verifying one cannot commit. A caller who needs it writes four lines of `HmacSha256` beside this module and gets the constant-time compare right on their own, which is the shape of mistake this module exists to prevent.

**Needs:** a caller, brought with the reason a sealed cookie or an RS256 issuer will not do.

### `nilo_fetch`

**An `Exchange` cannot be begun on a target.** `Exchange.begin` takes the client and a URL, and a target's `url(c, path, args)` is the URL — so the streamed call reaches the base and the template, and not the standing headers or the target's own gate. The shape is a `begin` on the target that takes a path and hands the Exchange the `Standing` the whole-body calls already pass ([ADR 0254](./adr/0254-a-target-is-a-type-and-a-path-is-a-template.md)).

**Needs:** a caller who streams from a service that has standing headers, since a signed request sets its own and an unsigned download has none.

**A plain call costs 4,139 bytes on every idle connection**, still the largest per-connection figure in the framework. It is fiber stack rather than buffers, at the depth `std.http.Client` drives it to. [`bench/result/fetch.md`](../bench/result/fetch.md) ranks the levers: moving the buffers into the arena costs +4,096 bytes since the stack release, shrinking them is worth nothing because a stack buffer no byte touches is never a resident page ([ADR 0238](./adr/0238-the-transfer-buffer-serves-nothing-here.md)), and what is left is the frame `std.http.Client` waits in.

**Needs:** a caller holding enough connections for 4 KB to matter.

**A certificate bundle is loaded per client, not per process.** `std.http.Client` rescans the system roots the first time it makes an HTTPS request. One client per program is the shape the docs push, so this has not bitten, but two would pay twice and nothing says so at the call site.

**Needs:** a caller who genuinely wants two clients.

### `nilo_job`

**`stats` is three numbers for the whole queue.** What an operator wants on a dashboard is how old the oldest `queued` row is (the lag) and the counts by kind, so that a thousand queued thumbnails and one queued invoice do not read as the same number. One more query, run only when asked.

**Needs:** a dashboard.

**`job.Memory` scans its slots.** 3–6 µs a claim over a few thousand fixed slots under a spin lock. Fine for a test and for the small program it is for; a heap would be 200 ns and an allocation-free heap somebody writes.

**Needs:** a memory queue big enough to notice.

**A worker started under `app.start(io)` and never `listen()`ed is a worker nobody stops.** `serveOn(io)` for a worker process returns when cancelled, and cancelling it is the caller's — there is no signal handler here, because the one in `http/` belongs to the server. A worker binary writes the four lines that catch SIGTERM and cancel the future.

**Needs:** a caller who has written those four lines twice.

### `nilo_s3`

**`COPY`.** Where S3 stops being bytes at a key and starts being a document format, and it carries its own trap for whoever adds it: S3 can answer a copy with **200 and an error in the body**, so a client that checks the status is wrong.

**Needs:** a caller who wants it enough to hold the XML.

**Multipart upload, and therefore upload of unknown size.** `putStream` frames by length because S3 does not accept chunked, so a body whose length is not known before it starts has no way in. Multipart is a protocol rather than a call: initiate, N parts each with its own ETag, then a completion document listing them. XML again.

**Needs:** a caller.

### Modules that do not exist yet

**`nilo_redis`: the same keyspace shape against somebody else's process.** A Service rather than a tool module, and deliberately not the one built first ([ADR 0139](./adr/0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Two of the three usual reasons to reach for a Redis are already gone here — a session is sealed into a cookie and an allowance is a table in this process — and the first case of several instances having to agree, a queue shared by several servers, was answered by the database they already share ([ADR 0198](./adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)). **The two will not share an interface**: what can fail differs, and hiding that turns "the cache is down" into "the cache is cold". Both existing Zig clients are alpha and neither has pub/sub; ADR 0139 records what each one does have.

**Needs:** the deployment with more than one instance in it.

**Anything else that dials — a `nilo_mail`, a second store.** Nothing structural is in the way. Each is a Fitting or a Service by one question: does it hold a connection to a named system, or is it given an address per call ([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked example of the second answer, and the most useful thing it leaves behind is that `nilo_fetch` turned out to be the right size — it needed one addition, `Exchange`, and no changes. **The bar is what a caller cannot already do**, and mail is the example of failing it: transactional mail is an HTTPS POST to a provider, which `nilo_fetch` sends today.

**Needs:** a caller, with the bar above applied first. This is still the most useful place for an outside contributor to look.

---

## Open questions

A question nobody has answered. Not a backlog item, and not blocked: what a reader wants to know is which evidence would end the argument.

### `nilo_core`

**Where `convert` belongs.** Turning text into a type is what a Core wants, but `convert.zig` reaches the Bulkhead to say a request failed. Either its failures come back as a value the caller turns into a 400, or it stays in the App layer and Core gets a smaller converter under the same rules. Two candidates have already come and gone: `nilo_config` is not a second caller, because sharing means naming `nilo_core` and giving up a plain `zig test` ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)); `percent.zig` went to Core without answering this, because neither direction of percent coding can fail ([ADR 0066](./adr/0066-percent-is-needed-by-two-layers.md)).

**What would settle it:** a caller in the App or Service layer. One below cannot afford to reach for it, which is what both false starts proved.

### `nilo_pw`

**Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble ([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md) has the numbers). The trade is real for a small machine holding many connections.

**What would settle it:** somebody on one.

**Whether a second factor belongs here.** TOTP (RFC 6238) is HMAC-SHA1 over a counter derived from the clock, a base32 secret, and a window; forty lines, and the trap is quiet: a code accepted twice inside its own thirty-second window is a replay, and a verifier that forgets to record the last counter it accepted passes every test. The same argument that put `pw.Token` here applies ([ADR 0241](./adr/0241-a-token-is-not-a-password-and-a-check-needs-no-request.md)). Against it is that the audience is narrower, and that the enrolment half (a QR code, a provisioning URI) is a page rather than a function.

**What would settle it:** an application that is asked for a second factor.

### `nilo_jwt`

**Whether nilo signs a token for a client that cannot hold a cookie.** [ADR 0140](./adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md) refuses signing because a server issuing its own sessions has `Session(T)`, and that holds for a browser. The client it does not obviously hold for is a native mobile application talking to the same API, where a bearer token is the convention and a cookie jar is a thing the developer has to go and find. HS256 sign and verify is forty lines; a signer here would have to be a type that cannot be handed an RSA public key as its secret, which is a Refusal rather than a runtime check.

**What would settle it:** a client that genuinely cannot hold a cookie, brought with the reason, since "the convention is a bearer token" is not one.

### `nilo_fetch`

**Whether retries belong anywhere.** How many times, how long between, and what counts as a failure are facts about somebody else's service. A caller who knows them can write three lines. A default that guesses them turns one outage into a thundering herd.

**What would settle it:** a shape that takes the policy as a type rather than a number, which is the same test every other feature here has had to pass.

### `nilo_job`

**Whether a job has a result.** `status(id)` says `done` and not what came of it: the URL of the export, how many rows the import took, the thumbnail's key. Today every "is it ready?" route builds a table of its own to hold that. A `pub const Result = T` on the kind, a `result` column written as JSON when `run` returns one, and `jobs.result(scope, id)` to read it is the shape; the cost is a column that is null on most rows.

**What would settle it:** a caller whose second table exists only to answer that route.

**Whether a job may say how many of it run at once.** "At most two calls to the payment provider in flight" is a `nilo.Gate` inside `run` today, which works and is invisible to the queue: a third row is claimed, waits at the gate, and holds a worker while it does. A per-kind ceiling the claim respected would leave the worker free.

**What would settle it:** a caller with a provider that rate-limits harder than their workers count.

**Whether priority belongs here.** Rows come out in `run_at` order and nothing else. A `priority` column is one more `ORDER BY` term and one more thing every push has to decide.

**What would settle it:** a queue where the emails wait behind the reports.

### `nilo_http`

**Whether nilo ships the response headers a browser reads as policy.** `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` and a `Content-Security-Policy` are four constant headers, so a middleware setting them would be `cors.zig`'s shape exactly. The argument against is that [ADR 0028](./adr/0028-tls-is-terminated-in-front.md) puts a proxy in front and the proxy is where an operator already writes these, and a framework that sets half of them invites the belief that it set all of them. HSTS is genuinely the proxy's, because nilo does not speak TLS.

**What would settle it:** an application that got one of them wrong, or an argument that a CSP belongs with the handlers that decide what a page loads rather than with the deployment.

**Whether a request carries a CSRF token nilo knows about.** A session cookie defaults to `SameSite=Lax`, which is what stops a cross-site form POST from carrying it, and that covers the case almost everybody has. What it does not cover is a `SameSite=None` cookie, a `GET` that changes something, and a browser old enough not to enforce Lax. Every framework that has this ends up with a token in the session, a hidden field in the form and a comparison in a middleware, and all three would fit here.

**What would settle it:** somebody who has to turn `SameSite` off.

**Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by `max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)), which is right for a form with a photo in it and wrong for a 2 GB video. The streaming version wants a parser that resumes across reads and an `Upload` that is a reader rather than bytes; it inherits nothing from `sendfile`, because sending is a descriptor handed to the kernel and receiving is a parser holding its place.

**What would settle it:** somebody designing it. Until then the answer is `c.bodyStream()`, which holds nothing and makes the framing the handler's problem.

### `nilo_sql`

**Whether the line past one table moves further.** It moved once: `.exists` is a condition and ships ([ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md)). What is still refused is joins, nested rows fetched with their parent, aggregates and `GROUP BY`, with `db.raw` as the way out. ADR 0171 names the two properties that let `EXISTS` across — it does not change the column list, so the Row still describes the answer, and it does not change the row count, so `.limit` still means what the caller thinks — and every one of the four breaks at least one. A join to a one-to-many breaks both, and the second is the expensive one: the query runs, the page renders, and some rows never appear.

**What would settle it:** a shape that keeps those two properties and the statement a comptime constant. Every property in [ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md) is downstream of the last one.

---

## Measurements outstanding

A decision that is waiting on a number, and the run that would produce it. [`bench/result/`](../bench/result/) is where the number goes when it exists; a run that changes nothing still earns an entry there if somebody would otherwise repeat it. **A box** means a benchmark machine rather than the shared two-core vCPU everything so far was taken on.

| Module | What the number decides | The run | Needs |
|---|---|---|---|
| `nilo_cache` | where the 60% between nilo and quick_cache on eight threads goes — the levers named so far are each a few percent ([`cache.md`](../bench/result/cache.md)) | `perf` on both binaries, not another guess | a box |
| `nilo_cache` | whether a bucket should have sixteen ways rather than eight: two cache lines touched against better retention at load | the retention curve and the read cost, both swept across ways | a box where the read cost is not mostly memory latency |
| `nilo_jwt` | whether a sign-in endpoint should cache a verification or just do it — an RSA exponentiation at 2048 bits is not small | one verify of each kind, and a row in `bench/result/` for it | an afternoon |
| `nilo_fetch` | whether the second arena allocation a whole-body call makes — the header block kept before the body reads over it ([ADR 0244](./adr/0244-a-response-carries-its-headers.md)) — shows up for anybody; head and body in one buffer is the shape if it does | a caller for whom it shows, since it is a bump and a `memcpy` inside the noise of a round trip | a caller |
| `nilo_fetch` | what a call costs through TLS: 59,151 bytes per HTTPS connection is std's number read out of its buffer sizes, 3.6× plain HTTP if it holds | `zig build smoke-tls -Dnetwork` already reaches a real endpoint; the measurement beside it is missing | an afternoon |
| `nilo_job` | whether a claim should take ten rows rather than one: a Postgres claim is 1.2 ms across a Docker port ([`job.md`](../bench/result/job.md)), and the price of ten is ten rows held by a worker that may die | `bench-job` extended to several workers | a box |
| `nilo_job` | whether `LISTEN/NOTIFY` is worth a pool connection held open: a push wakes a worker in the same process ([ADR 0229](./adr/0229-a-push-wakes-a-worker.md)), so `poll_ms` is only the latency of a row a *second* binary pushed | who is running two processes on one queue, and what they wait | a caller |
| `nilo_job` | whether sixteen workers on one SQLite file cost the lock: a single claimer handing rows over a channel takes fifteen of them off it, and ADR 0229 chose the wake without measuring the lock | a queue on one SQLite file with more workers than cores | a box |
| `nilo_http` | what `permessage-deflate` costs per connection, against the 4,669 bytes an idle one holds | a compressor per connection, weighed | an afternoon |
| `nilo_http` | what an internally tagged union costs to read: four passes over each tagged value (`skipValue`, the discriminator scan, `parseFromSliceLeaky`, `refuseUnknown`), two of them building a `std.json.Scanner`; `jsonmark.zig`'s header says nothing per request, which is true only on the write side | an array of a thousand tagged values, against the same array untagged; `http.md` has the write side (258 → 93 ns) and nothing for the read | an afternoon |
| `nilo_http` | whether `app.metrics`' plain shared atomics cost anything on a hot route, and whether response bytes and sockets should be counted too: four interleaved pairs put it inside the noise on two cores, which is the weakest place to look for cache-line contention | the same pair on eight cores; the fix is already named — shard per executor, pad to 64 bytes, sum at scrape | a box |
| `nilo_http` | whether `keep_bytes = 64 KiB` a thread is the right size: every WebSocket figure is a 64-byte payload that never leaves the first page; a 60 KiB message at a thousand a second is where `scratch.zig` starts refusing spares | `bench/compare/wsload/` with `-payload`; the run exists, the interpretation does not | an afternoon |
| `nilo_http` | whether the 32-lane scans (`scan.lanes`, `json.zig`'s escape scan) hold on aarch64, where 32 lanes is two NEON registers; every head-parsing and JSON figure is from one x86-64 box | `zig build run` and `bench/bench.sh` on the M1 Pro that has already run the cache and the build | an afternoon |
| `nilo_http` | whether the router needs a tree: indexing the first segment moved [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar out to about 40 routes, and an application with 203 exists | `zig build profile` on that application; two attempts that lost are in [`history.md`](./history.md) | the 203-route application reporting |
| `nilo_sql` | whether a SQLite statement should hop or run in the fiber, which the Wire makes every program choose ([ADR 0073](./adr/0073-a-file-has-no-socket-to-wait-on.md)): a hop and a cached read both cost a few microseconds, so `.in_fiber` is plausibly faster for a lookup service and fatal for one that scans | unloaded and behind the pool ([`sql.md` §2](../bench/result/sql.md) is why both); `bench-sql` has the unloaded `.in_fiber` half, `bench/sql_server.zig` on a SQLite `Db` is the rest | a box |
| `nilo_sql` | what the write half of the ten-way comparison costs under contention: `live.zig` proves `.update_nowait` and `.update_skip_locked` do what they say and nothing says what either costs, or where `FOR UPDATE SKIP LOCKED` stops scaling as a queue | the harness exists | a box where the generator, the database and ten candidates are not sharing eight cores |
| `nilo_s3` | what a request costs through TLS, which decides whether payloads are hashed: the plaintext numbers carry a SHA-256 over every body that the HTTPS ones would not, and neither corrects the other on paper | the same runs against a MinIO with a certificate | an afternoon |
| `nilo_s3` | whether caller-set `x-amz-meta-*` headers cost enough to refuse: SigV4 signs a sorted header list, a fixed set makes it a constant, and letting a caller add one puts a sort in every request | the sort, priced | a caller who wants the feature, bringing the number |

---

## Waiting on upstream

The change is in somebody else's repository. The last column is the pin it was last checked at, and the check is the point: re-test before repeating any row here.

| Module | What is blocked | Where | Checked at |
|---|---|---|---|
| `nilo_http` | `zig build dev -- --incremental` without LLVM: `-fincremental` with the self-hosted backend and the new ELF linker rebuilds `examples/hello` in 0.12 s and leaves `.zig-cache` flat, and its output dies at exec with `undefined symbol: main` whenever libc is linked, which every nilo server is; the old ELF linker spins on the first update instead ([ADR 0259](./adr/0259-a-restart-on-save-watches-the-binary-not-the-sources.md), [`build.md`](../bench/result/build.md#what-a-restart-on-save-costs-per-save)). `zig build-exe main.zig -lc -fincremental` on a five-line program reproduces it | zig | 0.16.0; re-test with `zig build dev-hello -- --incremental` and no `-Dllvm` on each release |
| `nilo_sql` | a pool-wide `statement_timeout` in the startup packet, which is the only way a plain `db.select` gets a deadline without a second round trip ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)); `options=` and `client_encoding` in a URL ride on the same packet and are refused rather than dropped until then. Meanwhile it is `ALTER ROLE app SET statement_timeout`, from the side that can already do it | pg.zig: `Conn.Opts.startup_parameters` is declared and `auth.zig` builds the message without it | `91d0705` |
| `nilo_sql` | one round trip per prepared statement that does not have to be sent: `conn.zig:243` writes a standalone `Sync` on the cache-hit path and waits for `ReadyForQuery` before Bind and Execute, where pgx and tokio-postgres send one. ~2.6 µs, and [`sql.md` §8](../bench/result/sql.md) says it is the whole of nilo's single-row deficit against Rust. Not the pipelining [ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md) refused | pg.zig: `queryOpts` | `91d0705`, and it still writes it |
| `nilo_sql` | telling a fiber that queues for the SQLite writer it already holds that it *is*, rather than that it might be: the wait is bounded ([ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md)) and ends in a `TimedOut` naming the likely cause; telling that apart from an honestly busy database needs to know which fiber holds the writer | `std.Io` handing a Service a fiber identity, or a design that gets one without it | 0.16.0 |
| the Engine | `zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled — not used here, and **fixed upstream** in zio `ab6873eb`; the account is under [risks](./risks.md#open). It arrives whenever nilo next moves the pin | zio | v0.17.0, which predates the fix |

---

## How this file is written

Seven rules. They are why the file has the shape it has, and adding to it means matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves entirely: no strikethrough, no "**Built**", no account of how it went. What was measured goes to [`history.md`](./history.md), what a reader has to change goes to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap only *partly* closed keeps one sentence scoping what is left, never a paragraph about the half that landed. **The test is that this file reads top to bottom as work outstanding.**

**2. Nothing decided is in here either.** An answer that is the answer — a question closed so it is not re-derived, a feature refused with its reason — goes to [`decided.md`](./decided.md), and a risk with no mechanism under it yet goes to [`risks.md`](./risks.md#open). This file is what is still open.

**3. An entry is in one section, by what it is waiting for.** A decision goes under **Next**, a use case under **Known, waiting for a caller**, an argument under **Open questions**, a number under **Measurements outstanding**, somebody else's commit under **Waiting on upstream**. Inside the first three, entries sit under their module's heading; a module with nothing in a section has no heading there, because the sections are the index and an empty heading says nothing.

**4. An entry opens with the whole claim, in bold**, and closes with one line: `Needs:` for the first two sections, `What would settle it:` for the third, the last column for the two tables. Somebody who reads only the bold lines has to come away with the right idea of what is outstanding, and somebody who reads only the closing lines has to know what to bring. Neither is optional and neither is prose.

**5. An entry is at most a screen.** Longer than that means it is an ADR, with an entry here pointing at it. A table row is at most a paragraph.

**6. No checkboxes, no dates, no owners.** A box implies a plan and this is not one. Nothing here is ordered; a module heading is a grouping, not a queue, and everything is a condition rather than a schedule.

**7. A number carries a link to where it was measured.** [`bench/result/`](../bench/result/) is the record. A figure with no run behind it decays into a claim, and a claim in a roadmap gets planned against, which is worse than a wrong number in a changelog.

Adding a module means a heading for it under whichever sections have entries for it, and nothing else — there is no index to keep in step.
