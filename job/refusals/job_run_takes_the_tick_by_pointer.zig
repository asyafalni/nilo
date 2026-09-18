//! A `run` asking for the tick by pointer. After the job and the Run, a
//! pointer is a service looked up in `.deps`, and the tick is not one: it
//! is the row's id, attempt and due time, and it is handed over by value
//! (ADR 0246). Left to the deps lookup this would say `.deps` has no
//! `*job.Tick`, which is true and points the wrong way.

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run, tick: *job.Tick) !void {
        _ = self;
        _ = scope;
        _ = tick;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
