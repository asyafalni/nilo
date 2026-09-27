//! A through entry that says `.join = .left`.
//!
//! The join is already outer wherever a reference may be null, so `.join`
//! only ever says the one thing it changes: `.inner` (item 109).

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
    pub const nilo_through = .{ .kind_tracks = .{ .path = .{ .kind_id, .tracks_range }, .join = .left } };

    id: i64,
    kind_tracks: ?bool,
};

export fn refusal() void {
    _ = sql.selectFor(ItemLine, @TypeOf(.{}));
}
