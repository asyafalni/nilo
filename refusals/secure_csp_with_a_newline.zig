//! A policy written across two lines, whose second line would be a header nobody named.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.secure.api(.{ .csp = "default-src 'none';\nframe-ancestors 'none'" })) catch {};
}
