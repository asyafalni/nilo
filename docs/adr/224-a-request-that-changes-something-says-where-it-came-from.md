# A request that changes something says where it came from

**Status:** accepted
**Topic:** [cors-proxy](../design/cors-proxy.md)
**Applies:** [ADR 080](./080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md), [ADR 088](./088-an-origin-is-a-fact-about-the-deployment.md).
**Found by:** comparing nilo with [by965738071/http-framework](https://github.com/by965738071/http-framework), whose `CsrfMiddleware` (double-submit cookie) is the one security middleware it has and nilo did not.

## Context

A session cookie defaults to `SameSite=Lax` ([ADR 029](./029-a-header-is-checked-once-and-two-of-them-repeat.md)), which stops a form on another site from posting with it. It does not stop three things: a cookie an application had to set `SameSite=None` on, a browser too old to enforce Lax, and **a page on another subdomain of the same site**, because Lax is about the site and `uploads.example.com` is the same site as `app.example.com`. The roadmap held this open as "whether a request carries a CSRF token nilo knows about", on the premise that every framework ends up with a token in the session, a hidden field in the form and a compare in a middleware.

## Decision

**`nilo.csrf.sameOrigin` refuses, with a 403 before the handler runs, a request that changes something and that the browser says came from a page this server does not serve. `csrf.with(.{ .origins = … })` names the other pages it takes them from, and `csrf.reading(&origins)` reads that list from the same `cors.Origins` a `cors.reading` does.**

`GET`, `HEAD` and `OPTIONS` pass without a look. For every other method the rule is asked in this order:

1. `Sec-Fetch-Site: same-origin` or `none` passes.
2. Any other `Sec-Fetch-Site`, `same-site` included, passes only when `Origin` is a named origin.
3. No `Sec-Fetch-Site` but an `Origin`: passes when it is named, or when it names the authority the `Host` header did, scheme aside, which is ADR 080's rule for the WebSocket handshake and the same function.
4. Neither header: passes.

It is opt-in, a middleware like `cors`, and a route that takes posts from anywhere leaves it with `without(nilo.csrf.sameOrigin)` ([ADR 099](./099-a-route-can-say-what-covers-it.md)).

## Why the browser's word and not a token

The premise in the roadmap was true in 2015 and is not now. Every engine sends `Sec-Fetch-Site` on every request since 2023, every engine sends `Origin` on a `POST`, `PUT`, `PATCH` and `DELETE` since 2020, and a page can set neither. Go 1.25 shipped `http.CrossOriginProtection` on exactly this and no token.

A token is the wrong shape for nilo in particular. The session is sealed into the cookie with nothing kept on the server ([ADR 033](./033-a-session-is-sealed-into-the-cookie.md)), so the token would be a field every `Session(T)` has to carry and every handler has to render into every form, in a framework that has no templates to render it with ([ADR 027](./027-tls-is-terminated-in-front.md), README "What it won't do"). A front end calling a JSON API would need a second way to fetch it. A double-submit cookie, the variant http-framework ships, moves the state to the client and keeps the rendering, and is broken by the same subdomain that breaks Lax, because a sibling subdomain can write a cookie on the parent domain.

The header check needs none of that: no state, no entropy per request, nothing in the session and nothing in the form.

## Why `same-site` is refused

It is the case this closes that `SameSite=Lax` leaves open. A user's upload served from `files.example.com`, or a staging host somebody forgot, is same-site to `app.example.com`, and Lax sends the cookie with its post. An application whose front end really is on a sibling subdomain names it, which is one line and says what it is doing.

## Why a request with neither header passes

`curl`, a payment provider's webhook, another service, and every load generator in `bench/` send neither, and none of them has somebody else's cookie to borrow. The browser that sends neither predates 2020. Refusing them would break every non-browser client to close a case that has left the browser market. ADR 080 made the same trade for the handshake.

## Why the `Host` compare is only the fallback

When the browser has said `cross-site`, an `Origin` that matches the `Host` is not allowed to overrule it. The `Host` compare ignores the scheme, because TLS is terminated in front and the server never learns it (ADR 080); the browser does know it, and an `http://` page posting to its `https://` twin is cross-site to it. So the fallback only runs for a browser that said nothing, where it is the best there is. It also means a proxy that rewrites `Host` (nginx's default `proxy_set_header Host $proxy_host`) only refuses browsers from before 2023.

## What is refused, and where

`with` refuses three things while compiling: an empty origin, `"*"`, and an entry that is not an origin (no `://`, or a path after the host, the trailing slash copied from an address bar). `"*"` is refused rather than meaning "anyone", because trusting every page is not installing the middleware, and a CORS list is where somebody would copy it from. A capital letter is not refused, unlike `cors.with`: nothing goes back out, so the compare is case-insensitive and there is no spelling that has to survive. `reading` takes a `cors.Origins`, whose `set` already refuses `"*"` and an empty entry at startup.

## What was rejected

- **A synchronizer token in `Session(T)`**, for the reasons above: a field in every session, a render in every form, and no templates to do it with.
- **A double-submit cookie**: as above, and a subdomain that can write a cookie defeats it.
- **On by default.** ADR 080 made the WebSocket check the default because nothing else refused a cross-site handshake. Here `SameSite=Lax` already refuses the common case, and a default would break every application whose API takes posts from a front end on another origin, which is the ordinary shape of one. An application can reach for it in one line.
- **Checking `GET`.** A cross-site `GET` is a link, and refusing it refuses every link into the site. A `GET` that changes something is not covered by this or by any CSRF check: the route is the bug.
- **Reading `X-Forwarded-Host` through `trusted_hops`.** The same reason as ADR 080: what is compared has to be the authority the request named.

## What it costs

- **Allocations per request:** none. Held by `test "csrf adds no allocation to the request it lets through"` in `http/behaviour.zig`.
- **Memory per idle connection:** none. The middleware holds nothing, and runs only while a request is in flight.
- **Throughput:** a request that changes nothing pays one compare of the method. One that changes something pays up to three walks of the request headers (`Sec-Fetch-Site`, `Origin`, `Host`) and a compare per named origin. Not measured: the primary metric is a `GET`, which never reaches the walks. **What would settle it:** a `POST` benchmark with and without it, built from the same tree.
- **Binary size:** nothing in a program that does not name it, because Zig does not analyse a declaration nothing references.

## What it breaks

Nothing: it is opt-in. An application that installs it and has a front end on another origin gets a 403 on that front end's first post, naming its origin and `csrf .origins`.
