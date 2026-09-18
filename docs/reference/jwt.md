# nilo_jwt

One page of [the reference](./README.md): checking somebody else's signed token.

## `nilo_jwt`

Checking somebody else's signed token, and nothing that needs a loop
([ADR 0140](../adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)). A
tool module: it imports nothing, so `zig test jwt/jwt.zig` runs the whole of
it.

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
};

fn signIn(gpa: std.mem.Allocator, keys: *const jwt.Keys, id_token: []const u8) !Claims {
    return jwt.verify(Claims, gpa, id_token, .{
        .keys = keys,
        .issuer = "https://accounts.google.com",
        .audience = "…apps.googleusercontent.com",
        .now_s = @divFloor(nilo.nowMillis(), 1000),
    });
}
```

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys` — a JWKS document read into the keys it can verify with: `RSA`, and `EC` on `P-256` |
| `keys.deinit()` | frees the lot |
| `keys.find(kid)` | `?Key`. A set with one key answers for a token that named none |
| `key.material` | `.rsa = .{ .e, .n }` or `.ec = .{ .crv, .x, .y }` — which one decides how a token under it is checked |
| `key.algorithm()` | the `alg` a token signed with this key has to say: `RS256` or `ES256` |
| `jwt.verify(Claims, gpa, token, opts)` | `!Claims` — the whole check, then the payload |
| `jwt.key_sizes` | the modulus lengths that have a branch: 256, 384, 512 bytes |
| `jwt.curves` | the curves that have a branch: `P-256` |

`Options`:

| | |
|---|---|
| `.keys` | `*const Keys`, the issuer's |
| `.issuer` | refuse a token whose `iss` is not this. Null skips it |
| `.audience` | refuse a token whose `aud` does not carry this. Null skips it |
| `.now_s` | seconds since the epoch. An argument, not a clock |
| `.leeway_s` | how far the two clocks may disagree, both ways. `0` |

**Fetching the key set is yours.** It is an HTTPS GET, which `nilo_fetch`
already sends, and holding the answer is `nilo_cache`. What this module does
is the half where being wrong is silent.

<!-- compiles: body -->
```zig
const res = try client.get(&run, "https://www.googleapis.com/oauth2/v3/certs", .{});
var keys = try jwt.parseKeys(gpa, res.body.view());
defer keys.deinit();
```

**Three things are not options**, because each of them is a way to write a
verifier that passes every test and is open:

- **The algorithm is the key's, never the token's `alg`.** An `RSA` key is
  checked as RS256 and an `EC` key on `P-256` as ES256, and the header is
  only compared: `{"alg":"none"}` and an HMAC signed with the RSA modulus
  you published are refused before a key is looked up, and `ES256` over an
  RSA key is a mismatch rather than a request
  ([ADR 0242](../adr/0242-the-key-decides-the-algorithm.md)).
- **Nothing in the payload is read until the signature has passed.** An `exp`
  off an unverified token is a number somebody chose.
- **`exp` is required.** A credential with no end is not one.

Strings in the returned claims point into the allocator you passed. Hand it
`c.arena()` and there is nothing to free.

| what it answers instead | when |
|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON |
| `error.WrongAlgorithm` | the header says anything but `RS256` or `ES256`, `none` included — or says one of them over a key of the other kind |
| `error.NoSuchKey` | the `kid` is not in the set, or none was named and the set has more than one key |
| `error.BadSignature` | the key is right and the signature is not |
| `error.NoExpiry` / `error.Expired` / `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not arrived |
| `error.WrongIssuer` / `error.WrongAudience` | `iss` or `aud` is not what you named |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits |
| `error.CurveNotSupported` | an EC key whose `crv` is not `P-256` |
| `error.SignatureWrongLength` | a signature that is not the size of its key — for ES256, sixty-four bytes of `r \|\| s`, which is where a DER signature lands |
| `error.KeyNotUsable` | a key the set carried that the arithmetic cannot use: an even RSA exponent, an EC coordinate that is not thirty-two bytes or not on the curve |

**What it will not do**: HS256, any curve but P-256, encrypted tokens, signing,
discovery, PKCE and the nonce. Signing is absent because a server issuing its
own sessions has [`Session(T)`](./ctx.md#sessiont) and needs no token; the rest is the
sign-in flow, which is yours.
