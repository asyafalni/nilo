# nilo_pw

One page of [the reference](./README.md): password hashing.

## `nilo_pw`

Password hashing
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).
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
| `nilo.verifyPassword(gpa, stored, text)` | `!bool` — the same check with no request in hand: a CLI, a job, a test. Same Gate, same pool |
| `nilo.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what a hash of yours costs |
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
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

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

**Checking needs no request; making does.** The salt of a stored hash is in
the string, so `nilo.verifyPassword` is the method without the `Ctx` — the same
Gate and the same blocking pool, for a CLI resetting an account, a job
re-hashing at a raised Cost, or a test with neither an App nor a Ctx. With no
loop at all it runs inline. There is no `nilo.hashPassword` beside it, because
a hash needs entropy and `c.entropy` is where the wait for it is paid
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

## A token that is not a password

A password-reset link, an email verification, an API key
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).
Thirty-two bytes of entropy, 43 characters to send, a SHA-256 digest to
store, and a constant-time compare when it comes back.

<!-- compiles: body -->
```zig
// making one: mail the text, store the digest, keep nothing else
const user = try db.one(User, c, .{ .where = .{ .email = form.email } }) orelse return;
const token = pw.Token.new(try c.entropy(pw.token_len));
const digest = token.digest();
_ = try db.insert(Reset, c, .{
    .user_id = user.id,
    .digest = sql.Bytes.of(&digest),
    .expires_at = sql.Timestamp.fromSeconds(sql.Timestamp.now().seconds() + 3600),
});
const sent = token.text();
const link = try std.fmt.allocPrint(c.arena(), "https://example.com/reset/{d}/{s}", .{ user.id, &sent });

// checking one, on the route the link points at
const presented = c.param("token") orelse return nilo.fail.unauthorized("that link is not one", .{});
const row = try db.one(Reset, c, .{ .where = .{ .user_id = user.id } }) orelse
    return nilo.fail.unauthorized("that link is not one", .{});
if (row.expires_at.micros < nilo.nowMicros() or !pw.Token.matches(row.digest.bytes, presented.view()))
    return nilo.fail.unauthorized("that link is not one", .{});
```

| | |
|---|---|
| `pw.Token.new(entropy)` | `Token` — from `try c.entropy(pw.token_len)`, or `std.Io.randomSecure` outside a request |
| `pw.token_len` | 32 — bytes of entropy one is made from, and `Token.len` |
| `token.text()` | `[43]u8` — base64url, no padding: the form to send. Safe in a URL, a header and a mail |
| `token.digest()` | `[32]u8` — SHA-256 over the bytes: the form to store. `Token.Digest` is the type |
| `pw.Token.matches(stored, presented)` | `bool` — decode, hash, compare in constant time. `stored` is the `[]const u8` a `bytea` hands back |
| `pw.Token.parse(presented)` | `?Token` — the token read back, for a lookup where the digest is the key: `parse(header).?.digest()` |

**Every wrong answer is `false`.** A presented value of the wrong length, a
character outside base64url, a padded spelling: one answer, because which
way it was wrong is not something to tell whoever presented it. And a stored
value that is not 32 bytes is `false` too — which is what a table that stored
the 43-character text instead of the digest answers on every row, so the
mistake the digest exists to prevent fails closed.

**No argon2, on purpose.** A password has perhaps forty bits of entropy and
the stretching is what makes each guess cost 13 ms. A token has 256 and no
number of guesses at 256 bits is a threat; the digest is stored so that a copy
of the table is not a set of working links, and SHA-256 does that in a
microsecond. A reset endpoint that answered in 13 ms would be one that can be
walked.

**Expiry and single use are columns**, `expires_at` and `used_at` on the
caller's table, the way the password hash's row is the caller's. What this
settles is the three things that are the same in every application and wrong
in most: how wide, how sent, how compared.
