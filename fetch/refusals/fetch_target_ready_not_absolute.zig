//! The ready path is a path like any other the target sends, and hangs off
//! the base the same way, so it has to begin with `/`.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Api = fetch.Target("api", .{ .ready = "status" });
    var client: fetch.Client = undefined;
    _ = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
