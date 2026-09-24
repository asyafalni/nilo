//! `incr` on a Space that holds a struct. A count is an integer, and a Space
//! of anything else has nothing to add one to — the Refusal names the type
//! and the Space that would count (ADR 109).

const cache = @import("nilo_cache");

const Cart = struct {
    owner: u64,
    items: u16,
};

export fn refusal() void {
    var store: cache.Store = undefined;
    const Carts = cache.Space("cart", Cart, .{});
    const carts = Carts.open(&store);
    _ = carts.incr("u42", .{ .owner = 1, .items = 1 });
}
