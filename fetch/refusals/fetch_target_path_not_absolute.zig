//! A target's path hangs off its base, so one that does not begin with `/`
//! would join the base's last segment to its first: `https://api.example.com`
//! and `v1/charges` is `https://api.example.comv1/charges`.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "v1/charges", .{}, .{}) catch {};
}
