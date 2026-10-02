# Testing

**A check that has never been seen to fail cannot be trusted yet, and an error message nobody tests will quietly go out of date.**

**Guide:** [Testing](../guide/testing.md) · **Reference:** [Testing](../reference/testing.md#testing)

The code is `http/testing.zig` (`Client`, `Wired`, `Answer`, `Refusals`, `show`), `core/tmp.zig` (`tmpDir`, which `nilo.testing` re-exports), `http/wiring.zig` (`program_mode`, `checkRootWiring`), and `refusals/` together with the tables in `build.zig`.

## Overview

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

nilo.testing.tmpDir() ──► tmp.path(&buf, "app.db") ──► SQLite, app.static, a socket   (ADR 250)
```

From the outside, a check that has only ever passed looks exactly like a check that cannot fail. The left column exists because the compiler keeps nothing from a failed build; the right column exists because a body, a status and whether an answer is current all look fine right up until they are not.

## Rules

1. **Every new compile-time check comes with a file in `refusals/` and a row in its module's table.** `zig build test` compiles the file and checks the first line of the error message, minus the `nilo: ` prefix the step adds itself, so a check that fails inside `std` cannot be recorded as passing. [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
2. **Refusals are never cached.** The compiler keeps nothing from a failed compilation, so every file under `refusals/` is analysed again on every `zig build test`. [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
3. **A check ships together with proof that it fails**: first choice, a test run against the old behaviour to show it failing; second, a counter-test proving it stays quiet on correct code; only where neither is possible, a recorded measurement. [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
4. **A number showing that a cost disappeared by itself gets more scrutiny than one showing that work made something faster.** A good result nobody worked for has nothing to check it against. [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
5. **`std.log.default_level` tells nilo which optimize mode the root program was built in**, exposed as `wiring.program_mode`. `null` stands for the `ReleaseFast`/`ReleaseSmall` pair, instead of guessing which. The comparison is compile-time and disappears in a matching build. [ADR 069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md)
6. **A mismatched build mode produces a warning, not an error**: once from `checkRootWiring` in `listen()`, and once from `nilo.testing.Client.init`, because `listen()` never runs in a test, and the test step is where the mistake happens. [ADR 069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md)
7. **`Client.sendRequest` takes a whole request with every field defaulted**, and the four older helpers (`get`, `post`, `postWith`, `request`) are that call with defaults filled in. `setHeader` sticks for every request after it. [ADR 086](../adr/086-the-test-client-can-do-what-a-client-does.md)
8. **The cookie jar is off by default** and turned on once, in `Options.cookies` at `init`, because turning it on under an existing test suite would change what existing assertions test without changing a line of them. [ADR 086](../adr/086-the-test-client-can-do-what-a-client-does.md)
9. **`Wired` builds one `App` and one `Client`, and tears down the client first.** Routes and services are still your own calls on `wired.app`, and no database belongs to it. [ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)
10. **`Answer.bytes` and `Answer.json` copy into the arena you give them and de-chunk the body first.** An unknown field in a response body is ignored, the opposite of how a request body is checked. [ADR 147](../adr/147-a-response-is-read-back-the-way-it-was-written.md)
11. **Every `Answer` records which request it came from, and `text`/`bytes`/`json` return `error.AnswerStale` once a later request has run on the same `Client`.** `raw`, `head` and `body` still point into the client's single buffer, for a test that wants to read it directly. [ADR 171](../adr/171-an-answer-knows-which-request-it-was.md)
12. **`nilo.testing.Refusals` catches a rejection when no request is in flight.** `begin`/`end` set up a fallback slot so `fail.status` still records a status and a message, and `.caught()` reads it back; `end` restores whatever used the slot before. [ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)
13. **Startup work registered with `app.before` gets the same slot in its own frame**, so a failing seed's log line names which registration failed, its status and its message, instead of just `Failed`. [ADR 129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md)
14. **`nilo.testing.show` renders a value as JSON into whatever is formatting it**, for `{f}` in an `errdefer` or a plain `std.debug.print`, because `std.testing.expectEqual` prints with `{any}` and never calls a type's own formatter. [ADR 137](../adr/137-a-failed-assertion-that-can-be-read.md)
15. **A test suite whose database will not connect passes, not fails.** `nilo_start`'s connection diagnostics log at `warn`. A `Row` that disagrees with its table still logs at `err`, because that is a broken program, not a machine without a database running. [ADR 145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)
16. **This repository's live SQL tests skip on a laptop and fail on CI.** With `$CI` set and no `DATABASE_URL`, `test-sql` fails before it runs. Every live connection carries `lock_timeout` and `idle_in_transaction_session_timeout` of ten seconds in its URL, and a test that ends with a connection still out fails naming it, so a leaked transaction costs a test rather than a hung run. [ADR 239](../adr/239-a-live-test-skips-on-a-laptop-and-fails-on-ci.md)
17. **`nilo.testing.tmpDir()` hands back a directory and the path to a file in it**, into a buffer or an allocator the caller holds, so a `TmpDir` can move without a path pointing at the copy it moved from. It is always iterable, and it lives in Core because `sql/`'s tests need it too and cannot reach `nilo.testing`. [ADR 250](../adr/250-a-test-directory-hands-back-its-path.md)

## Decisions

| ADR | What it decides |
|---|---|
| [026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md) | A compile-time check's message is locked in by a refusal file and a row in `build.zig`'s table |
| [032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) | A check ships only once it has been seen to fail |
| [069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md) | How nilo detects a mismatched optimize mode and warns |
| [086](../adr/086-the-test-client-can-do-what-a-client-does.md) | `sendRequest`, sticky headers, and the cookie jar on `testing.Client` |
| [129](../adr/129-a-refusal-outside-a-request-is-still-a-refusal.md) | Catching a fail function's status and message with no request in flight |
| [137](../adr/137-a-failed-assertion-that-can-be-read.md) | `nilo.testing.show`, a JSON renderer for failed assertions |
| [145](../adr/145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md) | Which SQL diagnostics log at `warn`, so a suite without a database still passes |
| [147](../adr/147-a-response-is-read-back-the-way-it-was-written.md) | `Answer.bytes`/`.json`, and `Wired` for building an `App` and a `Client` together |
| [171](../adr/171-an-answer-knows-which-request-it-was.md) | `Answer` records a generation, so reading a stale answer is `error.AnswerStale` instead of the wrong body |
| [239](../adr/239-a-live-test-skips-on-a-laptop-and-fails-on-ci.md) | This repository's live SQL tests skip without a URL, fail the build on CI without one, and give up on a leaked transaction after ten seconds |
| [250](../adr/250-a-test-directory-hands-back-its-path.md) | `tmpDir` in Core, with a path into the caller's buffer or allocator, always iterable |

Related topics: the second `Content-Length` and second `Host` that turn a hand-built test request into a 400 are [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md) (http1-protocol); `clearCookie`'s `Max-Age` is [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md) (cookies-sessions); the four-axis budget every check here is measured against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); a handler that blocks the thread, which the watchdog catches instead of a refusal file, is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) (engine).

## Open questions

- **The "where" half of ADR 014's error message rule is only tested for route registration.** Nothing checks, anywhere else, that the reader's own line stays first in the reference trace, because the build system cannot assert on it; this is recorded in ADR 026's consequences.
