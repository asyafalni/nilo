//! A job that declares `final` and retries nothing.
//!
//! With one attempt every failure is final already, so the set decides
//! nothing — and a line that does nothing is a line somebody will read as
//! doing something (ADR 179).

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    pub const final = error{Rejected};
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
