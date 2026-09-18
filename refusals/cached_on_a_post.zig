//! A `Cached` on a POST. A kept answer is served to whoever asks next, and
//! the second client's request was not the first client's ([ADR 0247](../docs/adr/0247-a-route-can-say-cache-this-answer-for-a-minute.md)).

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

const NewOrder = struct { sku: nilo.Str };

fn place(p: nilo.Cached(Pages, .{ .ttl_s = 60 }), incoming: NewOrder) u32 {
    _ = p;
    return @intCast(incoming.sku.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", place) catch {};
}
