//! A failure shape with the right fields and nothing to fill them. nilo has
//! a status and a sentence and no way to know which field wants which.

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    detail: []const u8,
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
