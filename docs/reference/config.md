# nilo_config

One page of [the reference](./README.md): settings out of the environment.

## `nilo_config`

Settings, read into a struct of your own before the socket opens
([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
Nothing here allocates and nothing here does IO.

```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,                                   // a default is "not set"
    database_url: []const u8,                           // no default: required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,                                // may be absent
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(init.io, &buf);

    const read = config.fromEnv(Settings, init.minimal.environ);
    const settings = read.value() orelse {
        try read.report(&out.interface);
        try out.interface.flush();
        std.process.exit(2);
    };
    // an ordinary struct — `app.provide(&settings)` makes it a Service
}
```

The field name upper-cased is the variable: `database_url` is read from
`DATABASE_URL`. A field is text, a number, a `bool`, an enum, or any of those
wrapped in `?`; anything else is a Refusal.

| | |
|---|---|
| `config.fromEnv(T, environ)` | `Read(T)` out of the process environment |
| `config.from(T, source)` | out of anything with `get(name) ?[]const u8` |
| `config.fromWith(T, .{ .prefix = "NILO_" }, source)` | the same, with a prefix on every name |

| | |
|---|---|
| `r.value()` | `?T` — the Config, or null when any setting failed |
| `r.report(w)` | every failure, one per line, into a `*std.Io.Writer`. Writes nothing when there are none |
| `r.failed()`, `r.failedCount()` | |
| `r.failures()` | an iterator of `Failure`, in the order the struct declares them |
| `r.given("port")` | the text that arrived, converted or not. Field name checked while compiling |
| `r.nameOf("port")` | `"PORT"`, prefix and all |

A `Failure` is `.field`, `.name`, `.reason`, `.given`, `.expected`, and
`.say(w)` writes nilo's own sentence for it. `Reason` is `missing`,
`not_a_number`, `not_true_or_false`, `not_a_choice` — four, and it stays four:
whether the port is one this machine may bind is your question.

| Source | |
|---|---|
| `config.Env{ .environ = … }` | the environment block, read where it lies. Allocates nothing. POSIX only |
| `config.Map{ .map = init.environ_map }` | the portable half, and what Windows uses |
| `config.Fixed{ .pairs = &.{ .{ "PORT", "9000" } } }` | pairs of your own — the seam for a file you parsed yourself |
| `config.Dotenv{ .text = … }` | a `.env`'s **text**. You open the file; this reads it |
| `config.layered(.{ a, b })` | several sources in the order they win — the first with the name answers |

### A `.env`

`Dotenv` takes text, not a path
([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)), so the module
still opens no file and still allocates nothing. **The text has to outlive the
Config** — a `[]const u8` field points into it, exactly as it points into the
environment block.

```zig
const text = std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
const file = config.Dotenv{ .text = text };

const read = config.from(Settings, config.layered(.{
    config.Env{ .environ = init.minimal.environ },   // a set variable wins
    file,                                            // the file is the floor
}));

try file.report(w);   // writes nothing when the file is clean
```

`io` and `environ` both come from `main`'s own argument, and `w` is
`std.Io.File.stderr().writer(io, &buf)`'s `.interface`. The whole of a real
`main` — the one this is a fragment of — is on
[the settings page](../guide/config.md#the-whole-of-a-real-main).

| | |
|---|---|
| `f.get("PORT")` | `?[]const u8` — the first line setting that name |
| `f.failed()`, `f.failedCount()` | lines that meant to be settings and are not |
| `f.failures()` | an iterator of `BadLine` |
| `f.report(w)` | every bad line, one per line. Writes nothing when there are none |

A `BadLine` is `.number`, `.why`, `.name`, and `.say(w)`. `Wrong` is
`no_equals`, `empty_name`, `bad_name`, `unbalanced_quote` — all about the shape
of the line; whether the value converts is `Reason`'s question. **A report never
quotes a value**, because a `.env` is where a password lives.

Reads `NAME=value`, blank lines, `#` comments on their own line, `'` and `"`
quoting, an optional `export ` prefix, and CRLF. **Refuses** escapes, multi-line
values, `${OTHER}` interpolation, and comments after a value — so
`PASSWORD=abc#123` is intact, and `PORT=8080 # the port` says
`PORT has to be a whole number, not "8080 # the port"` rather than guessing.

**It opens no files.** `std.zon.parse` is in the standard library;
[sam701/zig-toml](https://github.com/sam701/zig-toml) is the one to reach for
if the file has to be TOML. Either way the pairs come back as a `Fixed` and
this module never had to carry the dependency.
