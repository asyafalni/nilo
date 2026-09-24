//! A versioned answer under a `Cached`: the kept answer is replayed as it
//! was kept, so a 304 decided for the first client would be sent to every
//! client after it, whether they hold the version or not
//! ([ADR 189](../docs/adr/189-a-version-a-handler-names-is-an-etag.md)).

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

const Order = struct { id: u32, total: i64 };

fn list(p: nilo.Cached(Pages, .{ .ttl_s = 60 })) nilo.Versioned([]const Order) {
    _ = p;
    return .{ .version = 1, .value = &.{} };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orders", list) catch {};
}
