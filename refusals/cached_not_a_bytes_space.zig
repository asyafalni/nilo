//! A `Cached` that names something other than a bytes Space as where
//! answers are kept ([ADR 0247](../docs/adr/0247-a-route-can-say-cache-this-answer-for-a-minute.md)).

const nilo = @import("nilo_http");

fn page(p: nilo.Cached(u32, .{ .ttl_s = 60 })) u32 {
    return @intCast(p.key.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/pages", page) catch {};
}
