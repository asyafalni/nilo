//! A route bound to a listener the 32-bit word cannot hold. A server may
//! answer on more addresses than that, but a route is bound to 0 to 31
//! (ADR 252).

const nilo = @import("nilo_http");

fn ok(c: *nilo.Ctx) !void {
    try c.sendText(200, "ok");
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.onListener(&.{32}).get("/x", ok) catch {};
}
