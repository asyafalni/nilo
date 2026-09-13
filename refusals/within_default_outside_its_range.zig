//! A default a request could never have sent. The bound is checked on what
//! arrives, and a default never arrives — so it is checked here instead
//! ([ADR 0206](../docs/adr/0206-a-whole-number-inside-a-range-is-a-type.md)).

const nilo = @import("nilo_http");

const Query = struct {
    limit: nilo.Within(1, 200) = .of(500),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Query);
}
