# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It holds what a session needs every time; anything needed once in a while lives in its own file and is linked from here.

## What this is

**nilo is a toolkit for Zig 0.16: eleven modules, of which the largest is an HTTP server.** What they share is one idea: **your types are the contract, and the compiler is the check.** A plain Zig function is a route, and its argument list produces routing, typed input, a 400 for anything that does not fit, and an OpenAPI document. A plain struct is a table, and its fields produce the SQL before the program starts. Nothing is annotated.

**A module gets built because the job is common, not because it is interesting**, and it gets in only if it is expressible as a type the caller already wrote, checked while compiling, with its cost written down (ADR 0018). The README's three words, helpful, quick, cheerful, are the order the trades are made in.

Three files carry context this one does not repeat:

- **`CONTEXT.md`**: the vocabulary and the words the project refuses (Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative test"). Match it in code, comments, docs and commit messages.
- **`docs/adr/`**: the binding decisions, each naming the alternative it rejected. Check here before proposing a design change; "why not X?" usually has an answer on file. **ADR 0041 decides which module new work goes in and ADR 0042 what that module may import**; read both before adding a file anywhere but `http/`, and ADR 0043 and 0072 before adding a module.
- **`docs/reference/`**: the whole public API, one page a module.

## Who works here

The repository is written to be worked on by somebody who did not write it, a person or a model. **Nothing load-bearing may live only in the author's head, only in a commit body, or only in this session.** A decision goes in an ADR, a lesson in `docs/history.md`, a rule in a build step. **Prefer making a rule enforceable over writing it down here**: a paragraph nobody runs is the thing that rots. `zig build layering` and the refusal steps are the two to lean on.

`CONTRIBUTING.md` is the outward-facing half: the four things a change carries (which axis it spends and the number, its refusals, its tests in both optimize modes, its documentation). Propose work in that shape. A change to those rules, the commands or the layout changes there and here together.

## Layout

**The repository is modules, not one library** (ADR 0041), and one question decides where a file goes: does it need the event loop? **A module imports downward only, and never a sibling**, which is what lets two of them be worked on at once. A Service reaches request-lifetime memory through a Scope, never a `Ctx`.

| Layer | Files | What it is |
|---|---|---|
| **Core** | `core/` | `Str`, the Scope, the clock, percent coding: the vocabulary every layer agrees about. Needs no loop, names no Engine, so `zig test core/core.zig` runs all of it. A file gets in by being needed by two layers (ADR 0066). |
| **Tools** | `id/`, `config/`, `pw/`, `cache/`, `jwt/` | one job each, no event loop. They *may* name `nilo_core` and none does: that would cost running under a plain `zig test`, the property that decides the layer (ADR 0042, ADR 0043). `cache/` spins because `std.Io.Mutex.lock` takes an `Io` this layer has none of, so nothing that waits goes inside its critical section. |
| **Fitting** | `fetch/`, `job/` | borrows the loop, owns no destination: an HTTP client, and a queue whose store is handed to it (`job.Table(Db)` takes the caller's Db type, ADR 0198). Import `nilo_core` only; tests run on `std.Io.Threaded` with no Engine, which is the layer's entry condition (ADR 0070). |
| **Services** | `sql/`, `s3/` | borrow the loop and hold a named system: a Postgres pool, a SQLite file, an object store. A SQLite statement blocks with nothing to wait on, which is why `sqlite.Options.threading` has no default (ADR 0073). `s3/` imports a Fitting (ADR 0072). Neither may name `nilo_http`. |
| **Engine** | `http/engine/zio.zig` | accept, read, write. **The only file allowed to name zio** (ADR 0002). |
| **Bulkhead** | `http/bulkhead.zig` | the whole contract nilo asks of an Engine, listed in its header. `Options` lives here so swapping engines cannot change what a user writes. |
| **HTTP + App** | `http/http1.zig`, `http/router.zig`, `http/app.zig` | parse, match, dispatch. `App.handleRequest` takes only a `*std.Io.Reader` and `*std.Io.Writer`, so almost every HTTP behaviour is tested on in-memory buffers. |
| **Ctx** | `http/ctx.zig` | one request in flight, and nilo's real API. |
| **Typed** | `http/typed.zig` | the compile-time engine: turns a typed handler into a Ctx handler. **A pointer is a service, a value is request data.** Path params match by position, because Zig keeps no argument names. |

**The layering rule is a build step**: `zig build layering` reads the `@import`s of every module but `http/` and refuses one missing from that module's row of `layers` in `build.zig`. Adding a module means a row there, in `shipped_roots`, and in `.paths` in `build.zig.zon`.

A request: `readHead` → `parseHead` → the head is *borrowed* from the read buffer unless the request will read again, when it is copied into the arena (read `borrowed` in `app.zig` before touching that path) → route match → middleware chain → resolved values → handler → response. The arena is reset per request, keeping `arena_keep` bytes. The rest of `http/`, by what it serves: `str` (request-lifetime text and the Debug-only use-after-request trap), `fail` (ADR 0007), `resolve`, `service`, `middleware`, `form`/`bound`/`convert`/`patch`, `session`/`cookie`, `password` (the Gate in front of `nilo_pw`, ADR 0048), `static`/`sendfile`/`filebody`/`range`, `stream`/`body`/`websocket`, `openapi`, `watchdog`, `logger`, `cors`.

### Dependencies and build flags

**The one dependency of a plain HTTP build is [zio](https://github.com/lalinsky/zio)**, pinned in `build.zig.zon`. Everything else sits behind a flag a dependent passes to `b.dependency("nilo", …)`, and a build without the flag fetches, builds and links none of it:

| flag | brings | ADR |
|---|---|---|
| `.sql = true` (`-Dsql`) | pg.zig (with buffer, metrics, xsync, tls) and zqlite (the SQLite amalgamation) | 0075 |
| `.tls = true` (`-Dtls`) | tls.zig; without it there is no `tls` module and the Engine's every use is under `@import("nilo_build").tls` | 0288 |
| `.grpc = true` (`-Dgrpc`) | nothing: HTTP/2, HPACK and gRPC are `http/h2.zig`, `hpack.zig`, `grpc.zig`. A call becomes an in-memory HTTP/1.1 `POST` to `App.handleRequest`, so a gRPC method is an ordinary route | 0297 |

It is the flag, not `.lazy = true`, that keeps a dependency out: `b.lazyDependency` is a request, and called unconditionally it ran for every dependent. This repository's own http test root is built with TLS and gRPC whatever the flags say. `zig build fetch-check -Dnetwork` builds `bench/dependent/` against two cold caches and fails on anything but zio landing; it needs the internet, so it is not on `test`.

## Commands

```
zig build test         # the loop: the suite in Debug, the refusals, every module's gate but
                       #   test-sql, plus layering and snippets
zig build test-all     # the above, the suite in ReleaseSafe, test-sql and refusals-sql.
                       #   What CI runs, and the whole gate
zig build test-{core,id,config,pw,cache,jwt,fetch,job,s3,dev}   # one module, both modes,
                       #   plus its refusals where it has a table
zig build test-fetch-engine  # an outbound deadline firing against a real port; on `test`
zig build test-sql     # nilo_sql, with test-job-sql and refusals-sql; Postgres if DATABASE_URL reaches one
zig build layering     # no module imports upward or sideways
zig build refusals     # the framework's table only; refusals-{sql,config,pw,cache,s3,job,fetch} for the others
zig build snippets     # the documentation's marked snippets, which must compile
zig build examples     # build every example; run-{hello,rest,orders,forms,spa,stream,chat,scheduled,outbound,sqlite}
zig build dev-{hello,…}  # an example restarted on a save to its Zig, and on nothing else (ADR 0259)
zig build fuzz -- --iterations 1000000 --seed 0x…   # generated requests at the parser; --frames for gRPC
zig build smoke-tls -Dnetwork   # a real HTTPS endpoint; not on test
mkdocs serve           # the guide as the website; `mkdocs build` is CI's strict check (ADR 0296)
```

Benchmarks and their scripts are in [`bench/README.md`](bench/README.md). `-Dstrip=true|false` overrides the per-artifact debug-info default.

**`test-all` is the whole gate.** It depends on every module step above plus `layering` and `snippets`; a change under `core/` moves every module while showing no lines under them in a diffstat, and the answer is that one command. `zig build test-all --summary all` prints the tree.

**On a host whose glibc was built by GCC 16, the native link of anything with libc fails** at `crt1.o:.sframe` with `unhandled relocation type R_X86_64_PC64`. Pass `-Dtarget=x86_64-linux-gnu` to every `zig build test*` and `examples` line, or `-Dllvm` for the examples.

**Read the exit code, not the word "failed".** A passing `test` prints several `failed command: …` lines and exits 0, because `zig build` prints one for every step that wrote to stderr. The exit code and a `Build Summary` reporting a failed step are what count.

**The refusals never cache**: the compiler keeps nothing from a failed compilation, so they are re-analysed every run and are the floor of a run that changed nothing (ADR 0027). They are not the slow part of a run that changed something; that is the largest single compilation ([`bench/result/build.md`](bench/result/build.md)).

**Take a stuck build's CPU time before believing it is slow.** `ps -o etime,cputime -C zig`: minutes of wall against seconds of CPU is a deadlock or something waiting on you (`--time-report` stands up a web server), and a documented slow path is the best hiding place for one. Suspect first the tests that open a real socket at both ends (`test-fetch`, `test-s3`, `http/live.zig`). **A wait on a flag needs a bound, and the giving-up path needs to set something**; a listener a test connects to is started with `io.concurrent`, because `io.async` may run it on the calling thread (ADR 0230). A genuinely slow build gets the same treatment: compare CPU against wall. The other readings (OOM, a piped log, a green run about an edited tree) are tabled in [`docs/history.md`](docs/history.md#a-suite-that-hangs-and-a-build-that-looks-stuck).

### Running one test

No `-Dtest-filter` is wired in, so build steps are all-or-nothing. What runs standalone:

```
zig test http/range.zig --test-filter "a suffix range"   # also cookie, patch, names, json
zig test core/core.zig                                   # and id/, config/, pw/, cache/, jwt/
zig test --dep nilo_core -Mroot=fetch/fetch.zig -Mnilo_core=core/core.zig
zig test --dep nilo_core -Mroot=job/job.zig -Mnilo_core=core/core.zig
```

Everything else under `http/` needs the module graph, so `zig build test` is the only way. **For the bottom two layers standalone is the entry condition, not a nicety**: if a change stops one of those lines working, the layering broke, not the test. That is why `fetch/deadline.zig`, which names `nilo_http`, is its own root (`test-fetch-engine`), and `job/live.zig`, which names `nilo_sql`, is `test-job-sql`. `nilo_s3` needs the module graph only because `s3/live.zig` names the generated `s3_config`.

## Invariants that are load-bearing

ADR 0018 splits performance into four axes that do not recover the same way:

- **Allocations per request** (hard). Held by `test "the request path stays inside its allocation budget"` in `http/app.zig`. A DX feature may not add one to a path that did not ask for it.
- **Memory per idle connection** (hard). 4,669 bytes for the framework and 5,183 for an idle WebSocket, and that is a **floor, not a total**: a suspended fiber holds its stack at its high-water mark, so a handler adds every byte of stack it ever touched for the life of the connection (ADR 0063). **In this framework the arena is cheaper than the stack**, and **where a fiber is suspended is what it costs**: the framework's frames are kept under a page, and a `std.log` call inlined into a connection loop puts its format machinery there (ADR 0071). Every feature that costs per-connection memory states the number in its own ADR. A `-Dtls` build pays a page per idle connection on every listener, because the plain park sits under 300 bytes short of a page boundary; `bench/mem.py` is what notices.
- **Throughput and p99**: DX wins below 10%.
- **Binary size**: a feature the linker cannot drop states its stripped `ReleaseFast` cost in the running total in ADR 0018.

**Every change is put against all four before it is written**, the axis it spends and the number, in a design argued in a session as much as in a diff. **A feature that cannot be made to fit does not ship in a worse shape**: it waits for the shape that fits.

### A benchmark that was run gets written down

**Every run that changed a decision gets an entry in [`bench/result/`](bench/result/)**, one file an area (the list is in [`bench/README.md`](bench/README.md)), saying what was run, on which machine, at which commit, the numbers, the decision they moved, and whether the number can be pushed further. Not the terminal, not a commit body. A run that changed nothing still earns one if somebody would otherwise repeat it. The lesson then goes to `docs/history.md` and the decision to an ADR. **A number with no run behind it decays into a claim, and a premise decays the same way and costs more.**

The habits, each of which caught something here (the cases are under *Measuring* in [`docs/history.md`](docs/history.md#measuring)):

- **Build the before, do not quote it**: `git archive HEAD | tar -x` into a scratch directory, same flags, same afternoon. Then **interleave** runs; a margin inside the spread is "unchanged", and a margin narrower than its spread is quoted as a range.
- **Say what the number was measured through**: a Docker port, loopback and a unix socket differ by 133%, and a Debug build hides behind a flag given once.
- **Put something next to it**: a control route doing the same work minus the thing measured.
- **Measure a per-operation saving twice**, unloaded and at the pool, because a pool connection is a serial queue.
- **Take a per-connection figure out until marginal meets average**, on both sides of a comparison.
- **Pin both sides to physical cores**, or the number is about the scheduler.

**A conclusion of "blocked on somebody else" gets one more hour than it feels like it needs, and one blocked on "a design" gets two.** Nothing downstream ever re-tests a blocker, and a requirement written as one mechanism reads as a blocker where written as what it has to catch it reads as a choice (ADR 0063, last section).

## Conventions

**Error messages are a feature, and a build step holds them.** Each file in `refusals/` (and `<module>/refusals/`) is a program written wrong on purpose that must fail with a message nilo wrote. Adding a comptime check means adding **both** a file and a row in the matching table in `build.zig`. **There are eight tables and eight steps**, one per module, and adding a row to one while running another is a check that silently never ran. Leave the `nilo: ` prefix off `.says`; the step supplies it, so a failure inside std cannot be recorded as passing. `.says` is matched with `endsWith`, so it is the whole tail of the message's first line. See `refusals/README.md` and ADR 0027.

**A published snippet is a program, and a build step compiles it.** `<!-- compiles -->` above a fenced `zig` block in the README, the reference or a guide page makes `zig build snippets` compile it after `docs/snippets/types.zig`; `<!-- compiles: body -->` wraps loose statements in a function with `values.zig`. The block in the page is the only copy. These cache, so marking one is nearly free (ADR 0083).

**Tests sit at the bottom of the file they test**, named as sentences about the behaviour: `test "a path param that is not a number becomes a 400 with a clear message"`. A new file under `http/` gets an `_ = @import(...)` line in the `test { … }` block at the end of `http/http.zig`, or it never runs. The examples carry tests and run in the same suite.

**Both optimize modes matter.** Debug is the loop and ReleaseSafe is the gate, because a lifetime bug passes in Debug, where a dangling pointer's bytes happen to still be there, and segfaults in the mode people deploy in. `Str`'s lifetime trap is Debug-only by design. **A `Str` never escapes its request** without `.keep()`, inside the framework as much as outside.

**`std.log.err` means the server is refusing to start.** Zig's test runner fails a run on any `err` line, so everything on the request path logs at `warn`, and a branch a test must reach returns a value rather than only logging.

**Doc comments say why, and name the ADR.** Every module's header is its design rationale, including the alternatives measured and dropped.

**Commits are conventional-commit prefixes with a short body.** The subject is `type: imperative sentence about the effect` (`feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `chore`, `!` for a break), and says what changed, not which files: `fix: stop the router reading routes that cannot match`. The body is optional, a few sentences explaining why or naming a number; the long account belongs in the files below, and a body that repeats them is a fourth copy. Commits before `b662f01` follow an older convention.

**Documentation is part of the change**, not a follow-up:

| what | where |
|---|---|
| a design decision and the alternative it rejected | a new file in `docs/adr/` |
| a lesson: a number measured, a premise that turned out false, a design tried and lost | `docs/history.md`, as one paragraph under the theme it teaches (its header has the rules) |
| what a user has to change | `CHANGELOG.md`, under `## Unreleased` |
| what is still open | `docs/roadmap.md` (its own rules are under [How this file is written](docs/roadmap.md#how-this-file-is-written)) |
| a question answered, a gap kept as the rule, a feature refused with its reason | `docs/decided.md` |
| a risk with no mechanism under it yet | `docs/risks.md`, under `## Open` |
| a benchmark run | `bench/result/` |
| a new guide page | `docs/guide/`, plus a line in `nav:` in `mkdocs.yml` or CI's `docs` job fails |

**The roadmap holds nothing built and nothing decided.** When something ships its entry leaves entirely, no strikethrough; what was learned moves to `docs/history.md`. Every entry opens with its whole claim in bold and closes with a `Needs:` or `What would settle it:` line, which is what makes a blocker that has quietly stopped being one findable. **`docs/history.md` stays short**: a lesson, not an account of what shipped, and a lesson learned again extends its entry rather than adding one.

Cutting a release (the version bumps, the pinned `?ref=#commit`, the release page) is [`docs/releasing.md`](docs/releasing.md).

## Refused on the record

Templates and HTTP/2 for ordinary routes are decisions, not gaps (README "What it won't do", ADR 0028); propose a change to the ADR instead of adding them. gRPC moved the same way: behind `-Dgrpc`, unary only, on a listener of its own (ADR 0297), with streaming and h1 plus h2c on one port waiting for a caller. TLS is the precedent for moving one: an option behind a build flag, the default build unchanged on the memory axis and 2.8 KB on the size one, and every number on the record before it shipped (ADR 0288).

<!-- devrun:begin -->
## Running this project's services

`devrun` runs every service in `process-compose.yaml` at once and keeps
each one's output in a plain file under `.devrun/logs/latest/`. Prefer it over
running a single dev server in the background: with one server you only
see that server's output, and the error is usually in another one.

```console
$ devrun up --detach      # start everything; returns once all are ready
$ devrun errors           # did anything break, and the log under it
$ devrun logs --since 2m  # every service's output, merged by time
$ devrun down             # stop everything
```

With no `process-compose.yaml`, supervise one command instead. The same
`logs`, `errors` and `down` work against it.

```console
$ devrun run --detach --ready-log "listening on" pnpm dev
```

`devrun run` exits with the command's own exit status. Its words pass
through untouched, so devrun's flags go before the command.

`devrun up --detach` exits non-zero if a service fails to come up, and
`devrun errors` exits non-zero while anything is broken, so both can be
branched on without reading their output.

Useful flags on `logs` and `errors`: `--grep 'panic|ERROR'`, `--tail N`,
`--since 30s`, `--json`, and `--raw` to defeat the trimming. Output is
bounded by default and says at the end what it left out. Run `devrun`
with no arguments for the rest.
<!-- devrun:end -->
