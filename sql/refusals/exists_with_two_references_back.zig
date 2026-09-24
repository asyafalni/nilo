//! An `.exists` over a parent the outer Row points at from two columns.
//!
//! The mirror of `exists_with_two_references`: `staff` with `home_region` and
//! `work_region` both pointing at `regions`, and the query asking whether the
//! region matches. Which of the two is a question about what the query means,
//! and `.via = .<column>` is how it is answered — a column of the outer Row,
//! named so it cannot be read as `.on`'s inner one (ADR 175).

const sql = @import("nilo_sql");

const Region = struct {
    pub const nilo_table = .{ .name = "regions", .key = .id };

    id: i64,
    name: []const u8,
};

const Staff = struct {
    pub const nilo_table = .{
        .name = "staff",
        .key = .id,
        .references = .{
            .home_region = .{ Region, .id },
            .work_region = .{ Region, .id },
        },
    };

    id: i64,
    home_region: i64,
    work_region: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Staff, @TypeOf(.{ .where = .{ .exists = .{
        .{ .in = Region, .where = .{ .name = @as([]const u8, "west") } },
    } } }));
}
