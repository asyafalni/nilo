//! A `.where` naming a field the Row carries beside its columns.
//!
//! The field is on the Row and in no statement, so a condition on it would ask
//! the database for a column it has never had. Refused by name rather than
//! as "no such column", because the field is plainly there (ADR 178).

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
    _ = sql.selectFor(Comment, @TypeOf(.{ .where = .{ .attachments = @as([]const Attachment, &.{}) } }));
}
