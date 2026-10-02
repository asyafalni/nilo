//! `.misfit = .unprocessable`. The entry is the status a client contract
//! states, so it is written as that number.

const nilo = @import("nilo_http");

const Search = struct {
    pub const nilo_json = .{ .misfit = .unprocessable };

    start: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Search);
}
