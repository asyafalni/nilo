# 0268 — a head is mostly cookies, and sixteen kilobytes of them

**Status:** accepted
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty)'s
`ServerConfig.request.buffer_size = 16384` against nilo's
`read_buffer = 8 * 1024`.

## Context

`read_buffer` is the connection's read buffer and, because the head is
parsed in place (ADR 0107), the ceiling on a request head: one that does not
fit is a 431. It was 8 KiB, which is what a head used to be.

A head today is mostly cookies, and a browser behind a single sign-on sends
big ones. An identity token from Azure AD, Okta or Keycloak is 2–4 KB
base64; the session cookie an application sets beside it is often the same
size again; a chunked cookie — which is what the SSO libraries do when a
token will not fit one cookie — is several of them. 8 KiB is inside the range
a real browser on a corporate network sends on every request, and the 431
it earns is answered to the one client least able to do anything about it:
the person who can neither see the cookies nor delete them.

Go's `net/http` allows 1 MiB of head by default and nginx's
`large_client_header_buffers` is `4 8k`, so 32 KiB; dusty's is 16 KiB. nilo's
was the smallest in the comparison table, and it was not chosen — it was
the buffer size, and the head limit fell out of it.

## Decision

**`read_buffer` defaults to 16 KiB.** Nothing else changes: the head is
still parsed in place, still the ceiling, still a 431 past it, and a server
that wants the old number passes `.read_buffer = 8 * 1024`.

## What it costs

**Memory per idle connection: unchanged, 4,669 bytes.** ADR 0071 hands the
read and write buffers' pages back to the kernel while a connection is idle,
and a buffer that is two pages bigger gives two more pages back. The figure
every doc repeats is the idle one, and it does not move.

**Memory per active connection: two more pages, 8 KiB.** A connection that
is inside a request holds its read buffer, and now holds four pages of it
rather than two. Ten thousand connections all mid-request would hold 80 MB
more than they did; ten thousand connections are not all mid-request, which
is why the idle figure is the one that gets multiplied. `bench/mem.py`
measures the idle figure and is the run to repeat; the active figure is
arithmetic on the page count and is stated here rather than measured.

**Throughput: unchanged.** A head that fitted in 8 KiB is read the same way
into 16; the parser scans what arrived, not the buffer.

**Allocations per request: unchanged.** The buffer is the connection's,
allocated once at accept.

## Alternatives

**Leave it at 8 KiB and document `read_buffer`.** The doc was already there
(`requests.md`: "turn it up if you serve clients with enormous cookies") and
it is read after the 431, by the operator, on a support ticket from the one
user behind the SSO. A default is what people run.

**32 KiB, nginx's total.** Four more pages held per active connection for a
head size that a chunked-cookie SSO reaches and an ordinary one does not.
16 KiB is where dusty and the SSO libraries' own chunking thresholds put the
line; a deployment past it knows it is.

**Decouple the head limit from the buffer** — read a head larger than the
buffer into the arena. It is the parser's zero-copy property (ADR 0107) and
the 431's whole simplicity that the buffer is the limit; a head that spills
into the arena is an allocation on the path of every large-cookie request,
which is the path this ADR is about.

## Consequences

- `http/bulkhead.zig`: `read_buffer: usize = 16 * 1024`, and the doc comment
  says what it costs and where.
- `docs/reference/app.md`, the deploying guide's snippet and table, and
  `requests.md` say 16.
- `bench/ws_server.zig` keeps its own `READ_BUFFER` default of 8 KiB: the
  WebSocket idle figures in `bench/result/http.md` were taken at that size
  and a bench that silently changes its own baseline is the thing
  `bench/result/` exists to prevent.
