//! What every program in this directory shares: run one operation `n` times
//! and say what it allocated (ADR 242).
//!
//! A program is a struct with `init(gpa)`, `op(self, scratch, i)` and
//! `deinit(self)`. `op` is handed `scratch`, an arena that is reset after
//! every call and counted, so the allocations a call makes are the module's
//! and not the harness's; `init` gets a plain allocator for whatever lives
//! across calls (a store, a key set, a pool), which is a cost paid once and
//! not per operation. `bench/release.py` runs the program twice under
//! cachegrind, at two counts, and takes the difference over the difference,
//! so `init`, `deinit` and process start come out of the instruction count.
//!
//! The output is one line, `{"n":…,"allocs":…,"bytes":…}`, totals over the
//! `n` calls. The harness is built from the newest tree and pointed at each
//! ref's modules, so this file and the programs may use only what every
//! measured ref exports; a program that does not compile against a ref is
//! that module's "n/a" for that ref, which `release.py` reports.

const std = @import("std");

pub fn run(init: std.process.Init.Minimal, comptime Program: type) !void {
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    const n = try std.fmt.parseInt(usize, args.next() orelse "1000", 10);

    const gpa = std.heap.smp_allocator;
    var program = try Program.init(gpa);
    defer program.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var counting: Counting = .{ .child = arena.allocator() };

    for (0..n) |i| {
        try program.op(counting.allocator(), i);
        _ = arena.reset(.retain_capacity);
    }

    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{{\"n\":{d},\"allocs\":{d},\"bytes\":{d}}}\n", .{ n, counting.allocs, counting.bytes });
    std.debug.print("{s}", .{line});
}

/// Keeps a value the optimiser could otherwise prove unused, so an operation
/// whose result nothing reads is still performed.
pub fn keep(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.bytes += new_len - memory.len;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.bytes += new_len - memory.len;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ra);
    }
};
