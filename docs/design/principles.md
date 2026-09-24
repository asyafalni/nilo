# nilo's design principles

**A feature ships only after its cost against all four of ADR 017's axes is written down, and only after nilo has said which framework's move it is borrowing and which one it refuses to imitate.** The day-to-day summary is CLAUDE.md's "Invariants that are load-bearing"; the running total of what every feature has cost is ADR 017 itself; the runs behind a number are `bench/result/`; the lessons that did not fit an ADR are `docs/history.md`. Code that enforces this rather than stating it: `http/app.zig` (`checkName`'s `@setEvalBranchQuota`), `http/typed.zig` (`operation`'s), `sql/row.zig` (`distance`'s), and `refusals/README.md` for the build step that holds an error message to its wording.

## How the pieces fit

This topic has no flow to draw: it is a spine and three applications of it. **ADR 017 is the spine.** v1's single rule, comfort wins under 10%, turned out to be measuring four numbers that do not recover the same way, so each now has its own rule and its own place it is held: throughput and p99 stay a percentage, checked against a real machine; allocations per request and memory per idle connection are hard invariants a test and a measurement hold; binary size is disclosed and totalled rather than budgeted. ADR 014 says where the architecture above that budget comes from, naming a predecessor for each borrowed move and refusing others by name. ADR 126 and ADR 136 are the budget enforced downward: 126 into what a comptime check may cost a caller who never asked for it, 136 into why a check that would only catch part of a cross-cutting mistake is refused rather than shipped as half a fix.

## The rule in force

1. **Performance is four numbers, not one percentage, and each is held the way its own recovery cost demands.** [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
2. **Throughput and p99 may lose up to 10% for a nicer API**, measured against a real machine: HttpArena's independent board and `bench/`'s own scripts pinned to physical cores. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
3. **Allocations per request are a hard invariant.** A DX feature may not add one to a path that did not ask for it, held by the test that the request path stays inside its allocation budget. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
4. **Memory per idle connection is a hard invariant**, 4,669 bytes as of [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md), and a floor rather than a total: a feature that adds to it states the number in the ADR that introduces it. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
5. **A feature the linker cannot drop states its stripped `ReleaseFast` cost**, added to the running total in ADR 017; no feature may cost unconditional *request-path* or *per-connection* size, only a disclosed unconditional total. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
6. **Every architectural move names the framework it was borrowed from.** Typed handlers and the generated OpenAPI document follow FastAPI's rule that the signature is the only source of truth; resolved values and groups follow Elysia's answer that a value is declared, not stashed in a locals map; the request arena and per-request budget follow nginx's pool-and-drop and TigerBeetle's allocate-once-then-stop. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
7. **Convention-over-configuration, runtime dependency injection, reflection and batteries-included are refused by name**, not merely left unbuilt, because for this audience each reads as a framework hiding something and every gram of it is paid at runtime. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
8. **A compile-time failure says what is wrong in words at the first frame a human named the thing, and says the fix, or it does not ship.** The standard is Elm's and Rust's; the failure mode refused by name is axum's wall of extractor trait errors. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
9. **A comptime check's cost is charged against the caller's whole comptime evaluation, not the one call site**, because `@setEvalBranchQuota` raises a ceiling on the caller's evaluation and a later, smaller value never lowers it. A framework that spends part of that budget raises it itself, generously rather than exactly, so its own walk is never what runs out. [ADR 126](../adr/126-a-check-pays-for-its-own-branches.md)
10. **A compile-time check on one instance of a cross-cutting mistake is refused if it only catches a fraction of it.** A check that lands makes the problem look solved and stops anyone looking at the rest of the surface where the same mistake is still free. [ADR 136](../adr/136-an-escape-hatch-that-costs-nothing-teaches-nothing.md)

## Decisions

| ADR | What it decides |
|---|---|
| [014](../adr/014-what-nilo-borrows-and-from-whom.md) | Which framework each architectural move is borrowed from, and which patterns are refused by name |
| [017](../adr/017-the-trade-budget-has-four-axes.md) | The four performance axes, which recover differently, and the running total every feature adds to |
| [126](../adr/126-a-check-pays-for-its-own-branches.md) | A comptime check's cost is the caller's whole evaluation, and the framework raises its own quota |
| [136](../adr/136-an-escape-hatch-that-costs-nothing-teaches-nothing.md) | Why a narrow compile check on `db.raw` was refused rather than shipped |

Beside this topic: the 4,669-byte idle-connection floor this page's rule 4 states is decided in [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md); resolved values, landed as ADR 014 describes, are specified in [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md); the `c.locals` map ADR 014 refuses by name was refused first in [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md); the generated OpenAPI document ADR 014 credits to FastAPI is specified in [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md); the `operationId` walk whose quota ADR 126 fixed is named in [ADR 119](../adr/119-a-route-can-say-its-own-name.md); the cheap `.projection` that ADR 136 found teaches nothing is [ADR 125](../adr/125-a-row-that-owns-no-table.md), and the raw-statement rule it weighs against a compile check is [ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md).

## Open

**What would change ADR 136's answer** is on the record in the ADR itself: a shape that is always wrong, rather than almost always, in a place that is not one module's escape hatch. If one turns up it gets a refusal of its own and this ADR is superseded; nothing so far has been always wrong.
