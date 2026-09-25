//! The Ctx carried into the loop inside the state. The loop runs once the
//! handler has returned, so the pointer is to a frame that has gone and a
//! request that is over, and the loop would read the next request's memory.

const nilo = @import("nilo_http");

const Seat = struct {
    joined_at: i64,
    c: *nilo.Ctx,
};

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, Seat{ .joined_at = 0, .c = c });
}

fn chatLoop(socket: *nilo.Socket, seat: Seat) !void {
    _ = seat;
    _ = socket;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
