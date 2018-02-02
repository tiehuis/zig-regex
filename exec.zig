const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const Parser = @import("parse.zig").Parser;
const Expr = @import("parse.zig").Expr;
const Compiler = @import("compile.zig").Compiler;
const Prog = @import("compile.zig").Prog;
const Inst = @import("compile.zig").Inst;

// A thread of execution in the vm.
const Thread = struct {
    // Pointer to the current instruction
    pc: usize,
    // Pointer to the position in the string we are searching
    sp: usize,

    pub fn init(pc: usize, sp: usize) Thread {
        return Thread { .pc = pc, .sp = sp };
    }
};

error RegexpOverflow;

pub fn exec_backtrack(prog: &const Prog, input: []const u8) %bool {
    const max_thread = 1000;

    var ready: [max_thread]Thread = undefined;
    var ready_count: usize = 0;

    // queue initial thread
    ready[0] = Thread.init(prog.start, 0);
    ready_count = 1;

    while (ready_count > 0) {
        // Pop the thread
        ready_count -= 1;

        var pc = ready[ready_count].pc;
        var sp = ready[ready_count].sp;

        // single thread execution
        while (true) {
            switch (prog.insts[pc]) {
                Inst.Char => |ch| {
                    if (sp >= input.len) {
                        break;
                    }
                    if (ch.c != input[sp]) {
                        // no match, kill the thread
                        break;
                    }

                    pc = ch.goto1;
                    sp += 1;
                },
                Inst.CharRange => |cr| {
                    if (sp >= input.len) {
                        break;
                    }
                    for (cr.ranges.toSliceConst()) |r| {
                        // TODO: Binary search.
                        if (r.min < input[sp] and input[sp] < r.max) {
                            pc = cr.goto1;
                            sp += 1;
                            break;
                        }
                    }

                    // no match in any range, kill the thread
                    break;
                },
                Inst.AnyCharNotNL => |c| {
                    if (sp >= input.len) {
                        break;
                    }
                    if (input[sp] == '\n') {
                        // kill thread
                        break;
                    }

                    pc = c.goto1;
                    sp += 1;
                },
                Inst.Match => {
                    return true;
                },
                Inst.Jump => |to| {
                    pc = to;
                },
                Inst.Split => |split| {
                    // goto1 and goto2 to check
                    if (ready_count >= max_thread) {
                        return error.RegexpOverflow;
                    }

                    // queue a thread
                    ready[ready_count] = Thread.init(split.goto2, sp);
                    ready_count += 1;

                    // try the first branch in the current thread first
                    pc = split.goto1;
                },
            }
        }
    }

    return false;
}

test "exec backtrack" {
    var p = Parser.init(debug.global_allocator);
    const expr = try p.parse("abc+d+.?");

    expr.dump();

    var c = Compiler.init(debug.global_allocator);
    const bytecode = try c.compile(expr);

    debug.assert((try exec_backtrack(bytecode, "abcd")) == true);
    debug.assert((try exec_backtrack(bytecode, "abccccd")) == true);
    debug.assert((try exec_backtrack(bytecode, "abcdddddZ")) == true);
    debug.assert((try exec_backtrack(bytecode, "abd")) == false);
}
