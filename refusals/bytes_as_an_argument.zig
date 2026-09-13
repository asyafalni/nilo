//! `nilo.Bytes` is what a handler answers *with*. Read as the request body —
//! which is what a struct by value is — it would land inside `std.json` being
//! asked to parse a body and a content type, which is a message nilo did not
//! write.

const nilo = @import("nilo_http");

fn take(bytes: nilo.Bytes) !void {
    _ = bytes;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/bundles", take) catch {};
}
