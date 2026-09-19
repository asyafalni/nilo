//! The arguments fill the template's segments, a tuple by position or a
//! struct by name; a bare value is neither.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{}", 42, .{}) catch {};
}
