# A header std owns goes out once

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

This replaces the `Begin.user_agent` slot added for fdm under 0.4.0, which made one of six reachable and left the caller to route the other five.

`std.http.Client` has slots of its own for six headers — `host`,
`authorization`, `user-agent`, `content-type`, `connection`,
`accept-encoding` — and writes each unless told otherwise. `Begin.headers`
goes to `extra_headers`, which std writes verbatim after its own. A caller
who put one of the six in `headers` got it twice on the wire.

fdm takes headers from a pasted `curl` line, so it sees `authorization:
Bearer …`, `user-agent: Mozilla/…` and `host:` as strings it did not choose.
It carried a `Headers` struct whose only job was to pull those three out into
`.authorization`, `.host` and `.user_agent` and hand the rest to `.headers`.
That is routing every nilo user with user-supplied headers will write, and
the list of what std owns is nilo's to know rather than theirs.

## Decision

**A name in `Begin.headers` that std has a slot for tells std to leave the
slot out.** The caller's line goes verbatim, once. The six names are known
in one place, `Given.of` in `fetch.zig`, and nowhere else.

The explicit fields — `Begin.host`, `.authorization`, `.content_type`,
`.user_agent` — stay as the form for a caller who has the value and not a
header line. A field set explicitly is an override, as it was.

`accept-encoding` is the one with a second half. The line goes out as the
caller wrote it, but the client still decodes nothing, so the `accept_encoding`
array std checks the *answer* against stays identity-only. A caller who
asks for `gzip` gets `error.HttpContentEncodingUnsupported` when a server
obliges, rather than a `Str` full of gzip — which is the trap this module's
header comment already describes, kept shut from the other side.

## Alternatives rejected

**Route by copying: pull the six out into the slots and pass a filtered
slice as `extra_headers`.** That needs somewhere to put the filtered slice.
On the Scope's arena it is an allocation per call with a routed header, and
`Exchange.begin` takes no Scope; on the stack it is a fixed array, and by
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) that is bytes on
every connection whose handler dials out. `.omit` costs neither: std writes
`extra_headers` verbatim either way, and the only thing that had to move was
its own line.

**Last one wins when the field and the line are both given.** A field is
the caller's own word for what the wire should carry, and the line is a
string they may not have chosen; silently dropping either is a guess. Both
go out, and the doc comment says so — "not both".

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 — six bools, gone before `request` returns |
| Throughput and p99 | six `eqlIgnoreCase` per header per call |
| Binary size | not measured separately |

The test sends `User-Agent`, `Host`, `Authorization` and `Accept-Encoding`
in `headers` and counts one line of each on the wire, the caller's.
