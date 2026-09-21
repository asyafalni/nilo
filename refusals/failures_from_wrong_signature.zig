//! A `nilo_failure` that can fail. The failure path must not have a failure
//! path of its own (ADR 0025), so the function that fills the struct is given
//! the status and the sentence and hands the struct back, and nothing else.

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) !ApiError {
        return .{ .code = status, .detail = message };
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
