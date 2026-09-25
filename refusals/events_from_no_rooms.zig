//! An event stream handed to its connection with no room to sit in. It could
//! only ever send keep-alive comments, so the empty tuple is a mistake rather
//! than a feed: most likely a room that was meant to be there.

const nilo = @import("nilo_http");

fn feed(c: *nilo.Ctx) !void {
    return c.eventsFrom(.{}, .{});
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/feed", feed) catch {};
}
