//! An ordering whose key is the caller's own SQL, handed to a statement nilo
//! writes. A typed select orders by columns it checked; text it did not write
//! is for `db.rawOrdered`
//! ([ADR 0204](../../docs/adr/0204-an-order-chosen-at-run-time-from-a-closed-set.md)).

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    title: []const u8,
};

const Sort = sql.Ordering(Ticket, .{ .id = .id, .title = "lower(title)" });

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{ .order = Sort.by(&.{.{ .key = .id }}) }));
    _ = found;
}
