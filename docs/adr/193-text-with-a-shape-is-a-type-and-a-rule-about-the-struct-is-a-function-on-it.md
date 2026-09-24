# Text with a shape is a type, and a rule about the struct is a function on it

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)
**Extends:** [ADR 167](./167-a-whole-number-inside-a-range-is-a-type.md),
whose `Within(min, max)` is the same answer for a number; this is the answer
for text, and for the rule no single field can hold.
**Extends:** [ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md), which
put every rule in the handler; a rule the struct can settle on its own is now a
declaration on it, and ADR 034 says so.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md),
[ADR 113](./113-a-path-param-can-parse-itself.md),
[ADR 166](./166-a-body-field-that-parses-itself.md).

## Context

The roadmap carried this as an open question — *whether a rule like "this
is an email address" belongs in this repository* — with the bar set at
three applications writing the same predicate. They have: `examples/rest`,
the stress application's `auth.zig`, and `bound.zig`'s own worked example
each write `indexOfScalar(u8, email, '@')` and a length check on the
password, and each writes them in the one handler that remembered to. A
second handler binding the same struct gets neither.

ADR 167 already answered this for a number, and its argument is the whole
of this one: a `u8` refuses 300 and nobody calls that a validation. **The
type has a shape, and the text did not fit it.** `Within(1, 200)` chose the
shape rather than inheriting it from a width, and the document could then
say `minimum`/`maximum` because it read them off a type that enforces them.
Text had no such type, so a password's length lived in an `if`, and the
document — the half a generated client reads before it sends anything —
said `string`.

The design that shipped first from this session stopped there: `Text` and
`Email` as types, everything else through `must`. Put beside what a zod
user writes it was low-level in two places, and both were real. A rule used
once — "starts with `SKU-`" — meant a type of its own with `nilo_parse`,
`nilo_expects` and `nilo_type_name`, eight lines to say what a predicate
says in one. And a rule across fields — "confirm matches password" — stayed
in the handler, which is exactly where the three applications above had
lost it.

## Decision

Two things, and the second amends ADR 034.

### `nilo.Text(.{ .min, .max, .check, .said })`, with `Email` and `Url` as presets

```zig
const SignUp = struct {
    email:    nilo.Email,
    password: nilo.Text(.{ .min = 10, .max = 72 }),
    nickname: nilo.Text(.{ .max = 30 }) = .of(""),
    sku:      nilo.Text(.{ .check = startsWithSku, .said = "has to be a SKU code" }),
};
```

A `Text` is a `Str` that parses itself ([ADR 113](./113-a-path-param-can-parse-itself.md)),
so it is read in the four places a `Str` is — a path param, a query value,
a form field, a JSON body ([ADR 166](./166-a-body-field-that-parses-itself.md))
— with one sentence for all four, and `Bound` collects it beside every
other field's failure with nothing added to the handler.

- **`min` and `max` count code points**, because that is what JSON Schema's
  `minLength` counts, and the document and the server have to mean the same
  thing by the same number. `std.unicode.utf8CountCodepoints` is one pass
  and no allocation.
- **`check` is a plain `fn ([]const u8) bool`**, and it is the escape hatch
  built in rather than bolted on: the rule ADR 034 feared a language could
  not express is a function here, and a function can express anything. The
  document says nothing about it, which is honest — a predicate has no JSON
  Schema.
- **`said` is the sentence**, in the shape `must` already uses: `"sku" has
  to be a SKU code`. Without it, a `Text` composes its own.
- **A `Text` never quotes the text back.** `Within` writes `not "500"`; a
  password in a 422 body and the log line beside it is a leak, so the
  sentence is `"password" has to be text of 10 to 72 characters, not 6`.
  The mechanism is one optional declaration on a type that parses itself,
  `pub fn nilo_explain(text: []const u8, w: *std.Io.Writer) !void`, which
  writes the tail after the label; a type without it gets the sentence ADR
  113 wrote, `has to be <nilo_expects>, not "<text>"`. `Email` keeps the
  quote, because an address is not a secret and seeing it is how the typo
  is found.
- **`Email` is `Text` with the check every application wrote by hand** —
  one `@`, something before it, a dot after it, no whitespace, 254 code
  points at most — and `format: email` in the document. It is not RFC 5322,
  and the reference says so: the check that matters is sending the mail.
  **`Url`** is `std.Uri.parse` with a scheme and a host, and `format: uri`.
- **`.value` is the `Str`**, and `view()`, `len()`, `eql()` and `blank()`
  are forwarded so the common reads need no unwrapping. `.of("…")` for a
  default checks it against the bounds and the check while compiling,
  because the default is the one value a request never sends.
- **The document says `minLength`, `maxLength` and `format`**, read off
  `nilo_text` by name the way `minimum` is read off `nilo_within`. A bound
  the type enforces is
  a promise the document may make; nothing here lets a type *claim* one
  ([ADR 167](./167-a-whole-number-inside-a-range-is-a-type.md), "what was
  not done").

### `nilo_check`: a rule about the struct, on the struct

```zig
const SignUp = struct {
    password: nilo.Text(.{ .min = 10, .max = 72 }),
    confirm:  Str,

    pub fn nilo_check(self: SignUp, r: *nilo.Rules(SignUp)) void {
        r.must("confirm", self.password.eql(self.confirm.view()), "has to match the password");
    }
};
```

`must` here is the one ADR 034 shipped — the same name, the same three
arguments, the same bool that reads as the rule *holding*, the same
sentence coming out under the same label in the same 422. What moves is
where it is written: on the struct, so that every handler binding the
struct gets the rule, rather than in one handler, so that the next one
forgets it. It runs once, after every field has bound and before the
handler is called, in each of the four slots and under `Bound`.

**This is what ADR 034 rejected, and why it is not.** The rejected list
names a `nilo_rules` decl beside `@"min(10)"` in a field name and a
`Validate(T)` wrapper — three spellings of a *second language*, data that
claims a rule the framework then has to interpret, and that always needs an
escape hatch for the rule it cannot say. `nilo_check` is not data and
interprets nothing: it is Zig, it is the `must` chain the handler already
wrote, and its escape hatch is that it is a function. The sentence ADR 034
built its position on — *a rule that is not in the type stays in the
handler* — still holds, read the other way: a rule that **is** about the
type goes on the type.

**A rule that needs the request stays in the handler.** "That email is
already registered" wants a database; `nilo_check` takes the value and
nothing else, on purpose, so the two kinds of rule cannot be confused and
the struct cannot reach a service. The handler's `must` is unchanged for
that half.

**`nilo.Rules(T)`** is the per-field sentence array `Bound.Checked` already
holds, given a name a caller can write. A `Bound(W)` whose struct declares
`nilo_check` carries one — a slice per field — and one whose struct does not
carries a `void` in its place, so a binding of a struct that checks nothing
is the size it was, which is the cost ADR 034 kept off every binding. A
plain `Form(T)`, `Query(T)` or body whose struct fails its `nilo_check` is a
422 naming every rule that did not hold, through the same `sayAll` — every
rule is known at once, so there is no first-wins to fall back to. **The
check runs only when every field bound**: a rule read off a field that
never bound would be read off nothing, so the conversions are answered
first and the rules on the next attempt — which is also the order zod
runs a `refine`.

### What the engine does that it did not

A `Text` parsed out of a form or a query holds a `Str` the type built from
bytes, and a `Str` built from bytes has no lifetime marker. The engine
stamps it with the one on the text it was parsed from — `Str.stampLike` in
`nilo_core`, ten lines beside `stamp` — so the use-after-request trap
watches a `Text` the way it watches a `Str`. A body already gets this: App
stamps the whole parsed value, and `stamp` walks into a struct's fields.

## What it costs

Against ADR 017's axes:

- **Allocations per request:** none. A length is a count over bytes already
  in the arena; a check is the caller's function over the same bytes;
  `nilo_check` writes a `u8` per field into an array on the fiber's stack.
- **Memory per idle connection:** unchanged for a struct with no
  `nilo_check`. For one with it, a slice per field on the handler's frame
  while it runs — the room `Checked` already cost a handler that called
  `must` — and nothing held between requests.
- **Throughput and p99:** unchanged for a route naming none of this. For one
  that does, the work is what the handler's `if` did, moved.
- **Binary size:** one `nilo_parse` per distinct `Text` in the program, one
  `nilo_check` per struct that declares it, and the two presets when named.
  A program naming none carries none.

## Alternatives

**A bag of predicates for `must`, `nilo.rules.email(…)`.** Saves the
predicate and nothing else: still three lines in every handler, still
forgotten by the second one, and the document still says `string`. It was
the first design on the table this session and is the half-measure.

**A data marker, `nilo_rules = .{ .email = .email, .password = .{ .min = 10 } }`.**
What ADR 034 and ADR 167 both rejected, and the reasoning stands: a table
of claims the framework interprets is a language, and the first rule it
cannot express is the day it grows an escape hatch. `Text(.{ .check })` and
`nilo_check` are functions, and a function is its own escape hatch.

**A regex.** `std` has none, a pattern in the document that the server
enforces with different code is a lie waiting to be told, and every rule a
regex says in this repository's applications a predicate says more legibly.

**`Text` quoting the text back, as `Within` does.** A password in a 422 body.

**`nilo_check` taking a Scope**, so a rule could ask the database. Then the
struct reaches a service, the rule cannot be run from a test without one,
and "already registered" and "too short" come out of one function that has
to be read to know which needs what. The handler's `must` is where the
first kind lives, and it costs nothing to keep it there.

**Bytes rather than code points for `min`/`max`.** Cheaper by a pass, and a
`minLength: 10` the server reads as ten bytes refuses `naïveté` at eight
characters while the document promised it would pass.

## Consequences

- `http/text.zig`: `nilo.Text(opts)`, `nilo.Email`, `nilo.Url`; `.of`,
  `.value`, `view`, `len`, `eql`, `blank`; `nilo_parse`, `nilo_expects`,
  `nilo_explain`, `nilo_text`, `nilo_openapi`, `jsonParse`.
- `http/convert.zig`: `nilo_explain` read beside `nilo_expects` when a type
  that parses itself refuses text; `tryConvert` stamps what `nilo_parse`
  built.
- `core/str.zig`: `Str.stampLike(value, like)`.
- `http/bound.zig`: `nilo.Rules(T)`; `hasCheck(T)`, refusing a `nilo_check`
  of the wrong shape; `Bound.from` running the check; `enforce(slot, T,
  value)` for the plain slots, called from `Ctx.form`, `Ctx.json` and the
  query reader; the wording shared through `Wording(slot, T)`.
- `http/openapi.zig`: `Schema.sized` for `minLength`/`maxLength`/`format`,
  read off `nilo_text`.
- `http/ctx.zig`: a plain JSON body's 400 for a field that parses itself
  reads `nilo_explain` too, so the password is not quoted there either.
- Five Refusals under `refusals/text_*` and `refusals/check_*`: bounds the
  wrong way round, a `Text` with no bound and no check, a check with no
  `said`, a default outside its own shape, a `nilo_check` that is not
  `fn (T, *Rules(T)) void`. `refusals` is 163.
- The roadmap loses *whether a rule like "this is an email address"
  belongs in this repository*. ADR 034's "what was rejected" is read with
  this ADR beside it.
