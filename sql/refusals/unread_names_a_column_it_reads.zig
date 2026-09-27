//! `.unread` naming a column the Row also reads.
//!
//! A column is read into a field or declared unread, and saying both would
//! give it two types, one of which nothing checks (item 102).

const sql = @import("nilo_sql");

const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .unread = .{ .created_at = sql.Timestamp },
    };

    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = sql.selectFor(Deal, @TypeOf(.{}));
}
