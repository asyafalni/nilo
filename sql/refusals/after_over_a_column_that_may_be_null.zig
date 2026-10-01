//! A cursor over a column that may be null. A row comparison with a NULL in
//! it is true of nothing, so the rows holding one never come after any
//! cursor and the list loses them (ADR 150).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Task = struct {
    pub const nilo_table = .{ .name = "tasks", .key = .id };
    id: i64,
    due: ?sql.Timestamp,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.feed(Task, &run, .{
        .order = .{ .due = .asc, .id = .asc },
        .after = .{ .due = sql.Timestamp{ .micros = 0 }, .id = @as(i64, 1) },
        .limit = 20,
    }) catch {};
}
