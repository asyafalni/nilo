# CORS and the proxy in front

**Two headers a browser and a proxy each read on the server's behalf get exactly the answer their protocol defines: `Access-Control-Allow-Origin` echoes the one origin that matched rather than being formatted from a list, and `X-Forwarded-For` is trusted by naming which machine sent it rather than by counting how many there were.** How to use each is the guide ([`guide/middleware.md#the-ones-that-come-with-it`](../guide/middleware.md#the-ones-that-come-with-it), [`guide/deploying.md#who-the-client-is`](../guide/deploying.md#who-the-client-is)); every option is the reference ([`reference/middleware.md`](../reference/middleware.md), [`reference/app.md#listen-options`](../reference/app.md#listen-options)). The code is `http/cors.zig` (`Options`, `Origins`, `with`, `reading`, `permissive`) and `http/proxies.zig` (`Cidr`, `Forwarded`, `holds`).

## How the pieces fit

Both halves answer the same question from opposite ends of a request: which of several possible answers is the truth for *this one*, decided by matching against a list rather than by a single fixed value or a bare count.

```
  CORS: which origin gets the header
    request's Origin ──► compared against origins (comptime list or reading())
                            match  → that origin echoed back, Vary: Origin
                            no match → ordinary response, no header at all

  Proxy trust: which address is the client
    X-Forwarded-For, walked right to left ──► trusted_proxies (CIDRs, "private", "loopback")
                            entry is ours   → skip, keep walking
                            entry is not    → that is the client; stop
```

## The rule in force

1. **`Access-Control-Allow-Origin` carries one origin, so a server with more than one front end matches the request's `Origin` against a list and echoes the one that matched, rather than joining the list into the header.** [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
2. **The compare is exact, never case-insensitive**, because the value sent back has to be the bytes the browser will compare against its own origin; a configured origin with a capital letter is refused while compiling. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
3. **An `Origin` that matches nothing gets an ordinary response with no `Access-Control-Allow-Origin`, never a 403.** CORS is a rule the browser enforces on the user's behalf; a server that answered `curl` and a browser differently would be doing access control on a header the client chooses, and that is authentication's job, not this one's. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
4. **A named list sends `Vary: Origin` on every response, matched or not**, so a shared cache never serves one origin's refusal to another that would have matched; `&.{"*"}` sends neither the read nor the header, because that answer really is the same for everybody. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
5. **`*` beside a named origin, an empty list, an empty entry, and `credentials` beside `*` are all refused while compiling.** The last of those is what makes credentials safe here with no separate check: the combination a browser itself rejects cannot be built. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md), [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
6. **A front end's address is a fact about the deployment, not the program, so `cors.reading(&origins, .{…})` reads its list from a variable the caller fills before `listen()`, the same way `nilo_config` reads any other setting.** Everything else, methods, headers, credentials, max age, stays compile-time, because none of it is a fact that differs between one deployment of the same service and another. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
7. **The list is borrowed, not copied**, so the text has to outlive the server the way `.env` text and the environment block do; that is what lets a matched origin go out through `setStaticHeader` and keeps a cross-origin request at zero allocations under `reading` exactly as under `with`. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
8. **A list nobody filled refuses every cross-origin request and says so in the log once**, through an atomic flag, on the path a correctly configured server never reaches. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
9. **`X-Forwarded-For` is trusted by naming which machines are allowed to have written it, not by counting how many hops there were.** `.trusted_proxies` takes CIDRs, bare addresses, or the names `"private"` and `"loopback"`, and wins over the older `.trusted_hops` when both are set. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
10. **The header is read only when the connection itself came from a trusted address.** A machine on the open internet does not get to say who it is forwarding for, whatever it writes in the header. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
11. **The walk goes from the right, dropping every entry that names a trusted address; the first one that does not is the client, and everything left of it is unverified.** If every entry is trusted, the connection's own address is the honest answer, because there is no client behind them. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
12. **Every `X-Forwarded-For` field is read as one list, in wire order**, because a proxy is allowed to add a field of its own rather than append to the one the client sent, and reading only the first field lets a forged entry through a proxy that behaves honestly. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
13. **A `trusted_proxies` entry that is not an address stops the server at `listen()`, naming it**, before the port is taken, rather than answering with the wrong client address for the life of the deployment. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)

## Decisions

| ADR | What it decides |
|---|---|
| [078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md) | `origins` as a matched list rather than a formatted string, and where the refusal for a mismatch lands |
| [088](../adr/088-an-origin-is-a-fact-about-the-deployment.md) | `cors.reading`, a runtime list for the one fact that differs by deployment |
| [102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md) | `trusted_proxies`, trust by address rather than by hop count |

Beside this topic: the header caching rule that makes sending `Vary: Origin` on a miss necessary is [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md); a bare function pointer being what a `Middleware` is, which is why `cors.reading` needs a caller-owned variable rather than a Service, is decided in [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md); a repeated `Host` or a smuggled request being refused by the same reasoning `trusted_proxies` uses for a forged hop is [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md).

## Open

Nothing is open on the record.
