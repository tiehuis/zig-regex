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

error RegexpOverflow;

pub const VmBacktrack = struct {
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

    pub fn exec(engine: &const VmBacktrack, prog: &const Prog, input: []const u8) %bool {
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
                    Inst.ByteClass => |inst| {
                        if (sp >= input.len) {
                            break;
                        }
                        if (!inst.class.contains(input[sp])) {
                            // no match in any range, kill the thread
                            break;
                        }

                        pc = inst.goto1;
                        sp += 1;
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
};

test "exec backtrack" {
    var p = Parser.init(debug.global_allocator);
    const expr = try p.parse("abc+d+.?");

    expr.dump();

    var c = Compiler.init(debug.global_allocator);
    const bytecode = try c.compile(expr);

    const engine = VmBacktrack{};

    debug.assert((try engine.exec(bytecode, "abcd")) == true);
    debug.assert((try engine.exec(bytecode, "abccccd")) == true);
    debug.assert((try engine.exec(bytecode, "abcdddddZ")) == true);
    debug.assert((try engine.exec(bytecode, "abd")) == false);
}
