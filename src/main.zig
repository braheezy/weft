//! One persistent replica per process, with optional TCP collaboration.
const std = @import("std");
const vaxis = @import("vaxis");
const model = @import("editor.zig");
const networking = @import("network.zig");

pub const std_options: std.Options = .{ .log_level = .err };

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    network,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try parseArgs(args);
    if (config.help) {
        var out_buffer: [1024]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &out_buffer);
        try out.interface.writeAll(
            "Usage: weft [--listen IP:PORT | --connect IP:PORT]\n" ++
                "                   [--session FILE] [--document NAME]\n\n" ++
                "Default session: replica.crdt; default document: shared\n" ++
                "Use a different session file on each peer. IP literals support IPv4\n" ++
                "and [IPv6]:port. TCP is intended for a trusted LAN or Tailscale.\n" ++
                "Ctrl-O toggles networking; Ctrl-S saves; Ctrl-Q quits.\n",
        );
        try out.interface.flush();
        return;
    }
    const path = config.path;
    // Keep a stable lock inode while the snapshot is atomically replaced.
    const lock_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}.lock", .{path});
    const lock_file = try std.Io.Dir.cwd().createFile(init.io, lock_path, .{ .truncate = false });
    defer lock_file.close(init.io);
    if (!try lock_file.tryLock(init.io, .exclusive)) return error.SessionInUse;
    var session = blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                var actor: [16]u8 = undefined;
                try init.io.randomSecure(&actor);
                break :blk try model.Session.init(allocator, actor, config.document);
            },
            else => return err,
        };
        defer allocator.free(bytes);
        break :blk try model.Session.decode(allocator, bytes);
    };
    defer session.deinit();
    var document_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config.document, &document_hash, .{});
    if (!std.mem.eql(u8, &session.document, &document_hash)) return error.DocumentMismatch;
    var message: []const u8 = "Type to edit. Ctrl-S saves this replica; Ctrl-O toggles networking.";
    var quit_armed = false;
    var frame = std.heap.ArenaAllocator.init(allocator);
    defer frame.deinit();
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &buffer);
    defer tty.deinit();
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());
    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    const signal_resize = !vx.state.in_band_resize;
    if (signal_resize) try loop.installResizeHandler();
    defer if (signal_resize) loop.uninstallResizeHandler();

    var network = networking.Network{
        .io = init.io,
        .allocator = allocator,
        .session = &session,
        .config = config.network,
        .notify_context = &loop,
        .notify_fn = notifyNetwork,
    };
    try network.start();
    defer network.stop();

    while (true) {
        {
            try network.mutex.lock(init.io);
            defer network.mutex.unlock(init.io);
            try draw(frame.allocator(), &vx, &session, &network, path, message);
            try vx.render(tty.writer());
        }
        _ = frame.reset(.retain_capacity);
        switch (try loop.nextEvent()) {
            .key_press => |key| {
                if (key.matches('o', .{ .ctrl = true })) {
                    if (network.worker != null) {
                        network.stop();
                        message = "Offline. Local edits continue; Ctrl-O reconnects.";
                    } else {
                        try network.start();
                        message = if (config.network == null) "Start with --listen or --connect to enable networking." else "Networking resumed.";
                    }
                    continue;
                }
                try network.mutex.lock(init.io);
                defer network.mutex.unlock(init.io);
                if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
                    if (!session.dirty or quit_armed) return;
                    quit_armed = true;
                    message = "Unsaved edits. Ctrl-S saves; Ctrl-Q again discards and quits.";
                    continue;
                }
                quit_armed = false;
                handleKey(init.io, key, &session, path, &message) catch |err| {
                    message = @errorName(err);
                };
            },
            .winsize => |size| try vx.resize(allocator, tty.writer(), size),
            .network => {},
        }
    }
}

fn notifyNetwork(context: *anyopaque) !void {
    const loop: *vaxis.Loop(Event) = @ptrCast(@alignCast(context));
    try loop.postEvent(.network);
}

const Config = struct {
    path: []const u8 = "replica.crdt",
    document: []const u8 = "shared",
    network: ?networking.Config = null,
    help: bool = false,
};

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        if (std.mem.eql(u8, arg, "--session")) {
            config.path = args[i];
        } else if (std.mem.eql(u8, arg, "--document")) {
            config.document = args[i];
        } else if (std.mem.eql(u8, arg, "--listen") or std.mem.eql(u8, arg, "--connect")) {
            if (config.network != null) return error.ChooseListenOrConnect;
            const address = try std.Io.net.IpAddress.parseLiteral(args[i]);
            if (address.getPort() == 0) return error.InvalidPort;
            config.network = .{ .mode = if (std.mem.eql(u8, arg, "--listen")) .listen else .connect, .address = address };
        } else return error.UnknownArgument;
    }
    if (config.document.len == 0 or config.path.len == 0) return error.EmptyArgument;
    return config;
}

fn handleKey(io: std.Io, key: vaxis.Key, session: *model.Session, path: []const u8, message: *[]const u8) !void {
    const ctrl = vaxis.Key.Modifiers{ .ctrl = true };
    if (key.matches('s', ctrl)) {
        const bytes = try session.encode();
        defer session.allocator.free(bytes);
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.file.writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.flush();
        try file.file.sync(io);
        try file.replace(io);
        session.dirty = false;
        message.* = "Saved this replica and its complete history.";
        return;
    }
    const editor = session.current();
    const directions = .{
        .{ vaxis.Key.left, model.Editor.Direction.left },
        .{ vaxis.Key.right, model.Editor.Direction.right },
        .{ vaxis.Key.up, model.Editor.Direction.up },
        .{ vaxis.Key.down, model.Editor.Direction.down },
        .{ vaxis.Key.home, model.Editor.Direction.home },
        .{ vaxis.Key.end, model.Editor.Direction.end },
    };
    inline for (directions) |pair| {
        if (key.matches(pair[0], .{})) {
            editor.move(pair[1]);
            return;
        }
    }
    const before = editor.replica.historyCount();
    if (key.matches(vaxis.Key.backspace, .{})) {
        try editor.backspace();
    } else if (key.matches(vaxis.Key.delete, .{})) {
        try editor.delete();
    } else if (key.matches(vaxis.Key.enter, .{})) {
        try editor.insert("\n");
    } else if (!key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.meta) {
        if (key.text) |text| {
            try editor.insert(text);
        } else if (key.codepoint >= 32 and key.codepoint < 0xe000 and key.codepoint != 127) {
            var encoded: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(key.shifted_codepoint orelse key.codepoint, &encoded);
            try editor.insert(encoded[0..len]);
        }
    }
    if (editor.replica.historyCount() != before) {
        session.edited();
        message.* = "Local edit retained. Connected peers receive changes automatically.";
    }
}

const muted: vaxis.Style = .{ .fg = .{ .index = 8 } };
const accent: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };

fn line(window: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= window.height) return;
    _ = window.child(.{ .y_off = @intCast(row), .height = 1 }).print(&.{.{ .text = text, .style = style }}, .{ .wrap = .none });
}

fn draw(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, session: *model.Session, network: *networking.Network, path: []const u8, message: []const u8) !void {
    const window = vx.window();
    window.clear();
    if (window.width < 32 or window.height < 9) {
        line(window, 0, "Enlarge terminal to at least 32 x 9", accent);
        return;
    }
    const header = try std.fmt.allocPrint(allocator, " CRDT / {s}  {s}", .{ path, if (session.dirty) "* unsaved" else "saved" });
    line(window, 0, header, accent);
    const endpoint = if (network.config) |config|
        try std.fmt.allocPrint(allocator, "{s} {f}", .{ @tagName(config.mode), config.address })
    else
        "local";
    const status = try std.fmt.allocPrint(allocator, " {s} / {s} / received {}  {s}", .{ @tagName(network.status), endpoint, network.received, if (network.last_error) |err| @errorName(err) else "" });
    line(window, 1, status, muted);
    const body_height = window.height - 5;
    {
        const pane = window.child(.{
            .y_off = 2,
            .width = window.width,
            .height = body_height,
            .border = .{ .where = .all, .style = accent },
        });
        try drawEditor(allocator, pane, &session.editor);
    }
    line(window, window.height - 3, message, muted);
    line(window, window.height - 2, " ^O connect/disconnect  /  automatic peer sync", accent);
    line(window, window.height - 1, " Arrows/Home/End move  ^S save  ^Q quit", accent);
}

fn drawEditor(allocator: std.mem.Allocator, pane: vaxis.Window, editor: *model.Editor) !void {
    if (pane.height < 3 or pane.width < 3) return;
    const loc = model.location(editor.text(), editor.cursor);
    const title = try std.fmt.allocPrint(allocator, "Document  Ln {}:{}  ops {}  heads {}", .{
        loc.line + 1,                  loc.column + 1,
        editor.replica.historyCount(), editor.replica.frontierView().len,
    });
    line(pane, 0, title, accent);
    const body = pane.child(.{ .y_off = 2 });
    if (body.height == 0) return;
    if (loc.line < editor.top_line) editor.top_line = loc.line;
    if (loc.line >= editor.top_line + body.height) editor.top_line = loc.line - body.height + 1;
    // Keep a conservative scalar window: a scalar can occupy two terminal cells.
    const span = @max(@as(usize, 1), (body.width - 1) / 2);
    if (loc.column < editor.left_scalar) editor.left_scalar = loc.column;
    if (loc.column >= editor.left_scalar + span) editor.left_scalar = loc.column - span + 1;

    var lines = std.mem.splitScalar(u8, editor.text(), '\n');
    var logical_line: usize = 0;
    while (lines.next()) |text| : (logical_line += 1) {
        if (logical_line < editor.top_line) continue;
        const row = logical_line - editor.top_line;
        if (row >= body.height) break;
        const start = model.byteOffset(text, editor.left_scalar);
        line(body, @intCast(row), text[start..], .{});
        if (logical_line == loc.line) {
            const end = model.byteOffset(text, loc.column);
            const col = vaxis.gwidth.gwidth(text[start..end], body.screen.width_method);
            body.showCursor(@min(col, body.width - 1), @intCast(row));
        }
    }
}
