const std = @import("std");
const Ast = std.zig.Ast;

const max_lines = 70;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const ls = try io.lockStderr(&.{}, null);
    defer io.unlockStderr();
    const term = ls.terminal();
    const out = &ls.file_writer.interface;

    if (args.len != 2) return 2;

    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, args[1], arena, .unlimited, .of(u8), 0);

    var tree = try Ast.parse(arena, source, .{});
    defer tree.deinit(arena);

    if (tree.errors.len != 0) return error.ParseFailed;

    var bad = false;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name = if (proto.name_token) |t| tree.tokenSlice(t) else "<anonymous>";

        const body = tree.nodeData(node).node_and_node[1];
        const open = tree.tokenLocation(0, tree.firstToken(node)).line + 1;
        const close = tree.tokenLocation(0, tree.lastToken(body)).line + 1;
        const len = close - open + 1;

        if (len > max_lines) {
            try term.setColor(.red);
            bad = true;
        }
        try out.print("{s}:{d} {s}: {d} lines\n", .{ args[1], open, name, len });
        if (len > max_lines) {
            try term.setColor(.reset);
        }
    }

    return if (bad) 1 else 0;
}
