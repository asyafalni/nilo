//! A list with a null in it, given to `.not_in`.
//!
//! `"tag" <> ALL('{a,NULL}')` is NULL for every row, because SQL never finds a
//! value equal to NULL, so the select comes back empty and no error says why.
//! The null in a list is the same mistake `optional_in_a_condition` refuses for
//! a single value, reached through a list, and it is refused where the list is
//! written (ADR 040, ADR 052).

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tag: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{ .where = .{ .tag = .{ .not_in = &[_]?i64{ 1, null } } } }));
    _ = found;
}
