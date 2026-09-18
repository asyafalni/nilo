# 0242 — the key decides the algorithm

**Status:** accepted
**Extends:** [ADR 0140](./0140-nilo-verifies-a-token-and-does-not-fetch-one.md),
whose first rule this is the second reading of.
**Breaks:** `jwt.Key`, which was `kid`, `e`, `n` and is now `kid` and a
`material` union.

## Context

ADR 0140 admitted RS256 on one argument: a caller *can* write it on
`std.crypto.Certificate.rsa`, and the reason it ships anyway is that
getting it subtly wrong runs perfectly and leaves the endpoint open. It
listed the ways, and the first two were about `alg` — read it and do what
it says, and `none` is a signature; read it and dispatch, and an HMAC
under the published modulus is one. The module's answer was a constant:
`verify` does RS256, and the header is compared against the string.

An issuer this could not read then turned up, and it is the one most
likely to be paired with a Zig API. Supabase Auth signs ES256 — ECDSA over
P-256 with SHA-256 — as does Apple, and a token from either was
`error.WrongAlgorithm` here. The right refusal, and still a refusal. The
arithmetic is `std.crypto.sign.ecdsa.EcdsaP256Sha256`, so ADR 0140's
argument admits this the way it admitted RS256: what nilo adds is the
order of the checks and the refusal of everything else.

What the second algorithm changes is the first rule. "The algorithm is a
constant" was true of a module with one; a module with two has to say
where the choice is made, and there is exactly one wrong place to make it.

## Decision

**The key decides the algorithm. The header is compared, twice, and never
consulted.**

A JWKS key that says `"kty":"RSA"` is read as RS256 material — `e` and
`n`. One that says `"kty":"EC"` is read as ES256 material — `crv`, `x`
and `y`. `jwt.Key` carries which as a `material` union, and `token.zig`
switches on it after the `kid` match. The header's `alg` is looked at at
two points, both refusals:

1. **Before the key is looked up**, against the two names this module
   knows. `none`, `HS256`, `ES384` and everything else stop here, and so
   never reach a `kid` match — which is what keeps the `none` test in
   `token.zig` reading `WrongAlgorithm` rather than `NoSuchKey` against a
   set with two keys in it.
2. **After the key is found**, against the one name that key answers to.
   `ES256` over an RSA key is not "try ECDSA". It is a mismatch, and it is
   refused the way `none` is, before any arithmetic.

So a key set holding an RSA key and an EC key — what an issuer publishes
mid-migration, and what Supabase's does — cannot be talked into checking
one with the other. The token names a `kid`; the `kid` names a key; the
key names the algorithm; the header either agrees or the token is refused.
At no point does anything in the token pick code.

**A curve nilo has no branch for is refused by name, not skipped.** An
`EC` key with `crv` other than `P-256` is kept by `parseKeys` and is
`error.CurveNotSupported` at `verify`, the way an RSA key of an unhandled
size is `KeySizeNotSupported`. Skipping it at parse would turn the token
into `NoSuchKey`, which the guide tells the caller means "refetch" — and
they would refetch forever. A key of another *type* — Ed25519, a key
marked `enc` — is still skipped, because that one an issuer adds without
meaning anything about this program.

**The JWS signature is raw `r || s`, and the file says so at the top.**
Sixty-four bytes, each integer padded to the curve's width, per RFC 7518
§3.4. Every other place an ECDSA signature appears — a certificate,
`openssl dgst`, a `.sig` file — is DER, seventy bytes or so with a
variable length, and std offers both decoders side by side. This is the
one place a first attempt at ES256 goes wrong, so `es256.zig` names it
before the imports and a DER signature arrives as
`error.SignatureWrongLength` rather than as a `BadSignature` that costs
an afternoon.

## What was rejected

**Dispatching on the header's `alg` and then checking the key's type
agrees.** The same two comparisons in the other order, and the same
outcomes on every input this module's tests can name. Rejected because the
order is the thing ADR 0140 argued: a reader who sees `switch (alg)` at
the top of `verify` learns that the token picks the code path, and the
next contributor who adds a branch adds it there. Switching on the key
teaches the opposite, and the header comparisons read as the refusals
they are.

**Skipping unknown curves at `parseKeys`, the way unknown key types are
skipped.** Simpler, and one fewer error. Rejected above: it turns a key
nilo cannot use into a key that is not there, and the module already
tells callers what a missing key means.

**An `alg` field on `Options`, to pin one algorithm per call.** Belt and
braces, and a caller mid-migration would have to know which their issuer
is on this week. The key set already knows.

## What proves it

- RFC 7515 Appendix A.3, verbatim: the header, the payload with its
  `\r\n`s, the sixty-four-byte signature and the public half of the key in
  A.3.1, re-verified against an independent P-256 before being pinned in
  `jwt/vector.zig`. A vector produced by the code under test proves the
  code agrees with itself; the RFC's proves it agrees with the RFC.
- The same `r` and `s` as DER, refused by length.
- A header saying `ES256` over the RSA key, and one saying `RS256` over
  the EC key, both `WrongAlgorithm` against the mixed set — and the honest
  header over the EC key with the wrong signature getting as far as
  `BadSignature`, which is the comparison after the mismatch doing its
  job.
- `ES384` over a one-key set that would otherwise answer, refused before
  the lookup.
- A `P-384` key, kept by `parseKeys` and refused by name at `verify`.

## What it costs

**Allocations:** none that RS256 did not already make. The SEC1 point is
sixty-five bytes on the stack, the signature is read from the same scratch
arena the RS256 one is, and `parseKeys` decodes three base64url fields
into its arena where it decoded two.

**Stack, estimated and not measured:** `Signature.verify` holds a Sha256
state, two scalars and a point in its `Verifier`, and `mulPublic` builds
a nine-entry table of P-256 points — each three field elements of thirty-two
bytes — so the deepest frame is on the order of 1.5–2 KB above the caller.
That matters here for the reason ADR 0063 gives: a handler that verifies
on its own fiber holds its high-water mark for the life of the connection.
The RS256 path was never measured either, and a 2048-bit modular
exponentiation is not smaller. The roadmap's "a verification has no number
against it" now covers both.

**Binary size:** unmeasured; the coordinator will take the stripped
`ReleaseFast` number. A program that imports `nilo_jwt` now links P-256
whether or not its issuer signs with it, since the switch on `material` is
a run-time one. A program that does not import the module links neither,
which is a linker fact rather than a promise.

**Throughput:** nothing on any request path that did not call `verify`.

## Two things it found

Both are the same mistake and neither was ES256's. `std.json.parseFromSlice`
defaults to `.alloc_if_needed`, which hands back a slice *into the input*
for any string with no escapes in it. `parseKeys` read `kid` that way, so
a key set parsed from a response body pointed into the body; and `verify`
read the caller's `Claims` that way, so `claims.sub` pointed into
`payload_bytes` in the scratch arena that `verify` frees on the way out —
while the doc comment on both promised the opposite. No test caught it
because every test hands `verify` an arena, and a scratch arena freed back
into an arena gives nothing up — which is also why `c.arena()` in a handler
works, by accident, and a real allocator would not have. The ReleaseSafe
gate cannot see a dangling pointer into memory nobody reused. Both parses
say `.alloc_always` now, and each is held by a test that frees or
overwrites the bytes it would have pointed at: the claims are freed one
string at a time on `std.testing.allocator`, which refuses a pointer it
did not hand out.
