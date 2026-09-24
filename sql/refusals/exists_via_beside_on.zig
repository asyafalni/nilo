//! An `.exists` that says both `.on` and `.via`.
//!
//! They are the two ends of one join — `.on` a column of the inner Row, `.via`
//! a column of the outer one — and a join has one key on one side. Both at
//! once is two joins, or one written twice, and either way it is not what the
//! caller meant (ADR 175).

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
    department_id: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .exists = .{
        .{
            .in = Department,
            .on = .id,
            .via = .department_id,
            .where = .{ .name = @as([]const u8, "vision") },
        },
    } } }));
}
