# A `try` call hands back the error and says nothing

**Status:** accepted
**Topic:** [static-files](../design/static-files.md)
**Extends:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md)
(a load that stops the process says why in one line)
**Applies:** [ADR 009](./009-static-files-are-held-in-memory-or-opened.md)

## Context

`app.static(prefix, dir)` reads a directory into memory before `listen()`,
and a directory that is not there stops the process with one line saying
which path, because on that call the line is the whole explanation and
there is nobody else to give it to (ADR 001). `app.tryStatic` is the same
call with the error as a value, for a program that has a decision to make:
a test that builds no frontend, a backend that serves its API whether or
not `dist/` has been built yet.

The line came out of both. A program that wrote

```zig
app.tryStaticWith("/", "web/dist", .{ .spa_fallback = "index.html" }) catch |err| switch (err) {
    error.StaticDirNotFound => std.log.info("no frontend built; serving the API alone", .{}),
    else => return err,
};
```

read `error: static directory "web/dist" could not be opened: FileNotFound`
above its own `info:` line every time it started without a frontend. The
program had handled the case, said so at the level it chose, and nilo
contradicted it one line up. The `try` prefix on the call was the promise
that the caller decides, and the log broke it.

## Decision

**A `try` variant that hands an error back does not also report it. A
directory that is not there comes back from `tryStatic` and `tryStaticWith`
as `error.StaticDirNotFound`, and nothing is logged.**

`static.load` takes one more argument, `Absent`, which says what to do about
a directory it cannot open: `.reported` says so in one line and hands the
error back, which is what `app.static` wants since the process is about to
stop on it; `.returned` hands it back alone. The App's four `static` calls
share one `loadStatic` that passes the right one.

A problem *inside* a directory that is there is still said in one line by
both variants: a file that could not be read, a path longer than the walk
allows, a symlink out of the tree. The error name cannot carry which file,
and the line can, so a caller handed `error.FileTooLong` with no line would
have less than a caller handed the line. The rule is about the case the
caller can name from the error alone.

## What was rejected

**Silencing every line under `tryStatic`.** A per-file failure is not one
the caller can act on from `error.Unexpected`; the path is the useful part,
and the `try` variant does not have a place to hand it back.

**A `.quiet` field on `static.Options`.** The caller already said what they
wanted by choosing the call: `static` is "stop and tell me", `tryStatic` is
"tell me, I will decide". A second knob saying the same thing is a way to
set them to disagree.

**Logging at `debug` instead.** A test root fails on a logged `err` and not
on a `debug`, so the tests would have passed while the program's own log
still carried a line for a case it handled. Quieter is not the same as
handled.

## What it costs

One enum argument on `static.load`, which is a breaking change for a caller
that called it directly rather than through the App. Nothing at run time.

## Consequences

- `http/static.zig`: `Absent`, and `load` takes it.
- `http/app.zig`: `loadStatic`; `staticWith` passes `.reported`,
  `tryStaticWith` passes `.returned`.
- The reference marks which `App` calls stop the process and which hand the
  error back.
