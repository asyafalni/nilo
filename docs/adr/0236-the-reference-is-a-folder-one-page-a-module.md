# 0236 — the reference is a folder, one page a module

**Status:** accepted
**Extends:** [ADR 0083](./0083-the-guide-is-the-source-of-its-own-snippets.md)

## Context

`docs/reference.md` was one page, and the page was the point: the whole
surface, findable with one search, small enough to hand a model whole. At
4,154 lines it had stopped being that. Thirty-five `##` sections, and the
`nilo_sql` one alone was 1,433 lines, longer than the nine-page SQL guide
it summarises. A reader opening it for `Cookie` scrolled past `Bound(W)` and
`JSON shapes` to find twenty lines, and a reader of the `nilo_jwt` section
got a page that also held `Tx`, `Room` and the OpenAPI options.

The guide had already gone the other way (`docs/guide/`, one page a job, and
`docs/guide/sql/` a folder when one of those pages grew), and every module
guide page ends with a link into the reference. Those links named an anchor
on a page nobody could hold.

## Decision

`docs/reference/` is a folder of sixteen pages. **A module in the bottom
layers gets one page**, named for it: `sql.md`, `s3.md`, `fetch.md`,
`job.md`, `id.md`, `config.md`, `pw.md`, `cache.md`, `jwt.md`, and `core.md`
for `Str`, `Run`, the Scope, percent coding and the clock. **The server gets
seven, cut where the guide cuts**: `app.md` (the App, the loop, and the
options behind `static` and the OpenAPI document), `handlers.md` (arguments,
returns, JSON shapes), `ctx.md` (`Ctx`, `Cookie`, `Session(T)`, `Upload`,
failing), `streaming.md` (`Dir`, `Stream`, `Events`, `Body`, `Socket`,
`Room`), `middleware.md`, `testing.md`. Every `##` section of the old page
moved whole, under the same heading, so an anchor into it is the same anchor
on its new page.

`README.md` is what stays on one page: the modules table, the root wiring,
and **every heading listed once**, each a link. That is the search the
single page used to be. A name is found there and read on its page.

Three things moved with it:

- **The snippets table** in `build.zig` names the ten pages that carry a
  `<!-- compiles -->` mark, one row each, rather than one row for the folder.
  A page with no mark is not a row, since a row that checks nothing costs a
  read. The walk from ADR 0083's later amendment is what holds that list
  honest: a marked page that is not a row fails the step.
- **A block's object name keeps its folder.** `docs/reference/cache.md` and
  `docs/guide/cache.md` are both rows, and `slug` had been naming them both
  `cache`, so a failure in one would have named the other's page. A page
  under `docs/` now keeps everything under `docs/`, so the two are
  `reference_cache_1` and `cache_1`.
- **Every link in** — fourteen from the guide, two from ADRs, and the README,
  `CONTRIBUTING.md` and `CLAUDE.md` — names the page rather than the folder,
  so `../reference.md#run` became `../reference/core.md#run`. The twenty-eight
  links between sections became links between pages the same way.

## What was rejected

**One page a `##` section**, thirty-five of them. It was built first, and it
answers "where is `Cookie`" perfectly and nothing else: `stream.md` was
eleven lines, `body.md` twelve, and a reader of the request had five tabs
open for what is one object in their handler. The guide's pages are the
size a reader wants to hold, and this is the same cut.

**Leaving it** — on the grounds that a single page is what a model wants. A
model wants a surface it can hold, and the folder's `README.md` is a smaller
one than the page was: every name, none of the prose. What it points at is
the same text, one page over.

## Consequences

- Adding a `##` section to the reference is adding it to the page it
  belongs on, and a line to the `README.md` list. Adding a marked block to a
  page with none is adding a row to the snippets table, which the step says
  when it is forgotten.
- A page's own `above` and `below` mean what they say again; the one that
  had crossed a section (`Scope`'s "the two calls above", which were `Run`'s)
  now links to it.
- Historic mentions of `docs/reference.md` in `docs/history.md`, older ADRs
  and the stress project's notes are records of what a file said when it
  said it, and are left as written.
