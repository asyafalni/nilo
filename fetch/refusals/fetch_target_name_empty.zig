//! A target's name is what the health route and a log line call it, so an
//! empty one is a target nothing can name.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Nameless = fetch.Target("", .{});
    var client: fetch.Client = undefined;
    _ = Nameless.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
