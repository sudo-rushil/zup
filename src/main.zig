const std = @import("std");
const Io = std.Io;

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
        .location = .{ .url = index_url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.HttpStatus;

    const index = (try std.json.parseFromSlice(std.json.Value, arena, body.written(), .{})).value;
    const requested_version = if (std.mem.eql(u8, want, "stable")) latestStable(index) orelse return error.NoStable else want;

    const platform = try std.fmt.allocPrint(arena, "{s}-{s}", .{
        @tagName(@import("builtin").cpu.arch),
        @tagName(@import("builtin").os.tag),
    });

    const release = index.object.get(requested_version) orelse return error.UnknownVersion;
    // Some old releases have no version field
    const version = if (release.object.get("version")) |v| v.string else requested_version;
    const date = (release.object.get("date") orelse return error.BadRelease).string;
    const asset = release.object.get(platform) orelse return error.UnsupportedPlatform;
    const url = (asset.object.get("tarball") orelse return error.BadIndex).string;
    const size = (asset.object.get("size") orelse return error.BadIndex).string;

    try out.print("version {s}\nplatform {s}\ndate {s}\ntarball {s}\nsize {s}\n", .{
        version,
        platform,
        date,
        url,
        size,
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

        try out.print("downloading {s}\n", .{url});
        try out.flush();
        try download(io, &client, url, archive);
        try out.print("extracting\n", .{});
        try out.flush();
        try extract(io, archive, staging);

        const bin = try std.fs.path.join(arena, &.{ staging, "bin" });
        try cwd.createDirPath(io, bin);
        const zig_src = try std.fs.path.join(arena, &.{ staging, "zig" });
        const zig_dst = try std.fs.path.join(arena, &.{ bin, "zig" });
        try std.Io.Dir.rename(cwd, zig_src, cwd, zig_dst, io);

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

const index_url = "https://ziglang.org/download/index.json";

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

fn extract(io: Io, archive: []const u8, dir: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tar", "-xf", archive, "-C", dir, "--strip-components=1" },
        .stdin = .ignore,
    });
    const term = try child.wait(io);
    if (!term.success()) return error.TarFailed;
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }
//
// test "fuzz example" {
//     try std.testing.fuzz({}, testOne, .{});
// }
//
// fn testOne(context: void, smith: *std.testing.Smith) !void {
//     _ = context;
//     // Try command `zig build test --fuzz -Doptimize=ReleaseFast` to see if it manages to fail this test case!
//
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(u8) = .empty;
//     defer list.deinit(gpa);
//     while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
//         .add_data => {
//             const slice = try list.addManyAsSlice(gpa, smith.value(u4));
//             smith.bytes(slice);
//         },
//         .dup_data => {
//             if (list.items.len == 0) continue;
//             if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
//             const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
//             const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
//             try list.appendSlice(gpa, list.items[off..][0..len]);
//             try std.testing.expectEqualSlices(
//                 u8,
//                 list.items[off..][0..len],
//                 list.items[list.items.len - len ..],
//             );
//         },
//     };
// }
