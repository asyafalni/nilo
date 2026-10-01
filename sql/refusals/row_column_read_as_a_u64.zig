//! A Row reading a column as a `u64`. Both databases keep an integer in a
//! signed 64 bits, so half of what the field can hold has nowhere to be
//! stored, and a Row reading one used to compile and fail at the first row
//! past `maxInt(i64)`, or inside pg.zig with its own message (ADR 055).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Counter = struct {
    pub const nilo_table = .{ .name = "counters", .key = .id };

    id: i64,
    hits: u64,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.select(Counter, &run, .{ .where = .{ .id = 1 } }) catch {};
}
