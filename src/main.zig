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
        .use, .install => {
            if (args.len < 3) fail(out, "missing version");
            try out.print("{s} {s}\n", .{ @tagName(cmd), args[2] });
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
