# Static files

**A directory is read once, at `listen()`, and every request after that is answered from what that read produced, never from the filesystem again except where holding the bytes does not fit.** The guide is [`guide/static-files.md`](../guide/static-files.md); the options are in the reference at [`reference/app.md#static-options`](../reference/app.md#static-options) and [`reference/app.md#compress-options`](../reference/app.md#compress-options); `FileBody` is at [`reference/handlers.md#handler-returns`](../reference/handlers.md#handler-returns). The code is `http/static.zig` (the walk, the Set, the fallback), `http/serve.zig` (`serveSpilledFile`), `http/range.zig`, `http/accept.zig`, `http/compress.zig` and `http/filebody.zig`.

## How the pieces fit

```
listen()                                            request
────────                                            ───────
app.static(prefix, dir) ──► walk once ──► Set        GET prefix/name ──► Set.find
  held file:   bytes, ETag, gzip copy                     │
  spilled file (over max_file_bytes): name, size, mtime   ├─ held  ──► slice, maybe gzip (211), maybe a Range (020)
app.embedded(prefix, files) ──► same Set,                 ├─ spilled ──► open, stat the descriptor, sendfile (098)
  bytes borrowed from the binary, owns_bytes = false       └─ miss  ──► fallbackFor(path, Accept) (087)
                                                                  HTML navigation → spa_fallback
                                                                  otherwise → 404 naming the path
```

## The rule in force

1. **A directory is read once, at `listen()`, into memory the App owns**, and lookup is a binary search over URLs sorted at load; a file over `max_file_bytes` stays a name, its size and its modification time, and is opened again on every request that asks for it. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
2. **Path traversal is not possible rather than defended against.** The set of URLs a directory answers is fixed before the socket opens, so a name a request carries is a lookup in a list it cannot add an entry to. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
3. **Routes win over a file of the same name, dotfiles are skipped by default, and a static set is a terminal handler**, not middleware, wrapped by the ordinary chain like any other handler. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
4. **`app.embedded` serves the same `Set` with the read taken out.** Bytes are borrowed from the binary through `@embedFile`, `Set.owns_bytes` is false, and `max_file_bytes`, `max_total_bytes`, `dotfiles` and `.reload` all drop out because there is no disk under any of them. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
5. **A `Range` header that cannot be understood is ignored and the whole file goes out**, because RFC 9110 makes that a correct answer to every case; the exceptions are a range past the end of the file and the suffix `bytes=-0`, which asks for nothing, both answered `416` with `Content-Range: bytes */<total>`. [ADR 020](../adr/020-a-range-is-a-slice-and-two-headers.md)
6. **`If-Range` is honoured against the same ETag `If-None-Match` compares against**, and anything else, a stale tag, a date, a value that makes no sense, sends the whole file: the failure of not honouring a range is a bigger download, the failure of honouring one wrongly is a corrupt one. [ADR 020](../adr/020-a-range-is-a-slice-and-two-headers.md)
7. **A fallback answers a navigation, never a missing asset.** `spa_fallback` fires on a request whose `Accept` names `text/html`, or, when the client said nothing, on a path whose last segment has no extension; everything else under the prefix is a 404 naming the path. `spa_fallback_for` defaults to `.navigations`; `.any_path` is kept only for the behaviour that shipped before `0.2.0`. [ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)
8. **Every static set is asked for the real file before any set is asked for its fallback**, so a single-page app mounted at `/` cannot answer another set's asset with its own `index.html`. [ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)
9. **A spilled file's head is built from one `stat` of the descriptor about to be sent, not the number the walk remembered**, so its `Content-Length` and its ETag come from the same moment and can never disagree with each other or with the bytes that follow. [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)
10. **`.reload` is the spill threshold set to zero, and nothing else**: every file is opened, stat'd and read per request, so an edit shows without a restart and no Set is ever swapped under a live reader; a file created after startup still needs one. [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)
11. **A `try` call hands back the error and says nothing.** `app.static`/`app.staticWith` log a missing directory in one line because the process is about to stop on it; `app.tryStatic`/`app.tryStaticWith` return `error.StaticDirNotFound` with no log line, because the caller has already said it will decide; a problem inside a directory that does exist is still logged by both, since the error name alone cannot carry which file. [ADR 207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)
12. **`app.compress` gzips a qualifying answer per request on a compressor borrowed from a pool with one slot per executor thread**, and hands it back before the socket is written; nothing between the borrow and the return can park the fiber, so the pool is never empty on a running server. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
13. **The compressor is reset in place rather than reinitialised.** `compress.reset` matches the standard library's `init` field by field, at 40 bytes of stack against `init`'s 99,048, because a fiber holds whatever it touched at its high-water mark for the life of the connection. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
14. **A stream and an event stream are never compressed, and gzip is the only coding offered.** Neither has a whole body to gzip into the arena without holding the compressor across a write, which the borrow rule forbids. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)

## Decisions

| ADR | What it decides |
|---|---|
| [009](../adr/009-static-files-are-held-in-memory-or-opened.md) | A directory is held in memory or opened per request past a size threshold; `app.embedded` is the same Set with the read taken out |
| [020](../adr/020-a-range-is-a-slice-and-two-headers.md) | What a `Range` and an `If-Range` mean against a file already in memory or on disk |
| [087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md) | When `spa_fallback` answers, and when a miss is a 404 instead |
| [098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md) | A spilled file's `Content-Length` and ETag come from one `stat` of the descriptor being sent |
| [207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md) | A `try` variant of a static call hands the error back silently |
| [211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md) | Gzip on a per-thread compressor pool, and why a stream is left out |

Beside this topic: keeping file IO off the Bulkhead as a bespoke contract, and using `std.Io.Writer`'s own `sendFile` slot instead, is [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) (engine); a fiber holding whatever it touched at its high-water mark, which is why the compressor is reset rather than rebuilt, is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); a body under an encoding nilo does not offer being refused is [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md) (http1-protocol); `FileBody` following a status-in-the-type answer the way a redirect does is [ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md) (responses); the four-axis budget every cost above is measured against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles).

## Open

- **A stream and an event stream stay uncompressed, and brotli is not offered.** In [the roadmap](../roadmap.md), waiting on a caller streaming something large enough for the bandwidth to matter, or a reason for brotli that survives the C dependency it brings.
- **`.reload` does not notice a file created after the server started**, only an edit to one the walk already found. Recorded in [`docs/decided.md`](../decided.md) as a kept gap: rescanning on a miss would let a request-carried name decide when the disk is walked, which is the traversal `static` exists to refuse.

