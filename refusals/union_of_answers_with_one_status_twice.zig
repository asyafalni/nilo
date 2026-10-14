//! A union of answers whose two arms both say 400: one status in the API
//! description has one shape, so the second arm could never be told from the
//! first ([ADR 286](../docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

const nilo = @import("nilo_http");

const Hits = struct { total: u32 };
const Invalid = struct { offset: u32 };
const Unknown = struct { name: nilo.Str };

const Search = union(enum) {
    found: nilo.Status(200, Hits),
    bad_query: nilo.Status(400, Invalid),
    bad_field: nilo.Status(400, Unknown),
};

fn search() !Search {
    return .{ .found = .{ .value = .{ .total = 0 } } };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/search", search) catch {};
}
