//! A `.deps` written as a function, but not of the one shape a function
//! there has. `.deps` may be a function so that a `run` can ask for the
//! queue itself — `fn (comptime Jobs: type) type`, handed the finished type
//! and answering the struct of pointers (ADR 160). Two arguments is not
//! that, and the message says what is.

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

fn deps(comptime Queue: type, comptime Extra: type) type {
    _ = Extra;
    return struct { jobs: *Queue, mail: *Mailer };
}

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory, .deps = deps });
}
