//! nilo_cache: one `put` and one `get` of a small flat value on a Store of a
//! MiB, over a thousand keys, which is a read-through cache's whole round.

const std = @import("std");
const cache = @import("nilo_cache");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Cart = struct { owner: u64, items: u16, total_cents: u64 };
const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });

const Program = struct {
    gpa: std.mem.Allocator,
    /// On the heap, because a Space holds a pointer to it.
    store: *cache.Store,
    carts: Carts,

    pub fn init(gpa: std.mem.Allocator) !Program {
        // A fixed seed so placement is the same every run. A ref older than
        // the option hashes with no secret at all, which is fixed too.
        var options: cache.Options = .{ .bytes = 1 << 20 };
        if (@hasField(cache.Options, "seed")) options.seed = 0x6e696c6f;
        const store = try gpa.create(cache.Store);
        errdefer gpa.destroy(store);
        store.* = try cache.open(gpa, options);
        return .{ .gpa = gpa, .store = store, .carts = Carts.open(store) };
    }

    pub fn deinit(self: *Program) void {
        self.store.deinit();
        self.gpa.destroy(self.store);
    }

    pub fn op(self: *Program, _: std.mem.Allocator, i: usize) !void {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "user:{d}", .{i % 1000});
        self.carts.put(key, .{ .owner = i, .items = 3, .total_cents = 125_000 });
        const got = self.carts.get(key) orelse return error.CacheMissed;
        harness.keep(&got);
    }
};
