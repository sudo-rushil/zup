const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const platform = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
const zig_index_url = "https://ziglang.org/download/index.json";
const zls_index_url = "https://releases.zigtools.org/v1/zls/select-version?zig_version={f}&compatibility=only-runtime";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try usage(out);
        return;
    }

    const Command = enum { list, use, install, help };

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse fail(out, "unknown command");
    switch (cmd) {
        .help => try usage(out),
        .list => try list(io, out, init.environ_map, arena),
        .install => {
            if (args.len < 3) fail(out, "missing version");
            try install(io, out, init.environ_map, arena, init.gpa, args[2]);
        },
        .use => {
            if (args.len < 3) fail(out, "missing version");
            try use(io, out, init.environ_map, arena, args[2]);
        },
    }
}

fn list(io: Io, out: *Io.Writer, env: *std.process.Environ.Map, arena: std.mem.Allocator) !void {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    const path = try std.fs.path.join(arena, &.{ home, ".zig/zup" });

    var dir = std.Io.Dir.openDir(.cwd(), io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("no installs yet\n", .{});
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, lessVersion);

    for (names.items) |name| try out.print("{s}\n", .{name});
}

fn install(io: Io, out: *Io.Writer, env: *std.process.Environ.Map, arena: std.mem.Allocator, gpa: std.mem.Allocator, want: []const u8) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = zig_index_url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.HttpStatus;

    const index = (try std.json.parseFromSlice(std.json.Value, arena, body.written(), .{})).value;
    const requested_version = if (std.mem.eql(u8, want, "stable")) latestStable(index) orelse return error.NoStable else want;

    const release = index.object.get(requested_version) orelse return error.UnknownVersion;
    // Some old releases have no version field
    const version = if (release.object.get("version")) |v| v.string else requested_version;
    const date = (release.object.get("date") orelse return error.BadRelease).string;
    const asset = release.object.get(platform) orelse return error.UnsupportedPlatform;
    const url = (asset.object.get("tarball") orelse return error.BadIndex).string;
    const size = (asset.object.get("size") orelse return error.BadIndex).string;

    try out.print("version {s}\nplatform {s}\ndate {s}\ntarball {s}\nsize {Bi:.0}\n", .{
        version,
        platform,
        date,
        url,
        try std.fmt.parseInt(u32, size, 10),
    });
    try out.flush();

    const home = env.get("HOME") orelse return error.HomeNotSet;
    const root = try std.fs.path.join(arena, &.{ home, ".zig/zup" });
    const dest = try std.fs.path.join(arena, &.{ root, version });
    const staging = try std.fmt.allocPrint(arena, "{s}/{s}.installing", .{ root, version });
    const archive = try std.fmt.allocPrint(arena, "{s}/{s}.tar.xz", .{ root, version });

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);

    cwd.access(io, dest, .{}) catch {
        cwd.deleteTree(io, staging) catch {};
        try cwd.createDirPath(io, staging);
        errdefer cwd.deleteTree(io, staging) catch {};

        try out.print("downloading {s}\n", .{url});
        try out.flush();
        errdefer cwd.deleteFile(io, archive) catch {};
        try download(io, &client, url, archive);
        try out.print("extracting\n", .{});
        try out.flush();
        try extract(io, archive, staging, .{ .strip_components = 1 });

        const bin = try std.fs.path.join(arena, &.{ staging, "bin" });
        try cwd.createDirPath(io, bin);
        const zig_src = try std.fs.path.join(arena, &.{ staging, "zig" });
        const zig_dst = try std.fs.path.join(arena, &.{ bin, "zig" });
        try std.Io.Dir.rename(cwd, zig_src, cwd, zig_dst, io);

        try downloadZls(io, out, &client, arena, version, bin);

        try std.Io.Dir.rename(cwd, staging, cwd, dest, io);
        cwd.deleteFile(io, archive) catch {};

        if (!std.mem.eql(u8, version, requested_version)) {
            const alias = try std.fs.path.join(arena, &.{ root, requested_version });
            cwd.deleteFile(io, alias) catch {};
            try cwd.symLinkAtomic(io, dest, alias, .{ .is_directory = true });
        }

        return;
    };
    try out.print("already installed {s}\n", .{version});
}

fn use(io: Io, out: *Io.Writer, env: *std.process.Environ.Map, arena: std.mem.Allocator, want: []const u8) !void {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    const sym_link_path = try std.fs.path.join(arena, &.{ home, ".zig/bin" });
    const target_path = try std.fs.path.join(arena, &.{ home, ".zig/zup", want, "bin" });

    const cwd = std.Io.Dir.cwd();
    cwd.access(io, target_path, .{}) catch fail(out, "version missing");
    try cwd.symLinkAtomic(io, target_path, sym_link_path, .{ .is_directory = true });

    try out.print("version {s} is now active\n", .{want});
    try out.flush();
}

fn usage(out: *Io.Writer) !void {
    try out.writeAll(
        \\Usage: zup [command]
        \\
        \\Commands:
        \\
        \\  install <version>    install zig/zls
        \\  use <version>        use specified zig/zls version
        \\  list                 list all available versions
        \\  help                 display this help text
        \\
    );
}

fn fail(out: *Io.Writer, msg: []const u8) noreturn {
    out.print("{s}\n\n", .{msg}) catch {};
    usage(out) catch {};
    out.flush() catch {};
    std.process.exit(2);
}

fn lessVersion(_: void, a: []const u8, b: []const u8) bool {
    const va = std.SemanticVersion.parse(a) catch return std.mem.lessThan(u8, a, b);
    const vb = std.SemanticVersion.parse(b) catch return std.mem.lessThan(u8, a, b);
    return va.order(vb) == .lt;
}

test "semantic versions are correctly ordered" {
    try std.testing.expect(lessVersion({}, "0.16.0", "0.17.0"));
    try std.testing.expect(!lessVersion({}, "0.17.0", "0.16.0"));
    try std.testing.expect(!lessVersion({}, "0.17.0", "0.17.0"));
    try std.testing.expect(lessVersion({}, "0.16.0", "0.17.0-dev.1024"));
    try std.testing.expect(lessVersion({}, "0.17.0-dev.1024", "0.17.0"));
}

fn latestStable(index: std.json.Value) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_ver: ?std.SemanticVersion = null;
    var it = index.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "master")) continue;
        const v = std.SemanticVersion.parse(e.key_ptr.*) catch continue;
        if (best_ver == null or v.order(best_ver.?) == .gt) {
            best_ver = v;
            best = e.key_ptr.*;
        }
    }
    return best;
}

fn download(io: Io, client: *std.http.Client, url: []const u8, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fw.interface,
    });
    try fw.interface.flush();
    if (res.status != .ok) return error.HttpStatus;
}

/// Extract compressed tar archive to directory.
///
/// If `strip_components` is nonzero, the leading path components will be stripped.
fn extract(io: Io, archive: []const u8, dir: []const u8, opts: struct { strip_components: u32 = 0 }) !void {
    var flag_buf: [32]u8 = undefined;
    var argv: [6][]const u8 = undefined;
    argv[0..5].* = .{ "tar", "-xf", archive, "-C", dir };
    var n: usize = 5;
    if (opts.strip_components != 0) {
        argv[n] = try std.mem.print(&flag_buf, "--strip-components={d}", .{opts.strip_components});
        n += 1;
    }
    var child = try std.process.spawn(io, .{
        .argv = argv[0..n],
        .stdin = .ignore,
    });
    const term = try child.wait(io);
    if (!term.success()) return error.TarFailed;
}

test "extract" {
    const io = std.testing.io;
    try extract(io, "./test.tar.xz", "/tmp/out-strip", .{ .strip_components = 1 });
    try extract(io, "./test.tar.xz", "/tmp/out", .{});
}

fn downloadZls(io: Io, out: *Io.Writer, client: *std.http.Client, arena: std.mem.Allocator, version: []const u8, dir: []const u8) !void {
    var url: std.Io.Writer.Allocating = .init(arena);
    try url.writer.print(zls_index_url, .{
        std.fmt.alt(std.Uri.Component{ .raw = version }, .formatEscaped),
    });

    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url.written() },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.HttpStatus;

    const index = (try std.json.parseFromSlice(std.json.Value, arena, body.written(), .{})).value;

    if (index.object.get("message")) |msg| {
        try out.print("error: {s}\n", .{msg.string});
        return error.ZlsUnsupported;
    }

    const zls_version = (index.object.get("version") orelse return error.UnknownVersion).string;
    const date = (index.object.get("date") orelse return error.BadRelease).string;
    const asset = index.object.get(platform) orelse return error.UnsupportedPlatform;
    const zls_url = (asset.object.get("tarball") orelse return error.BadIndex).string;
    const zls_size = (asset.object.get("size") orelse return error.BadIndex).string;

    try out.print("zls version {s}\ndate {s}\ntarball {s}\nsize {s}\n", .{
        zls_version,
        date,
        zls_url,
        zls_size,
    });
    try out.flush();

    const archive = try std.fmt.allocPrint(arena, "{s}/{s}.tar.xz", .{ dir, version });
    var file = try std.Io.Dir.cwd().createFile(io, archive, .{});

    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);
    const archive_res = try client.fetch(.{
        .location = .{ .url = zls_url },
        .response_writer = &fw.interface,
    });
    try fw.interface.flush();
    if (archive_res.status != .ok) return error.HttpStatus;
    file.close(io);

    var child = try std.process.spawn(io, .{ .argv = &.{ "tar", "-xf", archive, "-C", dir }, .stdin = .ignore });
    const term = try child.wait(io);
    if (!term.success()) return error.TarFailed;

    std.Io.Dir.cwd().deleteFile(io, archive) catch {};

    return;
}
