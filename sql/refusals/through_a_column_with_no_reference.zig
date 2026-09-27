//! A column read through a column that points nowhere.
//!
//! The join is read out of the schema, as a parent's is, so the column has to
//! carry a `.references` (item 83).

const sql = @import("nilo_sql");

const Deal = struct {
    pub const nilo_table = .{ .name = "deals", .key = .id };

    id: i64,
    owner_id: i64,
};

const DealLine = struct {
    pub const nilo_table = Deal;
    pub const nilo_through = .{ .owner_name = .{ .owner_id, .full_name } };

    id: i64,
    owner_name: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(DealLine, @TypeOf(.{}));
}
