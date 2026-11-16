const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Value = std.json.Value;

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

    const Command = enum { help, list, use, rm };

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse fail(out, "unknown command");
    const home = init.environ_map.get("HOME") orelse return error.HomeNotSet;
    switch (cmd) {
        .help => try usage(out),
        .list => try list(io, out, arena, home),
        .use => {
            if (args.len < 3) fail(out, "missing version");
            try use(io, out, arena, init.gpa, home, args[2]);
        },
        .rm => {
            if (args.len < 3) fail(out, "missing version");
            try rm(io, out, arena, home, args[2]);
        },
    }
}

fn list(io: Io, out: *Io.Writer, arena: std.mem.Allocator, home: []const u8) !void {
    const paths: Paths = try .init(home, arena);

    var dir = std.Io.Dir.openDir(.cwd(), io, paths.zup_root, .{ .iterate = true }) catch |err| switch (err) {
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

    if (names.items.len == 0) {
        try out.print("no installs yet\n", .{});
    }

    for (names.items) |name| try out.print("{s}\n", .{name});
}

const Tool = enum { zig, zls };

const ToolMetadata = struct {
    tool: Tool,
    /// Tool version (for .zls this is zls's version; do not build paths from it)
    version: []const u8,
    date: []const u8,
    url: []const u8,
    size: u32,
    shasum: []const u8,

    fn fromZigIndex(index: Value, requested_version: []const u8) !ToolMetadata {
        const release = index.object.get(requested_version) orelse return error.UnknownVersion;
        // Some old releases have no version field
        const version = if (release.object.get("version")) |v| v.string else requested_version;
        const date = (release.object.get("date") orelse return error.BadRelease).string;
        const asset = release.object.get(platform) orelse return error.UnsupportedPlatform;
        const url = (asset.object.get("tarball") orelse return error.BadIndex).string;
        const size = (asset.object.get("size") orelse return error.BadIndex).string;
        const shasum = (asset.object.get("shasum") orelse return error.BadIndex).string;
        return .{
            .tool = .zig,
            .version = version,
            .date = date,
            .url = url,
            .size = try std.fmt.parseInt(u32, size, 10),
            .shasum = shasum,
        };
    }

    fn fromZlsIndex(index: Value) !ToolMetadata {
        const version = (index.object.get("version") orelse return error.UnknownVersion).string;
        const date = (index.object.get("date") orelse return error.BadRelease).string;
        const asset = index.object.get(platform) orelse return error.UnsupportedPlatform;
        const url = (asset.object.get("tarball") orelse return error.BadIndex).string;
        const size = (asset.object.get("size") orelse return error.BadIndex).string;
        const shasum = (asset.object.get("shasum") orelse return error.BadIndex).string;
        return .{
            .tool = .zls,
            .version = version,
            .date = date,
            .url = url,
            .size = try std.fmt.parseInt(u32, size, 10),
            .shasum = shasum,
        };
    }

    fn print(self: ToolMetadata, w: *Io.Writer) !void {
        try w.print(
            \\{s} {s} 
            \\  {Bi:.0}
            \\  {s}
            \\  {s}
            \\  {s}
            \\
        , .{ @tagName(self.tool), self.version, self.size, self.date, self.url, self.shasum });
    }
};

test "tool metadata size" {
    try std.testing.expectEqual(72, @sizeOf(ToolMetadata));
    try std.testing.expectEqual(8, @alignOf(ToolMetadata));
}

const Paths = struct {
    arena: std.mem.Allocator,
    /// zup root directory, typically ~/.zig/zup/
    zup_root: []const u8,
    /// bin directory added to path, typically ~/.zig/bin/
    bin_dir: []const u8,

    fn init(home: []const u8, arena: std.mem.Allocator) !Paths {
        return .{
            .arena = arena,
            .zup_root = try std.fs.path.join(arena, &.{ home, ".zig/zup" }),
            .bin_dir = try std.fs.path.join(arena, &.{ home, ".zig/bin" }),
        };
    }

    fn versionDir(paths: *const Paths, version: []const u8) ![]const u8 {
        return std.fs.path.join(paths.arena, &.{ paths.zup_root, version });
    }

    fn exe(paths: *const Paths, version: []const u8, tool: Tool) ![]const u8 {
        return std.fs.path.join(paths.arena, &.{ paths.zup_root, version, @tagName(tool), @tagName(tool) });
    }

    fn staging(paths: *const Paths, version: []const u8) ![]const u8 {
        return std.fmt.allocPrint(paths.arena, "{s}/{s}.installing", .{ paths.zup_root, version });
    }

    fn stageDir(paths: *const Paths, version: []const u8, tool: Tool) ![]const u8 {
        return std.fmt.allocPrint(paths.arena, "{s}/{s}.installing/{s}", .{ paths.zup_root, version, @tagName(tool) });
    }

    fn link(paths: *const Paths, tool: Tool) ![]const u8 {
        return std.fs.path.join(paths.arena, &.{ paths.bin_dir, @tagName(tool) });
    }
};

test "paths initialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths: Paths = try .init("/home", arena.allocator());
    const version = "0.17.1";

    try std.testing.expectEqualStrings("/home/.zig/zup", paths.zup_root);
    try std.testing.expectEqualStrings("/home/.zig/bin", paths.bin_dir);
    try std.testing.expectEqualStrings("/home/.zig/zup/0.17.1", try paths.versionDir(version));
    try std.testing.expectEqualStrings("/home/.zig/zup/0.17.1/zls/zls", try paths.exe(version, .zls));
    try std.testing.expectEqualStrings("/home/.zig/zup/0.17.1.installing", try paths.staging(version));
    try std.testing.expectEqualStrings("/home/.zig/zup/0.17.1.installing/zig", try paths.stageDir(version, .zig));
    try std.testing.expectEqualStrings("/home/.zig/bin/zig", try paths.link(.zig));
}

/// Ensure that zig and zls are downloaded and extracted to their tool directories
///
/// Cleans up staging directory and tarballs
fn ensure(io: Io, client: *std.http.Client, arena: std.mem.Allocator, paths: *const Paths, zig: ToolMetadata, zls: ToolMetadata) !void {
    const cwd = std.Io.Dir.cwd();
    const version = zig.version;

    if (cwd.statFile(io, try paths.exe(version, .zig), .{})) |_| {
        return;
    } else |_| {}

    const staging = try paths.staging(version);
    cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    errdefer cwd.deleteTree(io, staging) catch {};

    const dl = try std.fs.path.join(arena, &.{ staging, "dl" });
    try cwd.createDirPath(io, dl);

    const zig_archive = try std.fs.path.join(arena, &.{ dl, "zig.tar.xz" });
    try download(io, client, zig.url, zig_archive, zig.shasum);
    const zig_stage = try paths.stageDir(version, .zig);
    try cwd.createDirPath(io, zig_stage);
    try extract(io, zig_archive, zig_stage, .{ .strip_components = 1 });

    const zls_archive = try std.fs.path.join(arena, &.{ dl, "zls.tar.xz" });
    try download(io, client, zls.url, zls_archive, zls.shasum);
    const zls_stage = try paths.stageDir(version, .zls);
    try cwd.createDirPath(io, zls_stage);
    try extract(io, zls_archive, zls_stage, .{});

    try cwd.deleteTree(io, dl);
    try std.Io.Dir.rename(cwd, staging, cwd, try paths.versionDir(version), io);
}

/// Resolves zls metadata corresponding to desired zig version
fn resolveZls(out: *Io.Writer, client: *std.http.Client, arena: std.mem.Allocator, zig_version: []const u8) !ToolMetadata {
    var url: std.Io.Writer.Allocating = .init(arena);
    try url.writer.print(zls_index_url, .{
        std.fmt.alt(std.Uri.Component{ .raw = zig_version }, .formatEscaped),
    });
    const zls_index = try fetch(client, arena, url.written());
    if (zls_index.object.get("message")) |msg| {
        try out.print("error: {s}\n", .{msg.string});
        try out.flush();
        return error.ZlsUnsupported;
    }
    return .fromZlsIndex(zls_index);
}

/// Use wanted version of zig and zls
///
/// Resolves and downloads if necessary; always resolves `master` and `stable`
fn use(io: Io, out: *Io.Writer, arena: std.mem.Allocator, gpa: std.mem.Allocator, home: []const u8, want: []const u8) !void {
    const paths: Paths = try .init(home, arena);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, paths.bin_dir);

    if (cwd.statFile(io, try paths.exe(want, .zig), .{})) |_| {
        try activate(io, out, &paths, want);
        return;
    } else |_| {}

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const index = try fetch(&client, arena, zig_index_url);
    const key = if (std.mem.eql(u8, want, "stable")) latestStable(index) orelse return error.NoStable else want;
    const zig_meta: ToolMetadata = try .fromZigIndex(index, key);
    const zls_meta: ToolMetadata = try resolveZls(out, &client, arena, zig_meta.version);

    try zig_meta.print(out);
    try zls_meta.print(out);
    try out.flush();

    try ensure(io, &client, arena, &paths, zig_meta, zls_meta);
    try activate(io, out, &paths, zig_meta.version);
}

/// Activate wanted verson of zig and zls by symlinking into $HOME/zig/bin
///
/// Fails if zls is missing
fn activate(io: Io, out: *Io.Writer, paths: *const Paths, version: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for (std.enums.values(Tool)) |tool| {
        const target = try paths.exe(version, tool);
        // This can only run if zls is missing
        _ = cwd.statFile(io, target, .{}) catch fail(out, "zls is missing");
        try cwd.symLinkAtomic(io, target, try paths.link(tool), .{});
    }
    try out.print("version {s} is active\n", .{version});
    try out.flush();
}

/// Remove a concrete version
fn rm(io: Io, out: *Io.Writer, arena: std.mem.Allocator, home: []const u8, want: []const u8) !void {
    const paths: Paths = try .init(home, arena);
    const cwd = std.Io.Dir.cwd();
    _ = std.SemanticVersion.parse(want) catch fail(out, "not a version");
    const dest = try paths.versionDir(want);

    _ = cwd.statFile(io, dest, .{}) catch fail(out, "version is not installed");
    try cwd.deleteTree(io, dest);

    for (std.enums.values(Tool)) |tool| {
        const link = try paths.link(tool);
        if (cwd.statFile(io, link, .{})) |_| {} else |_| cwd.deleteFile(io, link) catch {};
    }

    try out.print("removed {s}\n", .{want});
    try out.flush();
}

fn usage(out: *Io.Writer) !void {
    try out.writeAll(
        \\Usage: zup [command]
        \\
        \\Commands:
        \\
        \\  use <version>        use specified zig/zls version
        \\  rm <version>         remove specified zig/zls version
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

fn latestStable(index: Value) ?[]const u8 {
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

/// Fetch untyped JSON from URL
fn fetch(
    client: *std.http.Client,
    arena: std.mem.Allocator,
    url: []const u8,
) !Value {
    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.HttpStatus;
    const response = try std.json.parseFromSlice(Value, arena, body.written(), .{});
    return response.value;
}

/// Download file from URL to path
fn download(io: Io, client: *std.http.Client, url: []const u8, path: []const u8, shasum: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var fw_buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &fw_buf);

    var hash_buf: [4096]u8 = undefined;
    var hashed: Io.Writer.Hashed(std.crypto.hash.sha2.Sha256) =
        .initHasher(&fw.interface, std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &hashed.writer,
    });
    if (res.status != .ok) return error.HttpStatus;

    try hashed.writer.flush();
    try fw.interface.flush();

    const digest = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
    if (!std.ascii.eqlIgnoreCase(&digest, shasum)) return error.ChecksumMismatch;
}

/// Extract compressed tar archive to directory
///
/// If `strip_components` is nonzero, the leading path components will be stripped
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
