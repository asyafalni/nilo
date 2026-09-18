# snippets

The world every checked block in the guide, the reference and the README
compiles against ([ADR 0083](../adr/0083-the-guide-is-the-source-of-its-own-snippets.md)).
`zig build snippets` finds a fenced ```` ```zig ```` block with a marker on the
line above it, puts a prelude in front, and compiles the result. The block in
the page is the only copy; there is no file here that mirrors it.

`types.zig` is the prelude — a `User`, a `Db`, a `Form`, the running example
every page not about SQL shares — and `values.zig` is the request in flight a
block of statements needs without introducing it: the `c`, `db` and `form`.
`sql_types.zig` and `sql_values.zig` are the SQL guide's own, because that
page teaches tables and needs an `Order`, an `Item` and five more besides.

Two marker shapes:

- **`<!-- compiles -->`** — the block declares one or more functions. The
  step generates an `export fn` that takes the address of each one, which is
  what pulls a function's body into analysis: Zig never analyses an
  unreferenced function, so without this a passing check would mean the text
  parsed and nothing more.
- **`<!-- compiles: body -->`** — the block is a run of statements rather
  than a declaration. It gets `values.zig` as well, wrapped in a function of
  its own, so it goes through analysis regardless of what it declares.

## A block that only declares a type gets neither

Taking the address of a function forces Zig to analyse it. Nothing does the
same for a bare `const Row = struct { … };` — a container-level declaration
nobody references is never analysed at all, on a plain `zig build-obj` as
much as here. A `<!-- compiles -->` block that declares a Row and stops
compiles clean whatever it says: a `.references` pointing at a table no Row
in the block names, a `.key` naming a field that is not there — every one of
them passes, because nothing ever read the declaration that would have
caught it. Demonstrated rather than reasoned: exactly that mistake compiled
clean until a reference was added.

**So a block that declares a type whose comptime checks matter ends with a
`comptime` block naming it.** Not a rule the extractor enforces — a
convention, the same way marking a block `<!-- compiles -->` in the first
place is a decision somebody makes rather than one a walker guesses.

```zig
const Member = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
};

comptime {
    _ = Member;
}
```

One line, and it is enough: referencing `Member` forces Zig to resolve it as
a type, which is what pulls its declarations — `nilo_table` included — into
analysis. A block declaring several Rows names each: `comptime { _ = .{ Org,
Member }; }` reads the same and is one line rather than several.

Where the guide already exercises the type — a `fn list(db: *sql.Db, …)
![]User` whose body calls `db.select(User, …)` — the function's own forcing
already does this, and no `comptime` block is needed beside it. It is only
the block that declares and stops that wants one.

A stricter version is possible and costs a design of its own: have the
extractor append a reference to every `pub` declaration it finds, which
would check every block of this shape whether or not its author remembered.
Nobody has built it; the convention above is what stands until somebody
does.
