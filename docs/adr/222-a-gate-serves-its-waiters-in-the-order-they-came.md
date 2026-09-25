# A Gate serves its waiters in the order they came, and a wait can have a limit

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Extends:** [ADR 044](./044-a-password-hash-is-gated-because-forgetting-is-silent.md) (the Gate it introduced as a counting lock is now also a queue)
**Applies:** [ADR 013](./013-handlers-must-not-block-the-thread.md) (waiting for a turn is a park, and the watchdog is told), [ADR 017](./017-the-trade-budget-has-four-axes.md) (what it spends)

## Context

`Gate` was the Engine's counting semaphore behind a wrapper: a lock and a
condition, a permit count, and `post` adding one back and waking a waiter.
That answers *how many* at once and says nothing about *which*. A turn given
back went onto the count, where the woken waiter has to take it, and a caller
arriving in the microseconds before that waiter ran again saw a free permit
and took it instead. Under steady load the one arriving is usually the one
that just left: its next request is already in hand.

That is not a queue. An engine in front of a database measured it with its own
gate over its read pool (five turns for expensive statements, eight clients,
each asking again as soon as it was answered), fifteen seconds a run, three
runs:

| turns go to | p50 | p99 | refused at the 2 s limit |
|---|---|---|---|
| whoever asks first | 200–271 ms | 1 963–2 049 ms | 13 |
| the oldest waiter | 366–388 ms | 541–570 ms | 0 |

The work done was the same either way, mean latency and throughput within 5 %.
First-come did not make anything faster; it moved the waiting onto a few
clients and made them wait out the whole limit.

That engine could not use `Gate` for a second reason: `enter` waits for as
long as it takes. A gate in front of a scarce resource usually has something
better to do past some point (serve an older answer, refuse and name the
limit), so it needs to stop waiting, and give up its place in the line when it
does. It had built its own ticket queue and polled it on `nilo.sleep(4)`.

## Decision

**A Gate hands a turn given back to the oldest waiter, and a caller takes a
free turn only when nobody is waiting.** And `enterWithin(ms)` waits at most
`ms`:

```zig
gate.enterWithin(500) catch |err| switch (err) {
    error.TimedOut => return serveOlderAnswer(),
    error.Canceled => return err,
};
defer gate.leave();
```

A wait that runs out holds nothing, owes no `leave`, and leaves the line as it
was: the next one moves up. `enterWithin(0)` asks whether a turn is free now.
`enter` is unchanged in shape and gains the order.

**The line is the Gate's own.** Each waiter puts a node on its stack and
appends it to the Gate's list; `leave` pops the head, marks it granted and
wakes that node's own condition, and adds to the free count only when the list
is empty. So a turn given back belongs to a named waiter from the instant
`leave` runs, and nothing arriving later can see it as free. A waiter parks
while it is not granted. When its wait ends in a timeout or a cancellation,
`granted` decides, not which of the two the condition reported: not granted,
it unlinks its node; granted as a limit ran out, it takes the turn it was
given; granted as a cancellation arrived, it hands the turn to the new head
or back to the Gate.

The Engine is asked for its `Mutex` and a condition over it with a timed wait,
and for nothing about the order in which that condition wakes; the Bulkhead
contract lists both. The Engine's semaphore has no caller left and is no
longer exported.

## What was rejected

**Exposing the Engine semaphore's timed wait and stopping there.** It gives
the limit and keeps the barging, which is the half that produced the table.

**Counting handed turns and relying on the condition's FIFO order**, which is
what this change first did. A newcomer checked the count before it had ever
parked, found a turn handed to someone else and took it; a review test that
calls `enter` again straight after `leave` saw it barge 45 times in 50. And a
cancellation that lands after the condition has consumed a signal left the
count saying "handed" with nobody to take it. Naming the waiter closes both.

**A ticket queue polled on `sleep`**, which is what the engine had. It is fair
and bounded, and every freed turn waits for the next poll: a cost that grows
as the work behind the gate gets shorter.

**Leaving `Gate` alone and adding a second, fair type.** Two locks that
differ only in whether the longest waiter is served is a choice nobody should
have to make; the unfair one has no caller that wants it. The password Gate
(ADR 044) keeps working unchanged and gains the order.

## What it costs

- Uncontended, `enter` and `leave` are one lock each way, as before.
- A waiter's node is three words and a condition on its own stack, only while
  it waits; `Gate` itself holds a count and the two ends of the list. Nothing
  per connection or per request moves.
- A program that never enters a Gate is the same size: `nilo-hello`, stripped
  `ReleaseFast`, 970 064 bytes before and after.

## Consequences

- A fair queue gives up what a first-come lock gets from handing a turn to a
  thread that is already running. At the service times a Gate exists for
  (ADR 044's hashes, a database statement) that is not measurable against the
  table above.
- `leave` from a caller that holds no turn is still a bug the Gate cannot
  see, as it was: it adds a turn that was never taken.
