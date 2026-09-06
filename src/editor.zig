//! UI-independent editor state. Every text mutation goes through Replica.
const std = @import("std");
const collab = @import("crdt_zig");

pub const Editor = struct {
    replica: *collab.Replica,
    cursor: usize = 0, // Unicode scalar boundary, never a byte offset.
    top_line: usize = 0,
    left_scalar: usize = 0,

    pub fn text(self: *const Editor) []const u8 {
        return self.replica.textView();
    }

    pub fn insert(self: *Editor, value: []const u8) !void {
        if (value.len == 0) return;
        const count = try std.unicode.utf8CountCodepoints(value);
        _ = try self.replica.insert(self.cursor, value);
        self.cursor += count;
    }

    pub fn backspace(self: *Editor) !void {
        if (self.cursor == 0) return;
        _ = try self.replica.delete(self.cursor - 1, 1);
        self.cursor -= 1;
    }

    pub fn delete(self: *Editor) !void {
        if (self.cursor == self.replica.visibleScalarCount()) return;
        _ = try self.replica.delete(self.cursor, 1);
    }

    pub const Direction = enum { left, right, up, down, home, end };

    pub fn move(self: *Editor, direction: Direction) void {
        const value = self.text();
        const loc = location(value, self.cursor);
        switch (direction) {
            .left => self.cursor -|= 1,
            .right => self.cursor = @min(self.cursor + 1, self.replica.visibleScalarCount()),
            .home => self.cursor = loc.start,
            .end => self.cursor = loc.end,
            .up => if (loc.start > 0) {
                const previous = location(value, loc.start - 1);
                self.cursor = previous.start + @min(loc.column, previous.end - previous.start);
            },
            .down => if (loc.end < self.replica.visibleScalarCount()) {
                const next = location(value, loc.end + 1);
                self.cursor = next.start + @min(loc.column, next.end - next.start);
            },
        }
    }
};

pub const Location = struct { line: usize, column: usize, start: usize, end: usize };

pub fn byteOffset(text: []const u8, scalar: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    for (0..scalar) |_| _ = it.nextCodepoint() orelse return text.len;
    return it.i;
}

pub fn location(text: []const u8, cursor: usize) Location {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var scalar: usize = 0;
    var start: usize = 0;
    var line: usize = 0;
    while (it.nextCodepoint()) |cp| : (scalar += 1) {
        if (cp == '\n') {
            if (scalar >= cursor) break;
            line += 1;
            start = scalar + 1;
        }
    }
    return .{ .line = line, .column = cursor - start, .start = start, .end = scalar };
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    editor: Editor,
    document: [32]u8,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, actor: collab.ActorId, document_name: []const u8) !Session {
        var document: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(document_name, &document, .{});
        return .{ .allocator = allocator, .editor = .{ .replica = try collab.Replica.init(allocator, actor) }, .document = document };
    }

    pub fn deinit(self: *Session) void {
        self.editor.replica.deinit();
    }

    pub fn current(self: *Session) *Editor {
        return &self.editor;
    }

    pub fn edited(self: *Session) void {
        self.dirty = true;
    }

    // One durable actor and document identity per client process.
    pub fn encode(self: *Session) ![]u8 {
        const snapshot = try self.editor.replica.save(self.allocator);
        defer self.allocator.free(snapshot);
        const bytes = try self.allocator.alloc(u8, 40 + snapshot.len);
        @memcpy(bytes[0..8], "CRDTNET1");
        @memcpy(bytes[8..40], &self.document);
        @memcpy(bytes[40..], snapshot);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Session {
        if (std.mem.startsWith(u8, bytes, "CRDTUI01")) return error.LegacyTwoReplicaSession;
        if (bytes.len < 40 or !std.mem.eql(u8, bytes[0..8], "CRDTNET1")) return error.InvalidSession;
        return .{ .allocator = allocator, .editor = .{ .replica = try collab.Replica.load(allocator, bytes[40..]) }, .document = bytes[8..40].* };
    }
};

/// UI approximation: treat the changed middle as one splice, with right affinity.
/// This is not a durable CRDT-relative position when a merge changes many regions.
pub fn rebaseCursor(before: []const u8, after: []const u8, cursor: usize) usize {
    var a = std.unicode.Utf8View.initUnchecked(before).iterator();
    var b = std.unicode.Utf8View.initUnchecked(after).iterator();
    var prefix: usize = 0;
    while (true) {
        const ac = a.nextCodepoint() orelse break;
        const bc = b.nextCodepoint() orelse break;
        if (ac != bc) break;
        prefix += 1;
    }
    const old_len = std.unicode.utf8CountCodepoints(before) catch unreachable;
    const new_len = std.unicode.utf8CountCodepoints(after) catch unreachable;
    var old_end = before.len;
    var new_end = after.len;
    var suffix: usize = 0;
    while (suffix < old_len - prefix and suffix < new_len - prefix) {
        var ai = old_end - 1;
        while (before[ai] & 0xc0 == 0x80) ai -= 1;
        var bi = new_end - 1;
        while (after[bi] & 0xc0 == 0x80) bi -= 1;
        if (!std.mem.eql(u8, before[ai..old_end], after[bi..new_end])) break;
        old_end = ai;
        new_end = bi;
        suffix += 1;
    }
    if (cursor < prefix) return cursor;
    if (cursor >= old_len - suffix) return new_len - (old_len - cursor);
    return new_len - suffix;
}

test "Unicode editing and line navigation use scalar boundaries" {
    var session = try Session.init(std.testing.allocator, [_]u8{1} ** 16, "test");
    defer session.deinit();
    const editor = session.current();
    try editor.insert("café\n中🙂");
    editor.move(.up);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
    editor.move(.end);
    try editor.backspace();
    try std.testing.expectEqualStrings("caf\n中🙂", editor.text());
    editor.move(.down);
    try editor.backspace();
    try std.testing.expectEqualStrings("caf\n中", editor.text());
}

test "session retains document actor and history across restart" {
    var session = try Session.init(std.testing.allocator, [_]u8{1} ** 16, "test");
    defer session.deinit();
    try session.current().insert("hello");
    session.current().cursor = 2;
    try session.current().delete();
    try session.current().insert("🙂");
    const bytes = try session.encode();
    defer std.testing.allocator.free(bytes);
    var loaded = try Session.decode(std.testing.allocator, bytes);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &session.document, &loaded.document);
    try std.testing.expectEqualStrings("he🙂lo", loaded.current().text());
    try std.testing.expectEqual(session.editor.replica.stats().next_counter, loaded.editor.replica.stats().next_counter);
}

test "cursor rebasing handles Unicode insertion deletion and unchanged text" {
    try std.testing.expectEqual(@as(usize, 3), rebaseCursor("ab", "中ab", 2));
    try std.testing.expectEqual(@as(usize, 1), rebaseCursor("a🙂b", "ab", 2));
    try std.testing.expectEqual(@as(usize, 1), rebaseCursor("ab", "ab", 1));
}

test "malformed session lengths are rejected" {
    try std.testing.expectError(error.LegacyTwoReplicaSession, Session.decode(std.testing.allocator, "CRDTUI01"));
    try std.testing.expectError(error.InvalidSession, Session.decode(std.testing.allocator, "CRDTNET1"));
}
