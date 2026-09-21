# nilo on HttpArena

This directory is nilo's entry in [HttpArena](https://www.http-arena.com/),
kept here so it is built and tested against the framework it describes. The
copy the board runs lives at `frameworks/nilo/` in
[MDA2AV/HttpArena](https://github.com/MDA2AV/HttpArena), and is this
directory as it is — the same five files, nothing generated.

| File | What it is |
|---|---|
| `src/main.zig` | the endpoints, one per profile, written the way the guide says to |
| `meta.json` | which profiles nilo subscribes to, and the tier it enters in |
| `Dockerfile` | one static musl binary from the commit `build.zig.zon` pins |
| `build.zig`, `build.zig.zon` | a dependent's build, with `nilo_sql` asked for |

## Which profiles, and why not the others

Subscribed: `baseline`, `limited-conn`, `latency-1m`, `latency-10k`,
`latency-500k-8cpu`, `pipelined`, `async`, `async-db`, `echo-ws`. Each is a
route in `src/main.zig` with the board's contract quoted above it.

Not subscribed, because the entry is *standard* mode and nilo refuses the
thing the profile needs ([ADR 0028](../../docs/adr/0028-what-nilo-will-not-do.md)):
`json-comp` (response compression), `fortunes` (a template engine, in
standard mode), and every TLS, HTTP/2, HTTP/3, gRPC and gateway profile.
The board's rule is that a profile left out is simply absent from that
column, not a zero.

## The one setting off its default

`max_connections = 65_536`. The `async` profile holds 32,000 connections open
at once and `echo-ws` runs to 16,384; the framework's default of 10,000
closes the rest at accept. The knob is documented in
[Deploying](../../docs/guide/deploying.md#how-many-connections-at-once),
which is what standard mode asks of a non-default setting.

## Building and running it here

```
cd bench/arena
zig build test                       # the handlers, as functions
zig build && ./zig-out/bin/nilo-arena
curl 'http://127.0.0.1:8080/baseline11?a=13&b=42'      # 55
```

`build.zig.zon` pins nilo to a commit on GitHub rather than to `../..`, so
the container the board builds is the build the row describes. To test a
change to nilo itself before it is pushed, point the dependency at the
working copy for the duration:

```zig
.nilo = .{ .path = "../.." },
```

and put the pin back before copying the directory across. Moving the pin is
one command, and it rewrites both the URL and the hash:

```
zig fetch --save=nilo git+https://github.com/nevindra/nilo#<commit>
```

## Validating it the way the board does

The board's own checks — the sums, the randomised operands, the request
split at every byte, 32 overlapping delays, the WebSocket handshake — run
from a clone of HttpArena with Docker present:

```
git clone https://github.com/MDA2AV/HttpArena.git
cp -r bench/arena HttpArena/frameworks/nilo
cd HttpArena
./scripts/validate.sh nilo
./scripts/benchmark-lite.sh nilo baseline     # one profile, load generator in Docker
```

Linux only, by the board's own account: the runner uses `--network host`
and cgroup v2 CPU accounting, neither of which Docker Desktop reproduces.
The numbers from a laptop are a smoke test; the ones that count come from
the board's runner, triggered on the PR with `/benchmark -f nilo`.
