# A request nobody else would answer is refused

**Status:** accepted
**Topic:** [http1-protocol](../design/http1-protocol.md)

## Context

nilo is deployed with a reverse proxy in front of it. That is not an assumption about how people run it, it is a decision on the record: TLS is terminated upstream ([ADR 027](./027-tls-is-terminated-in-front.md)), so there is always something in front reading the same bytes nilo reads.

Two parsers reading one request is fine while they agree about where it ends and who it is for. Request smuggling is what happens when they do not: the front end reads one request and forwards what it thinks is one, nilo reads one and a half, answers the first, and leaves the second half in the buffer as the start of the *next* client's request. What that next client gets back is a response to a request somebody else wrote. A scan of `applyHeaderAt` and `parseHead` found six places where nilo's reading of a header disagreed with the RFC, or with what every other server on the front end already refuses.

`fuzz.zig` has held a reference parser against the fast one since it was written, to catch exactly this. It caught none of the six, because the reference parser was written from the same reading of the spec as the thing it was checking: a differential test only finds what the two implementations disagree about, not what they agree on wrongly. The corpus was rewritten alongside each fix, by the other route (splitting forwards and keeping what came last, where `http1` takes the last comma and reads from there), and now carries a `Host` header on every framing entry so the whole corpus is not refused for want of one.

## Decision

**All of the following are `error.BadHeader`, already a 400, or (for the last two) their own named refusal:**

- A `Content-Length` value that is not one or more ASCII digits. `std.fmt.parseInt` is not `1*DIGIT`: it read `+5` as 5, `1_0` as 10, `-0` as 0, all bytes nginx, haproxy and envoy already refuse. A leading zero (`05`) is not on this list: it is legal ABNF, two digits, and every parser in the chain reads it as 5.
- A second `Content-Length` whose value differs from the first. Repeating the same value is allowed (RFC 9110 §5.3 lets a recipient treat repeated field lines as the one value they agree on).
- `Content-Length` and chunked framing in the same request, in either order. RFC 9112 §6.1 names this outright as the smuggling case.
- A second `Transfer-Encoding` line once chunked has been seen, because the lines combine into one list and chunked has to be last. `chunked` is read as the final comma-separated coding rather than as a substring (`std.ascii.indexOfIgnoreCase` used to take `xchunked` and `chunked-x` for chunked framing), so `gzip, chunked` is chunked and `xchunked` is not.
- **A `Transfer-Encoding` whose final coding is not `chunked`.** RFC 9112 §6.1 requires a 400 when a server cannot decode the final coding, and nilo can decode exactly one. Before this, `saysChunked` answering no did nothing at all, no error, no framing, `content_length` left at zero, so `Transfer-Encoding: gzip` with no `Content-Length` was answered as a request with no body while the bytes the client sent sat in the read buffer as the start of the next one.
- **An HTTP/1.1 request with no `Host`, or with two of them.** RFC 9112 §3.2 requires a 400 for both, and a front end already refuses them ([ADR 027](./027-tls-is-terminated-in-front.md)), so serving them was nilo agreeing to answer a request nobody else agreed to. **HTTP/1.0 is left alone**: `Host` was never required before 1.1. **A repeated `Host` is refused even when both copies agree**, unlike `Content-Length`: §3.2 refuses the repeat itself, because two authorities in one request is something the front end and nilo may route differently whether or not the strings match today.

`Request` carries two bools for this, `has_content_length` (an absent header and `Content-Length: 0` cannot otherwise be told apart) and `has_host`, both landing in padding the struct already had, so `@sizeOf(Request)` is unchanged.

### Where the checks live

Whether there is a body to refuse depends on `Content-Length` and `Transfer-Encoding` together, so the framing checks live in `finish`, called from every parser exit, rather than in the header arm that reads one value: a check in the arm would give a different answer depending on which of the three headers the client sent first. `Host`'s absence is knowable only once the head has ended, for the same reason, so it lives in `finish` too; a repeated `Host` is caught as the line goes past, in a fifth arm on the length switch.

## What was rejected

**Resolving rather than refusing**, in accordance with `Transfer-Encoding` alone as RFC 9112 §6.1 permits, and what most servers do. Wrong here for the reason the same paragraph gives: the message might indicate an attempt at request smuggling. Resolving means picking a reading and hoping the proxy picked the same one; a 400 means nobody has to guess.

**Sharing `range.number`** with the digit-only parser this needed. `range.zig` runs under a plain `zig test http/range.zig` with no module graph, and importing `http1.zig` would cost it that, so the same four-line parser stays duplicated in both files.

**Putting the `Host` rule in `App` instead of `parseHead`.** Would have cost the same test churn while splitting one message rule across two files; `parseHead` is what parses a request message, so the rule belongs to it.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none |
| Memory per idle connection | two bools, in padding `Request` already had |
| Throughput and p99 | unmeasurable: interleaved runs put this group of checks at +1.25ns on a 192ns request, sign flipping across runs, which reads as unchanged ([`bench/result/http.md`](../../bench/result/http.md)) |
| Binary size | +208 bytes, stripped ReleaseFast, on `nilo-hello`, for the `Host` checks together with three other changes in the same commit |

None of these arms run at all on a GET with no body, and a POST trades a `parseInt` for a digit loop over the same bytes.

**What it breaks**: a client that sent no `Host` used to be served and now gets a 400. No browser, proxy or HTTP library does that, and the front end in front of a deployed nilo already refused it, but a hand-written client speaking to nilo directly might not have. `testing.Client.get` and its siblings already wrote a `Host` line, so every test that went through the client was untouched; 267 request literals across seven files that built their own head by hand needed one added.
