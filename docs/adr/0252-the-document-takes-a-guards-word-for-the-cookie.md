# 0252 — the document takes a guard's word for the cookie

**Status:** accepted
**Extends:** [ADR 0191](./0191-an-authorization-header-a-handler-can-ask-for.md),
whose line — the document says what a type says and nothing a resolver
reads — gains one exception and says what it is.
**Applies:** [ADR 0017](./0017-the-api-description-comes-from-the-signatures.md),
[ADR 0080](./0080-a-route-can-say-it-is-not-covered.md),
[ADR 0126](./0126-a-route-can-say-what-covers-it.md).

## Context

A handler that takes `nilo.Authorization(.bearer)` gets a `security` entry
and a `securitySchemes` block, because the header is in the type and the
type is what the document reads. A handler behind a session cookie gets
nothing, because the cookie is read by a middleware on the group, or by a
resolver, and neither is a type. So the document said every route under
`/api` was open, and a consumer generating a frontend client from it hit
that for real: every route under their `/api` is behind a cookie and four
are not, and the client it generated sent no cookie to any of them.

The roadmap held the gap at *waiting on a design* for one sentence: how a
middleware says which scheme it enforces *without the document taking a
middleware's word for something it cannot check*. That sentence was doing
two jobs, and separating them is the design.

## Decision

**`app.guard(middleware, cookie)` declares that `middleware` refuses a
request without the cookie named `cookie`. Every route the middleware is in
front of is written with a `cookieAuth` requirement and a 401; the rest are
written as they were.**

The claim splits into two, and the document checks one of them:

- **Which routes are behind it, the document works out.** Whether a
  middleware is in front of a route is not the middleware's word — it is
  `use`, `useOn`, `with` and `without`, the same facts `resolveChains`
  reads to build the chains that will run. `mw.wraps` asks those facts the
  same two questions `chainFor` asks, without building the chain, and
  `writeOpenApi` asks it once per operation at the moment the document is
  written. So a `without` on the sign-in route unmarks it in the document
  because it unmarks it in the program, in the same line; there is no
  second list of exceptions to keep in step. That is the part the roadmap
  sentence was worried about, and it is not taken on anybody's word.
- **What the middleware does, the document takes on the caller's word.**
  That `requireSession` reads a cookie called `session`, and refuses
  without it, is a line of Zig inside a function body, and a compile-time
  check cannot read a function body — the rule ADR 0024 already states for
  `fail.conflict`. The declaration is one line, in the file where the
  middleware is installed, and it is the same trust ADR 0076 extends to a
  type that says it writes its own JSON: the program states a fact about
  itself that the framework cannot verify and would otherwise have to
  guess, and states it once.

**One guard per App.** A program has one session cookie (ADR 0035), and a
second `guard` call is `error.GuardAlreadyDeclared` rather than a second
scheme, because two cookie schemes on one document is a document a
generated client cannot sign in to. **Declaring is not installing**: `guard`
touches nothing on the request path, and a middleware that was declared but
never `use`d is in front of no route and writes no scheme — the document
lists a scheme only when something takes it, the rule ADR 0191 set.

**The cookie and the header compose as *both*.** A route behind the guard
whose handler also takes `Authorization(.bearer)` is written as one
requirement object holding both schemes, which OpenAPI reads as AND. That
is what happens: the guard ran first and refused without the cookie, and
the handler still asked for the header. Two objects would have read as OR,
and promised a sign-in that gets a 401.

**The scheme is `apiKey` in a cookie**, `{"type":"apiKey","in":"cookie",
"name":"session"}`, because it is the one spelling OpenAPI 3 has for a
session cookie and every generator reads it as "send the cookie". The 401
the document writes for a guarded route names the guard rather than
`WWW-Authenticate`, because a cookie 401 carries no challenge.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none. Nothing here runs on the request
  path; `declared_guard` is read by `writeOpenApi` and by nothing else.
- **Memory per idle connection:** unchanged.
- **Throughput:** unchanged.
- **Binary size:** `guard`, `wraps`, and a branch in the document writer.
  Linked only by a program that calls `docs()` or `writeOpenApi`, which
  already carries the writer.
- **Writing the document:** one allocation more — a copy of the operations
  list, so a `*const App` can mark it — once per `listen()` and once per
  `writeOpenApi`. Not a per-request cost; the served document is bytes in
  a static Set.

## Alternatives

**A cookie in the type**: `Session(T)` as an argument, the way
`Authorization` is. It exists, and it is the wrong place for the fact: the
consumer's guard is one middleware on the group (ADR 0201 is what made that
the shape), and the handlers behind it take a `CurrentUser` from a resolver
rather than the cookie. Putting the cookie in every handler's signature to
get it into the document would be a second thing to keep in step with the
guard, which is the objection the roadmap recorded.

**A middleware that declares itself**, by carrying a `nilo_security`
declaration the way a type carries `nilo_json`. A middleware is a function
pointer, and a function has no declarations to read; making it a struct to
hold one changes the type every `use` in the repository takes, for one
field a document reads.

**Marking at registration** rather than when the document is written.
Simpler, and wrong: `without` and `with` return groups, and a route can be
registered through one before the `use` that covers the prefix is called,
because ADR 0009 made the order not matter. The chains are resolved at
`listen()` for the same reason, and the document has to read the same
settled facts.

**A `securitySchemes` block with no per-route marking**, leaving `security`
off every operation and letting the consumer add it. That is the document
saying "there is a cookie" and not "who needs it", and the four open routes
are the whole reason the consumer asked.

## Consequences

- `App.guard`, `App.declared_guard`, `mw.Guard`, `mw.wraps`.
- `openapi.Operation.guarded`, `openapi.Info.cookie`, `openapi.cookie_scheme`,
  and the writer's cookie branch; `writeOpenApi` marks a copy of the
  operations from the middleware wiring.
- Two tests in `http/behaviour.zig`: the prefix-with-exceptions shape, and a
  declared-but-uninstalled guard writing nothing.
- The roadmap loses "The API description is silent about a session cookie".
- What is still not in the document: a resolver that reads the cookie with
  no middleware in front of the route. That route is not behind a guard,
  and the document says so; declare the guard on the group, which is what
  ADR 0201 built the group for.
