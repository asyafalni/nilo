//! A body holding a type that parses itself and has not handed `std.json` a
//! reader. On the path and in the query string nilo reads it through
//! `nilo_parse`; in a body `std.json` would read it as its fields, and a
//! client sending the text would be told the field has to be an object
//! ([ADR 166](../docs/adr/166-a-body-field-that-parses-itself.md)).

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(text: []const u8) ?Sku {
        if (text.len != 3) return null;
        return .{ .letters = text[0..3].* };
    }
};

const NewLine = struct {
    sku: Sku,
    quantity: u32,
};

fn add(body: NewLine) u32 {
    _ = body;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/lines", add) catch {};
}
