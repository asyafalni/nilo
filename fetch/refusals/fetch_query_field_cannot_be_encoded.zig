//! A query field whose type no query string can carry. A struct has no
//! text form a server would read, and writing one — JSON? `a.b=1`? — would
//! be a convention nilo invented, so the field is refused by name rather
//! than encoded somehow.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const When = struct { year: u16, month: u8 };

export fn refusal() void {
    var run: core.Run = undefined;
    const when: When = .{ .year = 2026, .month = 9 };
    _ = fetch.withQuery(&run, "https://api.example.com/search", .{ .page = 2, .when = when }) catch {};
}
