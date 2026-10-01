//! A list column read as `[]const sql.Timestamp`. The driver decodes an array
//! element into a number, a bool, text or a `uuid`, and a `Timestamp`, `Date`,
//! `Decimal`, `Bytes` or `Json` stopped inside pg.zig with its own compile
//! error. It is refused where the Row is read, in nilo's words.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Slot = struct {
    pub const nilo_table = .{ .name = "slots", .key = .id };

    id: i64,
    opens: []const sql.Timestamp,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.select(Slot, &run, .{ .where = .{ .id = 1 } }) catch {};
}
