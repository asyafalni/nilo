//! `{id}` in the template and no `.id` in the struct: the segment has
//! nothing to fill it, and the field is named so the fix is one word.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    _ = api.get(&run, "/v1/charges/{id}", .{ .charge = "ch_1" }, .{}) catch {};
}
