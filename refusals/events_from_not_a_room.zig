//! A service of the application's own passed where a Room goes. The stream
//! sits in rooms and nothing else, so what it was given is named back.

const nilo = @import("nilo_http");

const Inbox = struct { unread: u32 };

fn feed(c: *nilo.Ctx, inbox: *Inbox) !void {
    return c.eventsFrom(.{inbox}, .{});
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/feed", feed) catch {};
}
