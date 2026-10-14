//! A decision that does not say yes or no. `cors.deciding` needs a `bool`.

const nilo = @import("nilo_http");

fn allows(origin: []const u8) void {
    _ = origin;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.deciding(allows, .{})) catch {};
}
