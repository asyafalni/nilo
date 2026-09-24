# A setting is a field, and every bad one is named at once

**Status:** accepted
**Topic:** config

## Context

A service reads its port, its database URL and its log level before it opens a socket. nilo had nothing for that: `getPosix` and `std.fmt.parseInt` per setting, with a sentence written by hand at each one, and, because that is what `try` does, a program that stops at the first mistake. Fix `DATABASE_URL`, run again, discover `PORT`, run again: four restarts to learn four things the process knew on the first one.

The shape nilo already has for this is in [ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md): a binding that hands its failures back instead of ending the request, so a handler can name every field that broke rather than the first. Startup is that problem with the audience changed, an operator at a terminal instead of a REST client, and nothing about the argument depends on there being a request. [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) made the bottom layer a place a second module can go, and `nilo_config` is it.

A setting does not always start in the process's own environment. A `.env` file is the ordinary way a laptop or a container gets one, and whether this module should read one was left open on the grounds that it is a file format, past a refusal to parse one. The refusal turned out to be drawn one word too wide: it was never about formats, it was about depending on somebody else's parser, and a `.env`'s whole grammar is `NAME=value`.

## Decision

**A Config is a struct of your own, and the field is the setting.**

```zig
const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

const read = config.fromEnv(Settings, init.minimal.environ);
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

The field name upper-cased is the variable, `database_url` is read from `DATABASE_URL`, a default is what "not set" means, and a `?T` is a setting that may be absent. That is [ADR 011](./011-the-query-string-is-a-struct-of-your-own.md)'s sentence about a query string with two words changed, and the repetition is the point: a person who has read a `Query(T)` has already read this. A marker naming a variable that is not the field's own, the way `nilo_table` names a table, is not built: every Config that has needed one so far has been able to rename the field instead, and the roadmap holds it as an open question rather than a guess.

**Every bad setting is named at once, and that is the feature.** Not the reading, which is forty lines. `value()` is optional the way ADR 034's is, so there is no way to reach past a failure into a half-filled struct and serve on a port nobody set:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

**Four reasons, and it stays four.** `missing`, `not_a_number`, `not_true_or_false`, `not_a_choice`. Whether the port is one this machine may bind is the program's own question, and a reason set that grew to answer it would be a validation language wearing a smaller name, the sentence ADR 034 wrote about `Bound`, binding here for the same reason.

**It reads `[]const u8`, not `Str`, and the module imports nothing at all.** A `Str` is text that belongs to a request and goes stale when it ends; the trap that enforces it is that module's whole reason for existing. Settings are read once and held for the life of the process, so every `Str` here would be a `Str.static`, a lifetime annotation on text with no lifetime question. `getPosix` hands back a slice of the block the operating system gave the process, which outlives every use of it, and `[]const u8` says exactly that and nothing more.

`config.Env` reads that block in place, which is what makes it allocate nothing, and Windows moves the block: `Env.get` is a compile error there naming `config.Map`, the portable half, which takes the `environ_map` `std.process.Init` already hands to `main`. Nothing is unreachable, one source just costs a map and the other does not.

### It does not open a file

`nilo_config` reads whatever text it is handed; it never opens one itself. A source is anything answering `get(name) ?[]const u8`, a shape checked while compiling rather than an interface with a function table, and `config.Dotenv` is one: it takes text, not a path.

```zig
const text = std.fs.cwd().readFileAlloc(arena, ".env", 64 * 1024) catch "";
const file = config.Dotenv{ .text = text };

const read = config.from(Settings, config.layered(.{
    config.Env{ .environ = init.minimal.environ },  // a set variable wins
    file,                                           // the file is the floor
}));

try file.report(stderr);   // writes nothing when the file is clean
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

Taking text rather than a path is what keeps `Dotenv` inside this layer: it allocates nothing, holding the caller's slice and handing back slices into it, the same contract `Fixed` and `Env` already carry, so the text has to outlive the Config; it imports nothing, no `std.fs`, no allocator, no error set about a file that was not there; and `zig test config/dotenv.zig` runs every line of it against string literals, the entry condition below. Where the text came from is then the caller's business: `readFileAlloc`, `@embedFile`, a Kubernetes ConfigMap already in memory, a decrypted blob.

**Sources go in an order, and the first one with the name answers.** `config.layered(.{ a, b })` is a comptime tuple, `inline for`, no allocation and no merged map. A `.env` that could not be overridden by a real environment variable would be the wrong shape: the file is what a machine has when nobody said otherwise, and a set variable is somebody saying otherwise.

**A line that is not a setting is reported, not skipped.** A `.env` with `DATABASE_URL postgres://localhost` on line 7, no `=`, the typo everybody makes once, read by a lenient parser becomes "DATABASE_URL is not set" about a file that plainly sets it, and the fifteen minutes that follow is precisely the failure this module exists to stop. `Dotenv` carries the same four verbs `Read` does, `failed()`, `failedCount()`, `failures()`, `report(w)`, so a person who has read one has read the other:

```
2 lines are not settings:
  line 2 has no `=`, so it sets nothing
  line 3 sets "MY KEY", which is not a name an environment variable may carry
```

**Four reasons a line is not a setting, and they are all about shape:** `no_equals`, `empty_name`, `bad_name`, `unbalanced_quote`, one level down from the "four, and it stays four" above. Whether the value itself is any good is `convert.Reason`'s question, `PORT=soon` parses perfectly here and fails there, and that split keeps this file from growing a second opinion about types.

**The grammar is small, and what it refuses is the decision.** `NAME=value`, blank lines, `#` comments on their own line, `'` and `"` quoting, an optional `export ` prefix, and CRLF. No escapes, no multi-line values, no `${OTHER}` interpolation, and no comment after a value: `PASSWORD=abc#123` stays intact, and `PORT=8080 # the port` becomes `PORT has to be a whole number, not "8080 # the port"`, which says exactly what happened without this file guessing where a comment started. A strict rule that reports itself beats a lenient one that guesses.

**A report never quotes a value.** The one place this departs from `Read.report`: a `.env` is where a password lives, and a startup message is what reaches a log aggregator. The line number is what somebody needs to find the line; a name is quoted only where the name is what went wrong. Nothing in the module logs a Config either, so there was nothing to redact there in the first place, and a `secret` marker on a field is decided against for that reason.

### The entry condition beats the permission

ADR 038's table says a tool module *may* import `nilo_core`, and its text says a module in the bottom layer runs under a plain `zig test` or it is in the wrong layer. `nilo_id` imports nothing, so it never had to choose between them. `nilo_config` is the first to face the choice for real, because the obvious design shares `http/convert.zig`'s pure half rather than writing forty lines of `tryConvert` twice.

They cannot both hold for a module that uses the permission: `zig test config/config.zig` supplies no modules, and a file naming `nilo_core` fails to compile under it. **The entry condition wins, and the permission is what it always was: a permission.** A tool module may name `nilo_core` and pays for it with the property that decides its layer, which makes naming Core a thing to argue for rather than a default. `nilo_config` does not, and `zig test config/config.zig` runs all of its tests with no `build.zig` in the process. `convert.zig` stays where it is; what changed is that the caller who might move it now has to be one in the App or Service layer, because a bottom-layer caller cannot reach `nilo_core` without giving up more than the sharing is worth.

**Five tool modules stand on this floor today** (`id/`, `config/`, `pw/`, `cache/`, `jwt/`), **and none of them names `nilo_core`.** `nilo_id` writes its own clock rather than borrowing one; `nilo_pw` wants entropy, a thread and a hash count, all of them arguments or the caller's; `nilo_cache` wants a clock and a lock it does not have the `Io` to take. Zero imports is the shape a tool module takes, and naming Core is the exception a module has to argue for.

## What was rejected

**Import `nilo_core` and share `http/convert.zig`'s pure half.** This is the design the entry condition above closed off, and the drift argument for keeping `convert.zig`'s copy does not transfer either: `http/convert.zig` keeps one copy of its sentences because a handler shows a field's failure next to a 400 from the endpoint beside it, and two spellings of one mistake is what somebody files a bug about. A config report is written to stderr, once, before the socket opens, by a process about to exit; it is never beside anything. What it costs is forty lines of `tryConvert` in two places; what it buys is the property the layer is defined by.

**`Str` for the text.** Argued above: every `Str` here would be a `Str.static`, a lifetime annotation on text that has no lifetime question.

**Ship a TOML parser.** [sam701/zig-toml](https://github.com/sam701/zig-toml) is ~2,000 lines, arena-backed, maintained, and already on 0.16's `std.Io`. Writing one here means weeks to reach where somebody else already is, on a problem that is not this repository's, and depending on it means every project importing `nilo_config` fetches it, the property [ADR 037](./037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md) spent a lazy dependency to protect.

**Ship a YAML parser.** [kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) is the measurement that settles this: 322 of the ~400 cases in the official YAML test suite are on its skip list. The failure mode of a partial YAML parser is also the wrong one, misreading real files quietly rather than refusing them.

**Return an error and let the caller ask why.** `error.BadConfig` with the detail behind a second call is the shape most libraries have, and it costs a restart per mistake unless the caller writes the loop themselves. ADR 034 already refused it for a handler.

**A vtable, either for a source or for a layer inside `layered`.** An interface with a pointer and a function table would let either take something it has never heard of. Refused for [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)'s reason about a Scope: the comptime check refuses an unsuitable type in a sentence and generates the code a direct call generates. Nothing here is on a hot path, so this is consistency rather than speed, but a second way of spelling the same idea in one repository is its own cost. The tuple `layered` takes is written once at the call site and never grows at runtime.

**`config.fromDotenvFile(T, ".env", gpa)`: open the file here.** The obvious API, and it costs every property above: `std.fs`, an allocator, an owned buffer, and a decision this module has no business making (is a missing `.env` an error?). It also puts a fixture on disk into the test suite, breaking the entry condition. All of that to save three lines in `main`, in a program that has an allocator open anyway.

**Ship the `.env` reading as an example instead of a module.** Tempting, since the grammar is fifty lines, but it fails on the half that is not the grammar: an example does not carry the bad-line report, and an example copied into a project is exactly where "skip the line quietly" gets written. The reporting is the feature; the parsing is the part anybody could do.

**Let a malformed line be skipped**, what every `.env` library does. Refused for the same reason a module whose whole point is naming every bad setting at once cannot silently drop the line that explains why one of them looks unset.

**Report a bad line as a Config failure, in one list.** They answer different questions and neither can answer the other's: "line 2 is not a setting" is about the file, "DATABASE_URL is not set" is about the Config and stays true even if the name was never in the file. Merging them would mean the source knowing what a Config is, inverting the dependency that makes `Fixed`, `Env`, `Map` and `Dotenv` interchangeable. A program prints both, in that order.

**Last-wins for a duplicate name**, node's `dotenv`. Refused for `Fixed`'s rule instead: the first pair with a name wins, so a caller can put overrides in front of defaults.

**A trailing `#` comment.** The ambiguity has no good resolution: `PASSWORD=abc#123` is a real value and `PORT=8080 # the port` is a real comment, and no rule tells them apart without quoting rules that need escapes, which need a lexer. Refusing is one sentence in the doc and one legible error at runtime.

**Merge the layers into a map at startup.** An allocation, a hash and a copy of every value, to save a string comparison that happens a dozen times in the life of the process.

## What it costs

Put against the four axes ([ADR 017](./017-the-trade-budget-has-four-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | none, and none anywhere: a Config is read before the socket opens, into one fixed array sized while compiling, out of text that already exists. Nothing in this module calls an allocator. |
| Memory per idle connection | none. Nothing here is per-connection. |
| Throughput and p99 | none. No file in `http/` is touched. |
| Binary size | zero for a project that names neither `nilo_config` nor `Dotenv`/`layered`; 3,392 bytes for one that reads a Config; a further 6,448 bytes for one that also layers a `.env` under it |

Both figures are measured, stripped `ReleaseFast`, on two programs identical except for the feature, with `report` reachable in each so the number is the realistic one rather than the flattering one: `example-hello`, `example-rest` and `nilo-hello` come out byte for byte identical whether or not they import `nilo_config`, the same three programs ADR 038 used to record the same property for that module. The `.env` half is [`bench/RESULTS.md`](../../bench/RESULTS.md)'s own run, against a `git worktree` of the parent commit: 237,528 bytes either side of the change, and 243,976 with `Dotenv` and `layered` reachable, which is where 6,448 comes from. Neither cost grows with the number of readings; the Config's grows with its field count, a table built once while compiling, and the `.env`'s does not grow with the file, which is scanned in place.

Nine Refusals guard this module, one per mistake a Config or a source can be handed: a Config that is not a struct, one with no fields, a field nothing can convert, an unknown field, a source that is not a shape with `get`, a `layered` tuple forgotten, empty, or holding something that is not a source. All but two cost 30–40ms of `zig build test`, measured warm; the other two, `config_unknown_field` and `config_layered_not_a_source`, run nearer 110–150ms because their `@compileError` is reached through a generic function rather than from the type itself. Both figures are well under the ~270ms [ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md) records for the framework's own, and the reason holds for all nine: they analyse a module that imports nothing, so there is no Engine in front of the failure.
