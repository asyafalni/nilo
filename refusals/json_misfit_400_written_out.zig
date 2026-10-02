//! `.misfit = 400`. A body that is JSON and not the type's shape is already a
//! 400 for every type that says nothing, so the entry would change nothing.

const nilo = @import("nilo_http");

const Search = struct {
    pub const nilo_json = .{ .misfit = 400 };

    start: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Search);
}
