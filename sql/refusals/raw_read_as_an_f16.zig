//! One column read as an `f16`. A float column holds 32 or 64 bits on both
//! databases, and nothing decodes a half; this used to reach pg.zig and fail
//! there in words about a type the reader did not choose.

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.raw(f16, &run, "SELECT 1.5::float4", .{}) catch {};
}
