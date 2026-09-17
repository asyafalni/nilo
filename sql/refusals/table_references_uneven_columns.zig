//! A composite foreign key whose two sides are different lengths. The columns
//! line up one for one, so two pointing at one is a key that cannot be made.

const sql = @import("nilo_sql");

const Board = struct {
    pub const nilo_table = .{ .name = "boards", .key = .id };

    id: i64,
    org_id: i64,
};

const Card = struct {
    pub const nilo_table = .{
        .name = "cards",
        .key = .id,
        .references = .{
            .board = .{
                .columns = .{ .board_id, .org_id },
                .to = .{ Board, .id },
            },
        },
    };

    id: i64,
    board_id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{ Board, Card });
}
