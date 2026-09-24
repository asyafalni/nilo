//! An `Idempotent` that names something other than a bytes Space as where
//! answers are kept ([ADR 155](../docs/adr/155-a-request-answered-once-is-answered-the-same-way-again.md)).

const nilo = @import("nilo_http");

fn place(key: nilo.Idempotent(u32, .{})) u32 {
    return @intCast(key.key.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", place) catch {};
}
