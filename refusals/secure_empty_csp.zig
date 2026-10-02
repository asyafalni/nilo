//! An empty Content-Security-Policy, which a browser reads as no policy.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.secure.pages(.{ .csp = "" })) catch {};
}
