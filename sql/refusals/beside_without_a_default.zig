//! A field beside the columns with no default.
//!
//! No statement fills it, so a read has to leave it at something — and a
//! Row with an undefined field in it is the failure ADR 0008 says nilo cannot
//! recover from, found by whoever reads the field first (ADR 0217).

const sql = @import("nilo_sql");

const Comment = struct {
    pub const nilo_table = .{ .name = "comments", .key = .id };
    pub const nilo_beside = .{.attachments};

    id: i64,
    body: []const u8,
    attachments: []const i64,
};

export fn refusal() void {
    _ = sql.selectFor(Comment, @TypeOf(.{}));
}
