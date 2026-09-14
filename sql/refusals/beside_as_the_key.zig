//! A key naming a field the Row carries beside its columns.
//!
//! A key is what a statement finds a row by, and a field in no statement
//! cannot be one (ADR 0217).

const sql = @import("nilo_sql");

const Comment = struct {
    pub const nilo_table = .{ .name = "comments", .key = .token };
    pub const nilo_beside = .{.token};

    id: i64,
    body: []const u8,
    token: []const u8 = "",
};

export fn refusal() void {
    _ = sql.findFor(Comment, @TypeOf(.{ .token = @as([]const u8, "x") }));
}
