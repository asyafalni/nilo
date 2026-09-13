//! An ordering key naming a column the Row does not read. The same check
//! `.order` makes, made where the keys are declared rather than on the first
//! request that chooses one
//! ([ADR 0204](../../docs/adr/0204-an-order-chosen-at-run-time-from-a-closed-set.md)).

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    created_at: i64,
};

const Sort = sql.Ordering(Ticket, .{ .created = .creted_at });

export fn refusal() void {
    const found = sql.selectFor(Ticket, @TypeOf(.{ .order = Sort.by(&.{.{ .key = .created }}) }));
    _ = found;
}
