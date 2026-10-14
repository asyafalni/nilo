//! A union of answers where one arm is a plain struct: the status it answers
//! with is not in its type, so the document could not list it
//! ([ADR 286](../docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

const nilo = @import("nilo_http");

const Hits = struct { total: u32 };
const Invalid = struct { offset: u32 };

const Search = union(enum) {
    found: nilo.Status(200, Hits),
    refused: Invalid,
};

fn search() !Search {
    return .{ .found = .{ .value = .{ .total = 0 } } };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/search", search) catch {};
}
