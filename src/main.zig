const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
        .list => try usage(out),
        .use, .install => {
            if (args.len < 3) fail(out, "missing version");
            try out.print("{s} {s}\n", .{ @tagName(cmd), args[2] });
        },
    }
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

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try command `zig build test --fuzz -Doptimize=ReleaseFast` to see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
