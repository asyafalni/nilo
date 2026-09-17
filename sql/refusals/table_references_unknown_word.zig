//! A misspelled word inside a `.references` entry. Without this it is a
//! foreign key that compiles and deletes nothing on delete.

const sql = @import("nilo_sql");

const Board = struct {
    pub const nilo_table = .{ .name = "boards", .key = .{ .id, .org_id } };

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
                .to = .{ Board, .{ .id, .org_id } },
                .on_dlete = .cascade,
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
