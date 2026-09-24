# JWT verification

**nilo verifies a token somebody else signed and never signs or fetches one of its own.**
The guide is [`guide/jwt.md`](../guide/jwt.md), the names and signatures are [`reference/jwt.md`](../reference/jwt.md), and the code is `jwt/token.zig`, `jwt/keyring.zig`, `jwt/memo.zig`, `jwt/verifier.zig`, `jwt/rs256.zig`, `jwt/es256.zig`, with the App-layer half in `http/verified.zig`.

## How the pieces fit

```
issuer's JWKS ──► Keyring (rotates the key set, no race) ──► Verifier(Claims, Client)
                                                                       │
                                                     nilo.Verified(V) reads it,
                                                     or a 401 before the handler runs
```

A `Keyring` holds one issuer's keys behind an atomic pointer and refreshes them; a `Verifier` pairs a `Keyring` with the client that fetches it and the claims type a handler wants. `nilo.Verified(V)` is the argument a handler writes; nothing about a token is a resolved value or middleware, it is its own role in the typed engine.

## The rule in force

1. **`nilo_jwt` verifies; it does not fetch, discover, do PKCE, or check a nonce.** Verification is where being wrong is silent; a fetch that fails, fails loudly and is `nilo_fetch`'s job already. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
2. **The key decides the algorithm, never the token's header.** `alg` is compared twice, before the key lookup against the two names the module knows, and after against the one name the found key answers to; a key of an unrecognised type is skipped rather than refused, so an issuer publishing a new key type mid-migration cannot stop verification, and a key of a recognised type with an unsupported size or curve is refused by name. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
3. **RS256 and ES256 only**, no HS256 (a shared secret is what makes the header/key confusion possible), no other curve, no JWE, no signing. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
4. **Nothing is read until the signature has passed.** `exp` is required, `iss` and `aud` are checked whenever the caller names them, and a claims struct the caller wrote is filled only after that. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
5. **A `Keyring` swap publishes a new key set and frees the old one only after every reader pinned on it has left**, so a verify never waits and a rotation is felt at once by anything that looks a key up by `kid`. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
6. **An unknown `kid` fetches at most once per `refresh_interval_s`.** A miss races a compare-and-swap on the last-refresh time; the loser gets `NoSuchKey` the way it always did, which bounds a flood of forged tokens to one GET to the issuer per interval. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
7. **The client the ring refreshes through is a type parameter, and `nilo_jwt` imports nothing at all**, `zig test jwt/jwt.zig` is the whole of it with no `build.zig`. `nilo_http` does not name `nilo_jwt` either: `http/verified.zig` reads the `nilo_verifier` marker rather than importing the module, so a server that never asks for `Verified` links none of it. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md), [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
8. **`jwt.Verifier(Claims, Client)` holds the ring, the client and the claims type as one Service, and a handler writes `nilo.Verified(V)`.** `.claims` is parsed into the request arena, `.token` is the raw text, or the handler never runs and the client gets a 401 with `WWW-Authenticate: Bearer`. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
9. **`Verified` is its own role in the typed engine, not a resolved value**, because a resolver takes a `*Ctx` and a file outside `http_core` may not name one; `c.verified(V)` is the equivalent read for a middleware, and a handler under a guard that both ask pays the signature check twice. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
10. **Every refusal from the token is a 401 naming the reason** (`Expired`, `WrongAudience`, `NoSuchKey`); the issuer's keys being unreachable when a refresh was needed is the one case that is a 503 instead, because the token was never judged. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
11. **`Keyring.Options.remember_tokens` (default 0) memoises a verified signature by the token's own SHA-256 digest**, so a repeated bearer token skips the arithmetic and still runs `exp`, `nbf`, `iss` and `aud` fresh on every call. The memo is cleared on a swap only after the old set's readers have drained, so a key that has been rotated out cannot go on being remembered. [ADR 209](../adr/209-a-verified-signature-is-remembered-by-the-tokens-digest.md)

## Decisions

| ADR | What it decides |
|---|---|
| [111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) | What the module verifies, the RS256/ES256 split by key rather than header, and the `Keyring`'s lock-free swap |
| [191](../adr/191-verified-claims-are-a-handler-argument.md) | `jwt.Verifier` and `nilo.Verified(V)` as a handler argument, and why it is a role rather than a resolved value |
| [209](../adr/209-a-verified-signature-is-remembered-by-the-tokens-digest.md) | The signature memo keyed by the token's digest |

Beside this topic: the client a `Verifier` refreshes through is a Fitting (`nilo_fetch`), which is what a tool module naming a type parameter rather than importing buys, see [layering](layering.md); `Authorization(.bearer)` is the step before this one, [ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md); a `Session(T)` is not a token and is the alternative when nilo is the one issuing the credential, see [cookies-sessions](cookies-sessions.md).

## Open

- **Whether a sign-in endpoint should cache a verification or just do it** is unmeasured beyond the raw RSA/ECDSA cost; [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md) leaves this open in its "What it costs" section.
