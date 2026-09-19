# 0254 — a target is a type, and a path is a template

**Status:** accepted
**Extends:** [ADR 0070](./0070-a-fitting-borrows-the-loop.md), whose client
gains a type in front of it for the service a program calls more than once,
and [ADR 0243](./0243-the-ordinary-call-sends-json-and-a-query.md), whose
query half gains the path half it said it was waiting for.
**Applies:** [ADR 0060](./0060-a-second-database-is-a-second-type.md),
[ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md),
[ADR 0192](./0192-a-health-route-asks-the-services.md),
[ADR 0231](./0231-a-header-std-owns-goes-out-once.md).

## Context

`fetch.Client` is one for the whole program on purpose: the connection pool
lives in it, and a second client loads the certificate bundle a second time.
That left nowhere to write "Stripe is `https://api.stripe.com`, sends
`authorization: Bearer …`, and gets five seconds", so every call repeated all
three, and `examples/outbound/main.zig` was the evidence: five lines to
assemble a URL with two path params, a `user-agent` and a timeout on every
call. Two things could not be said at all, because the client has no
destination to say them about — a ceiling on calls to *this* service, so
that one slow third party stops eating the permits every other one shares,
and a `nilo_ready` for the upstream. The roadmap held the entry at *waiting
on a design* for one question: a type of its own, or a struct of defaults
handed to `Client`, which is the argument `s3.Bucket` already had.

## Decision

**`fetch.Target(name, options)` returns a type. Two services are two types,
therefore two Services, and a handler names the one it wants.**

```zig
const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

var stripe = try Stripe.open(&api, .{
    .base = "https://api.stripe.com",
    .authorization = cfg.stripe_key,
});
try app.provide(&stripe);

fn charge(stripe: *Stripe, c: *nilo.Ctx, id: nilo.Str) !Receipt {
    const res = try stripe.get(c, "/v1/charges/{}", .{id}, .{});
    if (!res.ok()) return nilo.fail.status(502, "stripe said no", .{});
    return res.json(Receipt, c);
}
```

The type-keyed registry resolves `*Stripe` with nothing added to it, and a
target started by `listen()` starts the client under it, so a program that
provides three targets and never the client works, and one that provides all
four starts the client four times, which sets the same `Io` four times.

**What is on the type is ADR 0068's rule, read the same way: whatever is a
property of the service rather than of the deployment.** The name, the
per-service `max_in_flight`, `timeout_ms`, `stall_ms`, `max_body` and a
`ready` path are the service's and sit on the type. **The base URL and the
credential are the deployment's**, given to `open`: a sandbox host and a test
key in development, the real pair in production, one binary
([ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
The roadmap sketch had `.base` on the type, and it was moved for the reason
ADR 0068 moved the endpoint: the win of the type was never comptime. It is a
URL built from a base held once rather than assembled at every call site,
and a header block that is the standing headers plus the call's, merged
only when both have something in them.

**A path is a template, and the template is read while compiling.** Two
shapes, decided by the arguments rather than by the template, so that a
path with no segment takes `.{}` either way:

- **A tuple fills `{}` by position** — `"/v1/charges/{}", .{id}` — and the
  count of segments against the count of arguments is a Refusal.
- **A struct fills `{name}` by field** — `"/v1/charges/{id}/refunds", .{
  .id = id, .limit = 10, .cursor = cursor }` — and **every field the
  template does not name is a query param**, under `withQuery`'s rules: an
  optional that is null is left out. A name with no field, a tuple for a
  named segment, a struct for a positional one, and a template that mixes
  the two are each a Refusal saying what to write instead.

A segment is an int, a bool or text, and text is percent-encoded with `/` as
data, so an id off a request that says `../admin` is one segment rather than
a walk. An optional is refused in a segment where it is welcome in a query,
because a segment cannot be left out. The URL is **one arena allocation,
sized exactly**: the template's pieces and the params are measured and then
written, the way `withQuery` already does, and `withQuery`'s measuring and
writing halves are what a target's `url` calls.

**Standing headers, and the call's own over them.** `authorization` and
`user_agent` are the two most services want and std has a slot for, so they
are fields on `Open` and go through the slot; anything else is a list of
lines. A line in the call's `headers` naming `authorization` or `user-agent`
goes *instead* of the standing value, the rule ADR 0231 set for std's own
slot, and a line naming any other standing header shadows it — so a target
that says `accept: application/json` can be asked for `text/csv` on one
call. The ordinary call has no standing headers and costs nothing here; a
call on a target that also passes headers of its own spends one bump of the
arena on the merge, the way `withRequestId` does for the id.

**A target's gate is taken before the client's and given back after it.**
`max_in_flight` on the type is a semaphore of the target's own, so a call to
a slow service queues at that service's gate holding no permit the others
share; zero, the default, is no gate of its own. The order is what makes it
compose rather than deadlock: target then client, always, and the client's
permit goes back when the Exchange ends, before the target's `defer` runs.

**`nilo_ready` is started-is-ready unless the type names a path.** The
reason is `s3.Store`'s: a balancer asks every second, and a GET to somebody
else's API at that rate is a bill and a rate limit rather than a check. A
service that publishes a status path names it in `ready`, and the probe is
then a GET to it under the target's own clocks, with anything but a 2xx
reported as the target's name and what went wrong.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none on a request that makes no call. A call
  on a target makes the same two arena allocations the client's call makes
  (the header block, then the body — ADR 0244) plus the URL, which the
  caller was already making by hand with an `Allocating` writer and is now
  one allocation sized exactly. A call that passes headers of its own under
  a target that has standing lines adds one for the merge.
- **Memory per idle connection:** unchanged. The template is comptime data;
  the URL is arena; the target is a pointer and a semaphore held once.
- **Throughput:** the gate is one more semaphore wait per call on a target
  that asked for one, and a null test on one that did not.
- **Binary size:** a type per target, each carrying the ten calls it
  instantiates; nothing for a program that names none.

## Alternatives

**A struct of defaults on `Client`**, `client.get(c, url, .{ .target =
&stripe })`. Every call still writes the host, and a handler cannot say in
its signature which service it reaches — the objection ADR 0060 made to one
`Db` with a name argument, and ADR 0068 to one Store with a bucket string.

**`.base` on the type**, as the roadmap sketched. Rejected by the rule the
sketch cited: the endpoint is the deployment's, and a comptime base would
make development and production two binaries.

**A path built through `withQuery` alone.** `withQuery` needs no base and a
path does, which is why the entry waited on this one; and a segment is not a
param — it is encoded with `/` as data and cannot be left out.

**An `Exchange` begun on a target.** Wanted, and not here: `Exchange.begin`
takes a client and a URL, and a target's `url(c, path, args)` is the URL.
The standing headers and the target's gate do not reach it, and the roadmap
keeps a sentence saying so.

## Consequences

- `fetch/target.zig`: `fetch.Target`, `fetch.target.Options`,
  `fetch.target.Open`, `fetch.target.OpenError`; `get`, `post`, `put`,
  `delete`, `patch`, `send`, `postJson`, `putJson`, `patchJson`, `sendJson`
  and `url`, each with a path in place of a URL; `nilo_start`, `nilo_ready`.
- `Client.sendAs` is public and takes a `Standing`; `withQuery` is split
  into `querySeparator`, `queryLen` and `queryWrite`, which a target's `url`
  shares.
- Twelve refusals under `fetch/refusals/fetch_target_*`; `refusals-fetch` is
  fifteen.
- `examples/outbound` is a `GitHub` target, and the five lines are gone.
- The roadmap loses "There is no target".
