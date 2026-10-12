//! A `max` (or `min`) over an enum that names a database type is ordered by
//! the position its labels were declared in on Postgres, and by their text on
//! SQLite, where the enum is only a name in a `TEXT` column. The same Row
//! would name a different label on each, with no error. Refused on SQLite; an
//! enum that names no database type is `text` on both and is fine
//! (ADR 181, ADR 055).

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
};

const Level = enum {
    low,
    high,

    pub const nilo_column = "level_kind";
};

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .references = .{ .customer_id = .{ Customer, .id } } };
    id: i64,
    customer_id: i64,
    level: Level,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const Peak = struct {
    pub const nilo_table = Ticket;
    pub const nilo_aggregate = .{ .top = .{ .max = .level } };
    customer: CustomerName,
    top: Level,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, Peak, @TypeOf(.{}));
}
