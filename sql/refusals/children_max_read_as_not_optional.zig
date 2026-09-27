//! The latest of the children read into a field that cannot be null.
//!
//! A row nothing points back at has no latest, and `max` over no rows is
//! null. The field has to say so, the way an aggregate's does (item 100).

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
    target_date: sql.Date,
};

const EpicCard = struct {
    pub const nilo_table = Epic;
    pub const nilo_children = .{ .latest_target = .{ .max = .{ Item, .target_date } } };

    id: i64,
    latest_target: sql.Date,
};

export fn refusal() void {
    _ = sql.selectFor(EpicCard, @TypeOf(.{}));
}
