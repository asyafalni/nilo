//! A job whose `final` is a list of names rather than an error set.
//!
//! An error set is checked as spelled — `error{Rejected}` is a type — where
//! a list of strings would be a line that never matched (ADR 0218).

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{ .times = 3 };
    pub const final = .{"Rejected"};
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
