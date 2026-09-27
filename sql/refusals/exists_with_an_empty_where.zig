//! An `.exists` with `.where = .{}`.
//!
//! An empty condition matches every row, so it is the entry with no `.where`,
//! and one question gets one spelling (item 107).

const sql = @import("nilo_sql");

const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: []const u8,
};

const Capability = struct {
    pub const nilo_table = .{
        .name = "partner_capabilities",
        .key = .id,
        .references = .{ .partner_id = .{ Partner, .id } },
    };

    id: i64,
    partner_id: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Partner, @TypeOf(.{ .where = .{ .exists = .{.{ .in = Capability, .where = .{} }} } }));
}
