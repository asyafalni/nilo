# Testing

**A guard that has never been seen to fail is not yet a guard, and a message nobody checks is a sentence somebody will let rot.** The guide page is [`guide/testing.md`](../guide/testing.md); every name here is in the reference at [`reference/testing.md`](../reference/testing.md#testing); the code is `http/testing.zig` (`Client`, `Wired`, `Answer`, `Refusals`, `show`), `http/wiring.zig` (`program_mode`, `checkRootWiring`), and `refusals/` with the tables in `build.zig`.

## How the pieces fit

```
compile time                                run time
─────────────                               ────────
refusals/*.zig ──► zig build test ──► "nilo: <message>"      (ADR 026)
  one mistake,       table in build.zig      compared verbatim,
  on purpose         says what it must say   prefix supplied by the step

nilo.testing.Wired.init ──► app.provide/app.post (yours) ──► wired.post(...)
                                                                   │
                                                                   ▼
                                                              Answer
                                                          .bytes .json .text     (ADR 147)
                                                          checked against
                                                          Client.made           (ADR 171)

nilo.testing.Refusals.begin() ──► fail.status(...) ──► refusals.caught()        (ADR 129)

nilo.testing.show(value) ──► {f} in std.debug.print / errdefer                  (ADR 137)

wiring.program_mode ──► checkRootWiring() and Client.init() ──► std.log.warn    (ADR 069)
```

A guard that only ever passed and a guard that cannot fail look identical from outside; the left column exists because the compiler forgets a failed build and the right column exists because a body, a status and an answer's freshness all look fine right up until they are not.

## The rule in force

1. **A new comptime check ships with a file in `refusals/` and a row in its module's table**, and `zig build test` compiles the file and asserts the message's first line, minus the `nilo: ` prefix the step itself supplies, so a check that stops inside `std` cannot be recorded as passing. [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
2. **Refusals never cache.** The compiler keeps nothing from a failed compilation, so every file under `refusals/` is re-analysed on every `zig build test`. [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
3. **A guard ships with the observation of it failing**: a test reverted against the old behaviour first choice, a counter-test proving it stays quiet on correct code second, a recorded measurement only where neither is possible. [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
4. **A number saying a cost went away on its own gets more scrutiny than one saying work made something faster.** A good result nobody worked for has nobody to check it against. [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
5. **`std`'s own `std.log.default_level` says which optimize mode the root was built at**, read as `wiring.program_mode`, `null` standing for the `ReleaseFast`/`ReleaseSmall` pair rather than guessing between them; the comparison is comptime and compiles away on a matching build. [ADR 069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md)
6. **A mismatched build mode warns rather than refuses**, once from `checkRootWiring` off `listen()` and once from `nilo.testing.Client.init`, because `listen()` never runs under a test and the test step is where the mistake happens. [ADR 069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md)
7. **`Client.sendRequest` takes a whole request with every field defaulted**, and the four older helpers (`get`, `post`, `postWith`, `request`) are that with defaults filled in; `setHeader` is sticky across every request that follows. [ADR 086](../adr/086-the-test-client-can-do-what-a-client-does.md)
8. **The cookie jar is off by default**, turned on once in `Options.cookies` at `init`, because switching it on under an existing suite would change what already-written assertions test without changing a line of them. [ADR 086](../adr/086-the-test-client-can-do-what-a-client-does.md)
9. **`Wired` assembles one `App` and one `Client`, tearing them down client-first**; the routes and services stay the caller's own calls on `wired.app`, and no database belongs to it. [ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)
10. **`Answer.bytes` and `Answer.json` copy into the arena they are given and de-chunk first**, and an unknown field in a response body is ignored, the opposite of the rule a request body is checked by. [ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)
11. **Every `Answer` carries the request count it was made at, and `text`/`bytes`/`json` refuse with `error.AnswerStale` once a later request has run on the same `Client`**; `raw`, `head` and `body` still borrow the client's one buffer for a test that means to read it directly. [ADR 171](../adr/171-an-answer-knows-which-request-it-was.md)
12. **`nilo.testing.Refusals` catches a refusal with no request in flight**: `begin`/`end` bind a fallback slot so `fail.status` still records a status and a sentence, and `.caught()` reads it back; `end` restores whatever held the slot before. [ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)
13. **Boot work registered with `app.before` gets the same box on its own frame**, so a failing seed's log line names which registration failed, its status and its sentence, rather than only `Failed`. [ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)
14. **`nilo.testing.show` renders a value as JSON into whatever is formatting it**, for `{f}` in an `errdefer` or a plain `std.debug.print`, because `std.testing.expectEqual` prints with `{any}` and never calls a type's own formatter. [ADR 137](../adr/137-a-failed-assertion-that-can-be-read.md)
15. **A suite whose database will not connect goes green, not red**: `nilo_start`'s own connect diagnostics log at `warn`; a `Row` that disagrees with its table still logs at `err`, because that is a broken program rather than a machine that has no database running. [ADR 145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)

## Decisions

| ADR | What it decides |
|---|---|
| [026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md) | A comptime check's message is locked by a refusal file and a build.zig table row |
| [032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) | A guard ships only once it has been watched to fail |
| [069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md) | How nilo detects and warns on a mismatched optimize mode |
| [086](../adr/086-the-test-client-can-do-what-a-client-does.md) | `sendRequest`, sticky headers, and the cookie jar on `testing.Client` |
| [129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md) | Catching a fail function's status and sentence with no request in flight |
| [137](../adr/137-a-failed-assertion-that-can-be-read.md) | `nilo.testing.show`, a JSON renderer for a failed assertion |
| [145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md) | Which SQL diagnostics log at `warn` so a suite with no database still goes green |
| [147](../adr/147-a-response-is-read-back-the-way-it-was-written.md) | `Answer.bytes`/`.json`, and `Wired` for an `App` and a `Client` built together |
| [171](../adr/171-an-answer-knows-which-request-it-was.md) | `Answer` carries a generation, so a stale read is `error.AnswerStale` rather than the wrong body |

Beside this topic: the second `Content-Length` and second `Host` that make a hand-assembled test request a 400 is [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md) (http1-protocol); `clearCookie`'s `Max-Age` is [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md) (cookies-sessions); the four-axis budget every guard here is measured against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); a handler that blocks the thread, which the watchdog rather than a refusal file catches, is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) (engine).

## Open

- **The location half of ADR 014's message rule is untested for everything but route registration.** Nothing asserts that a reader's own line stays first in the reference trace elsewhere, because the build system has no way to assert on one, as recorded in ADR 026's consequences.

