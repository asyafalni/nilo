//! A CLI resetting an account, checking the old password at a Cost turned
//! down so the tool feels quick. There is no request here and no Ctx, so it
//! reaches `nilo.verifyPassword` rather than the method — and the floor holds
//! on this door the way it does on the other: the Cost is what the no-account
//! path is measured out at, and a cheap one there is a stopwatch away from
//! the early return the optional exists to prevent.

const nilo = @import("nilo_http");

export fn refusal() void {
    _ = nilo.verifyPasswordWith(.{ .memory_kib = 64, .passes = 1 }, undefined, null, "hunter2") catch {};
}
