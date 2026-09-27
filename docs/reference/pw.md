# nilo_pw

**`nilo_pw` hashes and checks passwords with Argon2id, and makes the random tokens behind reset links and API keys.**

**Guide:** [Sessions](../guide/sessions.md) (signing in, and tokens that are not passwords) · **Design:** [Layering](../design/layering.md) (pw is one of its single-ADR topics)

## `nilo_pw`

Password hashing ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)): Argon2id, in the PHC string format everybody else writes.

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
| `c.hashPassword(gpa, text)` | `!pw.Hash`: the call a handler makes |
| `c.verifyPassword(gpa, stored, text)` | `!bool`. `stored` is `?[]const u8` |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, if you hash at a Cost other than the default |
| `nilo.verifyPassword(gpa, stored, text)` | `!bool`: the same check with no request in hand (a CLI, a job, a test). Same Gate, same pool |
| `nilo.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what your hashes cost |
| `pw.needsRehash(stored, cost)` | `!bool`: whether this row was hashed with a weaker Cost than you use now |
| `pw.huge_pages` | the allocator to pass: the 19 MiB in 2 MiB pages, 11.0 ms against 13.6 |
| `stored.text()` | the PHC string, `$argon2id$v=19$m=19456,t=2,p=1$…` |
| `pw.Cost.default` | OWASP's first recommendation: 19 MiB, 2 passes, 1 lane |
| `pw.Cost.floor_memory_kib` | 7168. Anything below it is a compile error |
| `pw.salt_len` | 16 |
| `pw.bytesFor(cost)` | how much one hash asks the allocator for. 19,922,944 at the default |
| `pw.hash` / `pw.hashWith` / `pw.verify` / `pw.verifyWith` | the plain functions, for a program with no server |

### Call the `Ctx` methods

**In a handler, call the `Ctx` methods, not `nilo_pw` directly.** One hash takes 13 ms and 19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so calling the module directly from a handler blocks the thread on every sign-in, and **nothing in the log ever says so**. The methods take the salt from `c.entropy`, park the fiber on the blocking pool, and hold one of the `listen(.{ .password_hashes_at_once = 8 })` permits.

### `stored` may be null

**`stored` is optional on purpose.** A sign-in for an address with no account has no hash to check. Returning early there answers in a millisecond instead of thirty, which turns the sign-in form into a way to ask which addresses are registered. Passing null does the work anyway and returns false, **at the Cost you give `verifyPasswordWith`**. That is why the method exists: the work done for a missing account has to match the work done for a real one ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

### The allocator

**`gpa` is an argument because 19 MiB should be visible.** Do not pass `c.arena()`: the request arena is reset per request and keeps `arena_keep` bytes, and pushing 19 MiB through it breaks the memory budget nilo treats as an invariant. Pass `pw.huge_pages` and the same 19 MiB arrives in ten pages instead of 4,864: 11.0 ms a hash instead of 13.6, with nothing held between hashes. On any system other than Linux it *is* `std.heap.page_allocator`, so the call reads the same everywhere.

### The PHC format

**A hash made elsewhere verifies here**, at any parallelism, and a hash made here can be read by anything that reads PHC. That compatibility is the only reason to use a standard format.

### Checking without a request

**Checking a password needs no request; hashing one does.** The salt of a stored hash is inside the string, so `nilo.verifyPassword` is the method without the `Ctx`. It uses the same Gate and the same blocking pool, for a CLI resetting an account, a job re-hashing at a raised Cost, or a test with neither an App nor a Ctx. With no event loop at all it runs inline. There is no `nilo.hashPassword`, because a hash needs entropy, and `c.entropy` is where the wait for it is paid ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

## A token that is not a password

For a password-reset link, an email verification or an API key ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)): thirty-two bytes of entropy, 43 characters to send, a SHA-256 digest to store, and a constant-time compare when it comes back.

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

### `pw.Token`

| | |
|---|---|
| `pw.Token.new(entropy)` | `Token`, from `try c.entropy(pw.token_len)`, or `std.Io.randomSecure` outside a request |
| `pw.token_len` | 32: the bytes of entropy a token is made from, and `Token.len` |
| `token.text()` | `[43]u8`, base64url with no padding: the form to send. Safe in a URL, a header and an email |
| `token.digest()` | `[32]u8`, SHA-256 over the bytes: the form to store. `Token.Digest` is the type |
| `pw.Token.matches(stored, presented)` | `bool`: decode, hash, compare in constant time. `stored` is the `[]const u8` a `bytea` column returns |
| `pw.Token.parse(presented)` | `?Token`: the token read back, for a lookup where the digest is the key: `parse(header).?.digest()` |

**Every wrong answer is `false`.** A presented value of the wrong length, a character outside base64url, or a padded spelling all get the same answer, because the person presenting it should not learn which way it was wrong. A stored value that is not 32 bytes is also `false`. That is what a table that stored the 43-character text instead of the digest returns on every row, so the mistake the digest exists to prevent fails closed.

**No Argon2, on purpose.** A password has perhaps forty bits of entropy, and the stretching is what makes each guess cost 13 ms. A token has 256 bits, and no number of guesses is a threat at that size. The digest is stored so that a copy of the table is not a set of working links, and SHA-256 does that in a microsecond. A reset endpoint that took 13 ms per check would be easy to overload.

**Expiry and single use are columns** (`expires_at` and `used_at`) on your own table, the same way the password hash lives in your own row. What this module settles is the three things that are the same in every application and wrong in most: how long the token is, how it is sent, and how it is compared.
