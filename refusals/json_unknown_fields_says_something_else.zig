//! `.unknown_fields` given a value that is not `.ignore`. The one choice is to
//! skip the keys; refusing them is what a type does when it says nothing, so
//! there is no other word for it to mean.

const nilo = @import("nilo_http");

const Settings = struct {
    pub const nilo_json = .{ .unknown_fields = .warn };

    theme: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Settings);
}
