//! A `Cached` with a `ttl_s` of 0 — an answer kept for no time, which is
//! a handler that runs every time ([ADR 188](../docs/adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)).

const nilo = @import("nilo_http");

const Pages = struct {
    pub const Held = [512]u8;
    pub const max_bytes: usize = 512;
    pub fn getInto(_: *Pages, _: []const u8, _: []u8) ?[]const u8 {
        unreachable;
    }
    pub fn putIfAbsent(_: *Pages, _: []const u8, _: []const u8) error{TooLarge}!bool {
        unreachable;
    }
    pub fn putFor(_: *Pages, _: []const u8, _: []const u8, _: u32) error{TooLarge}!void {
        unreachable;
    }
    pub fn del(_: *Pages, _: []const u8) bool {
        unreachable;
    }
};

fn page(p: nilo.Cached(Pages, .{ .ttl_s = 0 })) u32 {
    return @intCast(p.key.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/pages", page) catch {};
}
