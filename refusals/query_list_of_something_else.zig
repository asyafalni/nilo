//! A query field that is a list of something a query value cannot become. The
//! list is read, so the element is what has to convert
//! ([ADR 132](../docs/adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)).

const nilo = @import("nilo_http");

const Actor = struct { id: u32 };

const Search = struct { actors: []const Actor = &.{} };

fn list(search: nilo.Query(Search)) u32 {
    return @intCast(search.value.actors.len);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
