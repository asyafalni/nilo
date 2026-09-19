//! A template that fills by position is given a tuple; a struct's fields
//! would have to be matched to `{}` by declaration order, which is a rule
//! nobody would remember.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{}", .{ .id = "ch_1" }, .{}) catch {};
}
