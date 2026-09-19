//! A template fills its segments one way — `{}` by position from a tuple,
//! or `{name}` by field from a struct — and one that does both has no
//! arguments that fit it.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/{}/refunds/{id}", .{ .id = 1 }, .{}) catch {};
}
