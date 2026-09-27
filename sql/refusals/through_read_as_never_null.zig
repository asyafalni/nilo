//! A column read through a reference that may be null, into a field that
//! cannot be.
//!
//! A row whose reference is null has no row on the other side to read from,
//! which is the rule a parent field is held to (item 83).

const sql = @import("nilo_sql");

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };

    id: i64,
    full_name: []const u8,
};

const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .key = .id,
        .references = .{ .approver_id = .{ Staff, .id } },
    };

    id: i64,
    approver_id: ?i64,
};

const DealLine = struct {
    pub const nilo_table = Deal;
    pub const nilo_through = .{ .approver_name = .{ .approver_id, .full_name } };

    id: i64,
    approver_name: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(DealLine, @TypeOf(.{}));
}
