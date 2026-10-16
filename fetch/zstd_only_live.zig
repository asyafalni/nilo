//! A build that reads zstd and not gzip, against a real loopback server
//! (ADR 295). Its own root, built with `fetch_config.zstd` true and
//! `fetch_config.gzip` false: the two flags are independent, and a program
//! that asked for one links the other's codec nowhere.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

fn started(io: std.Io) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, .{});
    try client.nilo_start(io, .none);
    return client;
}

test "this root reads zstd and not gzip, and says so on the wire" {
    try testing.expect(fetch.reads_zstd);
    try testing.expect(!fetch.reads_gzip);
    try testing.expectEqualStrings("zstd, identity", fetch.accepted_encodings);

    try withIo(struct {
        fn run(io: std.Io) !void {
            var wire: [4 << 10]u8 = undefined;
            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(&wire, "200 OK", "", "{\"a\":1,\"b\":[1,2,3,4,5,6,7,8,9]}");
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqualStrings("{\"a\":1,\"b\":[1,2,3,4,5,6,7,8,9]}", res.body.view());
            try testing.expect(std.mem.indexOf(u8, canned.request(), "accept-encoding: zstd, identity") != null);
            try testing.expect(std.mem.indexOf(u8, canned.request(), "gzip") == null);
        }
    }.run);
}

test "a gzip answer is refused by a build that reads only zstd" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var wire: [4 << 10]u8 = undefined;
            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(&wire, "200 OK", "", "{\"a\":1}");
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            try testing.expectError(error.HttpContentEncodingUnsupported, client.get(&scope, try canned.url(&buf), .{}));
        }
    }.run);
}
