//! A number where a level belongs. `2` says nothing about whether it is more
//! urgent than `1` or less, and the answer differs between queues; the three
//! levels say it in the word.

const job = @import("nilo_job");
const core = @import("nilo_core");

const Backfill = struct {
    pub const nilo_job = "backfill";
    pub const retry: job.Retry = .{ .times = 3 };
    pub const priority = 2;
    since: u64,
    pub fn run(self: Backfill, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{Backfill}, .store = job.Memory });
}
