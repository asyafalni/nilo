# A document names every shape it has

`openapi.zig` held its named shapes in an array of sixty-four. Past that a
shape was written out in place — the comment said the document was bigger and
still correct, and it was. What it was not is a document a client can be
generated from with the names intact. A product of six contexts sat exactly at
the cap: the shapes that arrived last — `Quotation`, `Margin`, two `Summary`
types, `quotation.Line` — were inlined on every route that carried them,
while `Rab` and `rab.Line` a file away kept a `$ref`. `openapi-typescript`
produces an anonymous type for each, and a screen importing
`components["schemas"]["Quotation"]` compiles against the Go server and not
against this one. The only sign was a `$ref` that was missing.

The full product is thirteen contexts and 267 operations; a straight
extrapolation is around a hundred and fifty named shapes.

## A list that grows

`Components` is an `ArrayList` of slots now, and `openapi.write` takes the
allocator it grows in. The document is written once, from `resolveChains()`
before the server listens, and served from memory afterwards; nothing here
runs while a request is in flight, which is the one place an allocation is
free to happen. Every shape with a name gets a slot, and every slot gets a
`$ref`.

The fixed array had bought nothing: it was a stack struct sized for a number
somebody guessed, in a function that already writes into an allocating
buffer.

## What was not done

**A bigger constant, or a build option.** Either keeps a ceiling and the
missing `$ref` under it; the option puts the number in the caller's
`build.zig` where the next context to arrive is the one that finds it. The
port asked for either, with a log line when the ceiling is reached — and a
ceiling that does not exist needs no line.

**Writing components in a second pass over a counted first.** Counting the
distinct names needs the same storage the list is.

## Against ADR 0018's four axes

- **Allocations per request: zero.** The document is not on the request
  path, and never was.
- **Memory per idle connection: zero.**
- **Throughput: nothing.** One `ArrayList` for the seconds `resolveChains`
  takes, freed when the document is written.
- **Binary size: nothing measurable.** The fixed arrays go, the list comes.

## Consequences

- `openapi.write(gpa, w, ops, info)`; `App.writeOpenApi` passes its own.
- A test writing seventy named shapes and counting seventy `$ref`s.
- A generated client from the port's document has every shape by name.
