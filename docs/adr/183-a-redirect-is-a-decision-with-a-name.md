# A redirect is a decision with a name, and a followed one says where it ended

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

An empty `redirect_buffer` meant redirects were not followed and a 3xx came back as itself. For anything signed that is the right default. But "I do not want this followed" and "I did not think about redirects" were the same absence, and the symptom of the second was a `Head` with status 301 that a caller read as a bad upstream and reported as one. fdm did think about it, because `mirrors.kernel.org` made it, and the next CLI on nilo would find it the same way, in the first week, from a server that was right.

Once redirects had a name of their own, following one still lost where it ended. fdm needs it: the sixteen connections after a probe should hit the final URL rather than repeat the chain sixteen times. It got there by reaching through the `Exchange` into `std.http.Client.Request.uri`, which nilo does not promise, and formatting it before the `redirect_buffer` went out of scope; the comment explaining the lifetime was longer than the code.

## Decision

### `Begin.redirects` is a union with three arms, and the default says so out loud

- **`.refuse`, the default:** a 3xx with a `Location` is `error.RedirectRefused`. A 304 has no `Location`, is an answer to `if-none-match`, and is handed over as itself.
- **`.follow = &buf`:** walked, three deep at most, the `Location` resolved in the buffer, and `head.redirected` saying where it ended (below).
- **`.expose`:** the 3xx as itself, 302 and all, for the signed request that checks where an object moved and for the client that reads the body of the answer, which is where S3 puts the reason for a 301; `s3/bucket.zig` says it on every call, because a signature is over one host and following would send it elsewhere.

The intent has a name, the buffer goes where the one intent that needs it is, and the absence of a decision is no longer spelled like one. `Client.get` and the rest follow it as they did.

### `Head.redirected` is the `std.Uri` a followed redirect ended at, or null, and `head.location(buf)` writes it out as one string

std counts the redirects it has left in `RedirectBehavior`; fewer than it started with is a chain it walked, and `req.uri` is then the end of it, resolved by std's own `resolveInPlace` into the `redirect_buffer` the call was given. That is where the text lives: good for as long as the buffer is, which the caller owns.

The string form takes a buffer because a `std.Uri` is components, and writing them out needs somewhere to go. `error.NoSpaceLeft` is a URL longer than the buffer that held it, which is the only way it fails.

## What was rejected

**Keep the field and make a 3xx with an empty buffer the error.** Breaks nobody, and leaves the buffer's emptiness carrying two meanings with an error deciding between them at run time. The union costs every `begin` with a `redirect_buffer` in it one line each, and the alternative left the release untagged.

**An error on every 3xx.** A 304 is not a redirect, and a client sending `if-none-match` is owed it as an answer rather than as a failure with the right name.

**`location: ?[]const u8` on the Head, as a slice.** The obvious shape. There is no memory for it: the resolved URL is components pointing into `redirect_buffer`, and formatting them into the same buffer overwrites what they point at. A slice would need an allocation per redirected call, and `begin` has no Scope to take it from.

**`redirected` on `Response` as well.** `Client.send` keeps its redirect buffer on its own stack, so by the time a `Response` exists the text is gone; a `Str` in the Scope would be an allocation on a path that did not ask for it. The Exchange is where the buffer is the caller's, and it is the shape a caller that will open more connections is using anyway.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | `@sizeOf(?std.Uri)` on a `Head`, a value the caller holds for the head's window and not for the connection |
| Throughput and p99 | 0: a comparison of two integers at `begin` for the union, one more at redirect resolution |
| Binary size | not measured separately |

The union is the same slice and a tag, one error added to the set. The redirect test serves a `302` to `/moved` and a `200` on one connection, and reads `http://127.0.0.1:<port>/moved` back out of the head; the control asks the same of an answer that came from the URL it asked for and gets null. One connection rather than two, because std pools the first and comes back on it: a server that hung up after the `302` handed the client a reaped socket, and the stale-connection retry then sent the *original* URL again, which is a different test and the one that was accidentally written first.
