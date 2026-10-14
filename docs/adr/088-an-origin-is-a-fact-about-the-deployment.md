# An origin is a fact about the deployment

**Status:** accepted
**Topic:** [cors-proxy](../design/cors-proxy.md)

`cors.with` takes `comptime Options` and unrolls the compare over the literals,
which is what makes a named origin cost one `mem.eql` and no allocation
([ADR 078](./078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)).

The consequence is that **the same binary cannot serve staging and
production**. The front end's address is not a property of the program; it is a
property of where the program was deployed, and every other deployment fact in
nilo — the port, the database URL, the session secret — arrives at run time
through `nilo_config`. An application that had two environments had two
answers: recompile per environment, or write the middleware itself.

**`cors.reading(&origins, .{ … })` is the same middleware reading its list from
somewhere the program fills before `listen()`.**

```zig
var origins: nilo.cors.Origins = .empty;

pub fn main() !void {
    var buf: [4][]const u8 = undefined;
    try origins.setSplit(&buf, settings.web_origins);   // "https://a.com,https://b.com"
    try app.use(nilo.cors.reading(&origins, .{ .credentials = true }));
    try app.listen(.{});
}
```

**The idiom is not CORS's alone.** A rate limit's counts and a Content-Security-Policy are deployment facts too, and `nilo.Late(T)` (a value stated in the program or the address of one filled before `listen()`) is the shape they and `maxBody` share ([ADR 264](./264-a-deployment-fact-is-a-late-value.md)). `cors.reading` keeps its `Origins` because a list needs a type of its own.

## An origin list that changes while running is a service, asked per request

`reading` serves a fact fixed before `listen()`. Some lists are not: a collector whose allowed domains are rows in a database (Sentry's DSN domains, Plausible and PostHog site settings), a multi-tenant API storing each tenant's origins. Those change while the server serves, and a boot-time list cannot follow them.

**`cors.deciding(decide, .{ … })` asks the program per request.** `decide` is `fn (services: *S…, origin: []const u8) bool`: up to two pointers to services the App provides, then the origin as text. It is generated into a typed middleware (ADR 008) whose service arguments are exactly `decide`'s, so the existing machinery does the work: the service is looked up like a handler's, and a missing one stops `listen()` with "the middleware taking (\*S)". The program owns the data and its lock; nilo owns the headers. Everything else is comptime as in `with`: preflight, methods, headers, credentials, max age, `Vary: Origin` on every response.

- **`decide` sees services and the origin, not the route or other request values.** A preflight is answered before a handler is chosen and carries no key or body, so it can only ask whether this origin may talk to the server. A per-request finer check (a POST's origin against the app its key names) is handler logic.
- **It is called only when the request has an `Origin`, and never with `null`**, for the reason `Origins.set` refuses it.
- **The allowed origin is copied into the request arena** (`setHeader`): those are the request's bytes, borrowed from the read buffer, not the program's, so `setStaticHeader` would lend out something the `Str` rule forbids. Cost: an arena copy per allowed cross-origin request, no heap allocation; routes without it pay nothing.
- **`.origins` in the options is a compile error**, and a `decide` that does not end with a `[]const u8` origin, or does not return `bool`, is refused with the signature to write.

So the choice for a deployment fact is: fixed at boot, `reading` (or a `Late` value, ADR 264); changing while running, a service through `deciding`. The rejected alternative above, a service looked up with `c.service`, is accepted here because a typed middleware's needs are held at `listen()` now (ADR 008), which was the objection.

## What stays comptime, and why that is not a compromise

Everything except the list: the methods, the headers, the exposed headers, the
max age, whether credentials are allowed. None of those is a fact about the
deployment — a server that allows credentials in production and not in staging
is two different services — so they stay where they were, as constants that
never get formatted.

`with` is untouched. Its unrolled compare is the measured path, an application
that names its origins in code keeps it, and this adds a second entry point
rather than a runtime branch inside the first.

## Why a variable the caller owns

`Middleware` is a bare function pointer, `fn (*Ctx, Next) anyerror!void`. It
captures nothing, which is what lets a chain be an array resolved once at
`listen()` and walked with no indirection per layer. So state a middleware
reads has to be reachable statically, and there were three ways to do that:

- **A comptime pointer to the caller's variable.** What this is. The wiring
  cannot be forgotten, because the pointer is an argument; the failure mode is
  an empty list rather than a missing registration.
- **A Service, looked up with `c.service(*cors.Origins)`.** Idiomatic in every
  other part of nilo, and wrong when this was decided: `checkServices` read the *routes'*
  argument lists, so it could not see what a middleware needs. A typed middleware's needs are held now, which is why `deciding` takes one. Forgetting
  `app.provide` would compile, start, and silently answer no CORS headers at
  all.
- **A global inside `cors.zig`.** One list for the whole process, so two
  Apps or two prefixes could not have different ones, and nothing would say so.

## The list is borrowed, and that is what keeps the budget

`Origins.set` does not copy. The entries point at the environment block, a
`.env`'s text, or a literal — the same rule `nilo_config` states for a
`[]const u8` field — and they have to outlive the server.

That contract is load-bearing rather than a convenience: because the text
outlives the request, the matched origin goes out through `setStaticHeader` and
**not** through `setHeader`, so a cross-origin request costs the same zero
allocations it costs under `with`. Copying it would have put an allocation on
the request path of every app that named an origin, which is the one axis
[ADR 017](./017-the-trade-budget-has-four-axes.md) treats as an invariant.

## What is refused, and where

`with` refuses these while compiling: no origins at all, `*` beside a
name, `*` with credentials, a capital letter, `null`, and anything that is not
an origin (no scheme, or a path, a trailing slash included). A list that arrives at run
time cannot be refused any earlier than the call that takes it, so `set` and
`setSplit` return errors for the same mistakes — at startup, where a program
can print them beside its other settings. `null` and a path are
`error.OriginNotAnOrigin`.

`null` is refused because it is not one page: it is what a sandboxed frame or a
`file:` page sends, and any site can make one, so a list holding it trusts
every site, for CORS with credentials and for `csrf.reading`, which reads the
same list. `csrf.with` refused it while compiling from the start; the run-time
list and `cors.with` did not, until a review found `WEB_ORIGINS` with `null`
in it passing both.

`"*"` is refused outright rather than handled. A runtime list names the
deployments this server answers; answering anybody is `cors.permissive`, which
needs no list and reads no header. That refusal is also what makes credentials
safe here without a second check: the combination browsers reject cannot be
built.

The one thing said while compiling is naming origins in both places at once —
`reading(&origins, .{ .origins = … })` — because the field would be ignored,
and an ignored list is one somebody edits and then wonders about.

## An empty list says so, once

A program that registers `reading` and never fills it refuses every
cross-origin request, and the browser's message names none of that. The first
cross-origin request that finds the list empty logs one warning naming the
call. Once, through an atomic flag, on a path that a matching request never
reaches — so a correctly configured server pays a single relaxed load on the
requests that were going to be refused anyway.

Not at startup: nothing in a middleware runs at startup, and a program that
fills its list after `use` and before `listen` would be told off for something
it was about to do.
