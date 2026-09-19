//! A segment whose type no path can carry. A struct has no text form a
//! server would read, and an optional cannot be left out the way a query
//! param can, so the segment is refused by name.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const Api = fetch.Target("api", .{});
const When = struct { year: u16, month: u8 };

export fn refusal() void {
    var client: fetch.Client = undefined;
    var api = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
    var run: core.Run = undefined;
    const when: When = .{ .year = 2026, .month = 9 };
    _ = api.get(&run, "/v1/reports/{}", .{when}, .{}) catch {};
}
