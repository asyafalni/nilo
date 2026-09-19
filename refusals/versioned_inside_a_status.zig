//! A versioned answer inside a `Status` or a `Response`: the status is
//! already decided — 200, or 304 — and the headers are a field the versioned
//! type carries itself
//! ([ADR 0258](../docs/adr/0258-a-version-a-handler-names-is-an-etag.md)).

const nilo = @import("nilo_http");

const Order = struct { id: u32, total: i64 };

fn make() nilo.Status(201, nilo.Versioned(Order)) {
    return .{ .value = .{ .version = 1, .value = .{ .id = 1, .total = 0 } } };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", make) catch {};
}
