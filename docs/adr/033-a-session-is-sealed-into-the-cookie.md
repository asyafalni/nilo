# A session is sealed into the cookie

**Status:** accepted
**Topic:** [cookies-sessions](../design/cookies-sessions.md)

## Context

[ADR 029](029-a-header-is-checked-once-and-two-of-them-repeat.md) gave nilo cookies and stopped there, on purpose: `c.setCookie` and `c.cookie` are the mechanism, and what goes in the cookie is policy. The roadmap sat on sessions for a release with the note that "it is not obvious there is a shape nilo should have an opinion about rather than an example of." That was wrong, and what settled it was reading how somebody else answered it: jetzig keeps the whole session **in the cookie**, encrypted and signed, with no server-side store at all. That is a shape nilo can have an opinion about, because the reason to prefer it is [ADR 017](017-the-trade-budget-has-four-axes.md)'s memory and throughput rows rather than taste.

Once the mechanism shipped, it turned out to promise more than it did. The only thing bounding a session's life was `Max-Age` on the cookie, an instruction to a browser, which a browser obeys and nothing else does: a copy taken out of a proxy log, a `curl -v` pasted into a ticket, a backup, or somebody else's machine opens the cookie and goes on opening it until the secret is rotated, which signs out everybody at once. The guide had already promised otherwise, offering `s.setWith(.{ .user = id }, .{ .max_age = 30 * 24 * 60 * 60 })` under *Staying signed in* and, three paragraphs later, saying a cookie somebody copied still opens: two true sentences about two different things, read together as one wrong one. This is not the revocation gap below, whose answer needs a store; an expiry needs no store at all, since it is a number the server already knows when it writes the cookie.

## Decision

### The alternative, and why it loses

The obvious design is the one every framework with a database reaches for: the cookie carries an opaque id, and the server keeps a table of id → session. Costed against ADR 017 it is expensive in exactly the places nilo has said it will not spend. Memory per idle connection is the wrong metric here, but memory per *signed-in user* is a new one, and it is unbounded: a million idle sessions is a million rows nobody is reading, plus whatever it takes to find one. It costs an allocation per request, at least, since the id has to be looked up. It needs a lock, on the table shared across every thread serving requests, on the path of every authenticated request rather than only the ones that write. It needs an expiry sweep, a background fiber or a check on every read. And it does not survive a restart, so the honest version of it is not a table, it is Redis, a dependency nilo would be pushing onto every application that wants a login.

The sealed cookie has none of that. Nothing is stored, so there is nothing to sweep, nothing to lock, nothing to lose on restart, and nothing added to the 4,669 bytes an idle connection holds ([ADR 062](062-where-a-connection-waits-is-what-it-costs.md)). A request that does not ask for a session runs the code it ran before.

### What it costs instead

**A session cannot be revoked.** A sealed cookie is valid until it expires, so "sign out everywhere" is not a thing the mechanism can do by itself. The application's answer is a number in the session it checks, a token version bumped on password change, a lookup the application already does. nilo does not pretend otherwise.

**It is about 4 KB, and the ceiling is real.** A browser drops an oversized cookie silently, no error, no warning, a session that simply never appears. That is why what a session may hold is a fixed-size struct, numbers, bools, enums, `[N]u8`, optionals and nested structs of those, and why `Session(T)` refuses a slice at compile time.

**It goes up the wire on every request.** A 200-byte session is 200 bytes on every request to every path, static files included, which is the argument for keeping an id in it rather than a profile.

### The failure that shaped the format

Add a field to the session struct and deploy: every cookie already out there was written to the old shape, and decrypted against the new one it is not corrupt, it is **plausible**. The bytes that were a `bool` are now the low byte of a `u32`, and somebody is signed in as the wrong user. So the sealed plaintext is not just the fields: a version byte, a 32-bit fingerprint of the shape of `T` (its field names in order, with their types), then the fields, written field by field, little-endian, with no padding, rather than by copying the struct's memory, since a struct's layout is the compiler's to change. A cookie whose fingerprint does not match this build is treated as no cookie at all: the person signs in again. The fingerprint covers reordering as well as adding, which a size check alone would not: two fields the same total width in a different order are still the same byte count, and reading one as the other silently swaps two ids.

### The seal carries its own expiry, and `open` refuses it after

**The plaintext is `[version:1][fingerprint:4][expires_at:8][fields]`**, with `expires_at` in seconds since the epoch, little-endian, and `format_version` is 2. **Inside the seal rather than beside it**, which is the whole decision: an expiry in the cookie's own `Max-Age` is the client's to edit or drop, one under the AEAD tag is the server's, read only after `Cipher.decrypt` has succeeded, so it is a number this server wrote. `Options.max_age` fills both halves from one number, the cookie attribute as before and the sealed expiry, new: an application that wants thirty days writes thirty days once and gets it in both places.

A session cookie still has a ceiling even with no `max_age`. `max_age = null` means "ask the browser to forget this at the end of the window," which is the right default for a sign-in but says nothing to a copy, so null seals `default_max_age`, **24 hours**: long enough that nobody working an ordinary day is signed out, short enough that a leaked cookie is a problem with an end. It is a ceiling on the copy, not a target for the browser.

**An expired session is `null`, like every other failure.** Tampered, truncated, wrong-secret, wrong-shape and now expired all answer the same thing, because the application has one thing to do about all of them; expired does not become a distinguishable state that invites treating it as "nearly signed in."

**`openAt(T, text, key, now)` is public and `open` calls it**, which is [ADR 032](032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) applied: an expiry that could only be exercised by waiting a day is a guard that would only ever be *seen to pass*. With `openAt`, the moment before, the moment of and the moment after are three lines in a test, and it is also what lets an application stand a session at any age it likes without moving the machine's clock.

### `XChaCha20Poly1305`, and why encrypted rather than signed

A signed-but-readable cookie, the JWT shape, would have been less code, and is rejected for one reason: it makes every field of the session a thing the user can read, a decision the application would be making by accident. A session holding a tenant id, a role, or an internal user number should not be a thing anybody pastes into a decoder. The cipher is `std.crypto.aead.chacha_poly.XChaCha20Poly1305`, and the choice is mostly about the nonce: there is nowhere to keep a counter, since the whole point is that the server holds nothing, so the nonce has to be random, and XChaCha20's 192 bits is precisely wide enough for random to be safe, where AES-GCM's 96-bit nonce is not at this volume without care nobody should have to take. Being in `std.crypto` is the other half: [ADR 027](027-tls-is-terminated-in-front.md) refused TLS partly because the alternatives were a one-person crypto dependency or a C toolchain in the install story, and a session that needed either would have reopened that argument.

### The secret is the application's, and it is checked at `listen()`

Where the secret comes from, an environment variable, a mounted file, a secrets manager, is the application's, the same line [ADR 015](015-resolved-values-are-declared-by-their-type.md) draws around authentication. There is no default: a default key is a key everybody who has read this repository already has, and the failure mode of shipping with it is not a crash, it is a forgeable session. `Session(T)` with no secret set is a 500 naming the option, never a cookie sealed under zeroes. `listen(.{ .session_secret = … })` checks the length there and stops the server with a message, because a secret of the wrong length is a deployment mistake and startup is the moment somebody is watching. It has to be the same on every instance and survive a restart; the symptom otherwise is users being randomly signed out, a long way from its cause.

### `Session(T)` is a resolved value, and reading is not writing

It carries `nilo_resolve` like any other resolved value ([ADR 015](015-resolved-values-are-declared-by-their-type.md)), so a handler asks for it by writing it in its argument list, and the cookie is decrypted once per request however many things ask. Reading and writing are separate calls on purpose:

```zig
fn signIn(s: nilo.Session(Signed)) !nilo.Redirect(303) {
    try s.set(.{ .user = id });     // and not: s.value.user = id
    return .to("/");
}
```

A resolved value is handed to the handler **by value**. A mutated copy would go nowhere, compile cleanly, and look exactly like it had worked; `set` is a line in a diff instead, next to the `c.setCookie` it turns into.

## What was rejected

**Trusting `Max-Age` and doing nothing.** What there was before. It works right up until somebody has a copy of the cookie, which is the only case an expiry is for.

**A separate `lifetime` option beside `max_age`.** Two knobs that must agree, on a feature whose failure mode is silent. One number is the point.

**No ceiling when `max_age` is null.** Reads as the conservative choice and is the opposite: a session cookie is the default, so "no ceiling unless you ask" leaves the common path unbounded and the rare one bounded.

**Milliseconds for the expiry.** `Max-Age` counts seconds, a session measured to the millisecond is a session nobody asked for, and it would cost the same eight bytes for a range nobody uses.

**Sliding expiry, re-sealing on each request to extend it.** Puts a `Set-Cookie` on every response that carries a session, a header on the hot path for a policy nobody asked for; an application that wants it calls `s.set` with the value it already has.

**Keeping `format_version` at 1.** The size check refuses a version-1 cookie anyway, since the plaintext grew by eight bytes; bumping it means the guard that fires is the one that can say why.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | Unchanged at zero. The expiry is eight bytes inside a fixed-size buffer already there. |
| Memory per idle connection | Unchanged; nothing about a session is stored anywhere. |
| Throughput and p99 | One clock read per request that carries a session cookie, none for one that does not: `nilo_core`'s clock is a vDSO read measured at **15ns** ([ADR 041](041-core-knows-what-time-it-is.md)), against an XChaCha20Poly1305 decrypt on the same path. A route with no session is untouched. |
| Binary size | Not measured; two `readInt`/`writeInt` calls and a comparison on a path only a session reaches. |

**Cookie size grew by 12 bytes on the wire** (eight bytes of plaintext through base64); `max_cookie_bytes` stayed at 3,800, so what a `Session(T)` may hold shrinks by those eight bytes, and the refusal that names the size a struct would need is checked by `zig build refusals`.

The one behaviour change a user can see, and it is a real one: everybody holding a session was signed out the day the plaintext layout moved, the same thing adding a field to the session struct has always done, and from then on a session cookie that used to work indefinitely stops after a day unless `max_age` says otherwise.

### Rotation

Changing the secret used to sign everybody out at once. [ADR 225](./225-a-fallback-session-secret-opens-and-never-seals.md) adds fallback secrets, which open a cookie and never seal one, and the expiry above is what bounds how long one has to be kept: one `max_age`.
