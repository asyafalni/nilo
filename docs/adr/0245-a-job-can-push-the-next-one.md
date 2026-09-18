# 0245 — a job can push the next one

**Status:** accepted
**Amends:** [ADR 0198](./0198-a-queue-is-a-table-in-the-database-you-already-have.md),
the `.deps` of a `job.Jobs`: a struct, or a function that makes one.

## Context

A pipeline is the first thing a queue is for — download, then process,
then notify; a welcome now and a nudge three days later — and it did not
compile. The natural spelling is

```zig
const Jobs = job.Jobs(.{ .kinds = .{ Download, Process }, .store = job.Table(Db), .deps = struct { db: *Db, jobs: *Jobs } });
```

and the compiler answers `dependency loop detected`, in its own words,
pointing at nothing nilo wrote. `Jobs(…)` reads the fields of `.deps` to
check that each one is a pointer and that every `run`'s arguments are among
them, and one of those fields is `*Jobs` — the value of the declaration the
call is in the middle of computing. The roadmap carried it as Next 1 with
the shape that breaks the loop already named.

Writing it found that the loop is not only in `.deps`. `Download.run` is
`fn (Download, *nilo.Run, *Db, *Jobs) !void`, and reading its type — which
`checkRun` does, to say that the second argument is a `*nilo.Run` and the
rest are in `.deps` — resolves `*Jobs` too, and loops the same way. Moving
the deps out of the argument list and leaving the `run` checks in the body
of `Jobs(…)` still does not compile. Every read of a `run`'s signature has
to wait until the queue type exists, not only the read of `.deps`.

## Decision

**`.deps` may be a function of the queue type.** `fn (comptime Jobs: type)
type`, called inside the struct once `@This()` exists, and answering the
same struct of pointers a plain `.deps` is:

```zig
fn deps(comptime Queue: type) type {
    return struct { db: *Db, jobs: *Queue };
}

const Jobs = job.Jobs(.{ .kinds = .{ Download, Process }, .store = job.Table(Db), .deps = deps });

const Download = struct {
    pub const nilo_job = "download";
    pub const retry: job.Retry = .{ .times = 3 };

    file: i64,

    pub fn run(self: Download, scope: *nilo.Run, db: *Db, jobs: *Jobs) !void {
        try fetchInto(scope, db, self.file);
        _ = try jobs.push(scope, Process{ .file = self.file }, .{});
    }
};
```

`Jobs.Deps` is the struct either way, `open` takes it either way, and a
plain struct `.deps` is unchanged. The queue is a dep of its own kinds, so
it is opened once it has an address: `var jobs: Jobs = undefined; jobs =
.open(gpa, &table, .{ .db = &db, .jobs = &jobs }, .{});`.

**The checks that read a `run` move with it.** When `.deps` is a function,
`Jobs(…)`'s body checks what it can without a `run`'s type — the name,
`retry`, the payload's fields, a schedule's three declarations — and the
rest hangs off one private declaration, `late_checked`, that `open`,
`openWith`, `push`, `serve`, `serveOn`, `drain` and `runOne` all name in a
`comptime` block. A declaration is analysed once however many name it, so
a Refusal is reported once; and it is analysed after the queue's own
declaration has its value, which is the moment the loop is gone. A queue
whose `.deps` is a struct keeps every check in the body, at `job.Jobs(…)`,
as before.

**The lookup itself is the last check.** `depField` — the function that
finds the field of `Deps` whose type a `run` asked for — writes the
Refusal itself rather than reaching `unreachable`, and `call` builds a
`run`'s arguments through it. So a `run` asking for something `.deps` has
not got is refused at the checks when they run in the body, at `open` when
they were deferred, and at the call if neither was reached: the sentence
is written once and it cannot be got past.

## What was rejected

**A type-erased `*job.Queue`** that any `run` could ask for, with `push`
on it taking `anytype`. It breaks the loop without a function, and it
loses the check that a pushed kind is in `.kinds`: the erased queue does
not know its kinds, so `Download` could push a `Notify` nobody listed and
the row would sit in the table forever — the exact mistake
`job_pushed_but_not_listed` exists to refuse.

**Detecting the struct shape and refusing it in nilo's words.** `.deps =
struct { jobs: *Jobs }` loops while the *argument* is being evaluated,
before `Jobs(…)` runs a line, so there is nowhere for nilo to stand and say
"write a function". The message stays the compiler's. What nilo can say,
it says: a `.deps` that is a function of the wrong shape is refused naming
the one shape, and a function whose struct lacks what a `run` asks for
gets the sentence the plain shape always got.

**Running the deferred checks in a container-level `comptime` block**
inside the returned struct, which would fire at `job.Jobs(…)` without an
entry point being named. Whether such a block is analysed as its own unit
after the call returns, or inline while the type is being built — where it
would loop — is a property of the compiler this repository has not
measured, and a check whose timing is a guess is a check that may loop on
the case it exists for. A declaration named from the entry points has one
timing.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 |
| Throughput and p99 | unchanged: one `comptime` branch in `Jobs(…)`, and `call` builds the same argument tuple through the same lookup |
| Binary size | unchanged |

What it costs is where a Refusal arrives. For a queue whose `.deps` is a
function, a `run` with the wrong second argument is reported at the first
`open` rather than at the `job.Jobs(…)` line, with the compiler's
"referenced by" trace pointing back. Every program calls `open`, so
nothing ships unchecked; the line the error names moved.

## What proves it

`test "a job can push the next kind through a *Jobs dep, and two drains
run both"` in `job/job.zig`: `Download.run` takes `*PipelineJobs` and
pushes a `Process`; drained at the moment the first was due it runs one
kind, drained again it runs the other. Three Refusals hold the wording:
`job_deps_fn_of_the_wrong_shape`, `job_deps_fn_without_what_run_asks`
(through `open`, the deferred path), and the existing
`job_run_asks_for_a_dep_nobody_gave` for the struct shape.
