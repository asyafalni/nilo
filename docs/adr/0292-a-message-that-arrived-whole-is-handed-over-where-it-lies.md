# 0292 — a message that arrived whole is handed over where it lies

**Status:** accepted
**Applies:** [ADR 0052](./0052-a-message-is-copied-once-and-framed-once.md) (a message is copied once), [ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md) (the message buffer belongs to the executor, not to the socket), [ADR 0275](./0275-a-reset-between-frames-is-a-client-that-has-gone.md) (the last time `echo-ws-limited` found something).
**Found by:** HttpArena's `echo-ws-limited` column. On the arena's 64 cores nilo sat at 39 of them while every entry above it used 53 to 60, and it served fewer frames at 4,096 connections (945K a second) than at 512 (1.13M), where every entry above it served more.

## Context

`Socket.receive` collected every message into a buffer borrowed from the executor's free list (`http/scratch.zig`) and gave it back when the socket went quiet or ended. The list keeps 64 KiB of spares a thread, four buffers at the default `max_message` of 16 KiB, and anything past that goes back to the page allocator.

A socket that lives for ten messages meets that cap head on. With more sockets open on an executor than it keeps spares for, and `echo-ws-limited` opens 64 on each of the arena's executors at 4,096 connections, every connection `mmap`s sixteen kilobytes when its first frame arrives and `munmap`s them when it ends. An `munmap` in a threaded process is a TLB shootdown: the kernel interrupts every core the process is running on and waits for each to flush. On eight threads that is cheap, which is why nothing here saw it. On sixty-four it is a server waiting on its own cores.

The kernel counts shootdowns in `/proc/interrupts`. The arena's shape on this box, eight seconds at 4,096 connections through gcannon `--ws -r 10`:

| server | shootdowns |
|---|---|
| WebSocket, ten frames a connection | 409K to 1.27M |
| HTTP, ten requests a connection, same server | 550 to 632 |
| WebSocket, free list budget raised to 64 MiB (an experiment) | 8.3K to 8.6K |

The third row is what said the free list rather than anything else on the connection path.

## Decision

**A data frame that is the whole of its message, and whose payload is already in the connection's read buffer, is unmasked in that buffer and handed over from there.** No message buffer is taken for it. Everything else, a fragment, a frame split across reads or one bigger than the read buffer, is collected into a message buffer exactly as before.

It keeps the loan `Message` already described. `data` is good until the next `receive`, and the read buffer is refilled only by the next `receive`, which is the same promise the message buffer made because the next message overwrote it anyway. Unmasking stays one pass (ADR 0052): it XORs where the bytes lie instead of on the way out of the read buffer.

The header is now read before any buffer is taken, against `_max_message - filled`, which is the number `buf.len - filled` always came to. So a control frame no longer takes a buffer either.

## What was rejected

**Raising the free list's budget, or giving it hysteresis.** It fixes the column by holding a burst's buffers after the burst, which is the per-connection cost `scratch.zig` exists to remove, moved somewhere harder to see. Its own header says that about the first version of it.

**Handing buffers back lazily, trimmed on an idle executor.** Still an `munmap` per buffer, and the shootdown is paid on the same cores, only later.

## What it costs

Against ADR 0018's axes, `21890c6` against the change, the arena's own entry built from each, pinned to 4 cores (8 threads) with gcannon on the other 4, interleaved:

| axis | before | after |
|---|---|---|
| TLB shootdowns, `echo-ws-limited` shape, 8 s at 4,096 | 409K to 1.27M | **10K to 17K** |
| Frames a second, the same, three pairs | 1.24M, 1.27M, 1.44M | 1.40M, 1.43M, 1.50M |
| Frames a second at 512, two pairs | 1.53M, 1.63M | 1.62M, 1.68M |
| RSS, persistent echo at 4,096 connections | 94,784 KiB | **78,380 KiB** |
| Allocations per request | 1 | 1, the HTTP path is untouched |
| Memory per idle WebSocket | 5,183 | not re-measured; an idle socket already gave its buffer back at the peek, and that path is untouched |

**The throughput rows are not the claim.** Eight threads make a shootdown cheap, which is why this box never showed the column's shape; the rows only say the change did not cost anything here. The claim is the first row and the arena's next run, which is where sixty-four cores pay for every shootdown.

The RSS row is a second finding rather than the purpose: a busy socket whose messages all fit the read buffer no longer holds a message buffer at all, about 4 KiB resident a connection at the arena's frame size.

## Consequences

- `http/scratch.zig` now serves only messages that are fragmented, split across reads or bigger than the read buffer. Its cap stands, and a short-lived socket that sends large messages still pays an `mmap` a connection. Nothing has asked about that shape.
- `zig build profile`'s WebSocket rows now measure the in-place path, which is the path a message that fits takes.
