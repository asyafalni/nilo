//! A handler that answers one of several typed responses: a `union(enum)`
//! whose every arm is a `Status(code, T)` ([ADR 286](../docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).
//!
//! ```zig
//! const Search = union(enum) {
//!     found: nilo.Status(200, Hits),
//!     refused: nilo.Status(400, Invalid),
//! };
//!
//! fn search(q: nilo.Query(Q)) !Search {
//!     return .{ .refused = .{ .value = .{ .@"error" = "no such field", .offset = 12 } } };
//! }
//! ```
//!
//! **This file only says which types are one, and refuses the ones that are
//! malformed.** Sending lives in `typed.zig` (an arm goes through the very
//! path a bare `Status` takes, so its JSON writer, its fast path and its
//! headers are the ones a plain handler has, and a handler that does not
//! return a union pays nothing for this), and the document in `openapi.zig`
//! (one response per arm). A union is recognised by an arm carrying
//! `nilo_status`: a tagged union of anything else is still a JSON body, as
//! it was.
//!
//! **An arm is a `Status(code, T)` and not a `Response(T)`**, because a
//! `Response(T)` picks its status while the request runs and the document
//! can only write `default` for it: one arm that cannot be told apart from
//! another would make the union's whole point, a response per status,
//! unstatable. A handler whose status truly depends on what it found keeps
//! `Response(T)` on its own.

const std = @import("std");
const naming = @import("names.zig");

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// Whether `T` is a tagged union with at least one `Status(code, T)` arm,
/// which is what makes it an answer with several statuses rather than a
/// body that happens to be a union.
pub fn is(comptime T: type) bool {
    comptime {
        if (@typeInfo(T) != .@"union") return false;
        if (@typeInfo(T).@"union".tag_type == null) return false;
        for (@typeInfo(T).@"union".field_types) |A| if (hasDecl(A, "nilo_status")) return true;
        return false;
    }
}

/// Everything that can be wrong with the union, said at the route.
pub fn check(comptime pattern: []const u8, comptime U: type) void {
    comptime {
        const info = @typeInfo(U).@"union";
        for (info.field_names, info.field_types) |arm, A| {
            if (!hasDecl(A, "nilo_status")) @compileError(
                "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(U) ++
                    ", and its arm `" ++ arm ++ "` is " ++ naming.of(A) ++ ", not a `nilo.Status(code, T)`.\n" ++
                    "  A union of answers names each status in its type, so the API description can " ++
                    "list one response per arm. Write `" ++ arm ++ ": nilo.Status(200, " ++ naming.of(A) ++
                    ")` with the status that arm answers with.",
            );
        }
        for (info.field_names, info.field_types, 0..) |a_name, A, i| {
            for (info.field_names[i + 1 ..], info.field_types[i + 1 ..]) |b_name, B| {
                if (A.nilo_status != B.nilo_status) continue;
                @compileError(
                    "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(U) ++
                        ", and its arms `" ++ a_name ++ "` and `" ++ b_name ++ "` both answer " ++
                        std.fmt.comptimePrint("{d}", .{A.nilo_status}) ++ ".\n" ++
                        "  A status has one shape in the document, so one status is one arm. " ++
                        "Give one of them its own status, or put a `union(enum)` inside the body " ++
                        "type of a single arm when one status answers in two shapes.",
                );
            }
        }
    }
}
