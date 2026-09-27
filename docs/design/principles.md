# nilo's design principles

**A feature ships only after its cost on all four of ADR 017's axes is written down, and after nilo has said which framework's idea it borrows and which one it refuses to copy.**

**Guide:** none · **Reference:** none

The day-to-day summary is "Invariants that are load-bearing" in CLAUDE.md; the running total of what every feature has cost is in ADR 017 itself; the benchmark runs behind each number are in `bench/result/`; lessons that did not fit an ADR are in `docs/history.md`. Code that enforces this rather than just stating it: `http/app.zig` (`checkName`'s `@setEvalBranchQuota`), `http/typed.zig` (`operation`'s), `sql/row.zig` (`distance`'s), and `refusals/README.md` for the build step that holds each error message to its exact wording.

## Overview

There is no flow to draw here: this topic is one core decision and three that apply it. **ADR 017 is the core.** Version 1 had a single rule (developer comfort wins if it costs less than 10%), but that turned out to be measuring four numbers that do not recover in the same way. So each now has its own rule and its own check. Throughput and p99 stay a percentage, measured on a real machine. Allocations per request and memory per idle connection are hard limits, held by a test and a measurement. Binary size is disclosed and added up rather than budgeted. ADR 014 says where the design above that budget comes from, naming a predecessor for each borrowed idea and refusing others by name. ADR 126 and ADR 136 apply the budget: 126 to what a compile-time check may cost a caller who never asked for it, and 136 to why a check that would only catch part of a widespread mistake is rejected instead of shipped as half a fix.

## Rules

1. **Performance is four numbers, not one percentage, and each is protected according to how hard it is to win back.** [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
2. **Throughput and p99 may lose up to 10% for a nicer API**, measured on a real machine: HttpArena's independent leaderboard, and `bench/`'s own scripts pinned to physical cores. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
3. **Allocations per request are a hard limit.** A developer-experience feature may not add an allocation to a path that did not ask for it. The test that the request path stays inside its allocation budget enforces this. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
4. **Memory per idle connection is a hard limit**, 4,669 bytes as of [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md), and it is a minimum, not a total: a feature that adds to it states the number in the ADR that introduces it. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
5. **A feature the linker cannot remove states its stripped `ReleaseFast` size cost**, added to the running total in ADR 017. No feature may add size unconditionally to the *request path* or *per connection*; only a disclosed unconditional total is allowed. [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)
6. **Every design idea names the framework it was borrowed from.** Typed handlers and the generated OpenAPI document follow FastAPI's rule that the signature is the only source of truth. Resolved values and groups follow Elysia: a value is declared, not stored in a locals map. The request arena and per-request budget follow nginx's pool-and-drop and TigerBeetle's allocate-once-then-stop. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
7. **Convention over configuration, runtime dependency injection, reflection and batteries-included are refused by name**, not just left unbuilt. For nilo's users, each looks like a framework hiding something, and all of it is paid for at run time. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
8. **A compile-time error must say in words what is wrong, at the first place a person wrote the thing, and say how to fix it, or it does not ship.** The standard is Elm's and Rust's. The failure mode refused by name is axum's wall of extractor trait errors. [ADR 014](../adr/014-what-nilo-borrows-and-from-whom.md)
9. **A compile-time check's cost counts against the caller's whole compile-time evaluation, not just the one call site**, because `@setEvalBranchQuota` raises a limit on the caller's evaluation and a later, smaller value never lowers it. A framework that uses part of that budget raises it itself, generously rather than exactly, so its own walk is never what runs out. [ADR 126](../adr/126-a-check-pays-for-its-own-branches.md)
10. **A compile-time check for one instance of a widespread mistake is rejected if it only catches part of it.** A check that catches some cases makes the problem look solved, and stops anyone looking at the rest of the code where the same mistake still goes unnoticed. [ADR 136](../adr/136-an-escape-hatch-that-costs-nothing-teaches-nothing.md)

## Decisions

| ADR | What it decides |
|---|---|
| [014](../adr/014-what-nilo-borrows-and-from-whom.md) | Which framework each design idea is borrowed from, and which patterns are refused by name |
| [017](../adr/017-the-trade-budget-has-four-axes.md) | The four performance axes, which recover differently, and the running total every feature adds to |
| [126](../adr/126-a-check-pays-for-its-own-branches.md) | A compile-time check's cost is the caller's whole evaluation, and the framework raises its own quota |
| [136](../adr/136-an-escape-hatch-that-costs-nothing-teaches-nothing.md) | Why a narrow compile check on `db.raw` was rejected instead of shipped |

Related topics: the 4,669-byte idle-connection minimum in rule 4 is decided in [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md); resolved values, built as ADR 014 describes, are specified in [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md); the `c.locals` map ADR 014 refuses by name was first refused in [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md); the generated OpenAPI document ADR 014 credits to FastAPI is specified in [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md); the `operationId` walk whose quota ADR 126 fixed is named in [ADR 119](../adr/119-a-route-can-say-its-own-name.md); the cheap `.projection` that ADR 136 found teaches nothing is [ADR 125](../adr/125-a-row-that-owns-no-table.md), and the raw-statement rule it weighs against a compile check is [ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md).

## Open questions

**What would change ADR 136's answer** is written in the ADR itself: a pattern that is always wrong, not just almost always, in a place that is not one module's escape hatch. If one turns up, it gets its own refusal and this ADR is revised. So far nothing has been always wrong.
