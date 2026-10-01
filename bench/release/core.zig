//! nilo_core: what the App layer does with core on every request that carries
//! input, which is percent-decoding a path param and a query value and reading
//! a number out of a third as a `Str`.

const std = @import("std");
const core = @import("nilo_core");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Program = struct {
    pub fn init(_: std.mem.Allocator) !Program {
        return .{};
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(_: *Program, scratch: std.mem.Allocator, _: usize) !void {
        // Behind `keep`, so the optimiser cannot decode them while compiling.
        var path: []const u8 = "holiday%20photos%2Fbali%20%282024%29.jpg";
        var query: []const u8 = "caf%C3%A9+au+lait+%26+croissant";
        var number: []const u8 = "1759300000";
        harness.keep(&path);
        harness.keep(&query);
        harness.keep(&number);

        const name = core.Str.static(try core.percent.decode(scratch, path, false));
        const q = core.Str.static(try core.percent.decode(scratch, query, true));
        const id = core.Str.static(try core.percent.decode(scratch, number, false));
        harness.keep(name.eql("holiday photos/bali (2024).jpg"));
        harness.keep(q.len());
        harness.keep(try id.int(u64));
    }
};
