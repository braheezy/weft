//! One TCP peer, bounded frames, and periodic bidirectional anti-entropy.
//! Socket waits never hold the editor mutex. Cancel the worker before freeing
//! the Session or notification context. Only the UI owns start/stop.
const std = @import("std");
const collab = @import("crdt_zig");
const model = @import("editor.zig");
const Io = std.Io;

pub const max_frame = 16 * 1024 * 1024;
pub const Mode = enum { listen, connect };
pub const Status = enum { offline, listening, connecting, connected, retrying };
const Kind = enum(u8) { hello = 1, have = 2, changes = 3, ack = 4 };

pub const Config = struct { mode: Mode, address: Io.net.IpAddress };

pub const Network = struct {
    io: Io,
    allocator: std.mem.Allocator,
    session: *model.Session,
    config: ?Config,
    mutex: Io.Mutex = .init,
    status: Status = .offline,
    last_error: ?anyerror = null,
    received: usize = 0,
    rounds: usize = 0,
    listening_address: ?Io.net.IpAddress = null,
    last_activity: i96 = 0,
    stall_timeout_ns: i96 = 10 * std.time.ns_per_s,
    notify_context: ?*anyopaque = null,
    notify_fn: ?*const fn (*anyopaque) anyerror!void = null,
    worker: ?Io.Future(void) = null,

    pub fn start(self: *Network) !void {
        if (self.worker != null or self.config == null) return;
        self.worker = try self.io.concurrent(run, .{self});
    }

    pub fn stop(self: *Network) void {
        if (self.worker) |*worker| worker.cancel(self.io);
        self.worker = null;
        self.status = .offline;
    }

    fn notify(self: *Network) !void {
        if (self.notify_fn) |callback| try callback(self.notify_context.?);
    }

    fn setStatus(self: *Network, status: Status, err: ?anyerror) !void {
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            self.status = status;
            self.last_error = err;
        }
        try self.notify();
    }

    fn run(self: *Network) void {
        self.runLoop() catch |err| {
            if (err != error.Canceled) {
                self.setStatus(.offline, err) catch {};
            }
        };
    }

    fn runLoop(self: *Network) !void {
        const config = self.config.?;
        if (config.mode == .listen) {
            var server = try config.address.listen(self.io, .{ .reuse_address = true });
            defer server.deinit(self.io);
            try self.mutex.lock(self.io);
            self.listening_address = server.socket.address;
            self.mutex.unlock(self.io);
            while (true) {
                try self.setStatus(.listening, self.last_error);
                const stream = try server.accept(self.io);
                defer stream.close(self.io);
                self.withWatchdog(stream) catch |err| {
                    if (err == error.Canceled) return err;
                    try self.setStatus(.retrying, if (err == error.EndOfStream) null else err);
                };
            }
        } else {
            while (true) {
                try self.setStatus(.connecting, self.last_error);
                self.withWatchdog(null) catch |err| {
                    if (err == error.Canceled) return err;
                    try self.setStatus(.retrying, err);
                };
                try self.io.sleep(.fromSeconds(1), .awake);
            }
        }
    }

    fn connectOnce(self: *Network, accepted: ?Io.net.Stream) !void {
        if (accepted) |stream| return self.connection(stream, .listen);
        // Zig 0.16's Threaded backend does not implement connect's timeout
        // option. The cancellable watchdog below covers dial and stream stalls.
        const stream = try self.config.?.address.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(self.io);
        try self.connection(stream, .connect);
    }

    fn withWatchdog(self: *Network, accepted: ?Io.net.Stream) !void {
        try self.mutex.lock(self.io);
        self.last_activity = Io.Clock.awake.now(self.io).nanoseconds;
        self.mutex.unlock(self.io);
        const Result = union(enum) { exchange: anyerror!void, timeout: anyerror!void };
        var buffer: [2]Result = undefined;
        var select = Io.Select(Result).init(self.io, &buffer);
        defer select.cancelDiscard();
        try select.concurrent(.exchange, connectOnce, .{ self, accepted });
        try select.concurrent(.timeout, watchdog, .{self});
        switch (try select.await()) {
            .exchange => |result| return result,
            .timeout => |result| {
                try result;
                return error.PeerTimeout;
            },
        }
    }

    fn watchdog(self: *Network) !void {
        while (true) {
            try self.io.sleep(.fromSeconds(1), .awake);
            try self.mutex.lock(self.io);
            const stalled = Io.Clock.awake.now(self.io).nanoseconds - self.last_activity > self.stall_timeout_ns;
            self.mutex.unlock(self.io);
            if (stalled) return;
        }
    }

    fn connection(self: *Network, stream: Io.net.Stream, mode: Mode) !void {
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        self.exchange(&reader.interface, &writer.interface, mode) catch |err| {
            // Preserve cancellation hidden behind Reader/Writer's error sets.
            if (reader.err) |read_error| return read_error;
            if (writer.err) |write_error| return write_error;
            return err;
        };
    }

    fn exchange(self: *Network, reader: *Io.Reader, writer: *Io.Writer, mode: Mode) !void {
        const greeting = try self.hello();
        try sendFrame(writer, .hello, &greeting);
        const peer = try receiveFrame(self.allocator, reader, .hello);
        defer self.allocator.free(peer);
        try validateHello(&greeting, peer);
        try self.setStatus(.connected, null);
        while (true) {
            if (mode == .connect) {
                try self.sendHave(writer);
                try self.receiveChanges(reader);
                try self.sendMissing(reader, writer);
                const ack = try receiveFrame(self.allocator, reader, .ack);
                defer self.allocator.free(ack);
                if (ack.len != 0) return error.InvalidFrame;
                try self.io.sleep(.fromMilliseconds(100), .awake);
            } else {
                try self.sendMissing(reader, writer);
                try self.sendHave(writer);
                try self.receiveChanges(reader);
                try sendFrame(writer, .ack, &.{});
            }
            try self.mutex.lock(self.io);
            self.rounds += 1;
            self.last_activity = Io.Clock.awake.now(self.io).nanoseconds;
            self.mutex.unlock(self.io);
        }
    }

    fn hello(self: *Network) ![57]u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var bytes: [57]u8 = undefined;
        @memcpy(bytes[0..8], "CRDTTCP1");
        @memcpy(bytes[8..40], &self.session.document);
        @memcpy(bytes[40..56], &self.session.editor.replica.actorId());
        bytes[56] = @intFromEnum(self.session.editor.replica.orderingMode());
        return bytes;
    }

    fn sendHave(self: *Network, writer: *Io.Writer) !void {
        const bytes = blk: {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            break :blk try self.session.editor.replica.encodeHave(self.allocator);
        };
        defer self.allocator.free(bytes);
        try sendFrame(writer, .have, bytes);
    }

    fn sendMissing(self: *Network, reader: *Io.Reader, writer: *Io.Writer) !void {
        const bytes = try receiveFrame(self.allocator, reader, .have);
        defer self.allocator.free(bytes);
        var have = try collab.Have.decode(self.allocator, bytes, .{});
        defer have.deinit();
        var log = collab.ChangeLog.init(self.allocator);
        defer log.deinit();
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            var cursor = try collab.SyncCursor.init(self.allocator, &have);
            defer cursor.deinit();
            var batch = try cursor.next(self.session.editor.replica, 256, self.allocator);
            defer batch.deinit(self.allocator);
            try log.appendBatch(batch.changes.items);
        }
        try sendFrame(writer, .changes, log.bytesView());
    }

    fn receiveChanges(self: *Network, reader: *Io.Reader) !void {
        const bytes = try receiveFrame(self.allocator, reader, .changes);
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const editor = &self.session.editor;
            const before = try editor.replica.text(self.allocator);
            defer self.allocator.free(before);
            const result = try editor.replica.replayLog(bytes, .{ .limits = .{ .max_input_bytes = max_frame, .max_log_frames = 256, .max_frame_bytes = max_frame, .max_insert_bytes = max_frame } });
            editor.cursor = model.rebaseCursor(before, editor.text(), editor.cursor);
            if (result.frames != result.duplicates) self.session.dirty = true;
            self.received += result.applied;
        }
        try self.notify();
    }
};

fn validateHello(ours: []const u8, peer: []const u8) !void {
    if (peer.len != 57 or !std.mem.eql(u8, peer[0..8], "CRDTTCP1")) return error.ProtocolMismatch;
    if (!std.mem.eql(u8, peer[8..40], ours[8..40])) return error.DocumentMismatch;
    if (std.mem.eql(u8, peer[40..56], ours[40..56])) return error.DuplicateActor;
    if (peer[56] != ours[56]) return error.OrderingMismatch;
}

test "TCP peers converge across multiple batches disconnect edits and restart" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var a = try model.Session.init(allocator, [_]u8{1} ** 16, "tcp-test");
    defer a.deinit();
    var b = try model.Session.init(allocator, [_]u8{2} ** 16, "tcp-test");
    defer b.deinit();
    for (0..270) |_| try a.current().insert("a");
    try b.current().insert("B");

    var host = Network{ .io = io, .allocator = allocator, .session = &a, .config = .{ .mode = .listen, .address = .{ .ip4 = .loopback(0) } } };
    try host.start();
    defer host.stop();
    var address: ?Io.net.IpAddress = null;
    for (0..200) |_| {
        try host.mutex.lock(io);
        address = host.listening_address;
        host.mutex.unlock(io);
        if (address != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    var peer = Network{ .io = io, .allocator = allocator, .session = &b, .config = .{ .mode = .connect, .address = address orelse return error.ListenerTimeout } };
    try peer.start();
    defer peer.stop();
    try waitConverged(&host, &peer, 271);

    peer.stop();
    {
        try host.mutex.lock(io);
        defer host.mutex.unlock(io);
        a.current().cursor = 1;
        try a.current().delete();
    }
    b.current().cursor = 1;
    try b.current().delete();
    try b.current().insert("🙂");
    const saved = try b.encode();
    defer allocator.free(saved);
    const loaded = try model.Session.decode(allocator, saved);
    b.deinit();
    b = loaded;
    try peer.start();
    try waitConverged(&host, &peer, 274);
}

fn waitConverged(a: *Network, b: *Network, history: usize) !void {
    for (0..500) |_| {
        const equal = blk: {
            try a.mutex.lock(a.io);
            defer a.mutex.unlock(a.io);
            try b.mutex.lock(b.io);
            defer b.mutex.unlock(b.io);
            const ar = a.session.editor.replica;
            const br = b.session.editor.replica;
            break :blk ar.historyCount() == history and br.historyCount() == history and
                ar.pendingCount() == 0 and br.pendingCount() == 0 and
                std.mem.eql(u8, ar.textView(), br.textView());
        };
        if (equal) return;
        try a.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ConvergenceTimeout;
}

fn sendFrame(writer: *Io.Writer, kind: Kind, bytes: []const u8) !void {
    if (bytes.len > max_frame) return error.FrameTooLarge;
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .big);
    try writer.writeAll(&header);
    try writer.writeAll(bytes);
    try writer.flush();
}

fn receiveFrame(allocator: std.mem.Allocator, reader: *Io.Reader, expected: Kind) ![]u8 {
    const header = try reader.takeArray(5);
    if (header[0] != @intFromEnum(expected)) return error.UnexpectedFrame;
    const length = std.mem.readInt(u32, header[1..5], .big);
    if (length > max_frame) return error.FrameTooLarge;
    return reader.readAlloc(allocator, length);
}

test "wire rejects oversized truncated and unexpected frames" {
    var oversized = Io.Reader.fixed(&.{ 2, 255, 255, 255, 255 });
    try std.testing.expectError(error.FrameTooLarge, receiveFrame(std.testing.allocator, &oversized, .have));
    var truncated = Io.Reader.fixed(&.{ 2, 0, 0, 0, 2, 1 });
    try std.testing.expectError(error.EndOfStream, receiveFrame(std.testing.allocator, &truncated, .have));
    var wrong = Io.Reader.fixed(&.{ 3, 0, 0, 0, 0 });
    try std.testing.expectError(error.UnexpectedFrame, receiveFrame(std.testing.allocator, &wrong, .have));
}

test "hello refuses different documents duplicate actors and ordering" {
    var hello: [57]u8 = @splat(0);
    @memcpy(hello[0..8], "CRDTTCP1");
    var peer = hello;
    try std.testing.expectError(error.DuplicateActor, validateHello(&hello, &peer));
    peer[40] = 1;
    try validateHello(&hello, &peer);
    peer[8] = 1;
    try std.testing.expectError(error.DocumentMismatch, validateHello(&hello, &peer));
    peer[8] = 0;
    peer[56] = 1;
    try std.testing.expectError(error.OrderingMismatch, validateHello(&hello, &peer));
}

test "a stalled handshake times out and leaves the listener reusable" {
    const io = std.testing.io;
    var session = try model.Session.init(std.testing.allocator, [_]u8{3} ** 16, "timeout-test");
    defer session.deinit();
    var host = Network{
        .io = io,
        .allocator = std.testing.allocator,
        .session = &session,
        .config = .{ .mode = .listen, .address = .{ .ip4 = .loopback(0) } },
        .stall_timeout_ns = 100 * std.time.ns_per_ms,
    };
    try host.start();
    defer host.stop();
    var address: ?Io.net.IpAddress = null;
    for (0..200) |_| {
        try host.mutex.lock(io);
        address = host.listening_address;
        host.mutex.unlock(io);
        if (address != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const endpoint = address orelse return error.ListenerTimeout;
    const idle = try endpoint.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer idle.close(io);
    for (0..250) |_| {
        try host.mutex.lock(io);
        const timed_out = host.status == .listening and (if (host.last_error) |err| err == error.PeerTimeout else false);
        host.mutex.unlock(io);
        if (timed_out) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WatchdogFailed;
}
