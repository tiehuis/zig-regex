const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");

const Parser = parse.Parser;
const Expr = parse.Expr;
const Assertion = parse.Assertion;
const Compiler = compile.Compiler;
const Prog = compile.Prog;
const Inst = compile.Inst;

const Input = struct {
    slice: []const u8,
    len: usize,

    pub fn init(slice: []const u8) Input {
        return Input {
            .slice = slice,
            .len = slice.len,
        };
    }

    pub fn at(i: &const Input, n: usize) u8 {
        return i.slice[n];
    }

    fn isWordChar(c: u8) bool {
        return switch (c) {
            '0' ... '9', 'a' ... 'z', 'A' ... 'Z' => true,
            else => false,
        };
    }

    pub fn isEmptyMatch(i: &const Input, n: usize, match: &const Assertion) bool {
        switch (*match) {
            Assertion.None => {
                return true;
            },
            Assertion.BeginLine => {
                return n == 0;
            },
            Assertion.EndLine => {
                return n == i.len - 1;
            },
            Assertion.BeginText => {
                // TODO: Handle different modes.
                return n == 0;
            },
            Assertion.EndText => {
                return n == i.len - 1;
            },
            Assertion.WordBoundaryAscii => {
                const last = (n == 0) or isWordChar(i.slice[n-1]);
                const next = (n == i.len - 1) or isWordChar(i.slice[n+1]);
                return last != next;
            },
            Assertion.NotWordBoundaryAscii => {
                const last = (n == 0) or isWordChar(i.slice[n-1]);
                const next = (n == i.len - 1) or isWordChar(i.slice[n+1]);
                return last == next;
            },
        }
    }
};

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

    pub fn exec(engine: &const VmBacktrack, prog: &const Prog, start: usize, input: []const u8) !bool {
        const max_thread = 1000;

        var ready: [max_thread]Thread = undefined;
        var ready_count: usize = 0;

        // queue initial thread
        ready[0] = Thread.init(start, 0);
        ready_count = 1;

        const inp = Input.init(input);

        while (ready_count > 0) {
            // Pop the thread
            ready_count -= 1;

            var pc = ready[ready_count].pc;
            var sp = ready[ready_count].sp;

            // single thread execution
            while (true) {
                switch (prog.insts[pc]) {
                    Inst.Char => |ch| {
                        if (sp >= inp.len) {
                            break;
                        }
                        if (ch.c != inp.at(sp)) {
                            // no match, kill the thread
                            break;
                        }

                        pc = ch.goto1;
                        sp += 1;
                    },
                    Inst.EmptyMatch => |em| {
                        if (sp >= inp.len) {
                            break;
                        }
                        if (!inp.isEmptyMatch(sp, em.assertion)) {
                            // no match, kill thread
                            break;
                        }

                        pc = em.goto1;
                        // do not advance sp
                    },
                    Inst.ByteClass => |inst| {
                        if (sp >= inp.len) {
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
    const expr = try p.parse("^abc+d+.?");

    expr.dump();

    var c = Compiler.init(debug.global_allocator);
    const bytecode = try c.compile(expr);

    bytecode.dump();

    const engine = VmBacktrack{};

    debug.assert((try engine.exec(bytecode, 0, "abcd")) == true);
    debug.assert((try engine.exec(bytecode, 0, "abccccd")) == true);
    debug.assert((try engine.exec(bytecode, 0, "abcdddddZ")) == true);
    debug.assert((try engine.exec(bytecode, 0, "abd")) == false);
}
