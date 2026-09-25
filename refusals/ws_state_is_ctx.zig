//! `c.upgrade(loop, c)`: the Ctx itself as the state. It passes every check
//! on the loop's shape, and the pointer is to a request that is over by the
//! time the loop runs.

const nilo = @import("nilo_http");

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, c);
}

fn chatLoop(socket: *nilo.Socket, c: *nilo.Ctx) !void {
    _ = c;
    _ = socket;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
