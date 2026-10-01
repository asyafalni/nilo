# A fallback answers a navigation, not a missing asset

**Status:** accepted
**Topic:** [static-files](../design/static-files.md)

`staticWith(.{ .spa_fallback = "index.html" })` answered **every** path under
its prefix that named no file. That is what a single-page app asks for on a
reload of `/users/42`, and it is also what turns a build that has moved on into
a lie:

- `index.html` refers to `app.abc123.js`; the directory now holds
  `app.def456.js`. The browser fetches the old name, gets **200 and a page**,
  and reports a syntax error on line 1 of something that was never JavaScript.
- A `fetch("/api/orders")` against a path with no route gets a page and reports
  a JSON parse error.

Neither names the missing file, which is the whole cost: the server had the
information and answered with something else.

**The fallback answers a request that says it is a browser opening a page,
and nothing else.** Everything else under the prefix is the 404 it always
should have been, and the 404 says which path.

## The rule

A request is a navigation when it is a `GET` or `HEAD` and one of two things
holds, tried in this order.

**The browser says so.** Every current browser sends `Sec-Fetch-Mode` (the
fetch metadata of W3C's Fetch Metadata Request Headers): `navigate` for a page
load, a reload and a followed link, and `cors`, `no-cors` or `same-origin` for
a `fetch`, a `<script src>`, a `<link>` and an `<img>`. When the header is
present it is the whole answer: `navigate` is a navigation and any other value
is not, whatever `Accept` says.

**Otherwise `Accept` has to ask for HTML by name.** A client that sends no
fetch metadata (an older one, or a browser on plain HTTP away from
`localhost`, where it is withheld) still opens a page with `text/html` at the
front of its list, and `http/accept.zig` was written to read exactly that.
`*/*` alone is not a navigation, and neither is a missing `Accept`: they are
what `curl`, a health check, a `<script src>` and most of `fetch()` send.

The path is not read. The first version of this rule guessed from it for the
client that said nothing, an extension meaning an asset and a bare segment a
route, and that guess is what let `fetch('/api/nope')` receive the page with a
200, so a typo in an API path looked like success to the client that made it.
That case was recorded here as indistinguishable at this layer. It was
distinguishable by a header nobody had looked at. A client that says nothing
now gets the 404, the one answer it cannot mistake for success, and nothing
about an API needs a catch-all route to keep it from being the page.

A route still wins before any of this is asked, and the 405 for a path some
route spells under another verb is unaffected: the fallback is reached only for
a request that matched no route. A `GET` from `curl` or a `fetch` for a path
registered under `POST` alone is a 405, where `*/*` used to be answered with
the page; the same request from the address bar is a navigation and is the
page, which is what a client-side route that shares its path with a `POST`
route needs. That is also why the catch-all `GET /api/*` route a port wrote to
stop the page answering an API typo is unnecessary, and was harmful: it made
every other verb on an unknown API path a 405 instead of a 404.

## What it does not catch, and the option that was weighed

**A browser's address bar is a navigation**, so somebody typing
`/api/nope`, or `/app.abc123.js`, gets the page and the client-side router
shows its own not-found screen. That is the right answer for a person, and
nothing fetches a script that way, which is what keeps the stale-bundle case
(a `<script src>` is `no-cors`) a 404.

**An `.except` list of path prefixes that never fall back** (`"/api/"`) was
weighed after the header rule and left out. The mistake it would catch, a
client calling an API path that is not there, is already a 404 under the
header rule, and the one case it would add is a person typing an API URL,
who is better shown the application's own screen than a bare 404. It would
cost a second place to configure the same boundary a route table already draws,
and a prefix match on every miss. A path that must never be the page is given
a route. It comes back when a caller shows a navigation that has to be a 404.

## Why an option, and why it defaults the other way

`.spa_fallback_for = .any_path` is what shipped before, and this is a change in
what a running server answers rather than a compile error, so an application
that depends on the old behaviour can say so in one field. The default is
`.navigations` because the failure it prevents is silent and the failure it
introduces is not: a deep link that 404s is reported by whoever hit it, where a
stale asset served as HTML is reported by nobody and diagnosed by nobody.

## Where the seam moved

`static.Set.find` used to return the fallback, so a caller could not tell a
file that exists from a miss — which is why nothing could decide anything about
the miss. `find` now answers only with a file the set really holds, and
`fallbackFor(path, asked)` is the second half.

`App.findStatic` asks **every** set for the file before it asks any set for its
fallback. That is a second behaviour change and a strictly better one: a
single-page app mounted at `/` no longer answers `/assets/app.css` from its
`index.html` before the directory holding that file is reached. It is the same
ordering rule `docs_set` already had for `/openapi.json`, generalised.

## What it costs

Nothing on the path that finds a file, which is every request an asset makes.
The two headers are read only when a request has already missed every set,
and they are read without allocating: a compare for `Sec-Fetch-Mode`, and
`accept.asks` walking `Accept` once for the client that sent none. A directory
with no `spa_fallback` never reaches any of it.

`http/accept.zig` is ~90 lines and generic over nothing, so it dead-strips out
of a program that serves no single-page app.
