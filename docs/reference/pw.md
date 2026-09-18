# nilo_pw

One page of [the reference](./README.md): password hashing.

## `nilo_pw`

Password hashing
([ADR 0048](../adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
Argon2id, in the PHC form everybody else writes.

<!-- compiles: body -->
```zig
// signing up
const stored = try c.hashPassword(pw.huge_pages, form.password.view());
_ = try db.insert(User, c, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.one(User, c, .{ .where = .{ .email = form.email } });
if (!try c.verifyPassword(pw.huge_pages, if (row) |r| r.password.view() else null, form.password.view()))
    return nilo.fail.unauthorized("that is not a sign-in", .{});

// and while the plaintext is still in hand, if the Cost has gone up since
if (row) |r| if (try pw.needsRehash(r.password.view(), .default)) {
    const fresh = try c.hashPassword(pw.huge_pages, form.password.view());
    _ = try db.update(User, c, .{ .set = .{ .password = fresh.text() }, .where = .{ .id = r.id } });
};
```

| | |
|---|---|
| `c.hashPassword(gpa, text)` | `!pw.Hash` — the call a handler makes |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8` |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, if you hash at anything but the default |
| `pw.needsRehash(stored, cost)` | `!bool` — was this row written weaker than you write now |
| `pw.huge_pages` | the allocator to hand it: the 19 MiB in 2 MiB pages, 11.0 ms against 13.6 |
| `stored.text()` | the PHC string, `$argon2id$v=19$m=19456,t=2,p=1$…` |
| `pw.Cost.default` | OWASP's first recommendation: 19 MiB, 2 passes, 1 lane |
| `pw.Cost.floor_memory_kib` | 7168 — below it is a compile error |
| `pw.salt_len` | 16 |
| `pw.bytesFor(cost)` | what one hash asks the allocator for. 19,922,944 at the default |
| `pw.hash` / `pw.hashWith` / `pw.verify` / `pw.verifyWith` | the pure functions, for a program with no server |

**Call the `Ctx` methods, not `nilo_pw` directly.** One hash is 13 ms and
19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so calling the
module straight from a handler holds the thread on every sign-in and **nothing
in the log ever says so**. The methods take the salt from `c.entropy`, park the
fiber on the blocking pool, and hold one of
`listen(.{ .password_hashes_at_once = 8 })` permits.

**`stored` is optional and null is the point.** A sign-in for an address with
no account has no hash to check; returning early there answers in a millisecond
instead of thirty and turns the form into a query for which addresses are
registered. Passing null does the work anyway and answers false — **at the Cost
you give `verifyPasswordWith`**, which is why that method exists: the work done
for an account that is not there has to be the work done for one that is
([ADR 0049](../adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**`gpa` is an argument because 19 MiB is worth seeing.** Not `c.arena()` — the
request arena is reset per request keeping `arena_keep` bytes, and pushing
19 MiB through it spends the one budget nilo treats as an invariant. Hand it
`pw.huge_pages` and the same 19 MiB arrives in ten pages instead of 4,864: 11.0
ms a hash against 13.6, with nothing held between them. On anything that is not
Linux it *is* `std.heap.page_allocator`, so the call site reads the same
everywhere.

**A hash made elsewhere verifies here**, at any parallelism, and a hash made
here can be read by anything that reads PHC. That is the only reason to have a
format.
