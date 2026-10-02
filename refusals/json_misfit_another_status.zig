//! `.misfit = 409`. JSON whose syntax is right and whose content does not fit
//! is a 422 by RFC 9110, or the default 400; a conflict is something else.

const nilo = @import("nilo_http");

const Search = struct {
    pub const nilo_json = .{ .misfit = 409 };

    start: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Search);
}
