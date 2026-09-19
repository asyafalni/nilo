//! A `{` with no `}` after it is a segment the template never finishes,
//! and sending it as text would put a brace on the wire.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{id", .{ .id = 1 }, .{}) catch {};
}
