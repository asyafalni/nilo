# Verified claims are a handler argument

**Status:** accepted
**Topic:** [jwt](../design/jwt.md)
**Extends:** [ADR 153](./153-an-authorization-header-a-handler-can-ask-for.md),
whose `Authorization(.bearer)` stops at the token; this is the step after
it, and [ADR 111](./111-nilo-verifies-a-token-and-does-not-fetch-one.md),
whose ring is what the step verifies through.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 038](./038-a-module-sits-where-the-loop-puts-it.md),
[ADR 059](./059-a-bucket-is-a-type-and-a-key-is-not.md),
[ADR 160](./160-a-queue-is-a-table-in-the-database-you-already-have.md).

## Context

A handler that wanted the user behind a bearer token wrote four things in
every handler, or once in a resolver: `nilo.Authorization(.bearer)`, then
`keyring.verifyOrRefresh` with the claims type, the arena, the clock, the
Ctx and the `fetch.Client`, then a `catch` turning every error into
`Authorization(.bearer).refuse`, then the struct. The guide showed the
resolver and called it the shape. It is the right shape for a handler that
wants a database row; for one that wants the claims, it is eleven lines
that are the same in every program.

The roadmap held the entry at *waiting on a design* for one question: a
`nilo.Verified(T)` argument names one type, and the refresh a rotation
costs needs two services — the ring and the client that fetches the
issuer's document. Which one does the argument name, and how does it reach
the other?

## Decision

**`jwt.Verifier(Claims, Client)` holds the ring, the client and the claims
type as one Service, and `nilo.Verified(V)` names it.** The handler gets
`.claims` parsed into the request arena and `.token` as the client sent it,
or a 401 with `WWW-Authenticate: Bearer` before it runs.

```zig
const Google = jwt.Verifier(Claims, fetch.Client);

var verifier = Google.init(&google, &api);
try app.provide(&verifier);

fn me(user: nilo.Verified(Google)) !Profile { … user.claims.sub … }
```

**The client is a type parameter, so `nilo_jwt` still imports nothing.**
This is the answer to the roadmap's question, and it is the answer
`job.Table(Db)` already gave for a store (ADR 160) and `Keyring.refresh`
gave for its `client: anytype`: the module asks for one call —
`get(scope, url, .{})` answering `ok()` and `body.view()` — and names no
module that provides it. A Verifier is two pointers and a `verify` that
fills in the three arguments every call in a program repeats.

**`nilo_http` does not import `nilo_jwt` either.** `http/verified.zig`
reads a marker, `nilo_verifier`, and calls `verify`; what it names is
`nilo_core`, `fail.zig` and `authorization.zig`. So the build.zig module
graph is unmoved, `zig build layering` has nothing new to check, and a
server that never names `Verified` links nothing of this — which is the
property the layering exists to buy, and which importing the module would
have kept only through lazy analysis. It is also what lets the http tests
run against a fake Verifier with no keys anywhere; the real one is tested
where it lives.

**It is a role of its own in the typed engine, not a resolved value.** A
resolved value would have been the natural shape — worked out once per
request, shared with a middleware through `c.resolve` — and it was the
first design. It does not fit: a resolver is a function whose arguments
are a `*Ctx` and services, and a file outside `http_core` may not name
`Ctx`. The role reads the header, the arena, the lifetime, the clock and
the Verifier, the way `.authorization` does, and `c.verified(V)` is the
same read for a middleware. What that costs is stated below and is the
one honest number in the design: a handler under a guard that asks again
verifies again.

**Every refusal from the token is a 401 naming the reason.** `Expired`,
`WrongAudience`, `NoSuchKey`: a client told why can act — refresh, sign in
again, stop — and none of the reasons is a secret, since the token is the
client's own. The one answer that is not a 401 is the issuer's keys being
unreachable when a refresh was needed: the token was never judged, so
that is a 503 and the client should try again.

**The document says bearer.** The `security` entry ADR 153 writes for an
`Authorization(.bearer)` argument is written for a `Verified` one, which
is what the document should have said for a verified token all along.

**Three shapes are refused while compiling**: `Verified(Claims)` with the
claims struct where the Verifier goes, which names where the struct
belongs; `Verified(*Google)` with the pointer a service argument would
have; and a `Verified` in the return type, which would echo the token.

## What it costs

Against ADR 017's axes:

- **Allocations per request:** none on a route that does not ask. On one
  that does, the claims are parsed into the arena, which is the one
  allocation `jwt.verify` makes for its caller and the one the resolver
  made before. `test "the request path stays inside its allocation
  budget"` is unmoved.
- **Memory per idle connection:** unchanged. The Verifier is two pointers
  in the registry; nothing is held per connection.
- **Throughput:** the signature check, on the route that asked — an RSA
  exponentiation or two P-256 scalar multiplications, which the roadmap
  still has no number for. A guard and a handler that both ask pay it
  twice; a resolver of the caller's own over `google.verify` pays it once,
  and the guide says which to write when.
- **Binary size:** nothing for a program that names no `Verified`, by
  construction rather than by lazy analysis.

## Alternatives

**A resolved value in `resolve.zig`.** Rejected above: the resolver takes
a `*Ctx`, and the file would have to be in the core. Its one advantage —
once per request — is available to a caller as five lines of resolver
over `google.verify`.

**`Verified(Claims)` with the ring found by type.** The argument would
name the claims and nilo would look up `*jwt.Keyring`; the client for the
refresh would then have to be looked up by type too, which means
`nilo_http` naming `fetch.Client`, which is a Fitting it does not import.
And a program with two issuers has two rings and one claims type, which
this cannot express and the Verifier can.

**Importing `nilo_jwt` from `nilo_http`.** Downward and allowed by ADR
038, and rejected for the reason `nilo_http` does not import
`nilo_cache` (ADR 109): a marker the caller's type carries needs no
wiring between the modules, and the module graph stays what it was.

**A generic reason in the 401.** "That token is not valid here" was what
the guide's resolver said. Rejected: it sends a client with an expired
token and a client with a forged one to the same place.

## Consequences

- `jwt/verifier.zig`: `jwt.Verifier(Claims, Client)` with `init`,
  `verify` and the `nilo_verifier` marker.
- `http/verified.zig`: `nilo.Verified(V)` with `claims`, `token`,
  `challenge` and `refuse`; `read` for the typed engine and
  `Ctx.verified`. Names nothing in `http_core`.
- `typed.zig`: the `.verified` role, its requirement, its document entry
  and the return-type refusal.
- Three refusals under `refusals/verified_*`; `refusals` is 158.
- The guide's jwt page leads with the argument; the roadmap loses
  "Verified claims are not a handler argument".
