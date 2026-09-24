//! A `.deps` function that answers a struct without the service a `run`
//! asks for. The checks on a `run`'s signature wait until the queue type
//! exists when `.deps` is a function (ADR 160), so this one fires at the
//! first thing the program does with the queue rather than at
//! `job.Jobs(…)` — and it is the same sentence the struct shape gets.

const job = @import("nilo_job");
const core = @import("nilo_core");

const Mailer = struct {};

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run, mail: *Mailer) !void {
        _ = self;
        _ = scope;
        _ = mail;
    }
};

fn deps(comptime Queue: type) type {
    return struct { jobs: *Queue };
}

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory, .deps = deps });

export fn refusal() void {
    var store: job.Memory = undefined;
    _ = Jobs.open(undefined, &store, undefined, .{});
}
