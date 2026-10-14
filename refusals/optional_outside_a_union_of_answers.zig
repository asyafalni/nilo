//! `?Search` where `Search` is a union of `Status` arms: the `?` is a 404 and
//! has no arm to belong to ([ADR 286](../docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

const nilo = @import("nilo_http");

const Hits = struct { total: u32 };
const Invalid = struct { offset: u32 };

const Search = union(enum) {
    found: nilo.Status(200, Hits),
    refused: nilo.Status(400, Invalid),
};

fn search() !?Search {
    return null;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/search", search) catch {};
}
