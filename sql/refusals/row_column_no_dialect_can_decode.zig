//! A Row reading a column as a plain struct of the caller's own. Nothing can
//! decode one: `dialect.accepts` answers `null` for it, the startup check
//! reads `null` as *accept anything*, and the first request that reads the
//! row used to stop inside pg.zig with `cannot decode value of type
//! …User__struct_3276` — a mangled anonymous name in a file the reader did
//! not write. This is the scalar half of what `listAccepts` already catches
//! for arrays, judged where the Row is first read.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Address = struct { street: []const u8, city: []const u8 };

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    address: Address,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.select(User, &run, .{ .where = .{ .id = 1 } }) catch {};
}
