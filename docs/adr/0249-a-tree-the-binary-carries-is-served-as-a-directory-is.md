# 0249 — a tree the binary carries is served as a directory is

**Status:** accepted
**Extends:** [ADR 0010](./0010-static-files-are-held-in-memory.md), whose
list now has a second way to be filled.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md).

## Context

`app.static` reads a directory at `listen()`, and everything after the read
is what a single-binary product wants: gzipped once while the App is built,
an ETag per file, the SPA fallback, no path to resolve, nothing per request
(ADR 0010, ADR 0109). What it could not take was a tree that `@embedFile`
put into the binary. A product whose UI is compiled in — the shape every
self-hosted tool with a web page ships as — therefore shipped a binary *and*
a directory *and* a working directory to get right, and the guide said so:
"the path is relative to the working directory the server runs in". That is
a different product from the one the binary promised.

The gap was recorded from outside first, by a 64,000-line observability
platform weighing a move onto nilo: "the hard part is already built and
built well. The only thing missing is a second way to get the bytes in."
`fromMemory` had existed since ADR 0017 for the API description and was
nearly that, except that it copies its bytes, takes no prefix, no options
and no fallback, and was written for one JSON file rather than a tree.

## Decision

**`app.embedded(prefix, files)` and `embeddedWith(prefix, files, options)`:
a list of `.{ .path, .bytes }` served through the same Set a directory is,
with the bytes borrowed from the binary rather than read.** `static.embed`
is `load` with the read taken out — the same join onto the prefix, the same
content type from the name, the same ETag, the same gzipped copy for the
files worth it, the same sorted list and binary search, the same fallback
rule. A request cannot tell the two apart, and no code on the request path
was touched.

Three things follow from where the bytes are, and each is a subtraction
rather than a second mode:

- **The Set does not own the bytes.** `@embedFile` bytes are mapped for the
  life of the process and cannot be given back, so `Set.owns_bytes` is
  false and `deinit` frees the URL, the two ETags and the gzipped copy and
  steps over the file. Copying instead would double the memory of every
  embedded tree for nothing — and `fromMemory` keeps copying, because its
  one file is generated at run time and the copy is what keeps it alive.
- **Nothing can spill, so nothing is over a limit.** `EmbedOptions` is
  `Options` less `max_file_bytes`, `max_total_bytes`, `dotfiles` and
  `reload`: no threshold, because there is no disk to leave a file on; no
  total, because the bytes are mapped whether or not a Set names them and
  charging them would count memory that is not spent twice; no dotfile
  rule, because every name was written by the caller; no reload, because
  there is nothing to reload from. The six that remain default from
  `Options` so the defaults are written once.
- **Two mistakes a directory cannot make are refused.** A directory holds
  one file per name; a list can hold two, and the binary search would then
  answer whichever it found first, forever. That is
  `error.StaticDuplicateUrl` naming the URL. A fallback that names no entry
  is the same `error.StaticDirNotFound` `load` gives, said for a list.
  Both are the caller's and not the environment's, so there is no
  `tryEmbedded`: a list that fails was fixed at compile time and there is
  nothing a program can do about it at run time but stop, which is what
  `static` does for an explained failure (ADR 0002).

**`@embedFile` stays in the caller's hands.** Its path is relative to the
file it is written in and the file has to be inside that module, so nothing
in nilo can name a caller's `dist/`. The list is what the caller writes; a
build step that walks a directory into one is an ordinary `build.zig` step
and is theirs until two projects have written the same one.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none. The request path is the one `static`
  already takes, unchanged.
- **Memory per idle connection:** unchanged; nothing here is per
  connection.
- **Memory held:** per file, the URL, two ETags and the gzipped copy —
  what a held file costs less its bytes. The log line reports the bytes the
  binary carries and the bytes this call allocated as two numbers, for the
  reason `load` reports held and spilled as two.
- **Binary size:** the tree itself, which the caller chose to embed, plus
  `embed`, which is a hundred lines beside `load` and shares its helpers.

## Alternatives

**Widening `fromMemory`.** It takes `Entry` — a URL, bytes, a content type
and a cache control — and copies the bytes. Teaching it a prefix, options,
a fallback and borrowed bytes would have made the API description's one
call carry six parameters it does not use, and left its copy, which the
generated document needs, looking like an oversight in the tree case.

**A build step in nilo that walks a directory and emits the list.** It is
the obvious second half and it is not built, for the reason
`docs/roadmap.md` gives for every convenience: until two callers have
written it, nobody knows which of its choices — hidden files, symlinks,
a size cap, where the generated file goes — are the ones that matter.

**Serving from `@embedFile` bytes through `fromMemory` and duplicating
them.** Works today and doubles the memory of every tree. A 5 MB
front-end bundle held twice is 5 MB spent on nothing, which is the kind of
number ADR 0018 exists to refuse.

## Consequences

- `static.Embedded`, `static.EmbedOptions`, `static.embed`,
  `App.embedded`, `App.embeddedWith`, and the same two on a group.
- `Set.owns_bytes`, threaded through `freeFile`.
- `LoadError.StaticDuplicateUrl`, and `explained` knows it.
- The guide's "the path is relative to the working directory" sentence is
  no longer the only answer, and the guide says so under
  [Files the binary carries](../guide/static-files.md#files-the-binary-carries).
- Three files under `http/testdata/embedded/` exist to be embedded by the
  tests, because a test cannot embed what the build did not put beside it.
