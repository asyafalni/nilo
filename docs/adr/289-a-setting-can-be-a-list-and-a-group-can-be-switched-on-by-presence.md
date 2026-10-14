# A setting can be a list, and a group can be switched on by presence

**Status:** accepted
**Topic:** config
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (nothing allocated, nothing per connection), [ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md) (a mistake stops in nilo's own words)
**Extends:** [ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)

## Context

A field was text, a number, a `bool`, an enum or any of those in `?`, and two kinds of setting that ordinary services have do not fit that. The first is a comma-separated list in one variable: `ALLOWED_ORIGINS=https://a.com,https://b.com`, `KAFKA_BROKERS=h1:9092,h2:9092`. The second is a group of settings that is off unless somebody asks for it: `SMTP_HOST` set means `SMTP_PORT`, `SMTP_USER` and `SMTP_PASSWORD` are now required, and `SMTP_HOST` unset means the service sends no mail. The port of photon (a service with real deployment rules) found both and read its environment by hand, about sixty lines tested case by case; a mail-sending service written for these tests needs the same two. The shape is drawn from those two programs and not from one.

The module's promise did not change: no allocation, no imports, `zig test config/config.zig`, and every bad setting named at once.

## Decision

**A list is `config.List(T, max)`, with room for `max` entries fixed while compiling.**

```zig
const Settings = struct {
    allowed_origins: config.List([]const u8, 8),
    broker_ports: config.List(u16, 4) = .of(&.{9092}),
    signals: ?config.List(enum { traces, logs }, 2) = null,
};
```

The struct holds `[max]T` and a length, `items()` returns the entries read, and a default is a list literal, `.of(&.{ … })`, checked while compiling. `T` is a scalar the module already reads (text, a number, a `bool`, an enum); an entry is read by the rule of its own type, so a bad one is named by its position: `KAFKA_PORTS entry 2 has to be a whole number, not "soon"`. Entries are split on commas, trimmed of spaces, tabs and line ends, and an empty one is skipped, so `a,,b,` is two. Text entries point into the source text, the lifetime a `[]const u8` field already has. `items()` takes a pointer, because the slice points into the struct.

**More entries than `max` is a failure, a fifth `Reason`, `too_many`.** `ALLOWED_ORIGINS has room for 4 entries, not 5`. It could not be one of the four: nothing about it is "not a number" or "not a choice", and `missing` is a different advice to an operator. It is still a conversion failure and not a validation language: the capacity is part of the type the field asked for, as the width of a `u16` is, and `1 ≤ n ≤ 3` or "no duplicates" stay the program's own question (`not_a_number` already covers a number the type cannot hold). A list with a bad entry among the first `max` entries and too many entries reports the bad entry, the more specific of the two; one failure is kept for a variable, and entries past `max` are not looked at.

**Empty means empty, and for an optional list it means absent.** `ALLOWED_ORIGINS=` is a list of no entries. `signals: ?List(…) = null` read from `SIGNALS=` is `null`, and so is `?List(…) = .of(&.{…})`: an empty variable clears an optional setting, its default included, which is the rule photon's operators rely on. A scalar `?[]const u8` is unchanged: `X=` is still the empty text, because changing that is a breaking change this decision does not need.

**A group is a `?Struct` field, read when any of its variables is set.**

```zig
const Settings = struct {
    smtp: ?struct {
        host: []const u8,        // SMTP_HOST
        port: u16,               // SMTP_PORT
        user: []const u8,
        password: []const u8,
        starttls: bool = true,
    } = null,
};
```

Its variables are the field name upper-cased, an underscore, and the inner field name, after the program's prefix: `smtp.host` under `.prefix = "APP_"` is `APP_SMTP_HOST`. The group is `null` while no variable of it says anything, a blank one included (`SMTP_HOST=` copied out of an example file is how people say "not here"). Once one does, the group is read like a struct: a required field that is not set is a failure named with the full variable, `SMTP_PORT is not set, and other SMTP_* settings are`, and every other rule (defaults, `?`, lists) holds inside it. **Inside an active group a blank variable reads as not set**, the same rule that leaves the group off: a field with a default takes it, an optional one is `null`, and a required one is a `missing` failure, so `SMTP_PORT=587` with `SMTP_HOST=` fails with `SMTP_HOST is not set` and not with an empty host. Outside a group nothing changes: `X=` is still the empty text. A default on the field (`= null`, or a value) is what an off group reads as.

**Layering needs nothing new.** Presence is asked of the source by name, per variable, so a group's `SMTP_HOST` from the environment and its `SMTP_PORT` from a `.env` combine the way any two settings do, and a variable present in any layer turns the group on. "Inheriting what the file set" is the existing rule, not a new one.

**One table of variables.** `Read(T)` keeps one outcome and one entry per variable, a group's fields counted as the fields inside it, so a failure inside a group is the same `Failure` as any other, `.field` is `smtp.port`, and `r.nameOf("smtp.port")` and `r.given("smtp.port")` take that path (a typo is still a Refusal). A group does not nest, has at least one field, and a `List` holds a scalar, has room for at least one entry, and a default fits: each is a Refusal with a file in `config/refusals/`.

## What was rejected

**A slice field, `[]const []const u8`.** It needs an allocator to hold the entries, or a hidden static buffer, and the module owns neither (ADR 039). A capacity in the type is the cost of staying allocation free, and the compile error for a default that does not fit is the other half of it.

**A list type that says nothing about capacity and fails at runtime without a number in the message.** The operator needs the number; it is in the type, so the message has it for nothing.

**Reuse `not_a_number` or `missing` for `too_many`.** Both would name the wrong thing to the person reading the report, and the report is the module's whole product. A fifth reason costs one enum tag and one `switch` arm in `Failure.say`.

**A plain nested struct as a group (no `?`), prefixed by the field name.** Always on is just a way to spell the variable names; the useful case is "off unless asked". A non-optional struct stays a Refusal, and the message says a group is a `?` struct.

**Presence that counts a blank variable.** The usual `.env.example` ships `SMTP_HOST=`, and a group that turned on from that would fail with three missing settings on a machine that meant to send no mail. A blank variable counts as not set inside an active group too: a group that went on from one variable and then read a blank sibling as empty text would hold a host of nothing, while a blank number is already `not_a_number`.

**Group inside group, `SMTP_RELAY_HOST`.** The name is a convention nobody can predict without reading the source, and the case that needs it is a second group beside the first.

**The two spellings of `bool` (`1/yes/on`).** Refused on the record: `bool` is `true` or `false` and nothing else.

**Report every bad entry of a list.** One outcome per variable keeps `Read` a fixed array; the first bad entry is named, and fixing it shows the next. A list rarely has two. Entries past the capacity are not converted, so a list with too many entries reports `too_many` and says nothing of a bad entry beyond the room.

## What it costs

Put against the four axes ([ADR 017](./017-the-trade-budget-has-four-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | none, and none anywhere: a list is an array in the struct, a group is a struct in the struct, and no allocator is named in this module. |
| Memory per idle connection | none. A Config is read before the socket opens. |
| Throughput and p99 | none. No file in `http/` is touched. |
| Binary size | none for a program that reads no list and no group (the code is generic and unreferenced); a list costs `max` entries in the Config value, 16 bytes each for text. |

Seven Refusals guard it: a list with no room, a list of a type an entry cannot be, a default that does not fit, a group in a group, a group with no fields, and two settings that read one variable (a plain `smtp_host` beside the group `smtp`, or `a.b_c` beside `a_b.c`).
