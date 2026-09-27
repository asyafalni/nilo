//! `.now` moved by months.
//!
//! A month is not a length: a month back from the thirty-first of March is
//! the third of March on SQLite and the twenty-eighth of February on Postgres.
//! The units taken are the ones both databases count the same way (item 105).

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{ .name = "work_items", .key = .id };

    id: i64,
    seen_at: sql.Timestamp,
};

export fn refusal() void {
    _ = sql.selectFor(Card, @TypeOf(.{
        .where = .{ .seen_at = .{ .gt = .{ .now = .{ .months = -1 } } } },
    }));
}
