//! A list written in place with `null` among its elements, given to `.in`.
//!
//! `&.{ 1, null }` is a tuple, not a slice, and the null in it never matches a
//! row: `.in` looks like "these, and the ones with no value" and finds only
//! "these". Refused for the reason `not_in_a_list_that_holds_null` is (ADR 040,
//! ADR 052).

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tag: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{ .where = .{ .tag = .{ .in = &.{ 1, null } } } }));
    _ = found;
}
