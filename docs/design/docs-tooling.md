# Documentation tooling

**A claim in the documentation is checked by a build step or it is not trusted here, and that includes the documentation about the documentation.** What a change has to carry is `CONTRIBUTING.md`'s fourth thing ([`../../CONTRIBUTING.md#4-its-documentation`](../../CONTRIBUTING.md#4-its-documentation)); the code is `build.zig` (`Snippets`, `AdrCheck`, `testBackend`), `dev/main.zig` (`nilo-dev`), `.github/workflows/ci.yml` and `docs.yml`, `mkdocs.yml` and `docs/site/hooks.py`.

## How the pieces fit

```
docs/guide/*.md, README.md, docs/reference/*.md
  a "compiles" mark        \  extracted at build time, put behind a page's
  a "compiles: body" mark  /  own prelude, compiled: zig build snippets

docs/adr/NNN-slug.md  ---adr-check--->  every citation, every Topic line,
  (the rule in force)                   every docs/design/ link, resolved

docs/design/<slug>.md  <--- topic page joins the ADRs of one topic

zig build test-all (Debug + ReleaseSafe, testBackend picks the backend)
  |
  v
git tag  --docs.yml, mkdocs.yml-->  the guide, versioned, published once
                                     (reference/ADRs/bench stay on GitHub)

save a .zig file --zig build --watch--> binary changes --> nilo-dev restarts
```

## The rule in force

1. **A `zig` block marked `<!-- compiles -->` above it is a program, and the page is its only copy.** It is extracted while `build.zig` runs, given a prelude (`docs/snippets/types.zig`, or a page's own) and compiled by `zig build snippets`, which `zig build test` depends on. A `docs/snippets/` mirror of complete programs was rejected: it checks a copy, and the page can drift under it while the build stays green. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
2. **`<!-- compiles: body -->` is a run of statements**, given the running example's values (`c`, `db`, `form`) as well as its types, so a page can show a struct once and then write ordinary statements against it. A name the block declares for itself is dropped from the prelude rather than fought over, and a local the block never reads is discarded the same way `export fn` drags a function in, so the trick never leaks into the published page as a stray `_ = x;`. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
3. **A page whose own types are the subject may declare a prelude of its own**, listed in `build.zig`'s `Snippets.pages` as `Page{ .path, .types, .values }`, rather than carrying seven types of noise borrowed from the sign-in example next door. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
4. **A marked block is a decision, not a walk.** Every page that carries one is named in `Snippets.pages`; a page with none is not a row, because a row that checks nothing costs a read for no reason. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md), [ADR 185](../adr/185-the-reference-is-a-folder-one-page-a-module.md)
5. **The reference is a folder, one page a module, and one page cannot describe the server.** A module in the bottom layers gets one page named for it; the server's is cut into seven the way the guide already cuts it (`app`, `handlers`, `ctx`, `streaming`, `middleware`, `testing`), and every heading kept its own anchor by moving whole. `README.md` lists every heading once, which is the single-page search the old page used to be. [ADR 185](../adr/185-the-reference-is-a-folder-one-page-a-module.md)
6. **The `ReleaseSafe` test builds run on Zig's self-hosted backend on x86_64, named only where it was measured to work.** `testBackend` returns `false` there and `null` (Zig's own default) everywhere else, because a test binary is compiled once and run once, and LLVM's pass execution was 94% of a 27.6-second compile that bought nothing this repository asks for. [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md)
7. **This is a very close gate, not an identical one, and the record says so.** A use-after-return is undefined behaviour whose detection depends on stack layout, which a backend swap can change; the trade made is a gate that runs on every `zig build test` instead of one a contributor is tempted to skip. Every `bench-*` target stays on LLVM regardless, because a throughput number through a non-optimising backend is fiction. [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md)
8. **`nilo-dev` restarts on the binary changing, not on a source file changing.** It runs one `zig build <step> --watch` and reads that step's own output file every 250ms, so the sources that matter are whatever the build already reads; nothing here keeps a second file list to fall out of step with `build.zig`. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
9. **A build that fails leaves the last binary that compiled running, except at the very first start.** The stale binary is removed only when the first build (before the watch begins) fails, because serving an old binary against sources that have moved on is a real cost (a stale schema seeding a database) that only matters before anything has served correctly yet. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
10. **Every stale build is deleted after each restart, by matching the new binary's bytes rather than by age.** One save leaves one new directory in `.zig-cache`, and the tool removes every other directory holding a copy of that binary's name, which keeps the loop's disk cost flat without touching Zig's own cache eviction (there is none). `nilo-dev` imports only `std` and ships as its own artifact, so no server links any of this. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
11. **The guide is the one part of the documentation published as a versioned site, once per minor release, and never from `main`.** `docs.yml` builds `docs/guide/` with Material for MkDocs and mike on a tag; the reference, the ADRs and the bench results stay on GitHub, and every link the guide makes into them is rewritten by `docs/site/hooks.py` to the tag the site was built from. [ADR 219](../adr/219-the-guide-is-published-once-a-release.md)
12. **`mkdocs.yml` builds strict, with heading anchors checked, and CI's `docs` job runs it on every push.** A page that links a heading somebody renamed fails there, not on release day, and a new guide page needs a line in `nav:` or the job fails. [ADR 219](../adr/219-the-guide-is-published-once-a-release.md)
13. **An ADR says the rule in force; a changed decision is edited in place.** The Decision section becomes what holds now, the position it replaced moves under "What was rejected" with the evidence that moved it, and a new number is only for a new decision. An ADR's head may name another only with `Applies`, `Extends`, `Carries out`, `Closes` or `Found by`; a word that means "this supersedes that" is refused, because that is a revision written as a new file instead. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)
14. **Every ADR names its topic, and a topic with a page in `docs/design/` writes it as a link to that page.** The page is where a reader starts: how the pieces fit, each rule with the ADR that decided it, and what is open; the ADRs stay the record of why. A page must link every ADR whose topic it names, so adding an ADR to a topic that already has a page is one change together with that page's Decisions table. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)
15. **`zig build adr-check` holds all of the above, on `test`.** It refuses a file not named `NNN-slug.md`, two ADRs sharing a number, a missing `**Status:**` or `**Topic:**` line, a topic written as a plain slug once its page exists, a `docs/design/` page whose relative link resolves to nothing, and, across every text file in the repository, a four-digit ADR number anywhere but `renumbered.md` or a three-digit one with no file behind it. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)

## Decisions

| ADR | What it decides |
|---|---|
| [068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md) | A marked `zig` block in the guide, README or reference is a program the build compiles, with one copy: the page |
| [138](../adr/138-a-test-does-not-need-the-optimiser.md) | `ReleaseSafe` test binaries build on Zig's self-hosted backend where it is measured to work |
| [185](../adr/185-the-reference-is-a-folder-one-page-a-module.md) | The reference is a folder, one page a module and seven for the server, cut where the guide cuts |
| [190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md) | `nilo-dev` restarts a running example on the binary a `--watch` build writes, and prunes the cache it leaves |
| [219](../adr/219-the-guide-is-published-once-a-release.md) | The guide is built into a versioned site and published on a tag; everything else stays on GitHub |
| [221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md) | An ADR is edited in place to state the rule in force; a topic page joins the ADRs of one topic; `adr-check` holds the shape of both |

Beside this topic: the refusals build step that `adr-check` and `zig build snippets` both follow the shape of is [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md) (testing); the four axes every "What it costs" section is measured against, including this topic's own, is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); the module layering `adr-check` complements with a build step of its own is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); the file reload `nilo-dev`'s restart is the other half of is [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md) (static-files).

## Open

- **`-fincremental` as the default for `nilo-dev`.** Rejected because it produces a binary that fails to run on Zig 0.16 when libc is linked; kept in [the roadmap](../roadmap.md) under `nilo_http`'s known gaps, waiting on upstream, as the number the dev loop wants to be.
- **Scanning `///` doc comments for compiled snippets.** `http/ctx.zig` carried one of the three broken lines ADR 068 found; the line itself is fixed, but a doc comment has no fence and would need its own extractor, left open on the record in [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md).
- **Waiting for Zig's aarch64 self-hosted backend to become the default.** `testBackend` already picks it up with no change here once it does; until then aarch64 runs both test modes through LLVM, recorded in [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md).
