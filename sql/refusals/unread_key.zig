//! A key the Row that names its table declares unread.
//!
//! A row is found and handed out by its key, so the Row reads it (item 102).

const sql = @import("nilo_sql");

const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .key = .code,
        .unread = .{ .code = []const u8 },
    };

    title: []const u8,
};

export fn refusal() void {
    _ = sql.findFor(Deal, []const u8);
}
