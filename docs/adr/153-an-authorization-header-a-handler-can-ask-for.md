# An Authorization header, or a session cookie, a handler can ask for

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

## Context

`c.header("Authorization")` works, and the six lines after it were wrong in both places this repository had them: `examples/orders/main.zig` and the resolver `docs/guide/jwt.md` shows. Both matched the scheme case-sensitively (`startsWith(value, "Bearer ")` refuses `bearer abc`, and RFC 9110 §11.1 says the scheme is case-insensitive), and neither 401 carried a `WWW-Authenticate` header (RFC 9110 §15.5.2 says it has to). Both copies compiled, passed their tests and read as ordinary code, which is the failure mode [ADR 111](./111-nilo-verifies-a-token-and-does-not-fetch-one.md) built `nilo_jwt` to keep out, a check that runs perfectly and is subtly wrong, one header up from where that module starts.

The question that started this was whether Fiber's `extractors` package, `FromHeader`, `FromQuery`, `FromCookie`, `FromAuthHeader`, and a `Chain` that tries each in turn, was worth copying. Read against nilo's argument list it mostly already exists as types rather than functions: a path param is positional, `Query(T)` and `Form(T)` are the query string and the body, `FromHeader(name, T)` is a header ([ADR 131](./131-a-header-a-handler-can-be-given.md)), `Session(T)` is the cookie, and `allowance.keyed(fn)` is `FromCustom`. What was left over was `FromAuthHeader("Bearer")`.

A second gap showed up once the header had a type: a handler behind a session cookie got no `security` entry at all, because the cookie is read by a middleware on the group or by a resolver, and neither is a type, so the document said every route under `/api` was open. A consumer generating a frontend client from it hit that for real: every route under their `/api` is behind a cookie and four are not, and the client it generated sent no cookie to any of them. The roadmap held the gap at *waiting on a design* for one sentence, how a middleware says which scheme it enforces without the document taking a middleware's word for something it cannot check, and that sentence was doing two jobs.

## Decision

**`Authorization(scheme)` is a typed argument for the header, refusing before the handler runs with the right challenge; `app.guard(middleware, cookie)` gives a cookie the same place in the document, on the trust the document already extends to a declared fact it cannot verify.**

### The header: `Authorization(scheme)`

```zig
fn me(auth: nilo.Authorization(.bearer), issuer: *const Issuer, c: *nilo.Ctx) !Profile {
    const claims = jwt.verify(Claims, c.arena(), auth.value.view(), …) catch
        return nilo.Authorization(.bearer).refuse("that token is not valid here", .{});
    …
}

fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !void {
    … auth.user, auth.password …
}
```

The same family as `FromHeader`: a typed argument, a `Role` in `typed.zig`, and an entry in the document. Three things are its own:

**Absent is a 401, not a 400, and the 401 says what would have done.** A missing `Authorization`, another scheme, an empty token, Basic that is not base64 or has no colon, each is refused before the handler runs, with `WWW-Authenticate: Bearer` or `Basic realm="…"` on the answer. The scheme is matched case-insensitively and the blanks around the token are not part of it.

**A refusal after reading carries the same header, without the handler holding a Ctx.** The token did not verify; the password did not match. That 401 is the handler's, and `T.refuse(fmt, args)` is `fail.unauthorized` with `T.challenge` attached, through the `Failure` the fiber already owns, the way every fail function works ([ADR 006](./006-failure-box-bound-to-the-fiber.md)), so a handler stays a plain function a test calls with no request behind it. `serve.sendFailure` writes the header when the Failure carries one.

**In the document it is a security scheme, not a parameter.** An `Authorization` argument becomes `security: [{bearerAuth: []}]` on the operation, a `401` in its responses, and one entry under `components.securitySchemes`, only for the schemes some route takes. A generated client reads that as "sign in", where a header parameter would read as "fill in a field". `c.authorization(.bearer)` is the same read for a resolver or a middleware, which have a Ctx and no argument list of their own. The parsing lives in `http/authorization.zig`, handed the header, the arena and the lifetime rather than the Ctx, so the file stays outside the App's core (`http_core` in `build.zig`).

### The cookie: `app.guard(middleware, cookie)`

`app.guard(middleware, cookie)` declares that `middleware` refuses a request without the cookie named `cookie`. Every route the middleware is in front of is written with a `cookieAuth` requirement and a 401; the rest are written as they were. The claim splits into two, and the document checks one of them:

- **Which routes are behind it, the document works out.** Whether a middleware is in front of a route is not the middleware's word, it is `use`, `useOn`, `with` and `without`, the same facts `resolveChains` reads to build the chains that will run. `mw.wraps` asks those facts the same two questions `chainFor` asks, without building the chain, and `writeOpenApi` asks it once per operation at the moment the document is written. A `without` on the sign-in route unmarks it in the document because it unmarks it in the program, in the same line; there is no second list of exceptions to keep in step.
- **What the middleware does, the document takes on the caller's word.** That `requireSession` reads a cookie called `session`, and refuses without it, is a line of Zig inside a function body, and a compile-time check cannot read a function body, the rule [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md) already states for `fail.conflict`. The declaration is one line, in the file where the middleware is installed, and it is the same trust extended to a type that says it writes its own JSON: the program states a fact about itself that the framework cannot verify and would otherwise have to guess, and states it once.

**One guard per App.** A program has one session cookie ([ADR 033](./033-a-session-is-sealed-into-the-cookie.md)), and a second `guard` call is `error.GuardAlreadyDeclared` rather than a second scheme, because two cookie schemes on one document is a document a generated client cannot sign in to. **Declaring is not installing**: `guard` touches nothing on the request path, and a middleware that was declared but never `use`d is in front of no route and writes no scheme, the document lists a scheme only when something takes it, the same rule the header follows.

**The cookie and the header compose as *both*.** A route behind the guard whose handler also takes `Authorization(.bearer)` is written as one requirement object holding both schemes, which OpenAPI reads as AND, matching what happens: the guard ran first and refused without the cookie, and the handler still asked for the header. Two objects would have read as OR, and promised a sign-in that gets a 401.

**The scheme is `apiKey` in a cookie**, `{"type":"apiKey","in":"cookie","name":"session"}`, the one spelling OpenAPI 3 has for a session cookie that every generator reads as "send the cookie". The 401 the document writes for a guarded route names the guard rather than `WWW-Authenticate`, because a cookie 401 carries no challenge.

## What is deliberately not built

**A chain.** Fiber's `Chain(FromHeader, FromQuery("token"), FromCookie(…))` is the feature the package exists for and the one refused here. A token in a query string is a token in every access log between the client and this process, and a value that may have come from one of three places is a value whose provenance the handler cannot reason about. The type says where it comes from, and there is one place.

**A `Source` enum with a runtime warning for the insecure ones.** Where nilo has a rule about where a value may come from, the rule is a Refusal at compile time, the two on file are an empty Basic realm and one with a quote in it.

**Digest, and `Bearer` with parameters** (`error="invalid_token"`, `scope=…`). The first is nobody's default in 2026; the second is a policy the handler is better placed to state in the message than the type is to guess.

**`?Authorization(.bearer)`**, a route that works signed-out and personalises signed-in. That shape is a resolver returning an optional, which exists, and it reads `c.authorization` inside a `catch`. Making the argument itself optional would mean deciding what a *present but wrong* header does on a route that did not require one, and the honest answers differ by endpoint.

## What was rejected

**Leaving the header to the resolver**, as ADR 131 left the header itself. The signed-in user *is* the resolver's job, and it still is, but the header is not the user, and the two mistakes above are in the reading of the header, which every resolver was rewriting. A resolver that wants the user takes `c.authorization(.bearer)` and keeps its job; what it no longer owns is the six lines it kept getting wrong.

**`fail.unauthorizedWith(challenge, …)` as the whole feature**, with no type. It fixes the missing-header case and not the case-sensitivity one, and it puts nothing in the document. The type is what makes the scheme's spelling nilo's business and the sign-in a generated client's.

**A cookie in the type**, `Session(T)` as an argument, the way `Authorization` is. It exists, and it is the wrong place for the fact: the consumer's guard is one middleware on the group ([ADR 014](./014-what-nilo-borrows-and-from-whom.md) is what built `app.group()`), and the handlers behind it take a `CurrentUser` from a resolver rather than the cookie. Putting the cookie in every handler's signature to get it into the document would be a second thing to keep in step with the guard.

**A middleware that declares itself**, carrying a `nilo_security` declaration the way a type carries `nilo_json`. A middleware is a function pointer, and a function has no declarations to read; making it a struct to hold one changes the type every `use` in the repository takes, for one field a document reads.

**Marking at registration** rather than when the document is written. Simpler, and wrong: `without` and `with` return groups, and a route can be registered through one before the `use` that covers the prefix is called, because [ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md) made the order not matter. The chains are resolved at `listen()` for the same reason, and the document has to read the same settled facts.

**A `securitySchemes` block with no per-route marking**, leaving `security` off every operation and letting the consumer add it. That is the document saying "there is a cookie" and not "who needs it", and the four open routes were the whole reason the consumer asked.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | Bearer: none, `.value` is a slice of the head, the way `c.header` answers. Basic: one, of the decoded length, from the request arena, on the route that asked for it. The guard: none, nothing here runs on the request path. A route asking for neither runs the code it ran before. |
| Memory per idle connection | None. `@sizeOf(Failure)` is 256 before and after: the challenge is one pointer to a comptime string, fitting because `n` became a `u8` (the buffer is 240 bytes) and the pointer took the six bytes of padding `status: u16` had been leaving before `n: usize`. |
| Throughput and p99 | One `c.header` walk for a route that asks, the same walk the handler was doing by hand, and an `eqlIgnoreCase` over six bytes. The guard: unchanged; writing the document costs one allocation more, a copy of the operations list so a `*const App` can mark it, once per `listen()` and once per `writeOpenApi`, not a per-request cost. |
| Binary size | A comptime generic and a branch in `sendFailure` on a pointer being null; `guard`, `wraps`, and a branch in the document writer, linked only by a program that calls `docs()` or `writeOpenApi`. Nothing the linker keeps for a program that names none of it. |

## Consequences

- One file, `http/authorization.zig`, outside the core; one `Role`, one line in the argument loop and one arm in the operation builder in `typed.zig`; one method on `Ctx`; one enum and two loops in `openapi.zig`; one pointer on `Failure`, one fail function, one branch in `sendFailure`.
- `App.guard`, `App.declared_guard`, `mw.Guard`, `mw.wraps`; `openapi.Operation.guarded`, `openapi.Info.cookie`, `openapi.cookie_scheme`, and the writer's cookie branch.
- `examples/orders` and the jwt guide are each three lines shorter and no longer case-sensitive; the roadmap's list of small middleware loses `basicauth` and `keyauth`, which are this type plus a lookup the application already has, and loses "The API description is silent about a session cookie".
- What is still not in the document: a resolver that reads the cookie with no middleware in front of the route. That route is not behind a guard, and the document says so; declare the guard on the group instead.
