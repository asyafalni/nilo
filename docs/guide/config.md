# Settings

**`nilo_config` reads your own settings struct out of the environment before anything opens, and names every bad setting at once.**

**Reference:** [`nilo_config`](../reference/config.md#nilo_config), [a `.env`](../reference/config.md#a-env) · **Design:** [Layering](../design/layering.md) (config is one of its single-ADR topics)

`nilo_config` is a module of its own: no event loop, no allocator, and it opens no file ([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).

## Declaring the settings

<!-- compiles -->
```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,                                   // a default is "not set"
    database_url: []const u8,                           // no default: required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,                                // may be absent
};
```

The variable name is the field name in upper case: `database_url` is read from `DATABASE_URL`. A field can be text, a number, a `bool`, an enum, or any of those wrapped in `?`; a list and a group are below. Anything else is a compile error naming the field.

**Every bad setting is reported at once.** That is the reason to read them into a struct rather than one at a time:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

## A list in one variable

**A setting that is several values is a `config.List(T, max)`, read from one variable with commas in it.** `ALLOWED_ORIGINS=https://a.com, https://b.com` is two entries: spaces around an entry go, an empty entry is skipped.

<!-- compiles -->
```zig
const config = @import("nilo_config");

const Brokers = struct {
    allowed_origins: config.List([]const u8, 4),
    kafka_brokers: config.List([]const u8, 3),
    kafka_ports: ?config.List(u16, 3) = null,
};

fn firstBroker(settings: *const Brokers) []const u8 {
    return settings.kafka_brokers.items()[0];
}
```

The `4` is the room for entries, fixed while compiling, which is how nothing is allocated. More than that is a failure that says so (`ALLOWED_ORIGINS has room for 4 entries, not 5`), never a list quietly short, and a bad entry names its position (`KAFKA_PORTS entry 2 has to be a whole number, not "soon"`). Call `items()` on the settings you keep, not on a copy: the slice points into the struct. A default is `config.List(u16, 3).of(&.{9092})`. A `?List` is `null` when the variable is set to nothing, which is how an operator clears it; a plain `List` is then empty. The entries are the same text `cors.Origins.setSplit` splits (`read.given("allowed_origins")` is the variable as it arrived), so a program may use either.

## A group switched on by presence

**A `?` struct is a group of settings that is off unless one of its variables is set.** Mail is the usual case: no `SMTP_HOST`, no mail; with one, the rest are required.

<!-- compiles -->
```zig
const config = @import("nilo_config");

const Mailer = struct {
    port: u16 = 8080,
    smtp: ?struct {
        host: []const u8,        // SMTP_HOST
        port: u16,               // SMTP_PORT
        user: []const u8,
        password: []const u8,
        starttls: bool = true,
    } = null,
};

fn sendsMail(settings: *const Mailer) bool {
    return settings.smtp != null;
}
```

With only `SMTP_HOST=mail.example.com` set, the report is

```
3 settings could not be read from the environment:
  SMTP_PORT is not set, and other SMTP_* settings are
  SMTP_USER is not set, and other SMTP_* settings are
  SMTP_PASSWORD is not set, and other SMTP_* settings are
```

A variable set to nothing but spaces does not switch the group on, so an `SMTP_HOST=` left in an example file means no mail. Once the group is on, a blank variable in it counts as not set too: a default is taken, an optional field is `null`, and a required one is reported as missing, so `SMTP_PORT=587` with `SMTP_HOST=` names `SMTP_HOST` instead of sending mail through a host of nothing. The layers combine per variable: `SMTP_HOST` from the environment and `SMTP_PASSWORD` from a `.env` are one group, and a variable in either turns it on. A group does not hold another group; put the second beside the first.

## A complete `main`

**Reading settings needs an `std.Io`, and `main` already receives one through `std.process.Init`.** Two things here need an `Io`, and the event loop that would supply one does not exist yet: `listen()` comes further down the same function. `std.process.Init` is Zig's, not nilo's, and it turns both of these into three lines instead of thirty:

<!-- compiles -->
```zig
const std = @import("std");
const nilo = @import("nilo_http");
const config = @import("nilo_config");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    // A `.env` is text somebody else read (ADR 039), so the program opens
    // the file. Missing is not an error — that is production.
    const text = std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
    defer if (text.len > 0) gpa.free(text);
    const file = config.Dotenv{ .text = text };

    // A set variable wins; the file is the floor.
    const read = config.from(Settings, config.layered(.{
        config.Env{ .environ = init.minimal.environ },
        file,
    }));

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buf);
    const w = &out.interface;

    try file.report(w);                  // writes nothing when the file is clean
    const settings = read.value() orelse {
        try read.report(w);
        try w.flush();
        std.process.exit(2);
    };
    try w.flush();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&settings);          // an ordinary struct is an ordinary service

    try app.listen(.{ .port = settings.port });
}
```

Four things in it are worth spelling out, because an application written before this page existed had to discover each one the hard way:

- **`main` takes `std.process.Init`.** That is where `io` and `environ` come from. Setting up a `std.Io.Threaded` of your own for one 98-byte read works, and is nine lines you do not need.
- **The text has to outlive the settings.** A `[]const u8` field points into it, just as it points into the environment block. Free it after the server stops, or never.
- **`report` takes a `*std.Io.Writer`.** For stderr that is `std.Io.File.stderr().writer(io, &buf)`: the `.interface` field is the writer, and it has to be flushed. A fixed buffer works too (`std.Io.Writer.fixed(&buf)` and `std.debug.print`), but it limits the length of a report that grows with the number of wrong settings.
- **`file.report` is a separate call from `read.report`.** They report different things: the first, lines in the file that are not settings at all; the second, settings that could not be converted. A clean file writes nothing.

## `.env` file syntax

**`Dotenv` reads a simple, strict subset of the `.env` format, and takes text rather than a path.** Taking text is what keeps the module free of IO ([ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).

It reads `NAME=value`, blank lines, `#` comments on their own line, `'` and `"` quoting, an optional `export ` prefix, and CRLF. It **rejects** escapes, multi-line values, `${OTHER}` interpolation, and a comment after a value. So `PASSWORD=abc#123` arrives intact, and `PORT=8080 # the port` reports

```
PORT has to be a whole number, not "8080 # the port"
```

rather than guessing which half you meant. **A report never quotes a value that came from the `.env`**, because a `.env` is where passwords live.

## Settings that middleware reads

**A rate limit and a Content-Security-Policy take the address of a settings field.** Keep the struct in a container-level `var`, fill it before `listen()`, and hand the field's address to the middleware, which reads it on each request: `nilo.allowance.with(.{ .per_window = &settings.api_rate, .window_s = 60 })` and `nilo.secure.pages(.{ .csp = &settings.csp })`. A number is a `u32` field and the policy a `[]const u8`. [Middleware](./middleware.md#limits-and-policy-from-the-environment) has the whole program.

## Using the settings in handlers

**A settings struct is an ordinary struct, so it is an ordinary service:**

```zig
try app.provide(&settings);

fn verbosity(cfg: *const Settings) []const u8 {
    return if (cfg.log_level == .debug) "loud" else "quiet";
}
```

`*const Settings` in a handler's arguments is all the wiring there is. (A route that says whether the server is *ready* is a different thing: that is [`app.health`](./deploying.md#health-checks), which asks the services rather than the settings.) See [Services](./services.md) for what else a handler argument like this can take, and [the reference](../reference/config.md#nilo_config) for the rest of the API.
