//! `.now` moved by a number with no unit.
//!
//! `.today` moves by days, because a day is all it counts. A moment could move
//! by days, hours, minutes or seconds, and `-90` alone leaves the reader to
//! guess which one the writer meant (item 105).

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{ .name = "work_items", .key = .id };

    id: i64,
    seen_at: sql.Timestamp,
};

export fn refusal() void {
    _ = sql.selectFor(Card, @TypeOf(.{
        .where = .{ .seen_at = .{ .gt = .{ .now = -90 } } },
    }));
}
