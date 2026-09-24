# OpenAPI

**The document is read off the handler signatures on the same pass that builds the routes, so it cannot drift from what the server actually serves.** How to turn it on is the guide ([`guide/openapi.md`](../guide/openapi.md)); every option and marker is the reference ([`reference/app.md#openapi-options`](../reference/app.md#openapi-options)). The code is `http/openapi.zig` (`Operation`, `Components`, `write`), `http/app.zig` (`docs`, `failures`, `writeOpenApi`, `describeLast`), and `http/wiring.zig` (`resolveChains`, where operations are collected).

## How the pieces fit

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

A route contributes an `Operation`, a plain value pointing at read-only memory; nothing here runs while a request is in flight.

## The rule in force

1. **The document is comptime data walked once, not a writer generated per route.** A writer per route would put a copy of the JSON-emitting code in the binary for every route registered; one function walks a list built at registration instead. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
2. **A type whose fields are not its JSON is described by what it says, or by nothing.** A type with a `jsonStringify` stops being reflected; a `nilo_openapi = .{ .type = "string", .format = "uuid" }` beside it says what it writes, and a custom writer with no marker gets `{}` and a note rather than a wrong schema. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
3. **A tagged union says its own wire shape.** `nilo_json = .{ .tag = "signal", .rename_all = .lowercase }` picks internal tagging over `std.json`'s default external one, and the document renders it as `oneOf` with `discriminator`; an unmarked union still gets the generated writer and is documented externally tagged, byte for byte what `std.json` sends. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
4. **Two names differing only by lifetime, `Foo_Str` and `Foo_Text`, merge into one component when they render identically all the way down.** Anything else, including two types that merely share field names, keeps its own name. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
5. **The document claims only what the signature settles.** `Response(T)` gets `default`, not a guessed status; a type with no JSON shape gets `{}`; a self-referential type stops eight levels deep; a `400` is listed only for a route with a typed path param, a query struct or a body. [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)
6. **`!?T` documents a 404, because the signature settles it.** A `fail.conflict` three lines into the body does not, and is not claimed. [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) (full rule on [`errors`](./errors.md))
7. **A `*Ctx` handler that returns nothing is `written`, not `default`, unless the route itself describes what it sends.** `app.health` and `app.metrics` call `describeLast` after registering, so nilo's own routes carry a real `200` and are not counted among the application's undescribable ones; the `listen()` line and the document both say "holds the Ctx and returns nothing" rather than guessing which of the two states that is. [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)
8. **`Status(code, void)` is the way out of state 7** for a handler that wants both its Ctx and a documented status. [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)
9. **`app.writeOpenApi(w)` writes the same bytes the server would serve, with no port, no database and no network.** `buildDocs` and the served copy go through this one call, so a checked-in file and a running server cannot describe two different APIs. [ADR 135](../adr/135-the-document-is-a-build-artefact.md)
10. **Every named shape gets a `$ref`, with no ceiling.** `Components` is a growing list read at `resolveChains()`, not a fixed-size array; a shape that arrived last is named exactly like one that arrived first. [ADR 170](../adr/170-a-document-names-every-shape-it-has.md)
11. **A failure shape the application names is described too.** `app.failures(T)` derives `components.schemas.Failure` from `T`'s fields, so the document and the wire cannot disagree about what an error looks like (full rule on [`errors`](./errors.md)). [ADR 024](../adr/024-every-failure-answers-as-json.md)

## Decisions

| ADR | What it decides |
|---|---|
| [016](../adr/016-the-api-description-comes-from-the-signatures.md) | The document is read off signatures: custom JSON writers, tagged unions, lifetime-merged names, and what is left unclaimed |
| [120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md) | A `*Ctx` handler that returns nothing is `written`, not `default`; nilo's own routes describe themselves |
| [135](../adr/135-the-document-is-a-build-artefact.md) | `writeOpenApi` produces the document with no server, for a checked-in file a CI step can diff |
| [170](../adr/170-a-document-names-every-shape-it-has.md) | `Components` is an unbounded list; every named shape keeps its `$ref` |

Beside this topic: what the signature settles for a failure and what stays a `fail.*` call invisible to the document is [`errors`](./errors.md) (ADR 023, ADR 024); a type answering with its own bytes rather than JSON, and the label the document gives it, is [ADR 157](../adr/157-a-type-can-write-its-own-answer.md) (responses); a struct's own field-renaming rule, separate from a union's `.rename_all`, is [ADR 148](../adr/148-a-field-name-is-a-spelling-too.md) (json); a type that writes around one known value so a rename or a schema still sees through it is [ADR 163](../adr/163-a-document-is-its-value.md) (json); static files, which is how the document is served once built, is [`static-files`](./static-files.md).

## Open

- **An endpoint authenticated by a resolver is documented as needing nothing.** `nilo.Authorization(…)` in a signature and an `app.guard` are documented ([ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)); a handler taking a resolved value like `CurrentUser` requires whatever header the resolver reads, and the document does not say so: a resolver is an opaque function, not a type carrying a security scheme. On record as a known hole in [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md).
