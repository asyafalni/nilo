//! An `.exists` between two tables that point at each other.
//!
//! `staff.department_id` points at `departments`, and `departments.head_id`
//! points back at `staff`. Asking from `staff` whether a department matches
//! could mean "my department" or "the department I head", and the two answer
//! different questions with the same shape. `.on` names the inner column and
//! `.via` the outer one, so saying which is one word (ADR 175).

const sql = @import("nilo_sql");

const Staff = struct {
    pub const nilo_table = .{
        .name = "staff",
        .key = .id,
        .references = .{ .department_id = .{ Department, .id } },
    };

    id: i64,
    department_id: i64,
};

const Department = struct {
    pub const nilo_table = .{
        .name = "departments",
        .key = .id,
        .references = .{ .head_id = .{ Staff, .id } },
    };

    id: i64,
    head_id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Department, .where = .{ .name = @as([]const u8, "vision") } },
    } } }));
}
