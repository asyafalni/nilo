//! An insert writing a field the Row carries beside its columns.
//!
//! The ordinary way to reach this is handing a whole Row back to `insert`
//! after filling the field, and the answer is the same as for a `.where`: no
//! column holds it, so nothing can be written to one (ADR 0217).

const sql = @import("nilo_sql");

const Attachment = struct { id: i64 };

const Comment = struct {
    pub const nilo_table = .{ .name = "comments", .key = .id };
    pub const nilo_beside = .{.attachments};

    id: i64,
    body: []const u8,
    attachments: []const Attachment = &.{},
};

export fn refusal() void {
    _ = sql.insertFor(Comment, @TypeOf(.{
        .body = @as([]const u8, "x"),
        .attachments = @as([]const Attachment, &.{}),
    }));
}
