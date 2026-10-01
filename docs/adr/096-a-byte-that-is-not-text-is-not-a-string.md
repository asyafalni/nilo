# A byte that is not text is not a string

**Status:** accepted
**Topic:** [json](../design/json.md)

A `[]const u8` holding `\xff` went out as `"\xff"` — inside quotes, escaped for
nothing, and not valid JSON. Whoever asked for it could not parse the response.

`json.zig`'s header makes one promise: **the output is byte-for-byte what
`std.json` would have written, except for a float** (the exception is the last
section, which owns it). This was the last place where that was untrue.
`std.json` asks `utf8ValidateSlice` before it writes a string and falls back to
an array of byte values when the answer is no; nilo asked nothing and wrote the
bytes.

**nilo now asks the same question, with the same function, and writes the same
array.**

```zig
{ .name = "\xff" }   // was {"name":"<ff>"}   now {"name":[255]}
```

## Why matching `std.json` is the whole decision

Three answers were on the table and only one of them is small.

**Refusing the type is not available.** `[]const u8` is the ordinary spelling of
text in Zig, and a handler returning a name out of a database has no way to
promise it is UTF-8.

**Refusing the value at run time** — a 500 on a body that is not text — is a
server deciding that a row with a stray byte in it may not be served at all.
That is a bigger claim than this layer is entitled to make, and it turns a
cosmetic problem into an outage.

**Writing what `std.json` writes** costs one question per string and keeps the
contract that makes this file's tests possible: `expectSame` runs both writers
over the same value and compares the bytes, so a case nobody thought of is
caught by the comparison rather than by somebody's judgement. Adding
`"\xff"` to those tests was the fix's own proof.

The document still says `string` for such a field, which is what `std.json`
leaves unsaid too. A type that is `[]const u8` is text as far as a schema is
concerned; a *value* that is not text is a run-time fact no schema describes.

## What it costs, and the case that costs the most

`std.unicode.utf8ValidateSlice` has a vector fast path that clears 32 bytes of
ASCII at a time and stops at the first byte over `0x7f`; the rest is walked a
byte at a time by the decoder. So the cost is not a function of the string's
length. **It is a function of where the first non-ASCII byte falls.**

Measured on this machine, `-OReleaseFast`, pinned to one core, best of 25
rounds of 200,000 calls, `std.unicode.utf8ValidateSlice` alone:

| what | bytes | ns |
|---|---:|---:|
| the primary metric's payload, ASCII | 365 | **10** |
| a short field value, ASCII | 9 | 5 |
| one `é` halfway through | 1,024 | 278 |
| one `é` near the front | 1,024 | 704 |
| every character non-ASCII | 1,024 | 2,404 |

Against the 126ns the whole write of that payload costs
([`bench/result/http.md`](../../bench/result/http.md)), the ASCII row is **+8%**
of the write and it is the row almost every response is.

**The best-of-five version of this table was wrong by 3–4× and it was wrong in
the direction that would have changed the decision.** It read 38ns for the
ASCII payload and 6,585ns for the non-ASCII one — an ASCII cost of 30% of the
write rather than 8%, which is the difference between "ship it" and "this needs
a vectorised validator first". Twenty-five rounds and three interleaved runs put
the last two within 1% of each other. The box had three of the author's own
builds on it during the first attempt, which is the whole explanation.

**The non-ASCII rows are the finding worth writing down.** A response whose text
is Japanese, Arabic or emoji-heavy pays the scalar decoder for everything after
its first non-ASCII byte, and at a kilobyte that is 19× the whole rest of the
write. `std.json` has always paid it, so nilo is not slower than the thing it
replaces — but nilo is *eight times faster* than `std.json` on ASCII and would
be much closer to it on CJK text, which is a different claim from the one this
file's header makes.

That is now a roadmap entry with a number behind it: a vectorised UTF-8
validator is the lever, and nobody has needed it yet. Shipping this without one
is the trade this ADR makes, and it is made in favour of being correct today
rather than fast on a payload nobody here has.

## Where the check lives

At the two call sites in `writeValue` that hand a run of bytes to a string
writer — a `Str` and a `[]const u8` — and not inside `writeString`.

`writeString` is also what the logger escapes with, and a log line is not a
JSON document being handed to a parser that will reject it. Putting the check
where the *value* is decided keeps the cost off it.

A non-exhaustive enum does not reach `writeString` either. Its named values
are literals settled while compiling, as an exhaustive enum's are, and a value
no field names is written as its number: `@tagName` on one is a panic, and
std.json reads `{"kind":7}` into exactly that.

## A float that is not a number is `null`

The same file's other promise, that the output is JSON, was broken by a float
too, and a float is also where the first promise stops holding (the next
section). `std.json` writes infinity as the bare word `inf`, which is not JSON at
all, and NaN as the string `"nan"`, which is JSON that is not a number. The
generated writer now writes `null` for both, for a `f16`, `f32` or `f64`
anywhere in a covered value.

Three answers were on the table, and the same argument as for a stray byte
picks one. **An error** would be a server deciding that a row with an infinity
in it may not be served at all, which turns a cosmetic problem into an outage;
and the only error a writer has is a write failure, which a connection treats
as a dead socket. **Writing what `std.json` writes** is the position this
replaces: the output cannot be parsed. **`null`** is what a browser's own
`JSON.stringify` makes of both, parses everywhere, and is a value the reader
of a `?f64` already has to handle.

It costs one `isFinite` per float, and the rule holds on **every** path out
of `http/`. A type `covers` does not recognise (a tuple, an untagged-looking
shape, a `std.json.Value`, a map, a type with its own `jsonStringify`, one
nested past eight) is written by `FiniteJson` in `json.zig`, a wrapper around
`std.json.Stringify` that walks the same shapes, writes the same bytes, and
asks every float it passes. A `jsonStringify(self, jw: anytype)` is handed the
wrapper, so a float it writes through `jw.write` is covered too, which is how
`std.json.Value` and `ArrayHashMap` are. **A `jsonStringify` that names
`*std.json.Stringify` as its parameter is the author's own** and keeps `std.json`'s
spelling of what it writes; the guard is not reachable through a type the
author fixed.

*Rejected: leaving the fallback as `std.json`'s whole value* ("nothing in
`std.json` can be told otherwise" was true of `Stringify.value`, and false of a
writer that stands in for `jw`): a response that took the fallback by one
unrecognised field in a thousand could send `inf`.

*What moved it: the audit of `http/` at `39896d2`, which found
`{"p":inf}` coming back out of a number a request had sent in
([ADR 084](./084-a-number-in-a-request-is-not-a-zig-literal.md)).*

## A float is spelled the way serde_json spells it

The first promise above no longer covers a float. **nilo writes every `f64` and
`f32` the way serde_json 1.0.150 does** (its `zmij` formatter), on the
generated writer and on every fallback path alike (`std.json.Value` floats,
maps, tuples, nested values, a `jsonStringify(self, jw: anytype)`), through
`nilo.writeJson` and `nilo.jsonAlloc` as much as through a response. The digits
are the shortest that read back as the same bits, as before; the layout around
them is serde's:

- a decimal exponent from -5 to 15 is written positionally, and an integral
  value keeps its `.0`;
- outside that, scientific with an explicit sign;
- infinity and NaN are `null`, as the section above decided;
- an `f32` uses its own shortest digits and serde's `f32` range, -6 to 12.

```zig
.{ .rate = 0.0 }        // was {"rate":0}                 now {"rate":0.0}
.{ .n = 1e15 }          // was {"n":1000000000000000}     now {"n":1000000000000000.0}
.{ .n = 1e16 }          // was {"n":10000000000000000}    now {"n":1e+16}
.{ .n = 1e-7 }          // was {"n":0.0000001}            now {"n":1e-7}
.{ .n = f64_max }       // was 309 digits                 now {"n":1.7976931348623157e+308}
.{ .n = @as(f32, 1.1) } // was {"n":1.100000023841858}    now {"n":1.1}
```

What does not change: `0.1`, `12.5`, `0.4527777777777778` and every value that
had a fraction and a moderate exponent are the same bytes. A body is read as
it was: `1` still fills an `f64`.

**Why this rule, and not `std.json`'s or JavaScript's.** `std.json` writes a
float by printing it positionally at any size: `f64::MAX` is 309 digits and
`5e-324` is 320 characters, an unbounded amount of bloat on the response path
for a value one `null` or one exponent would carry, and `1.0` is `1`, which a
typed client cannot tell from an integer. JavaScript's rule has the same
`1`. serde's has the three properties wanted together: bounded (the longest
`f64` is 24 bytes, an `f32` 17), a float stays a float on the wire, and it is
what the first large program written for nilo needs. **photon** is a Rust
observability platform being ported, and its UI and its diff tests were
recorded off serde_json: a recorded `/api/services/overview` of 28,749 bytes
differed at byte 19 (`"apdex":1` for `1.0`) the moment one service had no
errors, and 14 of 26 edge floats differed, all of them in this one respect.
Matching serde makes a migration comparable byte for byte instead of by a
parser's judgement. The fixtures are the test (`http/jsonfloat.zig`): the 24
finite values serde_json 1.0.150 printed, byte for byte, and a round trip of
300,000 random `f64` and `f32` bit patterns and every `f16`, in both modes.

**What it costs.** No allocation: the digits come from `std.fmt.float`'s Ryu
(`binaryToDecimal`, the routine `{e}` runs) and are laid out in a stack buffer
of `maxLen(T)` bytes, 24 for an `f64` and 17 for an `f32`. A whole number
below 2^53 (2^24 for an `f32`) is its own digits and skips Ryu. Against the
`std.json` path it replaces, `bench/json_float.zig`, interleaved and pinned to
one core of the Ryzen 7 9700X, ReleaseFast: short values (`0.0`, `1.0`, `12.5`)
31 to 14 ns a float, values with 17 digits 25 to 24 ns, random bit patterns
57 to 36 ns ([`bench/result/http.md`](../../bench/result/http.md)). A server
that writes a float is 8,864 bytes smaller stripped (`hello` with one `f64` and
one `f32` field, 1,029,584 to 1,020,720), because the decimal-formatting code
`print("{}")` brought is no longer linked; one that writes none is unchanged
(`rest`, 1,208,280 both). The request-path allocation budget holds.

**It is serde_json's spelling at one version, not a standard.** serde_json
moved from `ryu` to `zmij` and the exponent changed (`1e16` became `1e+16`);
"identical to Rust" means this crate version, which is why the version is in
the test's header and the number of fixtures is in its name. A type with its
own `jsonStringify(self, jw: *std.json.Stringify)` keeps `std.json`'s spelling
of the floats it writes: the author fixed the parameter, and the hook is not
reachable through it. A `jsonb` column's stored text is written by `nilo_sql`
through `std.json`, which cannot name this file (a module imports downward
only), and is not a response.

### What was rejected

**Leaving a float to `std.json`**, which is what this ADR and `json.zig`'s
header said until now (*how it chooses between `12.5` and `1.25e1` is not worth
copying*). It was a fair position while no program cared which spelling went
out. What moved it is the evidence above: a response path that writes 320
characters for `5e-324`, and the first real port failing its byte-for-byte
comparison on its commonest value.

**A float type of the caller's own** (`SerdeF64 { v: f64 }` with a
`jsonStringify`), which photon's spike proved works and which needs no change
in nilo. It makes every float field of every response type a different type,
and the generated document then says what `jsonStringify` types say, `{}` or a
guess, rather than `number`.

**An option that picks the spelling.** Two spellings in one program is a
response that depends on which handler wrote it, and the option is one more
thing a test has to name.

**JavaScript's rule**, positional up to 21 digits. It is `1` for `1.0`, so it
fails the same test on the same value.
