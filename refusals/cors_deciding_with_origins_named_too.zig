//! Origins named in two places at once. `cors.deciding` asks the program's own
//! function which origins are allowed, so the `.origins` field would be
//! ignored, and an ignored list is one somebody edits and then wonders about.

const nilo = @import("nilo_http");

fn allows(origin: []const u8) bool {
    return origin.len > 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.deciding(allows, .{
        .origins = &.{"https://example.com"},
    })) catch {};
}
