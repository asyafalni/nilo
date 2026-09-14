# A run can say its failure is final

`job.Retry` is decided once per kind while compiling, and *which* failure a
run has is only known when it runs. A reset socket or a 429 is different in
ten seconds; a 4xx saying *invalid from address* is the same 4xx in ten
seconds and in an hour; and both come back through the same error set. So a
job talking to an HTTP provider retried the bad request as many times as the
bad moment, and `deadOnes` showed six identical attempts at something that
could never work. The port's first real caller — a notification outbox —
answered by owning its own attempt ledger and running the tick with
`retry = .none`, which is the queue's own retry being unusable for the
thing it is for.

## `final`

```zig
const SendMail = struct {
    pub const nilo_job = "send-mail";
    pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 10_000, .to_ms = 3_600_000 } } };
    pub const final = error{ Rejected, NoSuchAddress };

    pub fn run(self: SendMail, scope: *nilo.Run, mail: *Mailer) !void {
        const answer = try mail.send(scope, self);
        if (answer.status.class() == .client_error) return error.Rejected;
        if (!answer.ok()) return error.Unavailable;
    }
};
```

A declaration on the kind: an **error set** naming the failures that are
final. A `run` that fails with one of them is dead on that attempt, whatever
`retry.times` says, and the row keeps the error's name as it does for every
other failure. Everything not in the set retries as before. A timeout is
never final — it is the queue's own word for a run that did not finish, and
the next attempt may.

The set is on the kind rather than in the error because that is where
`retry` is: the two halves of "what happens when this fails" sit side by
side, and a reader of the kind sees both. It is an error set rather than a
list of names because the language already has the type, and because
`error{Rejected}` is checked as spelled — a misspelt name in a list of
strings would be a line that never matched.

## What was not done

**`error.Unretryable`, recognised by the queue.** One word for every final
failure loses the error's name on the row: `deadOnes` would say
`Unretryable` where it now says `Rejected`, and the name is what somebody
reading the dead rows needs. It also puts a queue word into the error set of
every `run`, which is the run naming the queue rather than the other way
round.

**`job.dead(err)`, a call inside `run`.** It needs somewhere per run to
keep the name until the queue reads it — the fiber-bound box `nilo.fail`
uses — and a Fitting has no `http/` to borrow one from. A declaration costs
nothing per run and needs no box.

**Deciding by error name at run time**, `pub fn isFinal(err) bool`. It
would let a kind decide on the error's payload, which an error has none of;
what it has is a name, and the set names it already.

## Against ADR 0018's four axes

Nothing per request or per connection. Per failed attempt, one `inline
for` over the set's names — a handful of comparisons where a retry was about
to be written.

## Consequences

- `pub const final = error{…}` on a kind; read in `executeKind` ahead of
  the retry count.
- Two Refusals: a `final` that is not an error set, and one on a kind whose
  `retry` is `.none`, where it would decide nothing.
- The outbox can keep `.{ .times = 5, .backoff = … }` and stop on the first
  4xx.
