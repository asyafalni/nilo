//! `.join = .inner` inside a parent that may be missing.
//!
//! The parent is an outer join, and an inner one after it would leave out
//! every row whose parent is missing, not only those the path does not reach
//! (item 109).

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

const ItemOwner = struct {
    pub const nilo_table = Item;
    pub const nilo_through = .{ .kind_tracks = .{ .path = .{ .kind_id, .tracks_range }, .join = .inner } };

    kind_tracks: ?bool,
};

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .references = .{ .item_id = .{ Item, .id } },
    };

    id: i64,
    item_id: ?i64,
};

const TaskLine = struct {
    pub const nilo_table = Task;

    id: i64,
    item: ?ItemOwner,
};

export fn refusal() void {
    _ = sql.selectFor(TaskLine, @TypeOf(.{}));
}
