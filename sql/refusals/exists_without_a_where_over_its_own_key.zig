//! An `.exists` with no `.where`, over the Row this one's own key points at.
//!
//! With the key on the inner Row, the entry asks whether any row points back,
//! and has no other spelling. With the key on this Row it asks only whether
//! the row it points at is there, which the key column says without a
//! subquery (item 107).

const sql = @import("nilo_sql");

const Department = struct {
    pub const nilo_table = .{ .name = "departments", .key = .id };

    id: i64,
    name: []const u8,
};

const Staff = struct {
    pub const nilo_table = .{
        .name = "staff",
        .key = .id,
        .references = .{ .department_id = .{ Department, .id } },
    };

    id: i64,
    department_id: ?i64,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .not_exists = .{.{ .in = Department }} } }));
}
