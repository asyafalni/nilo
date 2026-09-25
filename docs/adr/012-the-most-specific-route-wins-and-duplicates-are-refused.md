# The most specific route wins, and a duplicate is refused

**Status:** accepted
**Topic:** [routing](../design/routing.md)

## The problem

The router returned the first pattern that matched, in registration order. Two things followed, and both were the kind of bug that costs an afternoon.

`/users/:id` registered before `/users/new` meant `/users/new` never ran. Nothing said so: the route existed, the server started, and requests went to the wrong handler. This is the same trap ADR 008 already removed from middleware — where `use` after `get` silently failed to apply — left standing in the router.

And registering the same path twice was accepted without a word. In an app whose routes are split across files, two `app.get("/users/:id", …)` calls are easy to end up with and impossible to notice.

## The decision

**Matching picks the most specific route, not the first one.** A literal beats a param beats a `*`, and an earlier segment outranks every later one. A route that ends where the path ends beats a `*` standing for nothing.

**The ranking is the order a tree of segments is searched in.** Depth first, and at each segment the literal child it names, then the param child, then a `*` standing there, backing out of a branch that reaches the end with no route for the method. The first route that search reaches is the most specific one, so nothing is scored and nothing is compared once a route is found. The tree is built when routes are registered and a match allocates nothing.

**A second route of the same shape is refused** with `error.DuplicateRoute`, from the `app.get` call that made it, naming the pattern already there. Param names are not part of the shape: `/users/:id` and `/users/:name` answer the same requests, so they collide.

Order of registration decides nothing at all, which is what `use` and `get` already promised each other.

## What it costs

A real table decided the structure: the Nodeflux ERP's 276 routes, every one under `/api` ([`bench/result/http.md`](../../bench/result/http.md#matching-on-a-real-table-of-276-routes-under-one-prefix)).

| `zig build profile` | the scan below | the tree, writing into the caller's `Match` |
|---|---|---|
| one route | 19–20ns | 12–13ns |
| 276 routes, mean | 124–126ns, 35% of a request | 27–28ns, 8% |
| 276 routes, worst | 245–250ns | 53–55ns |

On synthetic tables of 1 to 100 routes the tree is within a nanosecond of the scan or faster, the one-route case included, because the same change stopped returning a 300-byte `Match` by value.

## What was replaced, and the evidence that moved it

**A score, and a linear scan that compared it.** Two bits per segment, packed most-significant-first into a `u32`, computed at registration; the scan kept the best score it had seen, stopped at a route of nothing but literals, and skipped a route that could not outrank the one in hand on an integer compare. That cost +13ns over first-match when it landed (39ns to 52ns, about 2% of a 600ns request on that machine), inside ADR 017's 10%, and it was the right first version. It stopped being right in two ways.

- **It was linear in the table, and its cheap filters cannot see past a shared prefix.** The first-segment key that took 44% off a synthetic 100-route set compares four bytes of the first segment, and under `/api` every route has the same one. On the ERP's table a match was 125ns, 35% of nilo's own work for a request.
- **The score disagreed with this ADR's own rule wherever a `*` met a route of another length.** More segments meant more digits, so `/:x/b/c` (47) outranked `/a/*` (13) for `/a/b/c` although `/a/*` is the more specific where the two first differ; and `/files` against `/files/*` for `/files` was decided by which was registered first. The tree answers both the way the rule says, and the tests hold both.

**Sorting the route list by specificity at `listen()`** would have kept first-match-wins at no cost per request. Rejected because it makes the list's order a thing you cannot read: a debugger, a dump or `app.routes()` would show an order nobody wrote. The tree keeps the registration list as it was typed and holds its own indices into it.

## Consequences

- `/users/new` and `/users/:id` both work, in either order.
- `/files/*` can sit under `/files/readme` without swallowing it.
- `/a/*` wins over `/:x/b/c` for `/a/b/c`, and `/files` over `/files/*` for `/files` in either registration order. Both were answered the other way by the score this replaced.
- A table of hundreds of routes under one prefix costs a few nanoseconds a match more than a table of one.
- Two identical routes stop `main` at the second one instead of producing a server with a handler that never runs.
- A pattern that cannot work at all — no leading slash, a `:` with no name, a `*` that is not last, a param name used twice — is caught while compiling, by `validatePattern`, since `App` has the pattern at compile time. What used to be `std.debug.assert` and an `unreachable` at startup is now a build error naming the route.
