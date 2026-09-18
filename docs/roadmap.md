# Roadmap

What is coming, what is refused, and what nobody has decided yet. Nothing else. Once something is built its entry leaves this file: what shipped is in [`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in [`history.md`](./history.md), and the decisions that are binding are in [`adr/`](./adr/).

What this document is measured against is [ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md): **the signature is the whole contract**, on a server whose memory you can put a number on. A feature that does not serve one of those two is not automatically refused, but it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it is the part to read before adding to it.

## How to read this

Every module carries the same three lists, in the same order, and a module says so when one of them is empty.

| List | What is in it |
|---|---|
| **Next** | queued work. Somebody could start it on a Saturday |
| **Known gaps** | what is wrong today, with what fixing it would take |
| **Not decided** | a question nobody has answered. Not a backlog item |

**Every entry ends with one line saying what it is waiting for**, and that line is the fastest way through this file. Search for `Waiting on: ready` and you have the work that nothing is blocking.

| Waiting on | What it means |
|---|---|
| **ready** | nothing is in the way. It needs somebody's afternoon |
| **a caller** | the design is known and nobody has needed it yet. Bring the use case, not the patch |
| **a design** | the mechanism is known and the policy is not. What is missing is a decision somebody has to make, not code |
| **a number** | somebody has to measure before this can be decided |
| **a machine** | a benchmark box rather than a shared vCPU |
| **a harness** | a test shape the suite does not have |
| **upstream** | the change is in somebody else's repository, and the entry names which |
| **accepted** | this is the answer rather than a gap waiting to close. It is written down so nobody re-derives it |

An entry under **Not decided** ends with `What would settle it` instead, because an open question is not blocked. It is unanswered, and what a reader wants to know is which evidence would end the argument.

**A `Waiting on: upstream` is the line to distrust.** This repository has been wrong about a blocker five times, and four of those were somebody else's code that turned out to already do the thing ([history](./history.md)) — the latest being the standard library it pins, which had been reading a bound port back the whole time (see [the standing risks](#open)). Nothing downstream ever re-tests a blocker, so re-test it before repeating it.

## The modules

nilo is a toolkit whose largest module is a server, rather than a server with things beside it ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)). One queue mixing them together hides the fact that decides how the work gets done: **two modules touch no file in common**, so two of the lists below can be worked at the same time, by two people or by one person on two days. A number under **Next** is a position in that module's queue and says nothing about any other module's.

| Module | Layer | Where its work is |
|---|---|---|
| [`nilo_core`](#nilo_core-the-vocabulary) | needs no loop | an entropy pool nobody has needed, a layering step that trusts its test-import list, and where `convert` belongs |
| [`nilo_id`](#nilo_id-identifiers) | needs no loop | quiet. Two questions about scope, one gap nobody has hit |
| [`nilo_config`](#nilo_config-settings) | needs no loop | reading a name the field is not called |
| [`nilo_pw`](#nilo_pw-hashing-a-password) | needs no loop | a Cost floor that weighs the wrong half, and a password longer than a page |
| [`nilo_cache`](#nilo_cache-an-expiring-cache-in-this-process) | needs no loop | 60% still between it and quick_cache on eight threads, unattributed, no counter, and no `getOrPut` |
| [`nilo_jwt`](#nilo_jwt-checking-somebody-elses-token) | needs no loop | a key set that cannot rotate safely, and no number against a verification |
| [`nilo_fetch`](#nilo_fetch-calling-somebody-elses-api) | borrows the loop | no per-service base URL, and nothing measured through TLS |
| [`nilo_job`](#nilo_job-work-that-runs-later-again-or-on-a-schedule) | borrows the loop | a claim per row, a queued row that cannot be cancelled, and UTC only |
| [`nilo_http`](#nilo_http-the-server) | owns the loop | a response never compressed, a handler never told its client left, and fifteen answered questions kept to a row each |
| [`nilo_sql`](#nilo_sql-postgres-and-sqlite) | borrows the loop | `reset` and `squash` for the migrations, a plain query with no deadline, and a connection URL a managed Postgres hands out that stops the server |
| [`nilo_s3`](#nilo_s3-object-storage) | borrows the loop | nothing measured through TLS, and no `LIST`, `COPY` or multipart |

Everything that is about the repository rather than one module stays whole at the bottom: [modules that do not exist yet](#modules-that-do-not-exist-yet), [what is not coming](#not-coming), [which Zig](#zig-versions), and [the standing risks](#the-standing-risks).

---

## `nilo_core`: the vocabulary

`Str`, the `Lifetime` behind it, and the `Scope` that lets a Service allocate for a request without naming a server. It is the smallest module on purpose: a file earns its way in by being needed by two layers, not by having nowhere else to live ([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

### Next

Nothing queued.

### Known gaps

**A per-thread entropy pool, if a number ever justifies one.** `c.entropy` reaches the operating system on every call: 56ns on a kernel serving `getrandom` from a vDSO and roughly twenty times that on one that does not ([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). A CSPRNG seeded once per thread would remove it, and costs stored state, a fork hazard and a seeding moment. Written down so whoever finds the workload knows the design was priced rather than missed.

**Waiting on: a caller.** Nobody has a workload that needs it.

**The layering step cannot tell a test import from a real one.** `zig build layering` refuses an import that is not in that module's row of the `layers` table, and `sql/db.zig` legitimately names `nilo_http` from a `test` block. Telling the two apart needs a parser rather than a scan, so the table has an `in_tests` list the step allows and does not verify. A rule with a listed exception still beats a rule in a document. This is the part of it that is weaker than the rest.

**Waiting on: accepted**, until the exception list gets long enough to hide something.

### Not decided

**Where `convert` belongs.** Turning text into a type is what a Core wants, but `convert.zig` reaches the Bulkhead to say a request failed. Either its failures come back as a value the caller turns into a 400, or it stays in the App layer and Core gets a smaller converter under the same rules.

Two candidates have already come and gone. `nilo_config` was written down as the second caller and **is not one**: sharing means naming `nilo_core` for `Str`, and a bottom-layer module that does gives up running under a plain `zig test`, which is the entry condition for the layer ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). `percent.zig` was the likelier candidate and went to Core **without answering this** ([ADR 0066](./adr/0066-percent-is-needed-by-two-layers.md)), because neither direction of percent coding can fail, so there was no failure to hand upward. That was the cheap half.

**What would settle it: a caller in the App or Service layer.** One below cannot afford to reach for it, which is what both false starts proved.

---

## `nilo_id`: identifiers

A `Uuid` and the two layouts anybody writes, v4 and v7. It imports nothing at all, which is the strongest form of what the bottom layer is for.

### Next

Nothing queued.

### Known gaps

**A v7 is not sortable within a millisecond.** Two made in the same one come back in random order relative to each other. RFC 9562 allows a counter in `rand_a` and this has none, on the grounds that it buys ordering nobody asked for at the price of a threadlocal. A service inserting a batch in a tight loop is exactly the caller who would notice.

**Waiting on: a caller.** Nobody has looked at whether that happens in practice.

### Not decided

**Whether any other identifier belongs here.** ULID, nanoid and Snowflake are each a different trade of length against sortability against coordination; v3 and v5 are a hash of a name in a namespace and would make the module carry MD5 and SHA-1. A module holding all of them is a catalogue rather than a decision.

**What would settle it: the argument UUID had.** It is here because a database column has that type. Nothing else has that argument yet, and "somebody might want it" is not one.

---

## `nilo_config`: settings

A struct of your own filled from the environment, with **every** bad setting named at once rather than the first ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). It imports nothing, allocates nothing, and is over before the socket opens.

### Next

Nothing queued.

### Known gaps

**A name that is not the field's own.** `database_url` reads `DATABASE_URL` and there is no way to say otherwise, so a platform that already owns a name has to be met by renaming the field. `PGURL`, or `PORT` meaning something else in the same container. A marker in the reader's own struct is the shape the rest of nilo uses (`nilo_table`, `nilo_resolve`), and the work is one comptime lookup.

**Waiting on: a caller** who cannot rename the field, which is the same test every other marker had to pass.

**`config.Env` is POSIX only.** It reads the environment block where it lies, which is what makes the whole module allocate nothing, and Windows moves that block. `config.Map` is the portable half and takes the `environ_map` that `std.process.Init` already hands to `main`, so nothing is unreachable. It just costs the map, and the `@compileError` on `Env.get` says which to use rather than letting the failure come out of the standard library.

**Waiting on: accepted.** The allocation-free property is worth more than one uniform call.

**A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })` has to be written at each call, so two places reading one Config can disagree about it. Making the prefix part of the type would fix that and cost `Read(T)` its one-type-per-`T` property, which is what lets a function take a reading without naming the prefix it was read with.

**Waiting on: a caller** who has actually disagreed with themselves.

### Not decided

Nothing open. A setting marked secret, so `report` could print `PGPASSWORD=***`, was the one question here, and nothing in the module logs a Config yet, so there is nothing to redact.

---

## `nilo_pw`: hashing a password

argon2id as a pure function of a password, a salt and a Cost, plus the two `Ctx` methods that take the salt from the loop and a permit from the Gate ([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)), and a `Token` for the secret that is not a password ([ADR 0241](./adr/0241-a-token-is-not-a-password-and-a-check-needs-no-request.md)). It imports nothing at all, and a project that never signs anybody in links none of it, measured at 0 bytes.

### Next

Nothing queued.

### Known gaps

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything under 7 MiB, which is OWASP's weakest published configuration. But that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib * passes` would catch it, and would also refuse this repository's own test Cost, which is how the suite affords two optimize modes ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**Waiting on: a design** for being cheap in a test suite that is not also a way to be cheap in production.

**A password longer than a page costs what it is.** Argon2 hashes the whole input, so a client posting a megabyte gets a megabyte hashed. `max_body` bounds it at one megabyte by default and the Gate bounds how many at once, so it is not an opening. But everybody else truncates at 72 bytes or pre-hashes with SHA-512, and nilo does neither.

**Waiting on: a design**, which of the two, and nobody has made it.

### Not decided

**Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble (ADR 0048 has the numbers). The trade is real for a small machine holding many connections.

**What would settle it: somebody on one.**

**Who sends `std` a vectorised argon2.** `std.crypto.pwhash.argon2` does its 16-word permutation one word at a time. Written as four `@Vector(4, u64)` lanes, the shape the reference implementation has had since 2015, the same hash is **11.19 ms instead of 13.78**, and 8.98 out of `pw.huge_pages`, with byte-identical output at every shape it was checked at. nilo will not carry a copy of somebody else's crypto to get it ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**What would settle it: somebody sending the patch.** It is upstream's to take.

**Whether a second factor belongs here.** TOTP (RFC 6238) is HMAC-SHA1 over a counter derived from the clock, a base32 secret, and a window; forty lines, and the trap is quiet: a code accepted twice inside its own thirty-second window is a replay, and a verifier that forgets to record the last counter it accepted passes every test. The same argument that put `pw.Token` here applies ([ADR 0241](./adr/0241-a-token-is-not-a-password-and-a-check-needs-no-request.md)). Against it is that the audience is narrower, and that the enrolment half (a QR code, a provisioning URI) is a page rather than a function.

**What would settle it: an application that is asked for a second factor**, since a sign-in form is what most of this repository's callers have and a second factor is what fewer of them are asked for.

---

## `nilo_cache`: an expiring cache in this process

A ring of bytes with a table over it, sized once and never grown ([ADR 0138](./adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)), admitting a new entry through a tenth of that ring until something asks for it twice ([ADR 0187](./adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)). It imports nothing, so `zig test cache/cache.zig` is the whole of its suite, and a program that is not a server can take it on its own.

### Next

**1. Counting a read costs 4.2% on eight threads and 7.0% on one.** The increment has to be atomic now that a read holds no lock, and there is no cheaper exact version: per-thread counter lanes were built with a thread-local and with a lane hashed off the stack address, and measured 1.5% better on eight threads and 3% worse on one. quick_cache's answer is to put its counters behind a cargo feature that is off by default. Doing the same here is a build flag and a documented default, not a measurement.

**Waiting on: a design**, whether `Stats` may be absent.

**2. A Space of integers has no `incr`.** A per-key count (five OTPs per phone number an hour, failed sign-ins per email, a quota per API key) is a `get` and a `put` today, and two requests between them lose a count. The `Allowance` in `nilo_http` is the same thing keyed by address only, and it cannot be keyed by anything else. `incr(key, delta) i64` on a Space whose value is an integer is one load, one add and one store under the shard's put lock, which is the size of the `memcpy` the lock already covers. What it needs is a sentence: ADR 0138 says the lock is held across a `memcpy` and nothing else, ever, and an add is not a `memcpy`.

**Waiting on: a design**, on whether ADR 0138's rule is "nothing that waits" or "nothing but a copy". The first admits this; the second refuses it.

**3. The 60% between nilo and quick_cache on eight threads is unattributed, and every lever anybody has named is small.** Taking the lock off the read path ([ADR 0188](./adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)) closed the gap from 1.81× to 1.60×, and on one thread the two are 1.12× apart, so what is left is scaling rather than per-operation work; a ceiling build with no lock and no writes at all did not reach quick_cache either. The levers that *have* been priced are all a few percent and each waits on somebody short of it: a lookup is two dependent cache misses where a hash map is one (29.3 ns against 11.9), and closing that is a second structure that cannot bound its own memory; the clock is read on every `get` at about 4%, and skipping it is a flag read outside the lock; and the doorkeeper's tenth of the ring was three points better than a fifth and a twentieth on one trace shape, which is not the same as a tenth being right. The ranked list is [`bench/result/cache.md`](../bench/result/cache.md).

**Waiting on: a number**, and the number is a profile: `perf` on both binaries, not another guess. None of the four should be acted on before the big one is measured.

### Known gaps

**A value of `[]const u8` is the only shape that is not flat.** A struct with a `[]const u8` field in it is refused by name, and the caller encodes it. The shape that would fix it — writing the slices' bytes after the fixed part and pointing them back into the caller's buffer on the way out — is known and is maybe 120 lines of comptime, and nobody has asked for it yet.

**Waiting on: a caller.**

**There is no `getOrPut`.** Every caller writes the miss, the compute and the put, which is three lines rather than one and, more to the point, lets two threads compute the same value at once. A cache stampede is a real thing and this module has no answer to it. The answer is not obvious either: holding the lock across the caller's computation is the one thing this module may never do (ADR 0138).

The shape that fits the rule is a claim rather than a lock: `putIfAbsent` a marker, and whoever got it computes while everybody else either computes too or waits *outside this module*, where there is an `Io` to wait on. That is what `nilo.Idempotent`'s `in_flight` marker already does for a POST, and the route cache under [`nilo_http`](#nilo_http-the-server) is where a GET would get the same. What is not decided is whether a `getOrPut` with no `Io` should exist at all, or whether the answer is "the module hands out the claim and the layer with a loop does the waiting".

**Waiting on: a design.**

### Not decided

**Whether a bucket should have sixteen ways rather than eight.** Eight eight-byte slots are one cache line and that is where the number came from. Sixteen would be two lines touched, better retention at high load, and a table the same size. Nobody knows whether the second line costs more than the keys it saves.

**What would settle it:** the retention curve and the read cost, both swept across ways, on a machine where the read cost is not mostly memory latency.

---

## `nilo_jwt`: checking somebody else's token

RS256 and ES256 over a JWKS document, and nothing else ([ADR 0140](./adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md), [ADR 0242](./adr/0242-the-key-decides-the-algorithm.md)). The arithmetic is std's; what this adds is the order the checks happen in, the key deciding which one runs, and the switch over RSA key sizes. It imports nothing, so `zig test jwt/jwt.zig` is the whole of its suite.

### Next

**1. A key set cannot be rotated without a race, and the guide says it is three lines.** Today the caller fetches with `nilo_fetch`, parses with `parseKeys`, holds a `*const Keys`, and on `error.NoSuchKey` decides whether that means "refetch" or "refuse". Every issuer rotates, Google on the order of days, so the decision is not optional, and the three lines it takes are wrong in three ways that no test finds: a `NoSuchKey` with no refetch is every sign-in failing until a restart; a refetch with no rate limit is one HTTPS GET to the issuer per forged token; and replacing the `Keys` a handler on another fiber is reading, then `deinit`ing the old one, is a use-after-free. The last is not policy, it is concurrency, and it is the reason this belongs here rather than in a guide: `jwt.Keyring` holding the current `Keys` under a lock, `refresh(scope, client)` that swaps in a new set and keeps the old one until its readers are done, and a bound on how often an unknown `kid` may trigger a fetch. It borrows `nilo_fetch` only through a parameter, the way `job.Table` borrows a Db, so the module still imports nothing.

**Waiting on: a design** for who owns the old `Keys` after a swap, which is the lifetime question `nilo_cache` answered with a generation and a read-after check ([ADR 0188](./adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)) and this module cannot answer with a copy, because a key set is not flat.


### Known gaps

**A verification has no number against it.** Nobody knows what one costs, so nobody knows whether a sign-in endpoint should cache the answer or just do it. An RSA modular exponentiation at 2048 bits is the whole of the work and it is not small, which is the reason to expect the number to matter.

**Waiting on: a number**, and a row in [`bench/result/`](../bench/result/) to put it in.

**Only 2048, 3072 and 4096 bits of RSA, and only P-256 of EC.** A key size with no branch is `error.KeySizeNotSupported` and a curve with none is `error.CurveNotSupported`, rather than a best effort — the right refusal, and still a refusal. ES384 is the same twenty lines over `EcdsaP384Sha384`; ES512 wants P-521, which std does not carry; Ed25519 (`EdDSA`) is a different key type again, and is the one the mixed test set uses as the key nilo skips.

**Waiting on: a caller** who has an RSA key of another size or an EC key on another curve, which no issuer in the comparison publishes.

**Verified claims are not a handler argument.** A handler that wants the user behind a bearer token writes `nilo.Authorization(.bearer)`, then `jwt.verify` with the keys, the issuer, the audience and the clock, then a refusal with the challenge on it, in every handler or in a resolver of its own. `http/` may import `nilo_jwt`, which is downward, so the shape is one argument: `Google = jwt.Verifier(Claims, .{ .issuer = "…", .audience = "…" })`, opened with a keyring and `provide`d, and `fn me(user: nilo.Verified(Google), c: *nilo.Ctx)` is the claims or a 401 with `WWW-Authenticate: Bearer` before the handler runs. The `security` entry in the API description that [ADR 0191](./adr/0191-an-authorization-header-a-handler-can-ask-for.md) writes for a bearer argument would then be written for a verified one, which is what the document should have said all along. Costs what `Authorization(.bearer)` plus one `verify` cost today, on the route that asks.

**Waiting on: a design**, and on Next 1, because a verifier that holds a `*const Keys` is a verifier that cannot survive a rotation.

**HS256 is absent on purpose and that is not free.** A shared-secret token is what a service issues to itself, and the reason it is not here is that a module verifying both algorithms has to be careful about the confusion attack that a module verifying one cannot commit. A caller who needs it has to write four lines of `HmacSha256` beside this module and get the constant-time compare right on their own, which is the shape of mistake this module exists to prevent.

**Waiting on: a caller.**

### Not decided

**Whether nilo should hold the key set as well as read it.** Today the caller fetches with `nilo_fetch`, holds with `nilo_cache`, and decides when a `kid` miss means "refetch" rather than "refuse". That is three lines and one real decision, and every one of them is visible. A `Jwks.fetch(url)` that did all three would be one line and would hide the decision.

**What would settle it:** two callers writing the same refresh policy. One caller writing one is a caller, not a pattern. The concurrency half of this question, the swap, has moved to Next 1; what stays open here is only the policy: when a `kid` miss means fetch and when it means refuse.

**Whether nilo signs a token for a client that cannot hold a cookie.** [ADR 0140](./adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md) refuses signing because a server issuing its own sessions has `Session(T)`, and that holds for a browser. The client it does not obviously hold for is a native mobile application talking to the same API, where a bearer token is the convention and a cookie jar is a thing the developer has to go and find. HS256 sign and verify is forty lines and the confusion attack is the reason this module verifies one algorithm; a signer here would have to be a type that cannot be handed an RSA public key as its secret, which is a Refusal rather than a runtime check. Against it is everything ADR 0140 already says, and the fact that the mobile client *can* hold a cookie.

**What would settle it: a client that genuinely cannot hold a cookie**, brought with the reason, since "the convention is a bearer token" is not one.

---

## `nilo_fetch`: calling somebody else's API

Sixty-five lines of policy in front of `std.http.Client`: a gate on calls in flight, a deadline per call, a bounded drain, a body ceiling, and a body that comes back as a `Str` in the caller's Scope. The first **Fitting**, which borrows the loop and owns no destination ([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md)).

### Next

The policy half of this module is the strong half, and two rounds of fdm made it so. What the ordinary call still lacks is somewhere for a service's base URL and standing headers to live, and `examples/outbound/main.zig` is the evidence: five lines to assemble a URL with two path params, and a `user-agent` repeated on every call.

**1. There is no target: a base URL and the headers a service always wants.** `Client` is one for the whole program on purpose, since the pool lives in it, so there is nowhere to write "Stripe is `https://api.stripe.com`, sends `authorization: Bearer …`, and gets five seconds". Every call repeats all three. The shape this repository already has for the same problem is `s3.Bucket`: a type, `fetch.Target("stripe", .{ .base = "…" })`, opened once on the client with what it holds at run time, `Stripe.open(&api, .{ .authorization = key })`, and asked for by type, `fn charge(stripe: *Stripe, c: *nilo.Ctx)`. Two services are two types. It is also the natural home for two things the `Client` cannot hold because it has no destination: `max_in_flight` per host, since today one slow third party eats the permits of every other, and a `nilo_ready` saying whether the upstream answers. Nothing per request: a comptime type and a pointer. The path half of the query entry rides on it: `stripe.get(c, "/v1/charges/{}", .{id})` with the segment encoded on the way in is the five lines out of the example, and it needs a base for the path to hang off, where `fetch.withQuery` needed none.

**Waiting on: a design.** Whether a target is a type of its own or a struct of defaults handed to `Client`, which is the same argument `s3.Bucket` had and settled for the type ([ADR 0068](./adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)); and what a target does that a `Client` does not, which decides whether it is a wrapper or a layer. That is the ADR.

### Known gaps

**A plain call costs 4,139 bytes on every idle connection**, still the largest per-connection figure in the framework and no longer by three orders of magnitude. It is fiber stack rather than buffers, at the depth `std.http.Client` drives it to.

This entry said 16,495 for a month and named the fix as unbuilt. The fix shipped two days after the measurement — `releaseIdleStack` gives a quiet connection's stack pages back ([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)) — and nothing re-ran the number, which is the fourth time this repository has planned against a premise that had already stopped being true.

One lever is left and it is depth. [`bench/result/fetch.md`](../bench/result/fetch.md) ranks them: moving the buffers into the arena has been measured twice and costs +4,096 bytes since the stack release, and shrinking them is measured now and worth nothing, because a stack buffer no byte touches is never a resident page ([ADR 0238](./adr/0238-the-transfer-buffer-serves-nothing-here.md)). What is left is the frame `std.http.Client` waits in.

**Waiting on: a caller** who is holding enough connections for 4 KB to matter.

**A whole-body call makes two arena allocations, and every caller pays the second whether or not it reads a header.** The header block is kept before the body reads over it ([ADR 0244](./adr/0244-a-response-carries-its-headers.md)), and it is kept for every call because a flag nobody sets correctly at every site is worse than a few hundred bytes of arena. The shape that gets back to one without a flag is head and body in one buffer: with a `content-length`, allocate `head.len + length` once, copy the block to the front and read the body into the rest, with `header(name)` walking the front. A chunked body has to grow that buffer, which is the part that touches [ADR 0238](./adr/0238-the-transfer-buffer-serves-nothing-here.md)'s path.

**Waiting on: a number** — a caller for whom the second allocation shows up, since it is a bump of the arena and a `memcpy` inside the noise of a round trip.

**Nothing is measured through TLS.** Every figure in `bench/result/fetch.md` is `http://`, and the 59,151 bytes per HTTPS connection is std's number read out of its buffer sizes rather than one this repository has put on a scale. That is 3.6× the plain-HTTP figure, if it holds.

**Waiting on: ready.** `zig build smoke-tls -Dnetwork` already reaches a real endpoint; what is missing is the measurement beside it.

**A certificate bundle is loaded per client, not per process.** `std.http.Client` rescans the system roots the first time it makes an HTTPS request. One client per program is the shape the docs push, so this has not bitten, but two would pay twice and nothing says so at the call site.

**Waiting on: a caller** who genuinely wants two clients.

### Not decided

**Whether retries belong anywhere.** How many times, how long between, and what counts as a failure are facts about somebody else's service. A caller who knows them can write three lines. A default that guesses them turns one outage into a thundering herd.

**What would settle it: a shape that takes the policy as a type rather than a number**, which is the same test every other feature here has had to pass.

---

## `nilo_job`: work that runs later, again, or on a schedule

A Fitting, and the second one: a queue over a table in the caller's database, with a worker loop written against `std.Io` ([ADR 0198](./adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)), and a schedule that is a type making the caller choose ([ADR 0199](./adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)). What it costs and where the number came from is in [`bench/result/job.md`](../bench/result/job.md).

### Next

**1. A claim takes one row, and a busy queue pays a round trip per job.** On the two-core box a Postgres claim that takes a row is 1.2 ms across a Docker port ([`bench/result/job.md`](../bench/result/job.md)); a claim of ten rows would spread that over ten. The price is ten rows held by one worker that may die — every one of them waits out the lease — and the number that decides it is throughput under several workers, which one connection cannot measure.

**Waiting on: a machine** with cores, and a run of `bench-job` extended to several workers on it.

### Known gaps

**A queued row cannot be cancelled.** The user closed the export dialog, or unsubscribed before the nudge went out, and the row runs anyway. `cancel(id) !bool`, true when a `queued` row was deleted and false when it is `running`, finished or absent, is one more optional method on the store contract, the way `pushIn` is, and a `unique` key plus `cancel` is how "move it to tomorrow" gets written.

**Waiting on: a caller.**

**`stats` is three numbers for the whole queue.** What an operator wants on a dashboard is how old the oldest `queued` row is (the lag) and the counts by kind, so that a thousand queued thumbnails and one queued invoice do not read as the same number. One more query, run only when asked.

**Waiting on: a caller.**

**A schedule is UTC.** `0 3 * * *` is three in the morning in Greenwich, and a program in Jakarta writes `0 20 * * *` with a comment. A time zone is a table of rules that changes twice a year and a dependency to carry it.

**Waiting on: a design** for tzdata without a dependency, or a caller for whom the comment is not enough.

**`job.Memory` scans its slots.** 3–6 µs a claim over a few thousand fixed slots under a spin lock. Fine for a test and for the small program it is for; a heap would be 200 ns and an allocation-free heap somebody writes.

**Waiting on: a caller** with a memory queue big enough to notice.

**Nothing sweeps finished rows.** `Table.sweep(scope, before)` deletes `done` rows older than a moment, and nothing calls it: a program that wants the table small runs it from a scheduled job of its own. Written down so nobody is surprised by a table that only grows.

**Waiting on: accepted**, until somebody would rather have a `keep_done_s` setting than a three-line job.

**A worker started under `app.start(io)` and never `listen()`ed is a worker nobody stops.** `serveOn(io)` for a worker process returns when cancelled, and cancelling it is the caller's — there is no signal handler here, because the one in `http/` belongs to the server. A worker binary writes the four lines that catch SIGTERM and cancel the future.

**Waiting on: a caller** who has written those four lines twice.

### Not decided

**Whether a job has a result.** `status(id)` says `done` and not what came of it: the URL of the export, how many rows the import took, the thumbnail's key. Today every "is it ready?" route builds a table of its own to hold that. A `pub const Result = T` on the kind, a `result` column written as JSON when `run` returns one, and `jobs.result(scope, id)` to read it is the shape; the cost is a column that is null on most rows and a `run` that returns something on some kinds and nothing on others.

**What would settle it: a caller** whose second table exists only to answer that route.

**Whether a job may say how many of it run at once.** "At most two calls to the payment provider in flight" is a `nilo.Gate` inside `run` today, which works and is invisible to the queue: a third row is claimed, waits at the gate, and holds a worker while it does. A per-kind ceiling the claim respected would leave the worker free.

**What would settle it: a caller** with a provider that rate-limits harder than their workers count.

**Whether priority belongs here.** Rows come out in `run_at` order and nothing else. A `priority` column is one more `ORDER BY` term and one more thing every push has to decide.

**What would settle it: a queue where the emails wait behind the reports.**

**`LISTEN/NOTIFY` for a row another process pushed.** A push from the process the workers run in wakes one of them through the `Io`'s futex ([ADR 0229](./adr/0229-a-push-wakes-a-worker.md)), so `poll_ms` is now only the latency of a row a *second* binary put in the table — a web server pushing for a separate worker process. `NOTIFY` on the push and `LISTEN` on a pool connection would close that too, on Postgres only, at the price of one more thing the pool holds open.

**What would settle it: a number** — who is running two processes on one queue and waiting on that second.

**A claim holds the SQLite lock sixteen times over.** With a wake per push the idle cost of sixteen workers is one claim per `poll_ms` each, and the busy cost is sixteen writers on one file's lock. A single claimer handing rows to workers over a channel is the shape that takes fifteen of them off it, and ADR 0229 chose the wake over it because nothing had measured the lock as a cost.

**What would settle it: a number** from a queue on one SQLite file with more workers than cores.

## `nilo_http`: the server

The longest list here. It used to open with a group of five things a stranger on the internet could do to a server running exactly as written, and that group is down to one — a slow client can still buy more of the arena than it has paid for, at a fixed exchange rate rather than for free. Everything else here is work nilo has not done well enough yet.

The three that left first were a `Transfer-Encoding` nilo could not decode being served as a request with no body, a request with no `Host` or two of them being served, and a WebSocket handshake that never looked at `Origin` — [ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md) and [ADR 0102](./adr/0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md). The last two were a `Content-Length` committed before a byte of it arrived ([ADR 0105](./adr/0105-a-body-is-taken-as-it-arrives.md)) and a number that accepted Zig's own literal grammar ([ADR 0106](./adr/0106-a-number-in-a-request-is-not-a-zig-literal.md)).

### Next

**1. Reloading the server without a restart.** A development annoyance rather than a design hole, because a deploy restarts anyway. The static half is built: `staticWith(.{ .reload = true })` leaves every file on disk and opens it per request ([ADR 0125](./adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)), and a file that changes under a running server is described by the descriptor its bytes come out of. A file that did not exist at startup still needs a restart. What is left is the whole process, which cannot live inside `App` — a running binary cannot rebuild itself — so it belongs in the build alongside `zig build run`. jetzig's dev server sums the modification times of its source tree and rebuilds when the sum moves, which is about as much machinery as this deserves. The part to be careful about is that it cannot end up in a release binary.

**Waiting on: ready.**

**2. A form field cannot bind to a list.** A query parameter can, since [ADR 0164](./adr/0164-a-query-parameter-that-is-a-list.md); a `<select multiple>` or a checkbox group into a `Form(T)` is still a compile error naming the field. `parseMultipart` already keeps every occurrence in order and `Fields.find` deliberately returns the first, so the data is there and only the binding is missing.

**Waiting on: a design** for the separator, which is where this stops being the query case one slot over. A browser sends a repeated name and never a comma-joined one, so the reading that made sense for a query string — take both spellings, write the comma into the document — is half wrong here: there is no document to write, and a comma in a form value is a value with a comma in it.

**3. `permessage-deflate`.** Negotiated in the handshake, and a compressor per connection is memory that has not been budgeted.

**Waiting on: a number.** The per-connection cost has to be priced against the 4,669 bytes an idle connection holds today.

### Known gaps

**An internally tagged union is read four times, and the module says the marker costs nothing per request.** `jsonmark.zig`'s header says "Nothing per request and nothing per connection: the marker is read while compiling", and on the write side that is true and measured. On the read side `Reader.parse` calls `skipValue` to find the span, `fromSpan` scans it for the discriminator, `parseFromSliceLeaky` parses it for the variant's fields, and `refuseUnknown` scans it a fourth time because `ignore_unknown_fields` had to be turned on to get past the tag. `ctx.json` parses with default options, so the fourth pass is not optional. Two of the four build a `std.json.Scanner` with an allocator.

It is per tagged value, not per body, so a small object is nothing and an array of a thousand is four times the parse of every element. Nobody has measured either.

**Waiting on: a number.** `bench/result/http.md` has the write side (258ns down to 93ns on a 374-byte alert rule) and nothing at all for the read side.

**A `print` or `json` message bigger than the write buffer is still unchecked.** [ADR 0097](./adr/0097-a-frame-that-lies-about-its-length-is-not-sent.md) holds the two passes to each other by reading `Writer.end`, which is exact only while nothing drains. Past the write buffer a drain moves it and there is nothing left to compare against, so a large formatted message can still put a length on the wire that its bytes do not match.

**Waiting on: accepted.** The two calls are for the small structured messages a WebSocket carries, and the alternatives — a wrapper writer on every byte, or a third pass over the arguments — both cost more than the shape they would guard.

**Bytes sent and connections are not counted, and neither is sharded.** `app.metrics` counts requests, statuses and durations ([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)); it does not count response bytes, which is one more atomic on the write path that nothing has measured, and it does not count sockets, which belong at the accept layer rather than in `serveRequest`. The counters are also plain shared atomics: four interleaved pairs put the cost inside the noise on a two-core box, which is the weakest possible place to look for cache-line contention. If eight threads on one hot route turn out to cost something, the fix is already named — shard per executor, pad to 64 bytes, sum at scrape time.

**Waiting on: a number**, from the same pair run on the eight-core box.

**A response body is never compressed, and only a held file is.** Static files under the spill threshold are gzipped once while the App is built, which is the shape that costs nothing per request ([static files](./guide/static-files.md#compression)). A file over it is opened per request and so has no "once" to be compressed in ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)), and in practice a file that large is a video or an archive and is compressed already. A handler returning JSON gets no such thing either.

The reason is the one that shaped the static half. A deflate compressor needs a 64 KB window, so one per connection would multiply the 4,669 bytes an idle connection holds, and one per request would break the allocation budget ([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). **The shape that fits is a pool of compressors sized to the thread count rather than the connection count.** Four cores, 256 KB, and a request borrows one for as long as it is writing.

The inbound direction closed without the pool ([ADR 0251](./adr/0251-a-gzipped-body-is-inflated-into-the-buffer-that-holds-it.md)): a decompressor needs only the history of what it has written, and `std.compress.flate.Decompress` will use the destination as that history, so a gzipped body is inflated straight into the arena buffer that was going to hold it. What is left inbound is `c.bodyStream()`, which hands bytes out as they arrive and has no buffer to be the window, and every coding but gzip.

**Waiting on: a design.** What happens when the pool is empty, what it does to a stream, and what it does to SSE, which is the one thing that must never be buffered. A proxy in front does this today and does it well, in both directions.

**A handler that reads a body nilo does not know takes a `*Ctx`, and the document says nothing about it.** [ADR 0195](./adr/0195-a-type-can-write-its-own-answer.md) closed this on the way out: a type carrying `nilo_content_type` and `nilo_write` goes out as whatever it writes, under its own label, and the description names it. On the way in there is no third answer yet — a body is JSON, a form, or `c.body()` — so a route receiving protobuf, MsgPack or a vendor's binary takes a `*Ctx`, decodes by hand, and the API description cannot say what the route reads. The mirror is one declaration on the type: the same `nilo_content_type`, and a reader from the body's bytes into `Self`, checked and refused where the type is named the way `nilo_parse` is ([ADR 0142](./adr/0142-a-path-param-can-parse-itself.md)). nilo supplies the door and the caller brings the codec, which is the line ADR 0195 drew, and it is what "no protobuf" ([not coming](#not-coming)) should cost: a decoder in the caller's program, rather than a `*Ctx` and a blank in the document.

**Waiting on: a design** for two things. The name — `nilo_read(text, arena) !Self` is already the column protocol ([ADR 0055](./adr/0055-a-column-type-can-come-from-outside-this-module.md)) with the same shape, and a type can legitimately be both a column and a body. And what the document says for a body with no JSON schema: the content type and a bare description, the way [ADR 0076](./adr/0076-a-type-that-writes-its-own-json-says-so.md) words a type that writes its own body, or a `nilo_openapi` the type declares.

**The API description names one failure, and endpoints have several.** `!?T` puts a 404 in the document because the signature settles it ([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A `fail.conflict` on a duplicate email is a line in a function body and stays invisible. That is the rule rather than a gap, since the document promises what the signature settles, but it is the rule that costs the most.

**Waiting on: accepted.** The document promises what the signature settles, and that is the whole of ADR 0024. Widening it means a second place to write a failure down, which is an annotation wearing another name and is the one thing this framework does not ask for. It is here so nobody re-derives it as a gap. A shape that states a failure *in the type* would reopen it; wanting one does not.

**What a 60 KiB WebSocket message costs a busy server is unmeasured.** Every WebSocket throughput figure in `bench/result/http.md` is a 64-byte payload, which never leaves the first page of the buffer the executor lends a socket. What a 60 KiB message costs at a thousand a second, where `http/scratch.zig`'s byte budget starts refusing spares and the page allocator gets called on the message path, is the number that would say whether `keep_bytes = 64 KiB` a thread is the right size or a guess that happened to work.

**Waiting on: ready.** `bench/compare/wsload/` takes a `-payload`, so the run is there. The interpretation is what is missing.

**Every number in this module was measured on x86-64, and the aarch64 box that exists has only run the cache and the build.** `scan.lanes` is 32 because `std.simd.suggestVectorLength(u8)` reports 32 on x86-64 with AVX2, and it is a constant rather than a query; `json.zig` hard-codes the same 32 for its escape scan. On aarch64 a 32-lane compare is two NEON registers, which is probably still ahead of the scalar loop it replaced and has never been run. The head-parsing figures (183ns → 51ns, 303ns → 163ns) and the JSON figures (1038ns → 126ns) are all from the one box.

This entry used to end "there is simply no second architecture in `bench/result/`", and that stopped being true without the entry noticing: an Apple M1 Pro has run the cache's ordering proof ([`bench/result/cache.md` §7](../bench/result/cache.md)) and the build ([`bench/result/build.md`](../bench/result/build.md)), and found ADR 0190 on the way. What has not been run there is `bench/main.zig`.

**Waiting on: ready.** The machine is there; the run is one `zig build run` and `bench/bench.sh` on it, and a row in `bench/result/http.md`.

**The router is still a linear scan.** Indexing the first segment took 44% off a hundred-route app and moved [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar out to around 40 routes, so what is left is the actual tree, for the app with hundreds of them.

**Waiting on: a number.** The numbers no longer point at it urgently. `zig build profile` is the harness for the day they do, and two attempts that lost are written up in [`history.md`](./history.md) so they are not repeated. An application with 203 routes now exists, against a threshold measured at about 40, and has said it will report a number rather than ask for the work.

**A response a handler wrote can never answer 304.** An ETag is made in `static.zig` — `etagFor` over a held file's bytes, `etagForSpilled` over a mtime and a size — and matched by `static.etagMatches` against an `If-None-Match` or the `If-Range` that `range.parse` reads. Those are the file paths, and they are the only paths there are. A JSON endpoint polled every five seconds sends the whole body every time, and a handler that wants to do it by hand gets no help either: it reads `c.header("If-None-Match")`, works something out, and calls `c.sendEmpty(304)`.

The reason this is not simply a middleware is [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md). Hashing a response means the body exists before the head is written, which the streaming paths do not do, and it means a buffer to hash over. A weak validator the handler hands in — a row's `updated_at`, a version column — costs nothing and is the shape worth designing.

**Waiting on: a design** for what the handler hands over, given that nothing in this framework should be hashing a body per request.

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a shutdown or from one of the deadlines the Engine sets; a client closing its connection in the middle of a handler produces neither, so the work runs to the end and the response is written into a socket nobody is reading. The other half of this — cutting a slow handler off — is `nilo.deadline(ms)` now ([ADR 0133](./adr/0133-a-route-can-say-how-long-it-has.md)). This half is not, and it is not simply unbuilt: **the obvious implementation is wrong.** A read-side EOF is not "the client left". A client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its response, so answering "peer gone" from it would abandon correct requests. Gin gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Waiting on: a design** that separates "the client half-closed and is waiting" from "the socket is gone", which is two named signals rather than one flag. What is already real is a write that fails, and a handler sees that today.

**Answered, and kept to one line each.** Every row below has a design that is known and nobody who needs it, or a decision that has been made. They are here so the question is not re-derived, and they are rows rather than paragraphs because none of them is work until the last column happens.

| Claim | The answer today | What reopens it |
|---|---|---|
| A response whose text is not ASCII pays a byte-at-a-time UTF-8 walk: 10ns for the 365-byte payload `bench/` measures, 2,404ns for a kilobyte of `é` ([ADR 0121](./adr/0121-a-byte-that-is-not-text-is-not-a-string.md), [`http.md`](../bench/result/http.md)) | `std.json` pays the same; a Keiser–Lemire validator is the fix | a caller whose payloads are mostly not ASCII |
| `Room.handOut` holds the roster lock for a whole broadcast, so `join` and `leave` queue behind it | shortening the hold means draining in `takeSeat` as well, and nothing measures a Room under load: `bench/ws_server.zig` runs the chat loop with the room taken out | a harness that contends for the lock |
| A service argument is found by scanning the registry per request: 1.2ns an entry, 1.6% of a request at four services, 13.4% at thirty-two ([`http.md`](../bench/result/http.md)) | under [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s bar for every app in `examples/`; resolving it into the route at `listen()` is the fix | a caller with more than about sixteen services |
| A megabyte assembled in the arena is retained per connection, and a per-thread block cache read as worth 10,229 → 14,365 req/s | it cannot be built as described: a block recycled while an `io_uring` send still names it corrupts that response, and the number was taken on an L3 this box does not have ([history](./history.md#the-control-was-doing-work-the-route-it-was-subtracted-from-never-did)) | a rule for when a block is safe to recycle, which is [ADR 0004](./adr/0004-request-arena-and-the-str-type.md)'s territory |
| The API description costs +14 KB on hello and +34 KB on rest whether or not `docs()` is called ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)) | accepted: 14 KB does not buy a line in every dependent's `build.zig`; it rides along if a third build option ever lands | nothing on its own |
| The logged duration of a streamed response is its lifetime, not its latency | one line per request is the contract; time to first byte is a different number | a caller who needs time to first byte |
| A listener somebody else opened cannot be taken over, so a deploy with nothing in front drops connections in flight | `unix:` addresses ship ([ADR 0130](./adr/0130-a-path-is-an-address-to-listen-on.md)); an inherited descriptor is one more `address` variant in the Engine, plus a naming protocol (`LISTEN_FDS` or a bare number) | a caller with no proxy in front, saying which spelling their supervisor uses |
| `Forwarded` (RFC 7239) is not read, only the `X-` headers are ([ADR 0112](./adr/0112-a-request-can-be-read-past-the-parts-a-handler-names.md)) | nginx, HAProxy, Envoy, the cloud balancers and Cloudflare all send the `X-` headers | a proxy that writes `Forwarded` and nothing else |
| A cookie cannot be bound to a handler argument the way a header can ([ADR 0163](./adr/0163-a-header-a-handler-can-be-given.md)) | `Session(T)` owns the one cookie most programs read; a bare cookie is `c.cookie` and a convert | the cookie half at the scale the header half was built for |
| Every method nilo does not name is `.other`: `PROPFIND`, `PURGE`, `LINK`, `CONNECT` and `TRACE` are one tag | a method carrying its own text costs a string compare on the request path that an enum tag does not | WebDAV, a cache purge, or an internal API that needs two of them apart |
| Rotating the session secret signs everybody out at once | correct and blunt; better means a second key and a policy for how long to keep it | somebody who actually rotates |
| A sealed cookie cannot be revoked, so "sign out everywhere" is not in the mechanism | a version number in the session checked against the row the handler fetches anyway ([guide](./guide/sessions.md#what-it-cannot-do)); anything further is the store [ADR 0035](./adr/0035-a-session-is-sealed-into-the-cookie.md) declined | an argument that nilo should have more of an opinion than that |
| `If-Modified-Since` is never answered, only `If-None-Match` and `If-Range` | every browser and CDN made this century sends an ETag, and two validators are two answers that have to agree | a client that sends only the date |
| A route cannot be scoped by host; `useOn` and `group` scope by path | two processes behind the proxy, which is a good answer | a deployment that cannot put two processes behind the proxy |
| Of Fiber's thirty-two middleware, eight are neither queued here nor a typed argument: `favicon`, `etag`, `cache`, `responsetime`, `redirect`, `rewrite`, `proxy`, `skip` | each is three to ten lines against nilo's own middleware shape, which is the argument on both sides | an application that wrote one of the eight wrong |

### Not decided

**Whether nilo ships the response headers a browser reads as policy.** `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` and a `Content-Security-Policy` are four constant headers, so a middleware setting them would be `cors.zig`'s shape exactly — comptime options, `setStaticHeader`, nothing per request. The argument against is that [ADR 0028](./adr/0028-tls-is-terminated-in-front.md) puts a proxy in front and the proxy is where an operator already writes these, and a framework that sets half of them invites the belief that it set all of them. HSTS is genuinely the proxy's, because nilo does not speak TLS and cannot know whether the client did.

**What would settle it: an application that got one of them wrong**, or an argument that a CSP belongs with the handlers that decide what a page loads rather than with the deployment.

**Whether a request carries a CSRF token nilo knows about.** A session cookie defaults to `SameSite=Lax`, which is what stops a cross-site form POST from carrying it, and that covers the case almost everybody has. What it does not cover is a `SameSite=None` cookie, a `GET` that changes something, and a browser old enough not to enforce Lax. Every framework that has this ends up with a token in the session, a hidden field in the form and a comparison in a middleware, and all three would fit here — `Session(T)` already carries fixed `[N]u8` fields, and `Form(T)` already reads a hidden input.

**What would settle it: somebody who has to turn `SameSite` off**, since Lax is what makes the feature unnecessary for everybody else.

**Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by `max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)), which is right for a form with a photo in it and wrong for a 2 GB video. The streaming version wants a parser that resumes across reads and an `Upload` that is a reader rather than bytes.

It inherits no answer from `sendfile`, which settled the outgoing direction ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)): sending is a length and a descriptor handed to the kernel, and receiving is a parser that has to hold its place across reads.

**What would settle it: somebody designing it.** Until then the answer is `c.bodyStream()`, which holds nothing and makes the framing the handler's problem.

**Whether a rule like "this is an email address" belongs in this repository.** `Bound` reports five reasons a field did not bind — `missing`, `not_a_number`, `not_true_or_false`, `not_a_choice`, `wrong_kind` — and `must` lets a handler add a rule of its own to the same 422 ([ADR 0082](./adr/0082-a-rule-of-your-own-joins-the-answer.md)). What is not here is the vocabulary everybody else ships: `email`, `min`, `max`, `len`, `oneof`, `url`, and Gin's `dive` for the elements of a list. Every application writes those predicates itself.

The shape that would fit is not an annotation, and that is what makes the question live: a rule is already an ordinary Zig function handed to `must`, so `nilo.rules.email` would be a constant that costs nothing to a handler that does not name it. The argument against is that a validator's vocabulary never stops growing, and the reference says plainly today that this is not a validator.

**What would settle it: three applications having written the same predicate**, which is the evidence that it is vocabulary rather than policy.

---

## `nilo_sql`: Postgres and SQLite

### Next

**1. Four migration commands are missing, and two of them are the debt that forward-only creates.** `generate`, `check`, `status`, `migrate` and `verify` ship ([ADR 0153](./adr/0153-a-migration-is-a-diff-against-a-snapshot.md)). The four that do not are `push` and `pull`, which are the SQLite and the rescue cases, and `reset` and `squash`.

`reset` and `squash` are the ones that matter. There is no `down`, so a developer whose laptop database is in a state no version describes has nothing to type, and a project three years in has four hundred version files every CI run reads. Skipping them does not remove that pain, it moves it onto somebody's laptop and into somebody's build. `squash` is the harder half: it has to leave the ledger of every database that already ran the old versions alone, which means writing a new first version that is only ever applied to a database that has applied nothing.

**Waiting on: a design** for what `squash` writes into the ledger of a database that is already past it. Rewriting rows is out — that is the thing `verify` exists to catch.

**2. Decide whether a SQLite statement hops or runs in the fiber.** The Wire ships with the choice as a field that has no default, so every program says which it wants and neither is a guess ([ADR 0073](./adr/0073-a-file-has-no-socket-to-wait-on.md)). What nobody has is the number that should make one of them the advised setting. A hop costs a few microseconds and so does a cached read, so `.in_fiber` is plausibly faster for a lookup service and plausibly fatal for one that scans.

Both settings have to be measured unloaded and behind the pool, because [`bench/result/sql.md` §2](../bench/result/sql.md) is the standing warning that a per-operation saving measured only unloaded understated its worth at a pool by two to three times.

Half the harness is built. `zig build bench-sql` has a SQLite arm that needs no server and answers the *unloaded* half, but only for `.in_fiber`, because a hop needs the Engine that program does not have. The loaded half wants `bench/sql_server.zig` pointed at a SQLite `Db`, which does not exist yet and is the smaller of the two jobs.

**Waiting on: a machine.** The counters that could be taken on a shared vCPU have been ([§9](../bench/result/sql.md), [`spike/sqlite_facts`](../spike/sqlite_facts/)). This is the one that cannot.

**3. A watched statement cannot say which request it came from.** `db.watching` shows the text, the plan, the duration and the rows ([ADR 0137](./adr/0137-a-statement-can-be-watched.md)), so *which statement is slow* is answerable. *Slow on which page* is not: a `Sent` carries no request id and no route, and the one thing that knows both is the fiber the statement is running on.

**Waiting on: a design.** `fail`'s message box is bound to the fiber ([ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)) and reaching the same threadlocal from a Service is the arrangement the standing risk about `bulkhead.slot()` is already about. Handing the watcher the Scope is the other answer and costs the plain function pointer.

### Known gaps

**The schema check is opt-in, and forgetting it is silent.** `db.checking(.{ .tables = &.{ … } })` takes the Row list by hand and nothing warns when it is never called or when a Row is left out of it — the check simply does not run for that Row, and the disagreement it would have caught arrives as a 500 on the first request that reads the column. Zig cannot enumerate the Rows a program declares, so there is nothing to derive the list from; what there *is* is the fact that a `Db` with `check == null` is a decision nobody wrote down.

**Waiting on: a design.** A warning at `nilo_start` for a `Db` nobody called `checking` on is one line and is also noise for a program that meant it; an explicit `db.checking(.{ .tables = &.{} })` to say so is a second way to spell nothing.

What is left here is only the forgetting. The *second* way to end up without a check — calling `checking` and getting a warning because the default pool had dialled nothing — is closed ([ADR 0144](./adr/0144-a-check-dials-the-connection-it-needs.md)).

**`.like` on SQLite folds ASCII case and says nothing.** `.ilike` is spelled `LIKE` there now, the swap `icontains` already made, and the case-sensitive half of the pattern family is a Refusal on that Dialect for exactly this fact ([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)). `.like` predates that rule and still compiles, matching more than it was asked to and only on one database — the lie the seam exists not to tell. Refusing it is the consistent answer and breaks code that runs today.

**Waiting on: a design**, whether the break is worth the consistency, since a program on SQLite that wrote `.like` and wanted folding has been getting it.

**Nothing reports how the pool is doing.** `app.metrics` counts requests, statuses and durations ([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)); a `Db` counts nothing. Connections in use, how long a caller waited for one, statements run, and how many the pool threw away are all questions an operator asks first when a service slows down, and the last of them is already reachable — `postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is marked test-facing because nothing else reveals it.

**Waiting on: a design** that does not become a second metrics registry. `app.metrics` is the shape and a `Db` is a Service, which knows nothing about an App — so where the numbers meet is the question, not how to count them.

**The SQLite half has no live test against contention.** The Wire's own tests run one process, so the case the reader and writer split exists for has a design and no test: two writers meeting, `busy_timeout` expiring, `Locked` coming back.

**Waiting on: a harness.** A build step that stands up a second writer, which here is a second process on the same file rather than a socket.

**A query outside a transaction has no deadline, and `options=` and `client_encoding` in a connection URL are refused, for one upstream reason.** `tx.deadline(ms)` covers the operation that holds a connection ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)), and the wait *for* a connection is bounded by `core.Limits` since [ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md). A plain `db.select` takes whichever connection is free and gives it straight back, so there is nowhere to put a deadline that is not a second round trip per query; what would close it is a pool-wide `statement_timeout` handed over in the startup packet, which costs nothing per statement. The two libpq parameters that ride on the same packet, `options=` and `client_encoding`, are refused by `dialOpts` today for the same reason rather than silently dropped. (`channel_binding=require`, `gssencmode=require` and a client certificate are refused for the plainer reason that the driver does none of those.)

**Waiting on: upstream (pg.zig).** `Conn.Opts.startup_parameters` is declared and `auth.zig` builds the startup message without it, re-checked at the pin `91d0705`. One line there, then an option here. Until then it is `ALTER ROLE app SET statement_timeout`, from the side that can already do it.

**A Row over an attached SQLite database has nowhere to `ATTACH` it.** A schema in `nilo_table` means an attached database there ([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)), and `ATTACH` is per connection — but the Wire holds a writer and a pool of readers, opens them itself, and `db.exec("ATTACH …")` reaches the writer alone. The introspection then asks a reader that has never heard the name, which is how the test for the schema-qualified `sqlite_master` found this: it attaches on every `conns[i].handle` by hand, and a program cannot.

**Waiting on: a design** for a statement list run on every connection at open — which is also where a `PRAGMA` of the caller's own would go.

**pg.zig spends a whole round trip it does not need on every prepared statement.** `conn.zig:243` writes a standalone `Sync` on the cache-hit path and waits for `ReadyForQuery` before it sends Bind and Execute, where pgx and tokio-postgres send one. It is ~2.6 µs, and [`bench/result/sql.md`](../bench/result/sql.md) §8 says it is **the whole of nilo's single-row deficit against Rust**. This is not the pipelining [ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md) refused — that argument was about the round trip being mostly kernel and only amortisable in bulk, and this is one message that does not have to be sent at all.

**Waiting on: upstream (pg.zig)**, and it is a local change there rather than a protocol rewrite. The note at the [top of this file](#how-to-read-this) about distrusting an upstream blocker applies, and it was applied: at the pin `91d0705` the standalone `Sync` is still written on the cache-hit path of `queryOpts`, and `startup_parameters` is still a field of `Conn.Opts` that `auth.zig` never reads. Both blockers hold.

**Everything in the ten-way comparison was measured on one connection, and contention between writers has correctness tests and no benchmark.** [`bench/result/sql.md`](../bench/result/sql.md) §8 ranks ten clients across eleven operations, and §2 of the same file is the standing warning that a per-operation figure taken unloaded understates what a pool sees by two to three times, because a pool connection is a serial queue. So the ordering in §8 is the ordering of an unloaded round trip. The write half of it is insert, batch, update, delete and a transaction on that one connection, and `live.zig` proves `.update_nowait` refuses a held row and `.update_skip_locked` steps over one without saying what either costs: how long a writer queues, what `serializable` retries are worth, where `FOR UPDATE SKIP LOCKED` stops scaling as a work queue.

**Waiting on: a machine.** The harness exists; what it needs is a box where the generator, the database and ten candidates are not sharing eight cores with each other.

**Answered, and kept to one line each.** As under `nilo_http`: a known design and nobody who needs it, or a decision already made, kept as a row so it is not re-derived.

| Claim | The answer today | What reopens it |
|---|---|---|
| `db.watching` shows the statement, the plan, the duration and the rows, and not the values it bound ([ADR 0137](./adr/0137-a-statement-can-be-watched.md)) | the decision rather than the gap: bound values are personal data in a log | a second flag whose name says it puts personal data in a log, designed rather than defaulted |
| SQLite stores a `Timestamp` as an integer and there is no way to ask for text ([ADR 0136](./adr/0136-a-timestamp-is-checked-against-the-column-it-is-bound-into.md)) | a `time_form` beside `uuid_form` is the shape, and [ADR 0159](./adr/0159-what-a-server-prints-it-can-read.md) already gave `Timestamp` the RFC 3339 parser it needs | a caller with a SQLite file whose times are RFC 3339 text |
| A fiber that queues for the SQLite writer it already holds is told it *might* be, rather than that it is | the wait is bounded ([ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md)): `db.exec` inside a handler holding a `tx` ends in a `TimedOut` naming the likely cause; telling that apart from an honestly busy database needs to know *which fiber* holds the writer | upstream (`std.Io`) handing a Service a fiber identity, or a design that gets one without it |
| An upsert cannot name a constraint (`ON CONFLICT ON CONSTRAINT …`), a partial index (`… WHERE deleted_at IS NULL`) or a `DO UPDATE … WHERE` | `db.raw`, which cannot express `RETURNING` into a Row plus a conflict target without giving up the column check; a constraint name is a string this module would have to take on trust, which is the one place it takes nothing on trust | a caller, and the soft-delete uniqueness case is the one most likely to be it |
| `db.raw` is routed to the reader or the writer by its first keyword ([ADR 0074](./adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)), and a wrong guess fails loudly on a file and silently on `:memory:`, where SQLite's URI `mode=` outranks the open flags | refusing a bare `:memory:` at `open` stands in for the missing backstop | a design for the in-memory case, which is exactly the one a test suite reaches for first |

### Not decided

**Whether the line past one table moves further.** It moved once: `.exists` is a condition and ships ([ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md)). What is still refused is joins, nested rows fetched with their parent, aggregates and `GROUP BY`, with `db.raw` as the way out.

**And the four are now grouped for a reason rather than by habit.** ADR 0171 names the two properties that let `EXISTS` across: it does not change the column list, so the Row still describes the answer, and it does not change the row count, so `.limit` still means what the caller thinks. Every one of the four above breaks at least one. A join to a one-to-many breaks both, and the second of those is the expensive one — the query runs, the page renders, and some rows never appear.

**What would settle it: a shape that keeps those two properties and the statement a comptime constant.** Every property in ADR 0039 is downstream of the last one, so anything that gives it up is a different module.

---

## `nilo_s3`: object storage

SigV4 and S3's semantics; the HTTP underneath is `nilo_fetch` ([ADR 0067](./adr/0067-most-of-an-s3-client-is-not-s3.md), [ADR 0072](./adr/0072-an-object-store-is-a-service-that-dials.md)). A bucket is a type and a key is not ([ADR 0068](./adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)); a signing key changes once a day ([ADR 0069](./adr/0069-a-signing-key-changes-once-a-day.md)).

### Next

Nothing queued.

### Known gaps

**`COPY`.** Where S3 stops being bytes at a key and starts being a document format, and it carries its own trap for whoever adds it: S3 can answer a copy with **200 and an error in the body**, so a client that checks the status is wrong.

**Waiting on: a caller** who wants it enough to hold the XML.

**Multipart upload, and therefore upload of unknown size.** `putStream` frames by length because S3 does not accept chunked, so a body whose length is not known before it starts has no way in. Multipart is the only way S3 offers, and it is a protocol rather than a call: initiate, N parts each with its own ETag, then a completion document listing them. XML again.

**Waiting on: a caller.**

**Nothing is measured through TLS**, the same gap `nilo_fetch` has. Every figure in [`bench/result/s3.md`](../bench/result/s3.md) is `http://` against a MinIO in a container. The scheme is not cosmetic here, because it decides whether payloads are hashed: the plaintext numbers carry a SHA-256 over every body that the HTTPS ones would not, and the HTTPS ones carry a TLS record layer the plaintext ones do not. Neither is a correction that can be applied to the other on paper.

**Waiting on: ready.**

### Not decided

**Arbitrary object metadata, `x-amz-meta-*` set by the caller.** Refused on a performance argument rather than a taste one, which means it can be revisited with a measurement instead of an opinion. SigV4 signs a sorted list of header names, and a fixed header set makes that list a compile-time constant. Letting a caller add headers puts a sort in every request.

**What would settle it: the number for that sort**, brought by whoever wants the feature.

---

## Modules that do not exist yet

A section rather than a list inside somebody else's, because what decides whether one of these gets built is a repository-level seam rather than anything in a module that is already here.

**`nilo_redis`: the same keyspace shape against somebody else's process.** A Service rather than a tool module, and deliberately not the one built first ([ADR 0139](./adr/0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Two of the three usual reasons to reach for a Redis are already gone here — a session is sealed into a cookie and an allowance is a table in this process — so what is left is several instances having to agree — and the first case of that to arrive, a queue shared by several servers, was answered by the database they already share rather than by a Redis ([ADR 0198](./adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)). **The two will not share an interface**: what can fail differs, and hiding that turns "the cache is down" into "the cache is cold". Both existing Zig clients are alpha and neither has pub/sub, so a dependency would not hand over cross-instance fan-out either; ADR 0139 records what each one does have.

**Waiting on: a caller.** Bring the deployment with more than one instance in it, not the patch.

**Anything else that dials — a `nilo_mail`, a second store.** Nothing structural is in the way. Each is a Fitting or a Service by one question rather than a seam to design first: does it hold a connection to a named system, or is it given an address per call ([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked example of the second answer, and the most useful thing it leaves behind is that `nilo_fetch` turned out to be the right size. It needed one addition, `Exchange`, and no changes.

**The bar is what a caller cannot already do**, and mail is the example of failing it: transactional mail is an HTTPS POST to a provider, which `nilo_fetch` sends today. A module wrapping that is fifty lines of somebody's own program plus a vendor's API to keep in step.

**Waiting on: a caller**, and this is still the most useful place for an outside contributor to look — with the bar above applied first.

---

## Not coming

Not "later". Decided against, with the reasoning written down. This list is about the repository, so it is what to check before proposing a change, whichever module the change is in.

**Templates.** nilo is for building APIs and services, and rendering a page is the thing it is not for. Two arguments point the same way. Rendering means producing a string per request, which is an allocation per request, which is the one axis [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) treats as a hard invariant rather than a budget: the 4,669 bytes and the single allocation are what nilo has to sell, and a template layer spends both. And the two shapes Zig actually offers are far apart with nothing argued for in between, comptime-checked templates being a compiler of their own and runtime string interpolation being a worse `std.fmt`. [jetzig](https://www.jetzig.dev/) is built for that job and does it with zmpl, which is a better outcome for everybody than a second half-answer here.

A `<form>` posted to a handler still works. [`examples/forms`](../examples/forms/) is that, and `Bound(Form(T))` is what makes its failures legible ([ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md)). **This is a refusal of templates, not of everything on that side of the line.** Whether some other convenience from the batteries-included world earns its place gets decided one feature at a time, against the two numbers above.

**A serialiser for anything but JSON: XML, CSV, MsgPack, ProtoBuf.** Gin ships four and Fiber three, and nilo ships a declaration instead: a type carrying `nilo_content_type` and `nilo_write` goes out as whatever it writes, under its own label, and the document names it ([ADR 0195](./adr/0195-a-type-can-write-its-own-answer.md)). What is refused is the reflection — a struct turned into XML elements by a rule nilo picked — because XML has namespaces, attributes and a dozen date encodings, and the consumer who needs XML is by definition the one who will not change to suit nilo's pick. The same goes for CSV's quoting and MsgPack's schema. The bytes are the caller's; the label and the description are what nilo adds.

**A config file parser: TOML, YAML, or any other.** `nilo_config` reads the environment and hands `Fixed` to a program that has parsed something itself ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). Writing one means weeks to reach where somebody else already is, and depending on one means every project importing the module fetches it. For TOML that somebody is [sam701/zig-toml](https://github.com/sam701/zig-toml): about 2,000 lines, arena-backed, already on 0.16's `std.Io`. For YAML there is no finished answer to depend on, and that is the argument rather than a gap. [kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) skips 322 of the roughly 400 cases in the official suite, written by a Zig core contributor, and a partial YAML parser misreads real files quietly instead of refusing them.

`config.Dotenv` is not the exception it looks like. It takes *text*, opens no file, and needs no dependency at all ([ADR 0064](./adr/0064-a-dotenv-is-text-somebody-else-read.md)). What the module refuses is the filesystem, and a format whose parser somebody else has to maintain.

**A `recover` middleware.** Zig cannot recover from a panic at all, so there is nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).

**TLS, and with it HTTP/2 and a gRPC server.** Terminated in front, and that is the answer rather than the plan ([ADR 0028](./adr/0028-tls-is-terminated-in-front.md)). Zig's standard library can be a TLS client and not a TLS server, nobody in the comparison wrote their own, and the two alternatives are a one-person crypto dependency or a C toolchain in the install story. HTTP/2 and gRPC are said out loud because nobody derives them from "no TLS". `Ctx.clientIp()` and `.trusted_hops` are this decision's other half.

**An ORM.** `nilo_sql` is not one and the name is the promise. No change tracking, which costs a copy of every row. No lazy relations, which are queries nobody wrote. No identity map, which is a lifetime problem in a language with no garbage collector ([ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

**Auth contents.** The mechanism is provided, in middleware and resolved values. The policy is yours.

**Benchmark claims without a benchmark machine.** A figure gets published only alongside what it does *not* mean, and alongside the fact that a handler touching a database flattens the whole comparison ([ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)).

---

## Zig versions

The latest stable release only, on one branch. The people this is aimed at download Zig, run `zig build`, and give up if it fails. They are not going to go hunting for the right branch. The consequence is that every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

**0.4.0 needs Zig 0.16.**

---

## The standing risks

What could go wrong that is not a bug and not a feature, and is still waiting on something. The risks that *are* held, and what holds each, are a record rather than work, and they live in [`docs/risks.md`](./risks.md): eleven held by a mechanism with a test under it, and three that cannot be held and are said out loud instead. What stays here is what has no such mechanism yet.

### Open

**A fail function in spawned work is safe only because of where a threadlocal gets written.** `bulkhead.slot()` falls back to a threadlocal when a fiber has no slot, which spawned fibers never do. It is null on executor threads only because the one thing that sets it does so from inside `zio.blockInPlace`, which runs on a thread-pool worker. Both ends carry a comment saying so. Nothing enforces it, and if it broke, spawned work would write its message into an unrelated request, which is [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another route.

**Waiting on: a design** that makes it a rule rather than a comment.

**Nothing checks that a completion handed to the loop is given back before its frame goes.** `Wake` submitted two and never did, and the cost was a server that would not come back from a SIGTERM three runs in four ([ADR 0098](./adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)). What makes it a standing risk rather than a closed bug is that the fix is one `defer` and the next `submit` anybody writes is under no obligation to match it.

The failure gives nothing away at the place it happens: the loop writes into memory that has been handed on, and what arrives is a spinning thread somewhere else entirely, after a shutdown that has already logged success. Only the Engine may name zio, so the whole surface is one file — but one file is what the threadlocal entry above says too.

**Waiting on: a design** that makes it a rule rather than a `defer` somebody has to remember. This particular one is guarded — a test in the Engine parks a `Wake` and checks the queue is empty after `deinit` — but the guard names `Wake`, and the next `submit` will not be in `Wake`.

**`zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled.** Not used here, reported upstream with a standalone reproduction, and **fixed upstream** in zio `ab6873eb` with a fresh `Waiter` per receive attempt. A waiter node was pushed onto a queue it was already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`). Debug aborted 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast`, which has no such assertion, **hung 17 runs in 20** where a clean run takes 200ms. Cancellation was what reached it: the same program closing the channel and waiting was clean 5 in 5 ([zio#667](https://github.com/lalinsky/zio/issues/667)).

**Waiting on: upstream (zio)**, or rather on the pin: v0.17.0 predates the fix and is what `build.zig.zon` holds, so it arrives whenever nilo next moves it. Nothing here depends on it.

---

## How this file is written

Seven rules. They are why the file has the shape it has, and adding to it means matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves entirely: no strikethrough, no "**Built**", no account of how it went. What was measured goes to [`history.md`](./history.md), what a reader has to change goes to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap only *partly* closed keeps one sentence scoping what is left, never a paragraph about the half that landed. **The test is that this file reads top to bottom as work outstanding.**

**2. Three lists per module, in the same order, and no fourth.** Next, Known gaps, Not decided. A module with an empty list says "Nothing queued" rather than dropping the heading, because an omission and a deliberate blank look identical otherwise.

**3. An entry opens with the whole claim, in bold.** Somebody who reads only the bold lines has to come away with the right idea of what is outstanding. The paragraph under it is the detail, not the reveal.

**4. An entry ends with what it is waiting for**, from the fixed list at the [top of this file](#how-to-read-this), or with what would settle it under **Not decided**. This is not optional and it is not prose. It is the field that makes the file scannable, and it is the field that catches a blocker that has quietly stopped being one.

**5. An entry is at most a screen.** Longer than that means it is an ADR, with an entry here pointing at it. Migrations and templates are the two longest here and both are near that line.

**6. No checkboxes, no dates, no owners.** A box implies a plan and this is not one. What is queued is the numbered **Next** list, and a number is a position in that module's queue and nothing more. Everything else is a condition rather than a schedule.

**7. A number carries a link to where it was measured.** [`bench/result/`](../bench/result/) is the record. A figure with no run behind it decays into a claim, and a claim in a roadmap gets planned against, which is worse than a wrong number in a changelog.

Adding a module means adding its section here **and** a row in [the modules table](#the-modules), which is the only index this file keeps.
