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
            debug.print("\\t", .{});
        },
        '\r' => {
            debug.print("\\r", .{});
        },
        '\n' => {
            debug.print("\\n", .{});
        },
        // printable characters
        32...126 => {
            debug.print("{c}", .{ch});
        },
        else => {
            debug.print("0x{x}", .{ch});
        },
    }
}

pub fn dumpExpr(e: Expr) void {
    dumpExprIndent(e, 0);
}

fn dumpExprIndent(e: Expr, indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        debug.print(" ", .{});
    }

    switch (e) {
        Expr.AnyCharNotNL => {
            debug.print("{s}\n", .{@tagName(e)});
        },
        Expr.EmptyMatch => |assertion| {
            debug.print("{s}({s})\n", .{ @tagName(e), @tagName(assertion) });
        },
        Expr.Literal => |lit| {
            debug.print("{s}(", .{@tagName(e)});
            printCharEscaped(lit);
            debug.print(")\n", .{});
        },
        Expr.Capture => |subexpr| {
            debug.print("{s}\n", .{@tagName(e)});
            dumpExprIndent(subexpr.*, indent + 1);
        },
        Expr.Repeat => |repeat| {
            debug.print("{s}(min={d}, max={?d}, greedy={any})\n", .{ @tagName(e), repeat.min, repeat.max, repeat.greedy });
            dumpExprIndent(repeat.subexpr.*, indent + 1);
        },
        Expr.ByteClass => |class| {
            debug.print("{s}(", .{@tagName(e)});
            for (class.ranges.items) |r| {
                debug.print("[", .{});
                printCharEscaped(r.min);
                debug.print("-", .{});
                printCharEscaped(r.max);
                debug.print("]", .{});
            }
            debug.print(")\n", .{});
        },
        // TODO: Can we get better type unification on enum variants with the same type?
        Expr.Concat => |subexprs| {
            debug.print("{s}\n", .{@tagName(e)});
            for (subexprs.items) |s|
                dumpExprIndent(s.*, indent + 1);
        },
        Expr.Alternate => |subexprs| {
            debug.print("{s}\n", .{@tagName(e)});
            for (subexprs.items) |s|
                dumpExprIndent(s.*, indent + 1);
        },
        // NOTE: Shouldn't occur ever in returned output.
        Expr.PseudoLeftParen => {
            debug.print("{s}\n", .{@tagName(e)});
        },
    }
}

pub fn dumpInstruction(s: Instruction) void {
    switch (s.data) {
        InstructionData.Char => |ch| {
            debug.print("char({}) '{c}'\n", .{ s.out, ch });
        },
        InstructionData.EmptyMatch => |assertion| {
            debug.print("empty({}) {s}\n", .{ s.out, @tagName(assertion) });
        },
        InstructionData.ByteClass => |class| {
            debug.print("range({}) ", .{s.out});
            for (class.ranges.items) |r|
                debug.print("[{d}-{d}]", .{ r.min, r.max });
            debug.print("\n", .{});
        },
        InstructionData.AnyCharNotNL => {
            debug.print("any({})\n", .{s.out});
        },
        InstructionData.Match => {
            debug.print("match\n", .{});
        },
        InstructionData.Jump => {
            debug.print("jump({})\n", .{s.out});
        },
        InstructionData.Split => |branch| {
            debug.print("split({}) {}\n", .{ s.out, branch });
        },
        InstructionData.Save => |slot| {
            debug.print("save({}), {}\n", .{ s.out, slot });
        },
    }
}

pub fn dumpProgram(s: Program) void {
    debug.print("start: {}\n\n", .{s.start});
    for (s.insts, 0..) |inst, i| {
        debug.print("L{}: ", .{i});
        dumpInstruction(inst);
    }
}
