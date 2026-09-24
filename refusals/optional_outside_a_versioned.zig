//! `?Versioned(T)`: a thing that is not there has no version, which is the
//! reason `Versioned(?T)` is refused (ADR 189), and the `?` outside the
//! wrapper is the same mistake one level up
//! ([ADR 203](../docs/adr/203-a-question-mark-goes-inside-the-wrapper.md)).

const nilo = @import("nilo_http");

const Order = struct { id: u32, total: i64 };

fn show(id: u32) ?nilo.Versioned(Order) {
    if (id == 0) return null;
    return .{ .version = id, .value = .{ .id = id, .total = 0 } };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orders/:id", show) catch {};
}
