//! An `.exists` whose `.via` names a column the outer Row does not have.
//!
//! `.via` is a column of *this* Row, and a name it lacks is a typo — or the
//! inner column written on the wrong word, which `.on` is for (ADR 0214).

const sql = @import("nilo_sql");

const Department = struct {
    pub const nilo_table = .{ .name = "departments", .key = .id };

    id: i64,
    name: []const u8,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };

    id: i64,
    department_id: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Department, .via = .dept_id, .where = .{ .name = @as([]const u8, "vision") } },
    } } }));
}
