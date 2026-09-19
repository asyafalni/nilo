//! A `}` with no `{` before it is the other half of the same mistake.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/id}", .{}, .{}) catch {};
}
