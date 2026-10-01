//! The same for the latest of the children: Postgres has no `max(uuid)`, so a
//! figure over a `Uuid` column is refused where the Row is named rather than
//! failing on the first request.

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
    public: sql.Uuid,
};

const EpicCard = struct {
    pub const nilo_table = Epic;
    pub const nilo_children = .{ .newest = .{ .max = .{ Item, .public } } };

    id: i64,
    newest: ?sql.Uuid,
};

export fn refusal() void {
    _ = sql.selectFor(EpicCard, @TypeOf(.{}));
}
