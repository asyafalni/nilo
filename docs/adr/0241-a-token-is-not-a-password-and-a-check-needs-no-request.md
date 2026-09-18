# 0241 — a token is not a password, and a check needs no request

**Status:** accepted
**Extends:** [ADR 0048](./0048-a-password-hash-is-gated-because-forgetting-is-silent.md),
which put the cryptography in `nilo_pw` and the Gate in `http/password.zig`;
[ADR 0046](./0046-entropy-belongs-to-the-loop.md), which decides where the
entropy comes from.

## Context

Two entries sat under `nilo_pw` on the roadmap, and the second turned out to
be the first one's caller.

**A token that is not a password had no home.** Every ordinary application
sends a password-reset link, an email verification and an API key, and the
recipe is the class of thing this repository builds modules for — the kind
that runs perfectly and is open: 32 bytes of entropy, base64url to send, the
*digest* stored rather than the token, a constant-time compare when it comes
back. What goes wrong in practice is the plaintext in the table, so that a
copy of the table is a set of working links; `std.mem.eql` on the compare;
or `id.v4` used as the token and kept exactly as it was sent. Nothing under
`pw/`, `id/` or any guide page said any of this, and a search of the guides
for "api key" and "reset" found nothing. A reader who reached for the one
secret-handling module the toolkit has found argon2id, which is the wrong
tool for this and looks like the right one.

**`verifyPassword` took a `Ctx` it did not use.** The first line of
`verifyWith` was `_ = c;`. Hashing needs a request because the salt comes
from `Ctx.entropy`; verifying reads the salt out of the stored string and
needs nothing from the request at all. The parameter was there for symmetry
with `hashPassword`, and what it cost was every caller that has no request:
a CLI that resets an account, a migration that re-hashes, a background job,
and a test that wants neither an App nor a fake Ctx all had to go through
`nilo_pw` directly — and so outside the Gate, which is the one thing
ADR 0048 said was not the caller's to remember.

## Decision

**`pw.Token` is the token that is not a password, under `nilo_pw`.** It is
32 bytes, made from entropy the caller brings — `try c.entropy(pw.token_len)`
in a handler, `std.Io.randomSecure` outside one — for the reason a salt is
(ADR 0046): the module has no Bulkhead to ask through, and being handed the
bytes is what keeps `zig test pw/pw.zig` running with no module graph.
`text()` is the 43 characters of base64url to send, by value; `digest()` is
the SHA-256 to store, by value; `Token.matches(stored, presented)` decodes,
hashes and compares in constant time; `Token.parse(presented)` is the token
read back, for the lookup where the digest is the key — an API key arrives
on its own, and the row is found by `parse(header).?.digest()`. Nothing
allocates and nothing takes an allocator.

**Every wrong presented value is `false`, and so is every wrong stored one.**
The wrong length, a character outside base64url, a padded spelling: one
answer, because which way a token was wrong is not something to tell whoever
presented it. And `stored` is a slice rather than a `[32]u8`, because that is
what a `bytea` column hands back — which makes a table that stored the
43-character text instead of the digest answer `false` on every row. The
mistake the digest exists to prevent fails closed and is found by the first
test rather than by the first attacker.

**No argon2, on purpose.** The stretching one file over exists because a
password has perhaps forty bits of entropy and 13 ms a guess is what makes
that survivable. A token has 256 bits and no number of guesses at 256 bits
is a threat; the digest is stored so that a copy of the table is not a set of
working links, and SHA-256 does that in a microsecond. Stretching would buy
nothing and cost a reset endpoint that answers in 13 ms, which is a reset
endpoint that can be walked.

**It lives under `nilo_pw` rather than in a module of its own**, settled by
the import rule: it needs `std.crypto` and nothing else, which is what `pw/`
already is (ADR 0042). And under `pw` rather than `id`, because a `Uuid` is a
key and a `Token` is a secret, and putting them on one page invites the
substitution the roadmap named.

**`nilo.verifyPassword(gpa, stored, text)` is the check with no request in
hand**, and `nilo.verifyPasswordWith(cost, …)` the same told what a hash
costs. It is `http/password.zig`'s `verifyAnywhere`: the same Gate and the
same blocking pool as the method, so a job on the server's loop holds one of
the eight permits like a sign-in does, and a CLI with no loop runs the call
inline — which is what `nilo.blocking` does outside a fiber (ADR 0003).
`c.verifyPassword` stays with its signature and calls it. There is no
`nilo.hashPassword` beside it, and that asymmetry is the point: making a
hash needs entropy, and the loop is where the wait for entropy is paid for.

## What was rejected

**Dropping the `Ctx` from `verifyPassword`.** The honest signature, and a
breaking change to a method that shipped and that every sign-in handler
calls, to remove a parameter that costs those handlers nothing. A second
name for one job is a real cost; a break for nothing is a larger one. The
free function is the shape that breaks nobody, and the method's doc says
which to reach for.

**A `c.token()` method, the way `c.hashPassword` is one.** `hashPassword` is
a method because it holds a permit and parks a fiber and forgetting to is
silent (ADR 0048). A token holds nothing and waits for nothing: SHA-256
over 32 bytes. `pw.Token.new(try c.entropy(pw.token_len))` is the same one
expression `id.v7(try c.entropy(…), …)` is, and ADR 0046 already decided
that shape. A method adding a name and nothing else is the second name for
one job that the paragraph above was careful not to add.

**A width the caller chooses, `Token(bits)`.** One width is what makes the
text one length, which is what lets `matches` refuse anything else before
decoding it, and what makes `text()` a `[43]u8` by value rather than a slice
into somewhere. Sixteen bytes is what a UUID holds, and the one message
`new` writes says so: `pw.Token.new(uuid.bytes)` is refused in nilo's words
rather than std's, and the refusal names where 32 bytes come from.
`new` takes `anytype` for that message and for nothing else.

**Expiry and single use in the module.** Both are columns in the caller's
table — `expires_at`, `used_at` — and the row is the application's the way
a password hash's row is. What is the same in every application and wrong
in most is how wide, how sent and how compared, and that is the whole of
what shipped.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0. `Token` is 32 bytes on the stack; `text()` 43 and `digest()` 32, by value |
| Memory per idle connection | 0. Nothing here suspends a fiber, so no frame is held across a wait. `nilo.verifyPassword` parks where `c.verifyPassword` did, in the same frame |
| Throughput and p99 | unchanged; no request path changed. One `Token` round trip is one SHA-256 and one base64 pass over 32 bytes |
| Binary size | a program that never names `pw.Token` links none of it. One that does links SHA-256 and a base64 codec from std; not measured, because a program with a session already links both |

The Gate path is one call deeper: `verifyWith` is now `_ = c;` and a call
to `verifyAnywhereWith`, which the compiler inlines or does not, on a path
that is about to spend 13 ms.

## What proves it

`pw/token.zig`: the text is 43 characters of base64url and reads back; the
digest is stable, is SHA-256 and is not the token; the text that was sent
matches the digest that was stored; a flip at every one of the 43 positions
is `false`; the wrong length, garbage, a padded spelling and an empty string
are `false`; a table that stored the text instead of the digest matches
nothing; two tokens never share a digest. `pw/refusals/pw_token_from_a_uuid.zig`
holds the width message. `http/password.zig`: a stored hash is checked with
no App, no Client and no Ctx, and the no-account and not-a-hash answers are
the ones the method gives.
`refusals/password_checked_off_the_loop_below_the_floor.zig` holds that the
Cost floor is reached through the new door.
