# nilo_config

**`nilo_config` reads settings from the environment into a struct of your own, and names every bad setting at once before the server starts.**

**Guide:** [Settings](../guide/config.md) · **Design:** [Layering](../design/layering.md) (config is one of its single-ADR topics)

## `nilo_config`

Settings are read into a struct of your own before the socket opens ([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). Nothing here allocates and nothing here does IO.

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

The variable name is the field name in upper case: `database_url` is read from `DATABASE_URL`. A field may be text, a number, a `bool`, an enum, or any of those wrapped in `?`. Any other type is a Refusal.

### `config.fromEnv` and `config.from`

| | |
|---|---|
| `config.fromEnv(T, environ)` | `Read(T)` from the process environment |
| `config.from(T, source)` | from anything with `get(name) ?[]const u8` |
| `config.fromWith(T, .{ .prefix = "NILO_" }, source)` | the same, with a prefix on every name |

### `Read(T)`

| | |
|---|---|
| `r.value()` | `?T`: the settings, or null when any setting failed |
| `r.report(w)` | every failure, one per line, into a `*std.Io.Writer`. Writes nothing when there are none |
| `r.failed()`, `r.failedCount()` | |
| `r.failures()` | an iterator of `Failure`, in the order the struct declares the fields |
| `r.given("port")` | the text that arrived, whether it converted or not. The field name is checked while compiling |
| `r.nameOf("port")` | `"PORT"`, prefix included |

### `Failure`

A `Failure` has `.field`, `.name`, `.reason`, `.given` and `.expected`, and `.say(w)` writes nilo's own sentence for it. `Reason` is one of `missing`, `not_a_number`, `not_true_or_false` and `not_a_choice`. There are four and there will stay four: whether a port is one this machine may bind is your application's question.

### Sources

| Source | |
|---|---|
| `config.Env{ .environ = … }` | the environment block, read in place. Allocates nothing. POSIX only |
| `config.Map{ .map = init.environ_map }` | the portable version, and what Windows uses |
| `config.Fixed{ .pairs = &.{ .{ "PORT", "9000" } } }` | pairs of your own, for example from a file you parsed yourself |
| `config.Dotenv{ .text = … }` | a `.env` file's **text**. You open the file; this reads it |
| `config.layered(.{ a, b })` | several sources in priority order: the first one that has the name wins |

### A `.env`

**`Dotenv` takes text, not a path** ([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)), so the module still opens no file and still allocates nothing. **The text has to outlive the settings**, because a `[]const u8` field points into it, exactly as it points into the environment block.

```zig
const text = std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
const file = config.Dotenv{ .text = text };

const read = config.from(Settings, config.layered(.{
    config.Env{ .environ = init.minimal.environ },   // a set variable wins
    file,                                            // the file is the floor
}));

try file.report(w);   // writes nothing when the file is clean
```

`io` and `environ` both come from `main`'s own argument, and `w` is the `.interface` of `std.Io.File.stderr().writer(io, &buf)`. The complete `main` this fragment comes from is on [the settings page](../guide/config.md#a-complete-main).

| | |
|---|---|
| `f.get("PORT")` | `?[]const u8`: the first line that sets that name |
| `f.failed()`, `f.failedCount()` | lines that were meant to be settings and are not valid |
| `f.failures()` | an iterator of `BadLine` |
| `f.report(w)` | every bad line, one per line. Writes nothing when there are none |

A `BadLine` has `.number`, `.why`, `.name` and `.say(w)`. `Wrong` is one of `no_equals`, `empty_name`, `bad_name` and `unbalanced_quote`, all about the shape of the line; whether the value converts is `Reason`'s job. **A report never quotes a value**, because a `.env` is where passwords live.

**What it reads:** `NAME=value`, blank lines, `#` comments on their own line, `'` and `"` quoting, an optional `export ` prefix, and CRLF. **What it refuses:** escapes, multi-line values, `${OTHER}` interpolation, and comments after a value. So `PASSWORD=abc#123` stays intact, and `PORT=8080 # the port` fails with `PORT has to be a whole number, not "8080 # the port"` instead of guessing.

**It opens no files.** For other formats, `std.zon.parse` is in the standard library, and [sam701/zig-toml](https://github.com/sam701/zig-toml) is the one to use if the file has to be TOML. Either way, the pairs come back as a `Fixed`, and this module never has to carry the dependency.
