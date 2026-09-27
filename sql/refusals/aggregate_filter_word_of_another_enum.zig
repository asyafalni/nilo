//! A value of some other enum in an aggregate's `.where`. A value of the
//! column's own enum is the word and is taken; another enum's value is a
//! different set of words that may share a name, so it is refused, and the
//! message says how the words are written rather than warning about a string
//! nobody wrote (item 104).

const sql = @import("nilo_sql");

const Category = enum { open, done, cancelled };
const Stage = enum { open, done };

const State = struct {
    pub const nilo_table = .{ .name = "states", .key = .id };

    id: i64,
    category: Category,
};

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .references = .{ .state_id = .{ State, .id } },
    };

    id: i64,
    state_id: i64,
    kind: []const u8,
};

const finished = [_]Stage{.done};

const Tally = struct {
    pub const nilo_table = Task;
    pub const nilo_aggregate = .{
        .open = .{ .count = .id, .where = .{ .state_id = .{ .category = .{ .not_in = &finished } } } },
    };

    kind: []const u8,
    open: i64,
};

export fn refusal() void {
    _ = sql.selectFor(Tally, @TypeOf(.{}));
}
