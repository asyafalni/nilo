//! Two `{}` and one argument: the second segment has nothing to fill it,
//! and the count is checked while compiling rather than answered with a
//! 404 from the far end.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{}/refunds/{}", .{"ch_1"}, .{}) catch {};
}
