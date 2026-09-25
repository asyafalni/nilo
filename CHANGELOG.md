# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

### Breaking

- **The session cookie is `__Host-session` wherever the prefix can hold** (`Secure`, `Path=/`, no `Domain`, the defaults), and that name is read before `session`. A sibling subdomain could plant a `session` cookie of its own under a path of this site, and the victim worked inside the attacker's account. Nobody is signed out: a `session` cookie still opens, and the next `set` moves it. What to change: `app.guard(…, "session")` becomes `app.guard(…, nilo.session.host_cookie_name)`, and a test or a client that reads the cookie by name reads the new one. A session with a `domain`, another `path` or `secure = false` keeps the plain name (ADR 033).

### Fixed

- **`host()` and `scheme()` believe `X-Forwarded-Host` and `X-Forwarded-Proto` only from a trusted proxy**, by the rule `clientIp()` uses: named in `trusted_proxies`, or counted by `trusted_hops` when none is named. They read `trusted_hops` alone, so an app that named its proxies got `scheme() == "http"` behind TLS, and one that set a hop count to fix that believed a forwarded host from any peer, the reset-link poisoning ADR 090 is there to stop. `scheme()` is `"https"` on a listener with its own TLS (ADR 102).
- **More than eight `X-Forwarded-For` fields no longer makes `clientIp()` answer with the proxy's address.** The last eight fields are read, which are the proxies' end of the list; a client that stuffed the head was read as the proxy, inside an allow-list of private addresses (ADR 102).
- **A chunk line ends at CRLF and nowhere else, a chunk extension may not carry a control byte, and a folded header line is a 400.** Each let nilo and a front end frame one request two ways, the TERM.EXT desync among them (ADR 070).
- **Three waits on a client that claimed a whole bound now have one.** The linger after a refused request is one second in all, not one second per read, which let a byte every 900 ms hold a fiber for eighteen hours (ADR 195). The body a handler never read is thrown away under `body()`'s rate floor, not a per-read limit, and a trailer section stops at 8 KiB (ADR 022). A WebSocket client that stops half way through a frame is closed after twice `idle_ms`, where it was never pinged and held its fiber for ever (ADR 021).
- **A box left blank on an optional or defaulted field is the field not given.** A browser sends an empty box as `age=`, and `Form(T)`, `Query(T)` and both `Bound` forms answered a 400 saying an optional age has to be a whole number. An empty `?Str` is still `""`, and a required field left blank is still refused (ADR 132).
- **`c.upgrade(loop, c)` is refused while compiling**, and so is a `*Ctx` anywhere in the loop's state. The Ctx is gone by the time the loop runs, so the loop read the next request's memory (ADR 062).

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.6.0](https://github.com/nevindra/nilo/releases/tag/v0.6.0)**: nothing needed in front, and read line by line for what a stranger can do. HTTPS, gRPC, compression and a cross-site check behind an option or a flag; every executor accepting and a response flushed before the connection waits; a Row that carries its parent, its children or a sum; and what a client on the socket could forge, crash or read, closed. Eleven things to read before deploying, listed there.
- **[v0.5.0](https://github.com/nevindra/nilo/releases/tag/v0.5.0)** — the
  roadmap read back against the tree: a Row that says more about its own
  table and `sql.Schema` as the one value that reads it, `nilo.Verified` and
  `jwt.Keyring`, `fetch.Target`, `nilo.Text` and `nilo_check`, `nilo-dev`, a
  queue that wakes its workers. Seventy-nine entries; eight things to read
  before deploying, listed there.
- **[v0.4.0](https://github.com/nevindra/nilo/releases/tag/v0.4.0)** — one
  module, `nilo_job`, and the thirty-odd shapes a second port needed: a
  listing page in one statement, an order chosen from a closed set, a route
  answering once per key, a health page, and the two fixes that let the suite
  run on a Mac. Twelve things to read before deploying, listed there.
- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
