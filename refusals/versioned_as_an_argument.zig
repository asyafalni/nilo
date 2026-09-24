//! `nilo.Versioned(T)` is what a handler answers *with*. Read as the request
//! body — which is what a struct by value is — it would land inside
//! `std.json` being asked to parse a version and a body, which is a message
//! nilo did not write
//! ([ADR 189](../docs/adr/189-a-version-a-handler-names-is-an-etag.md)).

const nilo = @import("nilo_http");

fn take(v: nilo.Versioned(u32)) !void {
    _ = v;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", take) catch {};
}
