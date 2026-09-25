# Cookies and sessions

**A cookie is read where it lies and never decoded, and a session is a cookie with policy on top: sealed, never stored.**
The guide pages are [`guide/cookies.md`](../guide/cookies.md) and [`guide/sessions.md`](../guide/sessions.md), the names and signatures are [`reference/ctx.md#Cookie`](../reference/ctx.md#cookie) and [`reference/ctx.md#Session(T)`](../reference/ctx.md#sessiont), and the code is `http/cookie.zig` and `http/session.zig`, with the choke point every response header goes through in `http1.zig`'s `putHeader`.

## How the pieces fit

```
Cookie header (request)  ──►  c.cookie(name)   Str, borrowed, undecoded
handler's own struct T   ──►  s.set(value)  ──►  seal  ──►  Set-Cookie (response)
                                              │
                             [version][fingerprint of T][expires_at][fields]
                             XChaCha20Poly1305, key from the application
                             (opened under the current key, then each fallback)
```

`putHeader` is the one place every response header passes through, cookie or not, so a check written there covers every way of setting one. `Set-Cookie` and `Vary` are the two response headers that repeat instead of replacing, for opposite reasons.

## The rule in force

1. **Reading a cookie allocates and decodes nothing.** `c.cookie(name)` walks the `Cookie` header in place and hands back a `Str` into the request head, RFC 6265's cookie-octet is opaque and nilo does not guess at an encoding layered on top. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
2. **Every response header goes through `putHeader`, and it refuses three things**: a reserved name (`Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection`), a name outside RFC 9110's `token` grammar, and a value carrying a control byte below `0x21` other than SP/HTAB, or `0x7F`. All three are `fail.internal`, and the value is never quoted back. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
3. **`Set-Cookie` and `Vary` repeat rather than fold**, `http1.repeats(name)` lists them. `Set-Cookie` repeats because RFC 6265 forbids comma-folding a cookie; `Vary` repeats because CORS and a served static file each set it independently and folding it in `putHeader` would mean an arena allocation on the static-file path. An exact duplicate is dropped. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
4. **A cookie value cannot carry its own delimiter.** `;` has no escape in the grammar, so a value containing one is refused before anything is written, rather than silently producing a cookie with an attribute nobody wrote. `SameSite=None` without `Secure` is refused the same way, since current browsers drop it. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
5. **Cookie defaults are the careful ones**: `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`. Turning one off is a visible line rather than a forgotten one; `Secure` costs nothing locally because browsers treat `http://localhost` as a secure context. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
6. **A session is sealed whole into the cookie, and nothing is kept on the server.** The alternative, an opaque id and a server-side table, costs an allocation and a lookup per request, a lock shared across every request, an expiry sweep, and does not survive a restart; the sealed cookie costs none of that. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
7. **A session cannot be revoked, and nilo does not pretend otherwise.** "Sign out everywhere" is the application's own version number inside the session, checked against a lookup it already does. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
8. **`Session(T)` refuses a slice while compiling.** A cookie is roughly 4 KB and a browser drops an oversized one silently, so what a session may hold is numbers, bools, enums, fixed arrays, optionals and nested structs of those. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
9. **The sealed plaintext is `[version][fingerprint of T][expires_at][fields]`**, fields written one at a time rather than copied from the struct's memory, because a struct's layout is the compiler's to change. The fingerprint covers a field added or reordered, so a cookie sealed under an old shape is read as no cookie rather than as plausible garbage. `format_version` is 2. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
10. **The expiry is inside the seal, not only in `Max-Age`.** `Max-Age` is the client's to edit or drop; `expires_at` under the AEAD tag is a number the server wrote and `open` checks after decryption. `max_age = null` seals `default_max_age` (24 hours) even though it asks the browser to forget the cookie at the end of the session, because a copy of the cookie does not respect that request. An expired session answers `null`, the same as every other failure. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
11. **The cipher is `XChaCha20Poly1305`, encrypted rather than merely signed**, so a field like a role or a tenant id is not a thing the user can read back. The 192-bit nonce is generated fresh each time because there is nowhere on the server to keep a counter. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
12. **The secret is the application's and has no default**; `listen()` checks its length and refuses to start rather than sealing under zeroes. `Session(T)` with no secret set is a 500 naming the option. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
13. **`Session(T)` is a resolved value, decrypted once per request however many things ask, and reading and writing are separate calls** (`s.value` versus `s.set(...)`), because a mutated copy of a by-value argument would compile cleanly and go nowhere. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
14. **A fallback secret opens a cookie and never seals one**, so the secret changes without signing anybody out. The current secret is tried first, then up to three fallbacks in order; there is no key id in the cookie, because adding one would change the format and sign everybody out once. The sealed expiry bounds the wait: one `max_age` after the switch, nothing sealed under the old secret opens anyway. On several instances a rotation is two deploys, the new secret staged as a fallback first. A leaked secret is dropped, never kept as a fallback. [ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md)

## Decisions

| ADR | What it decides |
|---|---|
| [029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md) | Cookies as a mechanism: reading, the header choke point, and which headers repeat |
| [033](../adr/033-a-session-is-sealed-into-the-cookie.md) | A session as policy over that mechanism: sealed, encrypted, expiring, unrevocable |
| [225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md) | Rotating the secret: fallback secrets open and never seal, three at most, kept for one `max_age` |

Beside this topic: a `Session(T)` is not a `Token`, see [jwt](jwt.md) for the credential nilo verifies rather than issues; the clock the sealed expiry is checked against is [ADR 041](../adr/041-core-knows-what-time-it-is.md), see [id-clock-entropy](id-clock-entropy.md); the entropy the nonce is drawn from is [ADR 042](../adr/042-entropy-belongs-to-the-loop.md), also in [id-clock-entropy](id-clock-entropy.md).

## Open

Nothing is open.
