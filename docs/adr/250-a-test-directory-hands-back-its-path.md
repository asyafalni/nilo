# A test directory hands back its path

**Status:** accepted
**Topic:** [testing](../design/testing.md)
**Applies:** [ADR 057](./057-percent-is-needed-by-two-layers.md), whose rule puts it in Core

## Context

`std.testing.tmpDir` returns a `Dir` and a random `sub_path`, and no path. Code under test that opens a file by name needs one: a SQLite database (`sqlite3_open_v2` takes a string), a unix socket, a directory `app.static` or `bulkhead.Dir.open` reads, a WAL a reader opens with libc `open`. The directory is `.zig-cache/tmp/<sub_path>` under the working directory, which std does not document and which is read off its source. nilo's own suite wrote that line by hand sixteen times, eleven under `http/` and five under `sql/`, and a program written on nilo wrote it a seventeenth time for its own file reader and asked for a helper.

std's directory also has a trap: `tmpDir(.{})` opens it as a path handle, and listing it panics with `BADF` inside `std.Io.Threaded`, which reads as an Engine bug ([`docs/history.md`](../history.md)). Four of the sixteen passed `.{ .iterate = true }` to get past it.

## Decision

**`nilo_core.tmpDir()` makes the directory and `tmp.path(buf, name)` or `tmp.pathAlloc(gpa, name)` names a file in it; `nilo.testing.tmpDir` is the same declaration.**

```zig
var tmp = nilo.testing.tmpDir();
defer tmp.cleanup();

var buf: [128]u8 = undefined;
const url = try tmp.path(&buf, "app.db"); // ".zig-cache/tmp/<random>/app.db", zero-terminated
```

- **No path borrows the `TmpDir`.** `path` writes into the caller's buffer and `pathAlloc` into the caller's allocator, so a `TmpDir` can be returned from a fixture's `init` or held in a struct field, as std's is, and a path taken before the move still names the file. Both are zero-terminated, because the callers that want a path most are C libraries, and `[:0]u8` passes where `[]const u8` is asked for.
- **An empty name is the directory itself**, which is what `app.static` and `bulkhead.Dir.open` take.
- **The path is relative to the working directory**, as std's directory is. Nothing is resolved, so there is no syscall and the length is fixed: `TmpDir.dir_path_len` is the directory's.
- **It is always opened iterable, and takes no options.** A test directory gains nothing from a path handle, and the option existed only to be got wrong.
- **`tmp.dir` is the open `Dir`**, for writing a file in by handle, and `cleanup` removes the directory and everything in it.

**It is in Core because two layers need it** ([ADR 057](./057-percent-is-needed-by-two-layers.md)): the App layer's tests hand the path to `app.static`, and `nilo_sql`'s hand it to SQLite, and `nilo_sql` is a Service that may not name `nilo_http` ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). It is the one file in Core only a test calls: std's `tmpDir` asserts `builtin.is_test`, and Zig analyses a function only when something calls it, so a program compiles none of it.

### What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md): nothing on any axis. No request path, no connection and no program reaches it; it exists only in a test binary.

## What was rejected

- **`nilo.testing.tmpPath(name)` in `http/testing.zig` alone**, the shape the request suggested. `sql/`'s five would have stayed hand-built, since a Service cannot reach `nilo.testing`, and the line would have gone on being written in two places.
- **A `path()` that returns a slice into the `TmpDir`.** The directory's path has a fixed length, so the value could carry it and hand out a slice with nothing to allocate. But std's `TmpDir` is copied freely, and six of the sixteen sites returned it from a fixture's `init` with the path taken first; a slice into the copy that was returned from would have pointed at a dead stack frame, which is the bug that passes in Debug and fails in ReleaseSafe.
- **Resolving the path to an absolute one.** It would survive a test that changes the working directory, which none does, at the cost of a `realpath` and a length that is no longer known while compiling.
- **Taking std's `OpenOptions`.** Every option but `.iterate = true` is std's default, and the default for `.iterate` is the trap.
