//! A `.unique` written as an empty string. The key is meant to come from what
//! identifies the row, and an empty one means that value went missing: every
//! such push would be answered `null` for the first one's sake.

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });

export fn refusal() void {
    var store: job.Memory = undefined;
    var jobs: Jobs = .open(undefined, &store, .{}, .{});
    var run: core.Run = undefined;
    _ = jobs.push(&run, SendWelcome{}, .{ .unique = "" }) catch {};
}
