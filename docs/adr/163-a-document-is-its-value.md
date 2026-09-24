# A document is its value

**Status:** accepted
**Topic:** [json](../design/json.md)

[ADR 148](148-a-field-name-is-a-spelling-too.md) drew a line:
a type that writes its own JSON and says, with `nilo_openapi`, that what it
writes is one scalar is a **leaf** — `std.json` writes the value and the
generated writer keeps writing the object around it. A type that writes its
own JSON and says nothing is a wall, and the whole response goes to `std.json`,
which is where [ADR 148](148-a-field-name-is-a-spelling-too.md)'s refusal
of `rename_all` fires.

`sql.Json(T)` is on the wrong side of that line, and it was the last DTO in
the port:

```zig
pub const TimelineRow = struct {
    pub const nilo_table = .projection;
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: sql.Uuid,
    occurred_at: sql.Timestamp,
    payload: sql.Json(std.json.Value),
    …
};
```

```
error: nilo: `activity.rows.TimelineRow` renames its fields, and this value goes to `std.json`,
       which does not read the marker (ADR 148).
```

The refusal is right to fire. `Json(T)` writes itself and does not say it is
a scalar, because it is not one: `events.payload` is a `jsonb` document. So a
Row with a `jsonb` column on it could not rename its fields, and the one read
in the product that carries the event log to a screen kept a thirteen-field
DTO and the function that copies into it.

## It already says what it is

`Json(T)` carries `pub const nilo_json_of = T;` — that is how the schema check
and the Wire know what is inside — and its `jsonStringify` is one line,
`jw.write(self.value)`. That is a type saying *I am exactly a `T`*, in the
same sense a `Uuid` says *I am exactly a string*. For a writer it is the
stronger promise: a scalar is handed to `std.json` whole because nothing can
be walked inside it, while a `T` is a shape the generated writer can walk
itself — and honour a `rename_all` inside, which a scalar has nothing to
rename.

So a type declaring `nilo_json_of = Inner` beside `value: Inner` is a
**document**, and both readers of a type treat it as its value:

- **`json.write`** writes `value` — through the generated writer when
  `covers(Inner)`, and otherwise as a leaf handed to `std.json` whole, with
  the object around it still nilo's. `Json(std.json.Value)` is the second
  case: `std.json.Value` writes itself as one value, which is all the
  punctuation on either side needs to know.
- **`openapi.schemaWithin`** describes it as `Inner`. `Json(Theme)` sends a
  `Theme` and was documented as `{}` with a note; now it is the object. A
  document of a type that says nothing of itself — `std.json.Value` — is still
  `untold`, exactly as before.

What is still refused is a marker inside the value that `std.json` would not
read. A document whose value the writer cannot walk *and* which holds a
renamed struct is not covered, so the ordinary fallback refusal is what the
caller sees — ADR 148's rule applied one level down rather than relaxed.

## Why a second marker rather than widening the leaf rule

The leaf rule could have been widened to *any* `jsonStringify` — every one
writes one JSON value, or the output is broken regardless. It was not,
because the gate is not about punctuation: it is about what the type has
promised, and a type that says nothing has promised nothing about what is
inside. `nilo_openapi` names a scalar; `nilo_json_of` names a type. Both are
a promise the writer can check against, and a bare `jsonStringify` is
neither. The line ADR 148 drew stands; this adds the second thing a type
can say.

**The marker already existed.** `nilo_json_of` has been on `sql.Json` since
the type landed, read by `sql/` alone. Reading it in `http/` by name is what
every marker does (ADR 038: `http/` may not import `sql/`), so nothing about
`sql.Json` changed, and a type of the caller's own can be a document the same
way.

## One Refusal

A type that declares `nilo_json_of = Payload` and has no `value: Payload` —
the field under another name, or of another type — is refused by name with
both halves written out. A document is written as its `value`, so the field
has to be there and has to be that type; anything else is a promise the
writer cannot keep.

## Against ADR 017's four axes

- **Allocations per request: zero.** The document's value is written where
  the wrapper was; nothing is copied.
- **Memory per idle connection: zero.**
- **Throughput: a saving where it applies.** A response holding a `Json(T)`
  used to go to `std.json` whole — every string in it a byte at a time
  (`json.zig`'s header has the number). It is on the generated writer now.
  Not measured on its own; the shape is the one ADR 148 measured, 250 → 165ns
  on a row with three leaves.
- **Binary size: nothing** for a program with no document in a response.

## Consequences

- A Row with a `jsonb` column can carry `rename_all`, which closes the last
  DTO the port had.
- `Json(T)` is described in the document as a `T`. A client generated from
  the document gets the shape it was always sent and never told about.
- `jsonmark.documentOf` is the one reader of the marker; `json.zig` and
  `openapi.zig` both ask it, which is what keeps the writer and the
  description agreeing about what a document is.
