//! nilo_job: one job pushed onto `job.Memory`, then claimed, run and marked
//! done, which is a row's whole life from a handler's `push` to a worker
//! finishing it.
//!
//! `runOne` rather than `runOneAt` with a fixed clock, because `runOneAt`
//! first exists at v0.5.0 and `runOne` at v0.4.0, where the module starts.
//! `push` reads the clock either way, so a fixed one would not take it out.
//! A clock read is a vDSO call and the same instructions whatever it answers.

const std = @import("std");
const core = @import("nilo_core");
const job = @import("nilo_job");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

/// The doc's own example kind: a small payload with a number and some text,
/// and a `run` that does nothing the optimiser can drop.
const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;

    user_id: i64,
    email: []const u8,

    pub fn run(self: SendWelcome, _: *core.Run) !void {
        harness.keep(&self);
    }
};

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });

const Program = struct {
    /// On the heap, because `Jobs` holds a pointer to its store and `init`
    /// returns the Program by value.
    state: *State,
    gpa: std.mem.Allocator,

    const State = struct {
        store: job.Memory,
        jobs: Jobs,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        // A fixed budget, so the slot count a claim scans is the store's
        // own `Slot` size over a constant and not something this file moves.
        state.store = try job.Memory.open(gpa, .{ .bytes = 64 << 10 });
        state.jobs = .open(gpa, &state.store, .{}, .{});
        return .{ .state = state, .gpa = gpa };
    }

    pub fn deinit(self: *Program) void {
        self.state.store.deinit();
        self.gpa.destroy(self.state);
    }

    /// A `Run` on the harness's arena, because `runOne` takes nothing else:
    /// so the allocations counted are the `Run` arena's chunks, not each of
    /// the module's own, and `bytes` is the one that moves. The same payload
    /// every call, so its JSON is the same length at every count and the
    /// difference over the difference is exact.
    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var run: core.Run = .init(scratch);
        defer run.deinit();
        _ = try self.state.jobs.push(&run, SendWelcome{ .user_id = 1_234_567, .email = "wati@example.com" }, .{});
        if (!try self.state.jobs.runOne(&run)) return error.NothingRan;
    }
};
