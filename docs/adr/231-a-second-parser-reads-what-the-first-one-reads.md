# A second parser reads what the first one reads

**Status:** accepted
**Topic:** [http1-protocol](../design/http1-protocol.md)
**Applies:** [ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md), [ADR 066](./066-a-lazy-dependency-is-a-request.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty), which parses with llhttp, beside the roadmap's entries on where nilo reads RFC 9112 differently, none of which `zig build fuzz` had caught.

## Context

`http/fuzz.zig` holds the parser to a reference written the slow, obvious way: split on newlines, trim a carriage return, read each line alone. That catches the fast path drifting from the obvious one. It cannot catch a reading of the RFC both of them share, because one author wrote both from one reading. The roadmap had five of those on file (a header name never checked to be a token, `Connection: keep-alive, close`, `Transfer-Encoding: gzip, chunked`, HTTP/1.0 with a `Transfer-Encoding`, a CRLF before the request line) and every one of them had passed the fuzzer.

The parser in front of nilo is somebody else's, and the risk ADR 070 guards against is two parsers reading one request two ways. The check that fits the risk is another parser. llhttp is Node's: written from a different reading, and hardened by years of smuggling reports against the most deployed server-side JavaScript there is.

## Decision

**`zig build fuzz-llhttp -Dllhttp` hands the heads `zig build fuzz` generates to nilo and to llhttp, and reports every difference by kind**:

- **nilo accepts a head llhttp refuses**: a leniency. Fails the run.
- **both accept it and frame it differently**: where the head ends, the method, the target, the version, the length, chunked, keep-alive, or an upgrade llhttp sees and nilo does not. Fails the run.
- **nilo refuses a head llhttp accepts**: counted by nilo's error and shown, never a failure. Stricter than Node is allowed.

**A difference that is nilo's on purpose is listed in `decided`** in `http/fuzz_llhttp.zig`, with the RFC section that makes it so, and is counted instead of failing. An entry matches on llhttp's reason *and on the input*, through a `when` of its own, because llhttp's reason names where it stopped rather than what was there: "Invalid char in url path" is a byte past 0x7f nilo takes on purpose or a control byte it must refuse, and matching the reason alone would let the second hide behind the first. Six are there: a method that is any token, and llhttp meeting one part way (`PUT.`), both RFC 9110 §9.1, where llhttp knows a fixed list; a repeated `Content-Length` with the same value (RFC 9110 §8.6); a byte past 0x7f in the target, which nginx and Go route as sent; a scheme RFC 3986 §3.1 allows and llhttp does not read (`h.tp:`, `ht:tp`); and `close` beside `keep-alive` on HTTP/1.0, which RFC 9112 §9.6 closes and llhttp keeps. A bare LF is made a CRLF on llhttp's copy only, because RFC 9112 §2.2 lets a recipient take one and llhttp's leniency for it stops at the request line.

**llhttp is a dependency behind `-Dllhttp`**, pinned to the 9.4.3 release tarball, and linked into this one program. `.lazy = true` is not enough on its own (ADR 066): without the flag nothing asks for it, and the step says what it needs.

**Not on `test`**, because it fetches. Its first run, a million inputs at seed 1, found twenty-one kinds of difference: three where nilo is the stricter, two decided, and sixteen not decided, in five groups: a method that is not a token, request-target bytes nobody checks, header names that are not tokens, a bare CR or a control byte in a line, and `Connection` read as one value rather than a list. Every group was a parser fix ([ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md), [ADR 073](./073-a-header-is-answered-as-asked-or-refused.md), [ADR 095](./095-a-target-is-read-in-the-form-it-arrived-in.md)), and the fixes turned up two more the first run had hidden behind them: an `http` target with no `//` and an authority a host cannot be spelled as, both refused now. What is left is ten kinds, every one decided, at seeds 1, `0x5eed` and `0xdecaf`, and the step exits 0. The first input of each kind is in `fuzz.zig`'s corpus, so `zig build test` replays what llhttp caught without llhttp.

## What it costs

Nothing on any axis of ADR 017: no line of it is in a program that ships, and a build without the flag fetches nothing.

## What was rejected

**Vendoring llhttp's C**, as dusty does. Twelve thousand lines in the tree, in a module that ships, for a program only this repository runs.

**llhttp as nilo's parser.** The SIMD parser is 163 ns on a browser's head and allocates nothing (`http1.zig`); llhttp would be a C dependency on every build and a callback per field. The point is its reading, not its code.

**A corpus of llhttp's own test cases.** Worth having and a different thing: fixed inputs somebody thought of. This checks the inputs nobody did.

## Consequences

- Every parser change runs `zig build fuzz-llhttp -Dllhttp` as well as `zig build fuzz`. A change that moves a finding into `decided` says why in the same commit.
- The step runs the generated inputs, not the corpus in `fuzz.zig`. Feeding the corpus through llhttp too is open.
