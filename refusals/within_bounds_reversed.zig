//! `Within(max, min)`: a range nothing is inside. Refused where it is written
//! rather than answering 400 to every request
//! ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).

const nilo = @import("nilo_http");

const Query = struct {
    limit: nilo.Within(200, 1),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Query);
}
