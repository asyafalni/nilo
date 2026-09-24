# Checking somebody else's token

`nilo_jwt` verifies a JWT that an identity provider signed — a Google ID
token, an Auth0 or Clerk access token, a Keycloak or Cognito bearer, a
Supabase session — and reads the claims into a struct of your own. RS256
and ES256, which between them are what those issuers sign with. It is a
tool module: no event loop, no allocator of its own, and it imports
nothing, so `zig test jwt/jwt.zig` runs the whole of it
([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).

**It is for a token somebody else issued.** A sign-in your own server keeps
is a [`Session(T)`](./sessions.md), sealed into a cookie, and needs no token
at all. The word *token* here only ever means a credential that arrived from
outside ([`CONTEXT.md`](../../CONTEXT.md#tokens)).

```zig
const jwt = @import("nilo_jwt");
```

and one line in `build.zig`, beside the `nilo_http` one:

```zig
.{ .name = "nilo_jwt", .module = nilo.module("nilo_jwt") },
```

## The whole of it

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool = false,
};

fn whoIsThis(gpa: std.mem.Allocator, keys: *const jwt.Keys, token: []const u8) !Claims {
    return jwt.verify(Claims, gpa, token, .{
        .keys = keys,
        .issuer = "https://accounts.google.com",
        .audience = "1234-abcd.apps.googleusercontent.com",
        .now_s = @divFloor(nilo.nowMillis(), 1000),
    });
}
```

`verify` does everything, in the order that is safe, and answers the claims
or one of the errors [below](#what-it-answers-instead). Three things decide
the shape of the call:

- **`Claims` is yours.** One field per thing the application wants out of the
  token; fields the token carries and the struct does not name are ignored.
  The registered claims — `iss`, `aud`, `exp`, `nbf` — are checked whether or
  not the struct mentions them, so a `Claims` with only `sub` in it is still
  a full check.
- **Strings in the answer point into `gpa`.** Hand it `c.arena()` inside a
  request and there is nothing to free; hand it a real allocator and the
  strings are yours to free.
- **The clock is an argument.** A module with no loop has no clock, and a
  test that cannot choose the time cannot test an expiry. Inside a request,
  `nilo.nowMillis()` is the one to pass.

## Options

| Field | Default | |
|---|---|---|
| `keys` | — | `*const jwt.Keys`, the issuer's — [below](#where-the-keys-come-from) |
| `issuer` | `null` | refuse a token whose `iss` is not exactly this. Null skips the check, which is right only when the key set itself is the proof of who signed |
| `audience` | `null` | refuse a token whose `aud` does not carry this — your client id. Null skips it, and a token minted for another application then passes |
| `now_s` | — | seconds since the epoch, for `exp` and `nbf` |
| `leeway_s` | `0` | how far the two clocks may disagree, both ways. Sixty is the usual number when the issuer is somebody else's machine |

Name the `issuer` and the `audience`. Both are optional because there are
deployments where the key set already settles them, and both are wrong to
leave off in the ordinary one: a Google ID token minted for *somebody else's*
application is signed by the same keys as one minted for yours, and `aud` is
the only thing that tells them apart.

## What is not an option

Each of these is a way to write a verifier that passes every test and leaves
the endpoint open, which is the whole reason the module exists rather than a
paragraph pointing at `std.crypto`:

- **The algorithm is the key's, never the token's `alg`.** A JWKS key that
  says `RSA` is checked as RS256 and one that says `EC` on `P-256` as ES256,
  and nothing in the header can change which. The header's `alg` is only
  compared: a header saying `none`, or `HS256` with the RSA modulus you
  published used as the HMAC secret, is refused before a key is looked up,
  and a header saying `ES256` over a key that is RSA — or `RS256` over one
  that is EC — is `error.WrongAlgorithm` before any arithmetic runs. A key
  set holding both kinds, which is what an issuer mid-migration publishes,
  cannot be talked into checking one with the other
  ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
- **Nothing in the payload is read until the signature has passed.** An `exp`
  off an unverified token is a number somebody chose.
- **`exp` is required.** A credential with no end is not one, so a token
  without it is `error.NoExpiry` however well it is signed.

## What it answers instead

| Error | When | What to answer |
|---|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON | 401 |
| `error.WrongAlgorithm` | the header says anything but `RS256` or `ES256`, `none` included — or says one over a key of the other kind | 401 |
| `error.NoSuchKey` | the `kid` is not in the set, or none was named and the set has more than one key | the issuer may have rotated — [refresh](#when-the-issuer-rotates), then 401 |
| `error.BadSignature` | the key is right and the signature is not | 401 |
| `error.NoExpiry`, `error.Expired`, `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not arrived | 401 |
| `error.WrongIssuer`, `error.WrongAudience` | `iss` or `aud` is not what you named | 401 |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct | 401 — or a 500 if the struct is the thing that is wrong |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits | 500, and a caller on the [roadmap](../roadmap.md#known-waiting-for-a-caller) |
| `error.CurveNotSupported` | an EC key whose `crv` is not `P-256` | the same 500, and the same roadmap entry |
| `error.SignatureWrongLength` | a signature that is not the size of its key — for ES256, sixty-four bytes of `r \|\| s` | 401. If it is *your* test token, the signer wrote DER — [below](#es256-and-the-shape-of-the-signature) |
| `error.KeyNotUsable` | the set carried a key the arithmetic cannot use: an even exponent, a coordinate that is not on the curve | 500 — the document is wrong, and no token will pass |

Every one of them is a 401 to the client, and the *reason* belongs in your
log rather than in the response: telling a caller which check failed is
telling them what to fix on the next attempt. The one worth a different
answer is `NoSuchKey`, because it is what a key rotation looks like from here.

## Where the keys come from

**The client that fetches the key set is yours** — deliberately, because it
is an HTTPS GET that [`nilo_fetch`](./fetch.md) already sends, and this module
imports nothing. A `Keyring` takes that client, fetches at startup, and fetches
again on an unknown `kid` at most once an interval; whether a miss should
refuse instead is `verify` rather than `verifyOrRefresh`, and yours to pick
([decided](../decided.md#answered-and-kept-to-one-line-each)). What the module
does with the document is read it:

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys` — a JWKS document read into the keys it can verify with: `RSA` as `n` and `e`, `EC` as `crv`, `x` and `y`. Keys of another type — an Ed25519, a key marked `"use":"enc"` — are skipped, not refused |
| `keys.find(kid)` | `?Key`. A set with exactly one key answers for a token that named no `kid` |
| `key.material` | `.rsa` or `.ec`, and the key's own `algorithm()` is `RS256` or `ES256` accordingly |
| `keys.deinit()` | frees the lot |
| `jwt.key_sizes` | the modulus lengths with a branch: 256, 384 and 512 bytes |
| `jwt.curves` | the curves with a branch: `P-256` |

`parseKeys` answers `error.NotAKeySet` for bytes that are not a JSON object
with a `keys` array, and `error.KeyNotUsable` for a key that said RSA and then
carried no `n` and `e`, or said EC and carried no `crv`, `x` or `y`. An EC
key on a curve other than `P-256` is *kept*, so that a token naming it is
`error.CurveNotSupported` rather than a `NoSuchKey` that sends you looking
for a rotation.

The document's address is published by the issuer — Google's is
`https://www.googleapis.com/oauth2/v3/certs`, and for anything OIDC it is the
`jwks_uri` in `/.well-known/openid-configuration`. **The ordinary shape is a
`Keyring`**: the issuer's URL, issuer and audience written once, the
document fetched at startup, and the set swapped safely when the issuer
rotates ([below](#when-the-issuer-rotates)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn fetchKeys(run: *nilo.Run, google: *jwt.Keyring, api: *fetch.Client) !void {
    try google.refresh(run, api, @divFloor(nilo.nowMillis(), 1000));
}
```

and in `main`:

```zig
var google: jwt.Keyring = try .init(gpa, .{
    .url = "https://www.googleapis.com/oauth2/v3/certs",
    .issuer = "https://accounts.google.com",
    .audience = cfg.google_client_id,
});
defer google.deinit();
try app.provide(&google);
try app.before(fetchKeys, .{ &google, &api });
```

`run` there is a [`nilo.Run`](../reference/core.md#run) — the Scope for work that
is not a request, which a startup path is. Since `nilo_fetch` is finished by
`listen()` like any other service, the fetch goes in `app.before`, which runs
inside `listen()` once the client is up and before the first request, exactly
as a database migration does ([A query with no
server](./sql/reading.md#a-query-with-no-server),
[ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
The ring asks the client for one call — `get(scope, url, .{})` — and holds
the module to importing nothing: the client is an argument, the way a
[`job.Table`](./jobs.md) takes your Db.

A program that wants the bytes and nothing else still has `parseKeys`:
`jwt.parseKeys(gpa, res.body.view())` off a `client.get`, held as a
`*const Keys` for a set that never rotates.

## ES256 and the shape of the signature

Supabase, Apple and a growing number of issuers sign with ES256 — ECDSA over
P-256 with SHA-256 — and their JWKS carries `{"kty":"EC","crv":"P-256","x":…,"y":…}`
rather than `n` and `e`. Nothing in the call above changes: the key's type is
what picks the arithmetic, and the same `verify` reads both.

One thing is worth knowing if you ever *make* an ES256 token for a test. A
JWS signature is the two integers `r` and `s` back to back, thirty-two bytes
each, sixty-four in all (RFC 7518 §3.4). Every tool outside JOSE — `openssl
dgst`, a certificate, a `.sig` file — writes the DER `SEQUENCE { INTEGER r,
INTEGER s }` instead, seventy bytes or so with a variable length. A token
whose last segment is DER arrives here as `error.SignatureWrongLength`, by
name, rather than as a `BadSignature` you spend an afternoon on. The
module's own vector is RFC 7515's, which sidesteps the question.

## The signed-in user

With the keys held, the claims behind a bearer token are one argument
([ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)):

<!-- compiles -->
```zig
const Google = jwt.Verifier(Claims, fetch.Client);

fn me(user: nilo.Verified(Google)) Claims {
    return user.claims;
}
```

and beside the ring in `main`:

```zig
var verifier = Google.init(&google, &api);
try app.provide(&verifier);
```

`jwt.Verifier(Claims, Client)` is the ring, the client its refresh needs
and the claims type, held as one service — which is what lets an argument
name one type and reach all three. Before `me` runs, nilo reads the
`Authorization` header, insists on `Bearer`, verifies the token through
the ring with the issuer, the audience and the clock, fetches the keys
once if a `kid` went missing, and hands over the claims parsed into the
request arena. Anything short of that is a 401 with `WWW-Authenticate:
Bearer` on it and the reason in the body — `Expired`, `WrongAudience` —
and the one thing that is not a 401 is the issuer being unreachable when
a refresh was needed, which is a 503 because the token was never judged.
`listen()` refuses to start if the verifier was not provided, the way it
does for a `*Db`; the OpenAPI document carries the bearer scheme and the
401.

The refusal after reading — the account is closed, the role is wrong —
is `nilo.Verified(Google).refuse("that account is closed", .{})`, the
same 401 with the same header. `user.token` is the token as the client
sent it, for a handler that passes it on to another service. A middleware
guarding a prefix reads the same thing with `c.verified(Google)`, and a
handler under it that asks again verifies again — the signature check
twice, which the next section is the way round.

**When the handler wants more than the claims** — the database row behind
`sub`, a struct of your own — the token check is a
[resolved value](./middleware.md#resolved-values): the type says how it is
worked out, a handler asks for it by writing it in its argument list, and it
is worked out once per request however many things ask.

<!-- compiles -->
```zig
const CurrentUser = struct {
    pub const nilo_resolve = authenticate;

    id: []const u8,
    email: []const u8,
};

fn authenticate(c: *nilo.Ctx, google: *jwt.Keyring, api: *fetch.Client) !CurrentUser {
    const auth = try c.authorization(.bearer);

    const claims = google.verifyOrRefresh(
        struct { sub: []const u8, email: []const u8 },
        c.arena(),
        auth.value.view(),
        @divFloor(nilo.nowMillis(), 1000),
        c,
        api,
    ) catch |err| {
        std.log.info("token refused: {t}", .{err});
        return nilo.Authorization(.bearer).refuse("that token is not valid here", .{});
    };

    return .{ .id = claims.sub, .email = claims.email };
}

fn profile(user: CurrentUser) !CurrentUser {
    return user;
}
```

`c.authorization(.bearer)` is the `Authorization` header read as one scheme
([the reference](../reference/handlers.md#authorizationscheme)): the scheme matched
case-insensitively, the blanks trimmed, and absent or another scheme answered
with a 401 that carries `WWW-Authenticate: Bearer` — the header every 401 has
to carry and the one a hand-written `startsWith(value, "Bearer ")` forgets.
`Authorization(.bearer).refuse` is `fail.unauthorized` with the same header
on it, for the refusal that comes after reading. A handler that wants the
token itself rather than the user asks for `nilo.Authorization(.bearer)` in
its argument list and gets a security scheme in the OpenAPI document as well.

`profile` is still an ordinary function — `profile(.{ .id = "7", .email = "…" })`
in a test, with no token anywhere. Guarding a whole prefix is the same `c.resolve`
the middleware page shows: `try app.useOn("/api", requireUser)` with
`_ = try c.resolve(CurrentUser)` inside it, and the handler behind it gets the
same lookup rather than a second one.

`c.arena()` is the right allocator there. The claims live exactly as long as
the request, and nothing is freed. A resolver that takes a `*Google` and
calls `google.verify(c.arena(), auth.value.view(), now_s, c)` is the same
five lines with the client already inside.

## When the issuer rotates

An issuer publishes a new key, signs with it, and keeps the old one in the
document for a while. From here that arrives as `error.NoSuchKey` on a token
that is otherwise fine. This guide used to say the answer was three lines —
fetch again, hold a `*const Keys`, swap under a mutex — and each of the
three was wrong in a way no test finds: no refetch is every sign-in failing
until a restart, an unbounded refetch is one GET to the issuer per forged
`kid`, and swapping a set another thread is reading is a use-after-free the
Debug build has no trap for. The last one is concurrency rather than policy,
and it is why the ring is in the module
([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).

**`verifyOrRefresh` is `verify`, and on `NoSuchKey` one fetch at most per
`refresh_interval_s`**, then `verify` again. Whichever request sees the miss
first takes the slot; the others inside that minute are `NoSuchKey` as they
were, which under a real rotation is a handful of 401s in the second the
first new-key token arrives, and under a flood of forged tokens is the bound
doing its job. A [ticker](./background.md) calling `refresh` on a schedule
sits beside it, and a refresh that ran — scheduled or not — is the last
one, so a miss straight after it does not fetch again.

| | |
|---|---|
| `ring.load(bytes)` | a document read and made current; the old set is freed once the verifies reading it are done, and a document that does not parse leaves it in place |
| `ring.refresh(scope, client, now_s)` | `client.get(scope, url, .{})` and `load`; `error.KeysNotAvailable` for anything but a 2xx, with the old set still held |
| `ring.verify(Claims, gpa, token, now_s)` | `jwt.verify` against the set held now, with the ring's issuer, audience and leeway; never fetches |
| `ring.verifyOrRefresh(Claims, gpa, token, now_s, scope, client)` | the above, and one bounded refresh on a missing `kid` |

**The swap is safe because a verify pins the set it reads.** A verify
counts itself on the set, reads, and counts itself off; a swap publishes
the new set and then waits for the old set's count to reach zero before
freeing it. Readers never wait. The one wait is the writer's, and it is a
spin bounded by the length of one verify, once per rotation — a
`std.Io.Mutex` needs an `Io` a tool module does not have, which is the
same reason the [cache](./cache.md) spins. `nilo_cache` answers the same
lifetime question with a copy and a generation
([ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md));
a key set is not flat, so here it is a pin.

When a `kid` miss should mean *refuse* rather than *fetch* is still yours:
call `verify` and decide. The interval is a bound on the fetch, not a
policy about it.

## Testing

`now_s` is an argument, so an expiry is tested by choosing the time rather
than by waiting. A token signed with a key you hold — `openssl genrsa` or
`openssl ecparam -name prime256v1 -genkey`, the public half as a JWKS
document, a token signed by any JOSE library — and a `verify` at the second
before its `exp`, the second of it, and the second after is the whole of a
test, and it runs under `zig test` with no server.

The module's own suite does exactly that against two fixed vectors
(`jwt/vector.zig`) — an RSA one signed elsewhere, and RFC 7515's own ES256
example — which is the file to copy the shape from.

## What it costs

**Nothing per request that is not yours.** The module allocates only what
the claims need, from the allocator you passed, and holds nothing between
calls.

**And the number for one verification is not on file.** An RSA verify at
2048 bits is a modular exponentiation and it is not small; an ES256 verify
is two scalar multiplications on P-256 and is usually the cheaper of the two,
but neither has been measured here. Whether a hot endpoint should cache the
answer or just do it is a question the roadmap is waiting on a measurement
for. Until then, the safe reading is that a resolved
value is already the cheapest shape — once per request, not once per
handler — and a session cookie set after the first verified request is the
usual way to stop paying it at all.

## What it will not do

HS256, any curve but P-256, encrypted tokens (JWE), signing, discovery, PKCE
and the nonce. Signing is absent because a server issuing its own sessions has
[`Session(T)`](./sessions.md) and needs no token; HS256 is absent because a
module verifying both a shared secret and a public key has to defend against
the confusion attack that a module verifying one cannot commit
([roadmap](../roadmap.md#known-waiting-for-a-caller)). The rest is
the sign-in flow — redirecting to the provider, exchanging a code — which is
yours.

## See also

- [The reference](../reference/jwt.md#nilo_jwt) — the surface as a list.
- [Sessions](./sessions.md) — what a signed-in user becomes after the first
  verified request.
- [Calling somebody else's API](./fetch.md) — the fetch that gets the key set.
- [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) —
  why verifying is here and fetching is not.
- [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) — why the key
  picks the algorithm, and what ES256 costs.
