//! Asking for the preload list without the includeSubDomains it requires.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.secure.api(.{ .hsts = .{ .preload = true } })) catch {};
}
