//! A list column read as `[]const u16`. Postgres decodes an array element
//! only as the width it stores, so `int2[]` is `[]const i16` and nothing
//! else; this used to stop inside pg.zig with its own compile error.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Grid = struct {
    pub const nilo_table = .{ .name = "grids", .key = .id };

    id: i64,
    cells: []const u16,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.select(Grid, &run, .{ .where = .{ .id = 1 } }) catch {};
}
