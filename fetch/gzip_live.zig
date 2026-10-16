//! Reading a gzip answer, against a real loopback server (ADR 292).
//!
//! Its own root, built with `fetch_config.gzip` true whatever `-Dfetch_gzip`
//! says, so the rest of the suite stays the proof of the build a dependent
//! gets by default.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");
const gzip = @import("gzip.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;

test {
    _ = gzip;
}

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

fn started(io: std.Io, settings: fetch.Client.Settings) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, settings);
    try client.nilo_start(io, .none);
    return client;
}

/// Some JSON, `count` objects of it: compressible the way an API's answer is.
fn json(gpa: std.mem.Allocator, count: usize) ![]u8 {
    var built: std.Io.Writer.Allocating = .init(gpa);
    errdefer built.deinit();
    try built.writer.writeByte('[');
    for (0..count) |i| {
        if (i != 0) try built.writer.writeByte(',');
        try built.writer.print("{{\"id\":{d},\"name\":\"host-{d}\",\"state\":\"running\",\"labels\":[\"a\",\"b\"]}}", .{ i, i % 17 });
    }
    try built.writer.writeByte(']');
    return built.toOwnedSlice();
}

test "this root reads gzip" {
    try testing.expect(fetch.reads_gzip);
}

test "a server that gzips regardless of identity is read as plain bytes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 100);
            defer testing.allocator.free(plain);
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(&wire, "200 OK", "Content-Type: application/json\r\n", plain);
            try testing.expect(canned.body_len < plain.len / 4);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            // The caller says identity, and the server gzips anyway: the
            // defect this build answers.
            const res = try client.get(&scope, try canned.url(&buf), .{
                .headers = &.{.{ .name = "accept-encoding", .value = "identity" }},
            });
            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expectEqualStrings(plain, res.body.view());
            try testing.expectEqualStrings("application/json", res.header("content-type").?);
        }
    }.run);
}

test "a call that says nothing about encodings advertises gzip and identity and gets the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 5000);
            defer testing.allocator.free(plain);
            const wire = try testing.allocator.alloc(u8, 256 << 10);
            defer testing.allocator.free(wire);

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(wire, "200 OK", "", plain);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqualStrings(plain, res.body.view());
            try testing.expect(std.mem.indexOf(u8, canned.request(), "accept-encoding: gzip, identity") != null);
        }
    }.run);
}

test "a plain answer is still plain in a build that reads gzip" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("200 OK", "", "just text");

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqualStrings("just text", res.body.view());
        }
    }.run);
}

test "max_body counts the decoded bytes, so a small answer cannot inflate past it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // Four megabytes of one letter is a few kilobytes of gzip.
            const plain = try testing.allocator.alloc(u8, 4 << 20);
            defer testing.allocator.free(plain);
            @memset(plain, 'a');
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(&wire, "200 OK", "", plain);
            try testing.expect(canned.body_len < 8 << 10);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            try testing.expectError(error.BodyTooLarge, client.get(&scope, try canned.url(&buf), .{ .max_body = 64 << 10 }));
        }
    }.run);
}

test "a body under the ceiling is read whole even when the wire was smaller than the ceiling by a hundred times" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try testing.allocator.alloc(u8, 1 << 20);
            defer testing.allocator.free(plain);
            @memset(plain, 'b');
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(&wire, "200 OK", "", plain);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{ .max_body = 1 << 20 });
            try testing.expectEqual(@as(usize, 1 << 20), res.body.len());
        }
    }.run);
}

test "bytes that are not gzip under a gzip header are an error that says so" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("200 OK", "Content-Encoding: gzip\r\n", "<html>an error page from a proxy</html>");

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            try testing.expectError(error.BodyEncodingInvalid, client.get(&scope, try canned.url(&buf), .{}));
        }
    }.run);
}

test "a corrupt gzip stream is an error and so is one that stops early" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 400);
            defer testing.allocator.free(plain);
            var wire: [16 << 10]u8 = undefined;

            for ([_]enum { flipped, cut }{ .flipped, .cut }) |damage| {
                var canned = try Canned.open(io);
                defer canned.close();
                try canned.replyGzip(&wire, "200 OK", "", plain);
                switch (damage) {
                    // A byte in the middle of the stream: a block that no
                    // longer decodes, or a checksum that no longer matches.
                    .flipped => wire[canned.body_len / 2] ^= 0xff,
                    // The footer and a little more gone, as a connection
                    // cut in the middle of a body would leave it.
                    .cut => canned.reply(canned.status, canned.headers, canned.body.?[0 .. canned.body_len - 12]),
                }

                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};

                var client = try started(io, .{});
                defer client.deinit();
                var scope: core.Run = .init(testing.allocator);
                defer scope.deinit();

                var buf: [64]u8 = undefined;
                testing.expectError(error.BodyEncodingInvalid, client.get(&scope, try canned.url(&buf), .{})) catch |err| {
                    std.debug.print("damage {s}\n", .{@tagName(damage)});
                    return err;
                };
            }
        }
    }.run);
}

test "a coding this build does not read is still refused" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("200 OK", "Content-Encoding: zstd\r\n", "not zstd at all");

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            try testing.expectError(error.HttpContentEncodingUnsupported, client.get(&scope, try canned.url(&buf), .{}));
        }
    }.run);
}

test "an Exchange pipes the decoded body, under a stall bound as well" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 3000);
            defer testing.allocator.free(plain);
            const wire = try testing.allocator.alloc(u8, 128 << 10);
            defer testing.allocator.free(wire);

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(wire, "200 OK", "", plain);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var url_buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&url_buf),
                .stall_ms = 5_000,
                .decode = true,
            });
            // The length on the wire, which is not the length of the body.
            try testing.expectEqual(@as(?u64, canned.body_len), head.content_length);

            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            const n = try ex.pipe(&out.writer);
            try testing.expectEqual(@as(u64, plain.len), n);
            try testing.expectEqualStrings(plain, out.written());
        }
    }.run);
}

test "an Exchange that did not ask to decode is handed gzip as an error, as before" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 50);
            defer testing.allocator.free(plain);
            var wire: [8 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyGzip(&wire, "200 OK", "", plain);

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var url_buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            try testing.expectError(error.HttpContentEncodingUnsupported, ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&url_buf),
            }));
        }
    }.run);
}
