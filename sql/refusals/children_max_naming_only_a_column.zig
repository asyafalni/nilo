//! A `.max` over the children that names the column and not the Row.
//!
//! A count names the Row whose table points back, `.{ .count = Item }`, and
//! the column alone does not say which table it is on. A `.max` names both,
//! the way a `.references` does: `.{ .max = .{ Item, .target_date } }`.

const sql = @import("nilo_sql");

const Epic = struct {
    pub const nilo_table = .{ .name = "work_epics", .key = .id };

    id: i64,
};

const Item = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .references = .{ .epic_id = .{ Epic, .id } },
    };

    id: i64,
    epic_id: i64,
    target_date: ?sql.Date,
};

const EpicCard = struct {
    pub const nilo_table = Epic;
    pub const nilo_children = .{ .latest_target = .{ .max = .target_date } };

    id: i64,
    latest_target: ?sql.Date,
};

export fn refusal() void {
    _ = sql.selectFor(EpicCard, @TypeOf(.{}));
}
