// AST/IR Inspection routines are in a separate compilation unit to avoid pulling in any
// dependencies on i/o output (which may not be supported in a freestanding environment).

const debug = @import("std").debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");

const Expr = parse.Expr;
const Instruction = compile.Instruction;
const InstructionData = compile.InstructionData;
const Program = compile.Program;

pub fn printCharEscaped(ch: u8) void {
    switch (ch) {
        '\t' => {
            debug.warn("\\t", .{});
        },
        '\r' => {
            debug.warn("\\r", .{});
        },
        '\n' => {
            debug.warn("\\n", .{});
        },
        // printable characters
        32...126 => {
            debug.warn("{c}", .{ch});
        },
        else => {
            debug.warn("0x{x}", .{ch});
        },
    }
}

pub fn dumpExpr(e: Expr) void {
    dumpExprIndent(e, 0);
}

fn dumpExprIndent(e: Expr, indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        debug.warn(" ", .{});
    }

    switch (e) {
        Expr.AnyCharNotNL => {
            debug.warn("{s}\n", .{@tagName(e)});
        },
        Expr.EmptyMatch => |assertion| {
            debug.warn("{s}({s})\n", .{ @tagName(e), @tagName(assertion) });
        },
        Expr.Literal => |lit| {
            debug.warn("{s}(", .{@tagName(e)});
            printCharEscaped(lit);
            debug.warn(")\n", .{});
        },
        Expr.Capture => |subexpr| {
            debug.warn("{s}\n", .{@tagName(e)});
            dumpExprIndent(subexpr.*, indent + 1);
        },
        Expr.Repeat => |repeat| {
            debug.warn("{s}(min={d}, max={d}, greedy={d})\n", .{ @tagName(e), repeat.min, repeat.max, repeat.greedy });
            dumpExprIndent(repeat.subexpr.*, indent + 1);
        },
        Expr.ByteClass => |class| {
            debug.warn("{s}(", .{@tagName(e)});
            for (class.ranges.items) |r| {
                debug.warn("[", .{});
                printCharEscaped(r.min);
                debug.warn("-", .{});
                printCharEscaped(r.max);
                debug.warn("]", .{});
            }
            debug.warn(")\n", .{});
        },
        // TODO: Can we get better type unification on enum variants with the same type?
        Expr.Concat => |subexprs| {
            debug.warn("{s}\n", .{@tagName(e)});
            for (subexprs.items) |s|
                dumpExprIndent(s.*, indent + 1);
        },
        Expr.Alternate => |subexprs| {
            debug.warn("{s}\n", .{@tagName(e)});
            for (subexprs.items) |s|
                dumpExprIndent(s.*, indent + 1);
        },
        // NOTE: Shouldn't occur ever in returned output.
        Expr.PseudoLeftParen => {
            debug.warn("{s}\n", .{@tagName(e)});
        },
    }
}

pub fn dumpInstruction(s: Instruction) void {
    switch (s.data) {
        InstructionData.Char => |ch| {
            debug.warn("char({}) '{c}'\n", .{ s.out, ch });
        },
        InstructionData.EmptyMatch => |assertion| {
            debug.warn("empty({}) {s}\n", .{ s.out, @tagName(assertion) });
        },
        InstructionData.ByteClass => |class| {
            debug.warn("range({}) ", .{s.out});
            for (class.ranges.items) |r|
                debug.warn("[{d}-{d}]", .{ r.min, r.max });
            debug.warn("\n", .{});
        },
        InstructionData.AnyCharNotNL => {
            debug.warn("any({})\n", .{s.out});
        },
        InstructionData.Match => {
            debug.warn("match\n", .{});
        },
        InstructionData.Jump => {
            debug.warn("jump({})\n", .{s.out});
        },
        InstructionData.Split => |branch| {
            debug.warn("split({}) {}\n", .{ s.out, branch });
        },
        InstructionData.Save => |slot| {
            debug.warn("save({}), {}\n", .{ s.out, slot });
        },
    }
}

pub fn dumpProgram(s: Program) void {
    debug.warn("start: {}\n\n", .{s.start});
    for (s.insts) |inst, i| {
        debug.warn("L{}: ", .{i});
        dumpInstruction(inst);
    }
}
