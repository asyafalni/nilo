//! A `nilo_beside` naming a field the Row does not have.
//!
//! A typo here would otherwise be a marker that quietly names nothing, and
//! the field it meant would be read as a column (ADR 0217).

const sql = @import("nilo_sql");

const Comment = struct {
    pub const nilo_table = .{ .name = "comments", .key = .id };
    pub const nilo_beside = .{.attachment};

    id: i64,
    body: []const u8,
    attachments: []const i64 = &.{},
};

export fn refusal() void {
    _ = sql.selectFor(Comment, @TypeOf(.{}));
}
