//! `Versioned(?T)` would give `null` two meanings — the 404 a `?T` means
//! everywhere else, and the "you already hold it" a versioned answer says
//! with a null value — and nilo refuses to pick
//! ([ADR 189](../docs/adr/189-a-version-a-handler-names-is-an-etag.md)).

const nilo = @import("nilo_http");

const Order = struct { id: u32, total: i64 };

fn show(id: u32) nilo.Versioned(?Order) {
    return .{ .version = id, .value = null };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orders/:id", show) catch {};
}
