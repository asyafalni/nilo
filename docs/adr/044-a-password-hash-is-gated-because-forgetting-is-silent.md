# A password hash is gated, its memory comes from the pages it walks, and a token is not a password

**Status:** accepted
**Topic:** pw

## Context

The roadmap carried `nilo_pw` as "unblocked, and in the shape `nilo_id` already has": argon2id as a pure function, in a tool module, with what it cannot reach arriving as arguments. Two of its other premises turned out to be wrong once measured, and a second module's worth of design followed from the gap.

**The first was the cost.** The roadmap assumed 100 ms. On a 16-core desktop, `ReleaseFast`, argon2id at `owasp_2id` (t=2, m=19 MiB, p=1) is 13.3 ms, one allocation of 19,922,944 bytes. The gap is the decision: at 100 ms a handler that forgets `nilo.blocking` trips the blocking detector at `block_warning_ms` (250 by default); at 13 ms it never fires. The mistake is silent, and a module that ships a cryptographic primitive whose misuse produces no symptom has to make the misuse impossible rather than document it.

**The second was where the 19 MiB comes from.** `std.crypto.pwhash.argon2` takes a `std.Io` in Zig 0.16, for the salt (through `io.random`, never reached here because the salt is an argument) and for lane parallelism at `p > 1` (through `processBlocksAsync`), which a tool module has none of. And measured separately, most of the cost is not the hashing: an ordinary allocator gives argon2 4,864 pages of 4 KiB to fault in one at a time, and that faulting-in is 2.2 ms of the 13.3 on its own.

**The third was a use this module never anticipated.** Every ordinary application also sends a password-reset link, an email verification or an API key: 32 bytes of entropy, sent as text, with the digest stored rather than the token and a constant-time compare when it comes back. Nothing under `pw/` or `id/` said any of this, and a reader who reached for the one secret-handling module the toolkit has found argon2id, the wrong tool for a value with 256 bits of entropy already, dressed as the right one. The same reader also found `verifyPassword` taking a `Ctx` it did not use, which meant every caller with no request (a CLI resetting an account, a migration re-hashing, a background job, a test) had to reach `nilo_pw` directly and so miss the Gate.

## Decision

### The cryptography and the gate

**`nilo_pw` is a tool module and holds only the cryptography.** `hash`, `hashWith`, `verify`, `needsRehash`, a `Cost`, and `Token`. It imports nothing at all, so `zig test pw/pw.zig` runs the whole of it, the entry condition [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) sets for the layer rather than a nicety.

**The salt and the allocator are arguments**, for the reason `nilo_id`'s entropy and millisecond are ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)): neither is reachable from down here, and 19 MiB is not a number a framework should spend without saying so.

**`Ctx.hashPassword` / `Ctx.verifyPassword` are the half a handler calls, and they are not a convenience wrapper.** They take the salt from `Ctx.entropy` ([ADR 042](./042-entropy-belongs-to-the-loop.md)), take a permit from a process-wide Gate, and park the fiber on the blocking pool. Because the mistake they prevent is invisible, it is not the caller's to remember.

**`bulkhead.Gate` is a counting lock**, a Mutex with a number bigger than one that serves its waiters in the order they came and can wait within a limit ([ADR 222](./222-a-gate-serves-its-waiters-in-the-order-they-came.md)), wrapped for the reason `Mutex` is wrapped: waiting for a turn is not the handler holding its thread, and the detector has to be told ([ADR 013](./013-handlers-must-not-block-the-thread.md)). `Options.password_hashes_at_once` defaults to 8: throughput peaks at 16 concurrent hashes and falls at 32, eight reaches 91% of the ceiling for a quarter of the memory and a third of the latency, and 32 at once would be 608 MiB, 7.3× the memory `max_connections`'s default 10,000 idle connections cost at 8,767 bytes each.

**`verify` takes `?[]const u8`, and null means there is no such account; it does the work anyway and answers false.** A sign-in that returns early on an unknown address answers in a millisecond instead of thirteen, which turns the form into a query for which addresses are registered. There is no signature that lets the fast wrong version be written, which is why there is no separate "dummy verify" to know about. `verifyWith` takes the Cost as well, because the no-account path is timed against it: the decoy hash used to be fixed at `.default`, so a deployment storing hashes at a different Cost answered "no such account" in 13 ms and "wrong password" in 30, the optional closing the early return while leaving the stopwatch open. `verify` still means `.default`.

**Argon2id, not bcrypt.** bcrypt cost=10 is 34.3 ms against argon2id's 13.3, 2.6× slower for a configuration nobody would call stronger; bcrypt cost=12 is 136.5 ms. What bcrypt buys is zero heap, entirely; nilo refuses that trade on purpose, because the 19 MiB is what costs an attacker with a GPU, it is transient rather than resident, and the Gate turns it into a number an operator can multiply.

### The memory: an allocator, not a cache

**`pw.huge_pages` is an allocator, and naming it is the caller's.** `mmap`, one `madvise`, `munmap`, sixty lines in `pw/pages.zig`; anything below 2 MiB goes to `std.heap.page_allocator` unchanged, so it stays an allocator rather than a trapdoor. It costs 11.0 ms a hash against 13.6 for an ordinary allocator, ten page faults instead of 4,864. **The memory is handed back at the end of every hash: nothing is held between them.** A mapping kept warm and reused measured 10.5 ms against a fresh huge-page one at 10.4, which is the whole argument against a pool: it would buy nothing for 152 MiB of resident memory held across every hash, the exact number the Gate above exists to keep 32 concurrent hashes from reaching.

```zig
const stored = try c.hashPassword(pw.huge_pages, form.password.view());
```

**`needsRehash` reads the parameters against the Cost in force.** The plaintext is in hand exactly once, at the sign-in that just succeeded, and that is the only moment a row can be written forward. Lanes are not compared: a hash somebody else's library made at `p = 4` is the same work as one at `p = 1`, and rewriting every row for it would be churn wearing an upgrade's clothes.

**A Cost with more lanes than memory is a Refusal.** Argon2 gives every lane four segments of two blocks, so `.lanes` above `.memory_kib / 8` cannot be computed; `hashWith` now refuses it while compiling rather than reaching the `unreachable` that answered it before, so the panic it would have been in `ReleaseFast` cannot happen. **The Cost is `comptime`, so a Cost below the floor is also a Refusal.** The floor is 7 MiB, OWASP's weakest published configuration; turning the cost down to make a suite fast is the mistake worth catching, because it is invisible afterwards, a weak hash looking exactly like a strong one.

**`hash` and `hashWith` return `error{OutOfMemory}`, not the two-member `Error`.** `NotAHash` is something only a stored string can be, so a caller that hashes had an arm to write that could never run.

### The token: not a password, and not a request

**`pw.Token` is 32 bytes, made from entropy the caller brings**, `try c.entropy(pw.token_len)` in a handler or `std.Io.randomSecure` outside one, for the reason a salt is: the module has no Bulkhead to ask through, and being handed the bytes is what keeps `zig test pw/pw.zig` running with no module graph. `text()` is 43 characters of base64url to send, by value; `digest()` is the SHA-256 to store, by value; `Token.matches(stored, presented)` decodes, hashes and compares in constant time; `Token.parse(presented)` reads a token back, for the lookup where the digest is the key: an API key arrives on its own, and the row is found by `parse(header).?.digest()`. Nothing allocates and nothing takes an allocator.

**Every wrong presented value is `false`, and so is every wrong stored one**: the wrong length, a character outside base64url, a padded spelling, one answer for all of them, because which way a token was wrong is not something to tell whoever presented it. `stored` is a slice rather than a `[32]u8`, what a `bytea` column hands back, which makes a table that stored the 43-character text instead of the digest answer false on every row rather than crash.

**No argon2, on purpose.** A password has perhaps forty bits of entropy and 13 ms a guess is what makes that survivable; a token has 256 bits, no number of guesses at which is a threat, and the digest exists so a copy of the table is not a set of working links. SHA-256 does that in a microsecond; stretching would buy nothing and cost a reset endpoint that answers in 13 ms and can be walked.

**It lives under `nilo_pw` rather than a module of its own**, settled by the import rule: it needs `std.crypto` and nothing else, which is what `pw/` already is ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). Under `pw` rather than `id`, because a `Uuid` is a key and a `Token` is a secret, and putting them on one page invites the substitution described above.

**`nilo.verifyPassword(gpa, stored, text)` is the check with no request in hand**, and `nilo.verifyPasswordWith(cost, …)` the same told what a hash costs. It is `http/password.zig`'s `verifyAnywhere`: the same Gate and the same blocking pool as the method, so a job on the server's loop holds one of the eight permits like a sign-in does, and a CLI with no loop runs the call inline, which is what `nilo.blocking` does outside a fiber. `c.verifyPassword` keeps its signature and calls it. There is no `nilo.hashPassword` beside it: making a hash needs entropy, and the loop is where the wait for entropy is paid for, so hashing with no request has nowhere to get the salt from.

## What was rejected

- **Leave hashing to the user with `nilo.blocking` and `nilo.Mutex`, both of which already exist.** Every other blocking call nilo has is slow (a database round trip, a file read), and a handler that forgets to wrap one is caught by the detector within a request or two. A password hash is expensive, not slow: it sits under every threshold and shows up as p99 on endpoints that have nothing to do with signing in. A rule only a correct reading of the documentation enforces is not a rule this repository keeps.
- **Put the Gate on the App.** There is one memory controller per process, not one per App; two Apps in one process at eight each is sixteen, the number the throughput table says not to run.
- **Take the 19 MiB from the request arena.** Nineteen megabytes through it would spend the one axis ADR 017 treats as an invariant rather than a budget, on every sign-in, and leave the high-water mark behind.
- **Ship the PHC encoder ourselves, or invent a format.** A hash nobody else can read is a hash nobody can migrate off, the only reason to have a format at all; `std`'s `phc_format` is public and is what every other library writes.
- **A pool of warm buffers behind the Gate**, eight permits holding eight 19 MiB mappings mapped, no `mmap` on the hot path. Measured and refused: a kept mapping is 10.5 ms, a fresh huge-page one is 10.4, so the pool buys nothing for 152 MiB of resident memory, 7.3× what 10,000 idle connections cost.
- **`MAP_POPULATE`.** Pre-faults the whole mapping in one syscall, needs no kernel setting, cannot stall on compaction: 11.9 ms, about half the win of huge pages. Written down as the fallback if huge pages are ever given up, so the number does not have to be measured twice.
- **Make `pw.huge_pages` the default `Ctx.hashPassword` reaches for.** The allocator is an argument precisely so 19 MiB is visible at the call site; routing it somewhere else quietly would make that argument a decoration. It also hides a real cost: with `transparent_hugepage/defrag` set to anything but `defer`, a fault that has to compact memory to find a huge page waits for it, and that wait lands on a sign-in.
- **Vendor a faster argon2.** `std`'s permutation is scalar; written as four `@Vector(4, u64)` lanes it measured 11.19 ms against 13.78 (8.98 out of huge pages), byte-for-byte identical at several parameter sets. Refused anyway: nilo does not own an argon2, it owns the decision to use `std`'s, and a copy of somebody else's crypto in `pw/` is a copy to keep in step with every upstream fix forever. The patch belongs in `std`; the measurement is recorded so whoever sends it does not have to redo it.
- **Let the Cost be a runtime value.** Refused for both hashing and `needsRehash`: turning the cost down to make a suite fast is the mistake worth catching because it is invisible afterwards, so the Cost is `comptime` and a Cost below the floor is a Refusal rather than a setting somebody can weaken at runtime.
- **A second function for the no-account case**, reconsidered once `verifyWith` took a Cost. Still no: the optional is what makes the fast wrong version unwritable, and `verifyWith` only makes the slow right version cost the right amount.
- **A runtime Cost for `needsRehash`.** It is `comptime` for the reason `hashWith`'s is: the Cost an application uses is chosen once, and a comparison against a runtime one would check nothing about the floor.
- **Dropping the `Ctx` from `verifyPassword`.** Removing a parameter that costs its callers nothing is a breaking change to a method every sign-in handler already calls; a second name for one job is a real cost and a break for nothing is a larger one. `nilo.verifyPassword` is the free function that breaks nobody.
- **A `c.token()` method, the way `c.hashPassword` is one.** `hashPassword` is a method because it holds a permit and parks a fiber, and forgetting to is silent. A token holds nothing and waits for nothing, SHA-256 over 32 bytes; `pw.Token.new(try c.entropy(pw.token_len))` is one expression, the same shape ADR 042 already gave `id.v7`. A method adding a name and nothing else is the second name this decision was careful not to add.
- **A width the caller chooses, `Token(bits)`.** One width is what makes the text one length, which is what lets `matches` refuse anything else before decoding it. `new` takes `anytype` so that `pw.Token.new(uuid.bytes)`, sixteen bytes where thirty-two are needed, is refused in nilo's own words rather than std's, naming where the bytes came from.
- **Expiry and single use inside the module.** Both are columns in the caller's table (`expires_at`, `used_at`), the way a password hash's row is the application's. What is the same in every application and wrong in most is how wide, how sent and how compared a secret is, and that is the whole of what shipped.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 for anything that does not hash or check a token. A handler that hashes makes one allocation of 19 MiB from an allocator it named itself. A `Token` is 32 bytes on the stack, `text()` and `digest()` by value. |
| Memory per idle connection | 0. 8,767 bytes, unchanged. The Gate is one struct per process, the 19 MiB is transient and held only while a hash runs, and nothing about a Token suspends a fiber. |
| Throughput and p99 | unchanged for a request that does not touch this module. A hash is −19% uncontended and −8% at eight at once with `huge_pages` against an ordinary allocator (11.0 ms against 13.6, 23.3 against 25.4); a `Token` round trip is one SHA-256 and one base64 pass over 32 bytes. |
| Binary size | 0 bytes for a project that never signs anybody in, measured as a byte-identical stripped `ReleaseFast` benchmark server before and after. A project that calls `Ctx.hashPassword` pays +152,612 bytes of text for argon2id, blake2b, the PHC encoder and the Gate; `huge_pages`, `verifyWith` and `needsRehash` together add +820 more; a program naming `pw.Token` links SHA-256 and a base64 codec from std, not separately measured because a program with a session already links both. |

## Consequences

**The blocking detector has a floor, now written down.** Anything that costs less than `block_warning_ms` but more than nothing is invisible to it; password hashing is the first call nilo ships in that band, and the answer each time is the one taken here: if forgetting is silent, the framework does the remembering.

**`nilo_pw` stores nothing.** No user table, no sign-in, no session, and no expiry or single-use tracking for a `Token`; a hash or a token digest is a value and where it lives is the application's. The session that follows a successful check is `Session(T)` ([ADR 033](./033-a-session-is-sealed-into-the-cookie.md)).

**A sign-in is the most expensive thing an unauthenticated client can ask for, by a wide margin, and the Gate bounds the memory rather than the queueing.** Past eight, requests wait; `header_timeout_ms` is what eventually answers a client that will not. Rate limiting the endpoint is the application's.

**A hash's memory goes back to the kernel rather than to the next allocation.** Argon2 does not wipe its blocks, so out of a recycling allocator the bytes a password was mixed into are whatever asks next; `munmap` is a property `huge_pages` has rather than the reason it exists.

**Two half-checks are written down rather than closed.** `Cost.floor_memory_kib` checks memory alone: `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of OWASP's weakest configuration and compiles, because a floor on `memory_kib * passes` would also refuse this repository's own test Cost, the one that lets the suite run in two optimize modes. And a password over 4 GiB is still `unreachable`, the one argon2 precondition this module cannot refuse while compiling, because a password is a value; `max_body` bounds a request's at one MiB by default, and the roadmap holds the undecided question of whether nilo should truncate or pre-hash a longer one.
