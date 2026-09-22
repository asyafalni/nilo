//! `?Status(201, T)`: the `?` around the wrapper rather than inside it. The
//! typed layer reads wrappers first and unwraps a `?` after them, so this
//! shape reached neither and the `Status` struct itself went out as JSON,
//! `headers` and all: a crash on the success path. The `?` is a 404 and
//! belongs on the body: `Status(201, ?T)`
//! ([ADR 0276](../docs/adr/0276-a-question-mark-goes-inside-the-wrapper.md)).

const nilo = @import("nilo_http");

const Receipt = struct { id: u32, paid: i64 };

fn pay(id: u32) !?nilo.Status(201, Receipt) {
    if (id == 0) return null;
    return .{ .value = .{ .id = id, .paid = 100 } };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/payments/:id", pay) catch {};
}
