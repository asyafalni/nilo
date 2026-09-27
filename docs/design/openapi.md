# OpenAPI

**The API document is built from the handler signatures in the same pass that registers the routes, so it cannot drift from what the server actually serves.**

**Guide:** [OpenAPI](../guide/openapi.md) · **Reference:** [OpenAPI options](../reference/app.md#openapi-options)

The code is `http/openapi.zig` (`Operation`, `Components`, `write`), `http/app.zig` (`docs`, `failures`, `writeOpenApi`, `describeLast`), and `http/wiring.zig` (`resolveChains`, where operations are collected).

## Overview

```
  route registration ──► App.operations (one Operation per route, ArrayList)
         │                        │
         │ app.docs(.{ title, version, … })     app.failures(T)
         │                        │                     │
         ▼                        ▼                     ▼
  resolveChains() ──► openapi.write(gpa, w, ops, info) ──► bytes, once
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                              ▼
           static.fromMemory                app.writeOpenApi(w)
           served at /openapi.json           no port, no database (ADR 135)
           and /docs (a CDN viewer)
```

Each route contributes an `Operation`, a plain value pointing at read-only memory. Nothing here runs while a request is being served.

## Rules

1. **The document is data built at compile time and walked once, not a writer generated per route.** A writer per route would put a copy of the JSON-writing code in the binary for every route; instead, one function walks a list built at registration. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
2. **A type whose fields are not its JSON is described by what it declares, or not at all.** A type with a `jsonStringify` is no longer described from its fields. A `nilo_openapi = .{ .type = "string", .format = "uuid" }` next to it says what it writes; a custom writer with no marker gets `{}` and a note, instead of a wrong schema. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
3. **A tagged union declares its own wire format.** `nilo_json = .{ .tag = "signal", .rename_all = .lowercase }` chooses internal tagging instead of `std.json`'s default external tagging, and the document shows it as `oneOf` with a `discriminator`. An unmarked union still gets the generated writer and is documented as externally tagged, exactly what `std.json` sends. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
4. **Two type names that differ only by lifetime, `Foo_Str` and `Foo_Text`, become one component when they render identically all the way down.** Anything else, including two types that just share field names, keeps its own name. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
5. **The document only claims what the signature guarantees.** `Response(T)` gets `default`, not a guessed status; a type with no JSON shape gets `{}`; a type that refers to itself stops eight levels deep; and a `400` is listed only for a route with a typed path param, a query struct or a body. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
6. **`!?T` documents a 404, because the signature guarantees it.** A `fail.conflict` three lines into the body does not, and the document does not claim it. [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) (full rule on [`errors`](./errors.md))
7. **A `*Ctx` handler that returns nothing is documented as `written`, not `default`, unless the route describes what it sends.** `app.health` and `app.metrics` call `describeLast` after registering, so nilo's own routes have a real `200` and are not counted among the application's undescribable routes. The `listen()` log line and the document both say "holds the Ctx and returns nothing", instead of guessing which. [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)
8. **`Status(code, void)` avoids rule 7** for a handler that wants both its Ctx and a documented status. [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)
9. **`app.writeOpenApi(w)` writes exactly the bytes the server would serve, with no port, no database and no network.** `buildDocs` and the served copy both go through this one call, so a checked-in file and a running server cannot describe two different APIs. [ADR 135](../adr/135-the-document-is-a-build-artefact.md)
10. **Every named type gets a `$ref`, with no limit.** `Components` is a list that grows, read at `resolveChains()`, not a fixed-size array, so the last type to arrive is named exactly like the first. [ADR 170](../adr/170-a-document-names-every-shape-it-has.md)
11. **An error shape the application defines is documented too.** `app.failures(T)` builds `components.schemas.Failure` from `T`'s fields, so the document and the wire cannot disagree about what an error looks like (full rule on [`errors`](./errors.md)). [ADR 024](../adr/024-every-failure-answers-as-json.md)

## Decisions

| ADR | What it decides |
|---|---|
| [016](../adr/016-the-api-description-comes-from-the-signatures.md) | The document is built from signatures: custom JSON writers, tagged unions, merged lifetime names, and what is left out |
| [120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md) | A `*Ctx` handler that returns nothing is `written`, not `default`; nilo's own routes describe themselves |
| [135](../adr/135-the-document-is-a-build-artefact.md) | `writeOpenApi` produces the document without a server, for a checked-in file CI can diff |
| [170](../adr/170-a-document-names-every-shape-it-has.md) | `Components` is an unbounded list; every named type keeps its `$ref` |

Related topics: what the signature guarantees about a failure, and what stays a `fail.*` call the document cannot see, is in [`errors`](./errors.md) (ADR 023, ADR 024); a type that answers with its own bytes instead of JSON, and how the document labels it, is [ADR 157](../adr/157-a-type-can-write-its-own-answer.md) (responses); a struct's own field-renaming rule, separate from a union's `.rename_all`, is [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md) (json); a type that wraps one known value so renames and schemas still see through it is [ADR 163](../adr/163-a-document-is-its-value.md) (json); static files, which is how the built document is served, is [`static-files`](./static-files.md).

## Open questions

- **An endpoint protected by a resolver is documented as needing nothing.** `nilo.Authorization(…)` in a signature and an `app.guard` are documented ([ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)). But a handler taking a resolved value like `CurrentUser` requires whatever header the resolver reads, and the document does not say so: a resolver is an opaque function, not a type that carries a security scheme. Recorded as a known gap in [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md).
