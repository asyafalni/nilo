# A verified signature is remembered by the token's digest

**Status:** accepted
**Topic:** [jwt](../design/jwt.md)
**Applies:** [ADR 191](./191-verified-claims-are-a-handler-argument.md)
(a handler names `nilo.Verified(T)` and the ring does the rest).
**Found by:** a query engine whose every request carries the gateway's
bearer token, measured at 2.2 ms a cache hit with 419 µs of it in
`es256.verify` — the same token, the same key, the same answer, ten
thousand times a second.

## Context

A ring verifies a token by decoding it, finding the key, checking the
signature and then the claims. The signature is the expensive part — P-256
verification is ~400 µs in the standard library, RSA-2048 more — and it is
the one part whose answer does not change between two requests: the same
bytes under the same key verify or they do not. The claims are about *now*
and are cheap.

A service behind a gateway sees a handful of long-lived service tokens; a
site sees one token per user for the length of a session. Either way most
verifies are of bytes the ring has already seen.

## Decision

`Keyring.Options.remember_tokens` (default 0: nothing changes for a
program that does not ask) sizes a memo of SHA-256 digests of tokens whose
signature verified under the set the ring holds. A verify hashes the
token first; a digest in the memo skips the signature check and nothing
else — `exp`, `nbf`, `iss` and `aud` are checked on every call. A miss
runs the signature check and, if it passes, remembers the digest. The
memo is fixed-size and indexed: open addressing on the digest's first
eight bytes, a probe window of eight, a table twice the capacity asked for
so it is never past half load. A lookup is at most eight comparisons
whatever the capacity — a linear scan under the lock, which the first
draft had, would have made a ring remembering a thousand tokens spend a
thousand comparisons on every request that came with a fresh token. An
insert that finds its window full evicts the home slot; a memo forgets by
design, and what it never does is answer for a digest it was not handed.
It is emptied by `load`, *after* the old set's readers have drained: a
reader still pinned on the old set is verifying under its keys, and a
clear at the swap would have let it remember that digest a moment later,
under keys the ring no longer holds. A key that is gone has verified
nothing, and a rotation must be felt at once.

The digest is over the whole token, so a changed signature, header or
payload is a different token and is checked. Full 256-bit digests, not a
truncation: the memo decides whether the arithmetic runs, so a collision
would be a forged token accepted, and a 64-bit hash is a birthday problem
somebody can afford.

## The alternatives that were rejected

**Remember the claims and skip the decode too.** The claims are checked
against now, so the memo would have to store `exp` and the rest and
re-run the checks against the stored values — the same work, in a second
place, with a `Claims` type the memo cannot copy generically. Decoding a
payload is microseconds; only the arithmetic was the cost.

**A memo in the Verifier rather than the ring.** The ring is what knows
when the keys changed, and forgetting on rotation is the whole of what
makes the memo sound. A memo outside it would need a hook back in.

**Leave it to the caller.** A handler cannot cache what
`nilo.Verified(T)` resolves before it runs.

## Consequences

- ES256 verify on a remembered token: 419 µs → a SHA-256 of the token
  and at most eight comparisons in the memo. On the engine that found this, a cache hit
  went from 2.2 ms to under a millisecond at sixteen connections.
- `hits` and `misses` on the memo say what it is worth on a given ring.
- 33 bytes a slot and two slots a remembered token, so `remember_tokens =
  1024` is 66 KiB.
- The memo is per ring, so two rings never share a digest; a token that
  verified under one issuer says nothing to another.
