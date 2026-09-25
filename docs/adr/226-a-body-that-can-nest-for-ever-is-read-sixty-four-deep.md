# A body whose type holds itself is read sixty-four levels deep

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)
**Applies:** [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (a fiber's stack is what a connection costs, and it has an end)

## Context

A JSON body is read by `std.json.parseFromSliceLeaky`, from `Ctx.json` and `Ctx.jsonCollecting`, which is every typed handler's body too. std reads a struct by calling itself once per field it descends into, and has no option that bounds how deep it goes: the bound is the fiber's stack.

For most types that is no bound worth having, because the type bounds it: a struct three levels deep is read three levels deep whatever the client sends, and anything deeper is an unknown field or a type mismatch. A type that holds itself is the exception. `struct { name: []const u8, c: []const Node }` is a comment tree, a menu, a filter expression, and a client decides how deep it goes. `{"c":[` twenty thousand times is 160 KB, inside the default `max_body`, and it was a segfault on an 8 MB fiber stack. A segfault is not a failed request: it ends every connection the process holds.

## Decision

**For a body type that can reach itself, a body nested more than 64 levels deep is a 400, and it is refused before the parse.**

- *Which types.* `nestsWithoutBound(T)` walks the type while compiling, through fields, union payloads, optionals, pointers, slices and arrays, and answers whether some type on the way reaches itself again. Only then is the body scanned. A type that cannot nest for ever pays nothing, not even the check: the answer is `comptime`.
- *How the depth is found.* One pass over the bytes counting `[` and `{` against `]` and `}`, stepping over strings and their escapes, stopping at the first level past the limit. Malformed JSON is the parser's to refuse; the scan only has to be right about JSON that is well formed.
- *Why 64.* A tree node is two levels (the object and the array of children), so 64 is a tree 32 deep, past anything a page shows or a person nests by hand. What it bounds is the stack the parse can touch, a few kilobytes rather than all of it, and a suspended fiber keeps what it touched ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)).
- *What the client reads.* `the body nests deeper than 64 levels, which is as deep as this endpoint reads`, as a 400 through the failure box like any other body refusal.

## What was rejected

- **A parse that counts as it goes.** std's `Scanner` knows the depth, and `innerParse` does not ask it. Parsing through a scanner of nilo's own means carrying a copy of std's struct and union parsing to get one comparison into it.
- **Scanning every body.** One pass over the bytes is cheap next to the parse, and it is still a pass over every body of every route for a failure only one shape of type can have. The comptime answer makes it free where it cannot matter.
- **Refusing a type that holds itself.** It would be the cheapest rule and the wrong one: a comment tree is an ordinary thing to post, and OpenAPI already describes such a type on purpose.
- **A bigger stack.** It moves the depth that crashes, and every connection pays for the pages.
- **An option on `listen()`.** Nothing has asked for a tree deeper than 32. A route that needs one reads `c.body()` and parses it itself; the constant is `max_json_nesting` in `http/ctx.zig` if a caller ever brings the case.

## Consequences

- **Allocations per request:** none added. **Memory per idle connection:** none added; the stack a request can touch is bounded where it was not. **Throughput:** nothing for a type that cannot nest; one pass over the body for one that can. **Binary size:** the scan, once per program that reads such a type.
- Test: `test "a body whose type holds itself is refused past the nesting it may have, before it is parsed"` in `http/behaviour.zig`, which also checks that a bracket inside a string is text.
- `std.json` still panics on a `u128` field posted as `2e38`, inside `@intFromFloat`. That is std's, and on [the roadmap](../roadmap.md) with the other numbers a body can reach.
