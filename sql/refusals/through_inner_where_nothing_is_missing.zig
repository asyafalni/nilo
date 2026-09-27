//! `.join = .inner` on a path whose every reference is never null.
//!
//! Every row reaches the column, so there is no row to leave out, and the
//! word would say something the query does not do (item 109).

const sql = @import("nilo_sql");

const Kind = struct {
    pub const nilo_table = .{ .name = "kinds", .key = .id };

    id: i64,
    tracks_range: ?bool,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };

    id: i64,
    full_name: []const u8,
};

const Item = struct {
    pub const nilo_table = .{
        .name = "items",
        .key = .id,
        .references = .{ .kind_id = .{ Kind, .id }, .owner_id = .{ Staff, .id } },
    };

    id: i64,
    kind_id: ?i64,
    owner_id: i64,
};

const ItemLine = struct {
    pub const nilo_table = Item;
    pub const nilo_through = .{ .owner_name = .{ .path = .{ .owner_id, .full_name }, .join = .inner } };

    id: i64,
    owner_name: []const u8,
};

export fn refusal() void {
    _ = sql.selectFor(ItemLine, @TypeOf(.{}));
}
