//! An unread column that is not optional and that nothing fills.
//!
//! An insert of the Row cannot write a column the Row does not read, so the
//! table has to fill it: a `.default`, or `.filled` when the database does it
//! by a means the marker cannot say (item 102).

const sql = @import("nilo_sql");

const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .unread = .{ .created_at = sql.Timestamp },
    };

    id: i64,
    title: []const u8,
};

export fn refusal() void {
    _ = sql.insertFor(Deal, @TypeOf(.{ .title = "Borealis" }));
}
