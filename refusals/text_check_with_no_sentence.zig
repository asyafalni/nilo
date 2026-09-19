//! `nilo.Text(.{ .check = … })` with no `.said`. Text the check refuses would
//! get a 400 that cannot say why, so the sentence is required beside the check
//! ([ADR 0264](../docs/adr/0264-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

const std = @import("std");
const nilo = @import("nilo_http");

fn startsWithSku(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "SKU-");
}

const NewItem = struct {
    sku: nilo.Text(.{ .check = startsWithSku }),
};

fn create(in: NewItem) !void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/items", create) catch {};
}
