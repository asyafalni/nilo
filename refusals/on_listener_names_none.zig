//! A route bound to no listener at all, which would be a route nothing
//! answers. `onListener` refuses an empty list while compiling (ADR 252).

const nilo = @import("nilo_http");

fn ok(c: *nilo.Ctx) !void {
    try c.sendText(200, "ok");
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.onListener(&.{}).get("/x", ok) catch {};
}
