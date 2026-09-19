//! A template that names its segments is given a struct with those names,
//! so a tuple has nothing to match `{id}` to. The message says which name
//! to write.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{id}", .{"ch_1"}, .{}) catch {};
}
