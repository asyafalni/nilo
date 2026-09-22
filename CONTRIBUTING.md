# Contributing to nilo

This is one person's toolkit so far, and it's built to stop being one. The most useful thing you can bring is not always a patch: a question that turns out to have no written answer is a real find, because the whole design rests on the answers being written down somewhere other than my head. "Why on earth is it like this?" is a welcome issue.

## Get it running

```
git clone https://github.com/nevindra/nilo
cd nilo
zig build test
```

Zig 0.16 and nothing else: no C library, no system package, no database. The first run after a clone builds everything; after that a run that changed nothing is a few seconds, almost all of it the refusals below.

Then read these four, in this order:

| | |
|---|---|
| [`README.md`](./README.md) | what this is and what it refuses to be |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project won't use |
| [`CLAUDE.md`](./CLAUDE.md) | the working brief: layout, every command, invariants, conventions |
| [`docs/adr/`](./docs/adr/) | the decisions, each one naming the alternative it beat |

The ADRs are the important one. Before you propose a design change, check whether it already has a file: "why not X?" usually has an answer on record, and if you disagree with it you get to argue with something specific instead of with a vibe.

## The commands

```
zig build test          # the loop: the suite in Debug, the refusals, every module gate, layering, snippets
zig build test-all      # the same plus ReleaseSafe and the SQL suite. What CI runs, and the whole gate
zig build refusals-sql  # one module's refusal table; refusals, -config, -pw, -cache, -s3, -job, -fetch for the others
zig build examples      # build every example
zig build fuzz -- --iterations 1000000 --seed 0x…
```

The full list, one line each, is in [`CLAUDE.md`](./CLAUDE.md#commands). Three things worth knowing before they surprise you:

**The refusals never cache.** The compiler keeps nothing from a compilation that failed, so every one of them is re-analysed on every run. They are the floor of a run rather than its slow part: a run after an edit is longer by whichever single compilation is biggest, because that one cannot be split across cores. [`bench/result/build.md`](./bench/result/build.md) has the numbers and the levers.

**The bottom layer runs without the build system.** `zig test core/core.zig`, and the same for `id/`, `config/`, `pw/`, `cache/` and `jwt/`, work on their own, filters and all. That is the entry condition for the layer, not a nicety: if a change stops one of them working, the layering broke, not the test. A Fitting is one step short because it borrows the loop ([ADR 0070](./docs/adr/0070-a-fitting-borrows-the-loop.md)), and needs `nilo_core` in the graph and nothing else:

```
zig test --dep nilo_core -Mroot=fetch/fetch.zig -Mnilo_core=core/core.zig
zig test --dep nilo_core -Mroot=job/job.zig -Mnilo_core=core/core.zig
```

**Everything under `http/` needs the module graph**, so `zig build test` is the only way to run it. `cookie`, `patch`, `names`, `json` and `range` are pure enough for `zig test http/range.zig --test-filter "a suffix range"`.

## What a change has to carry

Four things, the same four whether a person or a model wrote the code. The [pull request template](./.github/PULL_REQUEST_TEMPLATE.md) asks for them in this shape.

### 1. Which axis it spends, and the number

Performance here is four numbers, not one, and they don't recover the same way ([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | a nicer API wins if it costs under 10% |
| Allocations per request | fixed, held by a test in `http/app.zig` |
| Memory per idle connection | 4,669 bytes is the **floor**, and a handler adds every byte of stack it touches ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md), [ADR 0071](./docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)). Every feature states its own cost |
| Binary size | anything the linker can't drop states its measured cost, as a stripped `ReleaseFast` number |

Say which one your change spends, and by how much, when you *propose* it, not after it lands. If it costs an allocation on a path that didn't ask for one, it doesn't go in, and the honest move is to say so early. A feature that can't be made to fit doesn't ship in a worse shape: response compression is the standing example, known shape, not built, no allocate-per-request version shipped meanwhile.

### 2. Its refusals

A compile-time check's error message is part of the feature, and it needs a program that proves the message still says the right thing: a file in the module's `refusals/` directory and a row in the matching table in `build.zig`. [`refusals/README.md`](./refusals/README.md) shows how, including how to find the `.says` text (guess, run the step, read what it prints).

There are eight tables and eight steps, one per module, and each step runs only its own table. A row added to one while running another is a check that silently never ran. Leave the `nilo: ` prefix off `.says`; the build step adds it, which is what makes a failure inside the standard library impossible to record as passing.

### 3. Its tests

Tests sit at the bottom of the file they test, named as sentences about the behaviour rather than after the function:

```zig
test "a path param that is not a number becomes a 400 with a clear message" {
```

A new source file under `http/` needs an `_ = @import(...)` line in the `test { … }` block at the end of `http/http.zig`, or it never runs.

Run `zig build test-all` before you open a pull request. Debug is the loop; ReleaseSafe is the gate, because a lifetime bug passes in Debug, where the bytes a dangling pointer points at happen to still be there, and segfaults in the mode people deploy in.

### 4. Its documentation

Documentation is part of the change, not a follow-up:

| What you have | Where it goes |
|---|---|
| a design decision | a new file in [`docs/adr/`](./docs/adr/), naming the alternative it rejected |
| something you measured, or a guess that turned out wrong | [`docs/history.md`](./docs/history.md) |
| a benchmark you ran | [`bench/result/`](./bench/result/), one file an area |
| something now built | delete its entry from [`docs/roadmap.md`](./docs/roadmap.md) |
| a question answered, or a feature refused with its reason | [`docs/decided.md`](./docs/decided.md), and out of the roadmap |
| something a user has to change | [`CHANGELOG.md`](./CHANGELOG.md), under `## Unreleased` |
| a public API | [`docs/reference/`](./docs/reference/), one page a module, every heading listed once on its `README.md` |

**A snippet you publish is a program, so let the build compile it.** `<!-- compiles -->` above a fenced `zig` block (`<!-- compiles: body -->` for a run of statements) and `zig build snippets` compiles it with [`docs/snippets/types.zig`](./docs/snippets/types.zig) in front. Writing that step found seven mistakes in one five-line example ([ADR 0083](./docs/adr/0083-the-guide-is-the-source-of-its-own-snippets.md)). Unlike the refusals these cache, so marking one more is nearly free.

**A benchmark that changed a decision gets written down where it can be re-run.** The entry says what was run, on what machine, at what commit, through what transport (the same server measured 197k requests a second across a Docker port and 458k over a unix socket), what the numbers were, and what they changed; and it closes with whether the number can be pushed further, ranked. Build the before rather than quoting it, interleave the runs, pin both sides of a comparison, and quote a margin narrower than its own spread as a range. This is a rule because the repository has already published wrong numbers three times, and all three were found by re-measuring ([ADR 0071](./docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).

**The roadmap holds nothing finished and nothing decided.** When something ships its entry leaves entirely: no strikethrough, no "done". **`docs/history.md` stays short**: an entry gets in only if it would change what somebody does next time, not to record what shipped.

## Writing the code

- **Use the project's words.** [`CONTEXT.md`](./CONTEXT.md) lists each term and the words it refuses: Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative test". In code, comments and commit messages.
- **Doc comments say why, and name the ADR.** The header of every module is its design rationale, including the alternatives measured and dropped.
- **A `Str` never escapes its request without `.keep()`**, inside the framework as much as in user code.
- **A module imports downward only, and never sideways.** `zig build layering` enforces it. Which module a file belongs in is one question: does it need the event loop? ([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md), [ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md))

## Adding a whole module

A design decision before it's a patch, so it starts with an ADR. Mechanically it's three edits: a row in the `layers` table in `build.zig` saying what the module may import, an entry in `shipped_roots`, and a line in `.paths` in `build.zig.zon`. The bar is the README's: a part gets in if it is expressible as a type the caller already wrote, checked while compiling, with its cost written down, and it brings its own refusals. A bottom-layer module whose tests need the build system is in the wrong layer.

## Proposing a design change

Open an issue first; design changes are cheap to argue and expensive to build. If it lands it gets an ADR, and an ADR names the decision and the alternative that lost and why. A document that only describes what was built is a description, not a decision. [ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md) is a good first read: an earlier rule tested under real pressure, where the rule won and the convenient thing lost.

## Commits and pull requests

Conventional prefixes and a short body:

```
feat: read settings into a struct of your own
fix: stop the router reading routes that cannot match
```

`feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build` or `chore`, with a `!` for a break. Say what changed, not which files. The body is optional and earns its place by explaining *why* or naming a number, in a few sentences; the long version belongs in history, an ADR or the changelog, and a body that repeats them is a fourth copy to keep in sync.

One decision per pull request. A branch carrying two is two pull requests, and the [template](./.github/PULL_REQUEST_TEMPLATE.md) asks for the four things above. Run `zig build test-all` and `zig build examples` first; that's what CI runs, plus a million generated requests at the parser.

## Where to start

- **An [open question](./docs/roadmap.md#open-questions) in the roadmap.** Those want an argument more than a patch, and each entry ends with what would settle it.
- **A module that dials out.** Mail and Redis are ordinary work now: the outbound seam is designed ([ADR 0070](./docs/adr/0070-a-fitting-borrows-the-loop.md)), `nilo_fetch` is the way out and `s3/` is a worked example on top of it.
- **The small end, which is real work here.** A refusal whose wording could be clearer, a guide page that assumes something it shouldn't, an example for the case you hit. Wording is a feature in this repository, so improving a sentence is a change, not a chore.

## Working with an agent

Encouraged, and the repository is arranged for it. Hand it [`CLAUDE.md`](./CLAUDE.md) for the brief, [`CONTEXT.md`](./CONTEXT.md) for the vocabulary, [`docs/reference/`](./docs/reference/) for the API and [`docs/adr/`](./docs/adr/) for why. Let the build do the first round of review: `zig build test-all` catches a broken behaviour and `zig build layering` catches a broken design.

One ask: read the diff before you send it. An agent will happily write a paragraph into `docs/history.md` that repeats the changelog, or restate an ADR in a commit body. Those are the two failure modes worth watching for.

## What gets turned down

Templates, TLS, HTTP/2 and gRPC. These aren't gaps waiting for a volunteer, they are decisions with reasoning on file; the move is to argue against the ADR, not to open a pull request adding one. Also anything that needs an annotation to work, anything that can't say what it costs, and anything that adds an allocation to a request path that didn't ask for one. None of that is meant to sound closed; it's meant to save you from writing a thousand lines that were never going to land.

## License

MIT. By contributing, you agree your work ships under it.
