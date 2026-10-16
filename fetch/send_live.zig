//! A request body sent under a coding, and a chunked body the caller writes,
//! against a canned server on a real loopback socket
//! ([ADR 293](../docs/adr/293-a-request-body-can-be-sent-gzipped.md)).
//! Everything runs on `std.Io.Threaded`, like the rest of the module's live
//! tests, with a server started by `io.concurrent`.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;
const Reply = fetch.testing.Reply;

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

/// About 4 KB of the JSON an agent posts: repetitive, so gzip halves it
/// several times over.
fn inventory(gpa: std.mem.Allocator) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    for (0..60) |i| try w.writer.print("{{\"id\":{d},\"name\":\"container-{d}\",\"state\":\"running\"}},", .{ i, i % 7 });
    return w.toOwnedSlice();
}

fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch null;
        }
    }
    return null;
}

test "a body sent gzipped arrives gzipped, as long as its compressed bytes, and inflates to the original" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const plain = try inventory(testing.allocator);
            defer testing.allocator.free(plain);
            try testing.expect(plain.len > 2048);

            var buf: [64]u8 = undefined;
            const res = try client.post(&scope, try canned.url(&buf), plain, .{ .encoding = fetch.gzip });

            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expectEqualStrings("gzip", res.sent_encoding.?);
            try testing.expectEqualStrings("gzip", canned.requestEncoding().?);
            const wire = canned.requestBody();
            try testing.expect(wire.len < plain.len / 4);
            try testing.expectEqual(wire.len, contentLength(canned.request()).?);
            const back = try canned.requestBodyDecoded(testing.allocator);
            defer testing.allocator.free(back);
            try testing.expectEqualStrings(plain, back);
        }
    }.run);
}

test "a body under the coding's threshold goes out as it is, and says so" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.post(&scope, try canned.url(&buf), "{\"small\":true}", .{ .encoding = fetch.gzip });
            try testing.expect(res.sent_encoding == null);
            try testing.expect(canned.requestEncoding() == null);
            try testing.expectEqualStrings("{\"small\":true}", canned.requestBody());
        }
    }.run);
}

test "a server that does not read the coding is sent the body again, plain, once" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const script = [_]Reply{
                .{ .status = "415 Unsupported Media Type", .headers = "Accept-Encoding: identity\r\n", .body = "no gzip here" },
                .{ .body = "taken" },
            };
            var served = try io.concurrent(Canned.serveScript, .{ &canned, &script, 2 });
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const plain = try inventory(testing.allocator);
            defer testing.allocator.free(plain);

            var buf: [64]u8 = undefined;
            const res = try client.post(&scope, try canned.url(&buf), plain, .{ .encoding = fetch.gzip });

            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expectEqualStrings("taken", res.body.view());
            // Not coded any more, and the caller can see it.
            try testing.expect(res.sent_encoding == null);
            try testing.expectEqual(@as(usize, 2), canned.tried.count);
            const first = canned.headOfTry(0);
            const second = canned.headOfTry(1);
            try testing.expect(std.ascii.findIgnoreCase(first, "content-encoding: gzip") != null);
            try testing.expect(std.ascii.findIgnoreCase(first, "content-encoding") != null);
            try testing.expect(std.ascii.findIgnoreCase(second, "content-encoding") == null);
            try testing.expect(contentLength(first).? < plain.len / 4);
            try testing.expectEqual(plain.len, contentLength(second).?);
        }
    }.run);
}

test "a 415 that lists the coding is about something else and is not sent again" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const script = [_]Reply{
                .{ .status = "415 Unsupported Media Type", .headers = "Accept-Encoding: gzip, identity\r\n" },
            };
            var served = try io.concurrent(Canned.serveScript, .{ &canned, &script, 1 });
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const plain = try inventory(testing.allocator);
            defer testing.allocator.free(plain);

            var buf: [64]u8 = undefined;
            const res = try client.post(&scope, try canned.url(&buf), plain, .{ .encoding = fetch.gzip });
            try testing.expectEqual(std.http.Status.unsupported_media_type, res.status);
            try testing.expectEqual(@as(usize, 1), canned.tried.count);
            try testing.expectEqualStrings("gzip", res.sent_encoding.?);
        }
    }.run);
}

/// Waits, in short sleeps and at most two seconds, until the server has read
/// `n` chunks. The bound is the point: a chunk that never comes is a failed
/// expectation, not a hung suite.
fn waitForChunks(io: std.Io, canned: *Canned, n: usize) !void {
    for (0..400) |_| {
        if (canned.chunks_seen.load(.acquire) >= n) return;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    return error.ChunkNeverArrived;
}

test "a chunked body the caller writes reaches the server a line at a time, before the caller is done" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveUpload, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            var up: fetch.Exchange.Upload = .{};
            defer up.deinit();
            try ex.beginUpload(&client, &scope, &up, .{ .method = .POST, .url = try canned.url(&buf), .timeout_ms = 0 }, null);

            try up.writer().writeAll("{\"t\":1}\n");
            try up.writer().flush();
            try waitForChunks(io, &canned, 1);
            // The first line is on the server and the caller has not ended.
            try testing.expectEqualStrings("{\"t\":1}\n", canned.uploadSeen());

            try up.writer().writeAll("{\"t\":2}\n");
            try up.writer().flush();
            try waitForChunks(io, &canned, 2);
            try testing.expectEqualStrings("{\"t\":1}\n{\"t\":2}\n", canned.uploadSeen());

            const head = try up.end();
            try testing.expectEqual(std.http.Status.ok, head.status);
            const request = canned.request();
            try testing.expect(std.ascii.findIgnoreCase(request, "transfer-encoding: chunked") != null);
            try testing.expect(std.ascii.findIgnoreCase(request, "content-length") == null);
        }
    }.run);
}

test "a gzipped chunked body can be decoded up to each flush, and to the end" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveUpload, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            var up: fetch.Exchange.Upload = .{};
            defer up.deinit();
            try ex.beginUpload(&client, &scope, &up, .{ .method = .POST, .url = try canned.url(&buf), .timeout_ms = 0 }, fetch.gzip);

            const line1 = "{\"t\":1,\"stream\":\"stdout\"}\n";
            const line2 = "{\"t\":2,\"stream\":\"stderr\"}\n";
            try up.writer().writeAll(line1);
            try up.writer().flush();
            try waitForChunks(io, &canned, 1);

            // What has arrived is a gzip stream cut at a flush, and a reader
            // gets the first line out of it with an empty final block added,
            // which is what the server's next bytes would have supplied.
            var cut: std.ArrayList(u8) = .empty;
            defer cut.deinit(testing.allocator);
            try cut.appendSlice(testing.allocator, canned.uploadSeen());
            try cut.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff });
            try cut.appendNTimes(testing.allocator, 0, 64);
            var in: std.Io.Reader = .fixed(cut.items);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
            var got: [line1.len]u8 = undefined;
            try d.reader.readSliceAll(&got);
            try testing.expectEqualStrings(line1, &got);

            try up.writer().writeAll(line2);
            const head = try up.end();
            try testing.expectEqual(std.http.Status.ok, head.status);

            try testing.expectEqualStrings("gzip", canned.requestEncoding().?);
            const all = try fetch.testing.inflateGzip(testing.allocator, canned.uploadSeen());
            defer testing.allocator.free(all);
            try testing.expectEqualStrings(line1 ++ line2, all);
        }
    }.run);
}

test "an upload on a method that frames no body, or with a body of its own, is refused before anything is dialled" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var ex: fetch.Exchange = .idle;
            defer ex.end();
            var up: fetch.Exchange.Upload = .{};
            defer up.deinit();
            try testing.expectError(error.InvalidUpload, ex.beginUpload(&client, &scope, &up, .{ .method = .GET, .url = "http://127.0.0.1:1/" }, null));
            try testing.expectError(error.InvalidUpload, ex.beginUpload(&client, &scope, &up, .{ .method = .POST, .url = "http://127.0.0.1:1/", .body = .{ .slice = "x" } }, null));
            try testing.expectError(error.InvalidUpload, ex.begin(&client, .{ .method = .POST, .url = "http://127.0.0.1:1/", .body = .{ .upload = &up } }));
        }
    }.run);
}
