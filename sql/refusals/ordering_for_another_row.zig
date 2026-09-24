//! An ordering declared for one Row, used on another. Its columns were checked
//! against the Row it was declared for, so on any other Row the check said
//! nothing
//! ([ADR 165](../../docs/adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)).

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    title: []const u8,
};

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    email: []const u8,
};

const Sort = sql.Ordering(Ticket, .{ .id = .id, .title = .title });

export fn refusal() void {
    const found = sql.selectFor(Person, @TypeOf(.{ .order = Sort.by(&.{.{ .key = .id }}) }));
    _ = found;
}
