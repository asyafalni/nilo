# 0256 — a form list is a repeated name, and nothing else

**Status:** accepted
**Extends:** [ADR 0164](./0164-a-query-parameter-that-is-a-list.md), whose
list field the form slot now has too, under one rule of that ADR's four
turned the other way.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0031](./0031-a-form-is-the-body-read-by-another-rule.md),
[ADR 0036](./0036-a-binding-hands-its-failures-to-the-handler.md).

## Context

A query parameter has been able to bind to a list since ADR 0164. A
checkbox group or a `<select multiple>` into a `Form(T)` was still a compile
error naming the field, though the data was already there: `parseMultipart`
keeps every occurrence in order, `parseQuery` does the same for a
urlencoded body, and `Fields.find` deliberately answers the first so a
repeated name would not silently become the last. The roadmap held the
entry at *waiting on a design* for the separator — the one place this stops
being the query case one slot over.

## Decision

**A `Form(T)` field that is a slice of anything a form value can become is
a list, filled from every value sent under its name, in the order sent.
There is one spelling, the repeated name, and a comma is data.**

```zig
const NewPost = struct {
    title: Str,
    tags: []const Str = &.{},
    notify: []const Kind = &.{},
};
```

ADR 0164 read both spellings for a query — `?tag=a&tag=b` and `?tag=a,b` —
and wrote the comma into the document, because a query string is a wire
contract a generated client sends back and one value on a request line is
one thing to log. Neither reason reaches a form. A browser sends a group as
the same name once per value and never comma-joined, so there is no client
to keep in step with and no second spelling in the world to read; and the
document already describes a form array as `explode: true`, which is the
repeated name, so nilo has nothing to write. Splitting on a comma here
would turn `a,b` typed into one box into two tags, for no client that
exists.

The other three of ADR 0164's rules carry over as they stand, because they
are about a list and not about a separator:

- **Absent is the empty list**, never a 400. A group with nothing ticked
  sends no name at all, and that is what every filter and every opt-in
  already means by not being sent. A list field is therefore never
  *missing*, and wants `= &.{}` so the document says it is optional.
- **An empty value contributes nothing.** An unticked box is never sent; an
  empty text box is sent empty; a row of inputs sharing a name with two left
  blank is a list of the ones filled in, the way `?tag=` is an empty list.
- **The element converts exactly as a single field would**, so `[]const
  Kind` refuses `notify=nonsense` with the sentence a single `notify` gets,
  and under `Bound(Form(T))` the **first** bad value is the one reported
  while the rest of the list is still read.

**A list of `Upload` is a Refusal.** `<input type="file" multiple>` is the
one somebody will reach for, and it is refused by name rather than read as
text: an `Upload` is a part rather than a value, and a field takes one.
Reading several is a design of its own — how many, how big together — and
is not this entry.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** one, on a form that asked for a list and on
  no other, for the slice of elements, sized by a first pass over the
  parsed fields. The elements point into the parsed body, which lives as
  long as the request. `test "the request path stays inside its allocation
  budget"` covers no form and is unmoved.
- **Memory per idle connection:** unchanged.
- **Throughput:** a form with a list field walks its fields once more per
  list field, which is the count, and a form without one does not.
- **Binary size:** two collectors instantiated per list element type a
  program names.

## Alternatives

**Both spellings, as the query reads them.** Rejected above: the comma is
a contract for a client that does not exist here, and it costs the value
with a comma in it.

**A separator the caller chooses.** The knob ADR 0164 refused for the query,
refused again for the same reason — two invisible settings on the axis that
decides whether a filter silently drops rows.

**Reading the list in `typed.zig` beside the query one.** The query
collectors read `c.queries()`, and a form's values are in the `Fields` the
body parser produced, so the collectors sit in `form.zig` beside `fill` and
`fillCollecting`, which is the one place that knows both the parsed body and
the slot's conversion rules.

## Consequences

- `Fields.count`, `collectList` and `collectListCollecting` in
  `http/form.zig`; `fill` and `fillCollecting` take the arena.
- `checkFields` accepts a slice of a convertible element and refuses a list
  of `Upload` or of an optional; `refusals/form_list_element_cannot_convert`.
- `Bound(Form(T))` needed nothing: `convertsAs` already read the element of
  a list for the query, and the slot is what wording it picks.
- The roadmap loses "A form field cannot bind to a list".
