// PikeVM
//
// This is the default engine currently except for small regexes which we use a caching backtracking
// engine as this is faster according to most other mature regex engines in practice.
//
// This is a very simple version with no optimizations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const parse = @import("parse.zig");
const compile = @import("compile.zig");

const Parser = parse.Parser;
const Assertion = parse.Assertion;
const Prog = compile.Prog;
const InstData = compile.InstData;
const Input = @import("input.zig").Input;

const Thread = struct {
    pc: usize,
    slots: [40]?usize,
};

pub const PikeVm = struct {
    const Self = this;

    allocator: &Allocator,

    pub fn init(allocator: &Allocator) Self {
        return Self {
            .allocator = allocator,
        };
    }

    pub fn exec(self: &Self, prog: &const Prog, prog_start: usize, input: []const u8, slots: []?usize) !bool {
        var clist = ArrayList(Thread).init(self.allocator);
        defer clist.deinit();

        var nlist = ArrayList(Thread).init(self.allocator);
        defer nlist.deinit();

        const t = Thread { .pc = prog_start, .slots = []?usize {null} ** 40 };
        try clist.append(t);

        // TODO: Actually iterate using the Input class since we will need this for utf-8.
        var inp = Input.init(input);

        // TODO: we need to iterate once past the last match, can we avoid doing this everywhere?
        var pos: usize = 0;
        while (pos < inp.len + 1) : (pos += 1) {
            while (clist.popOrNull()) |thread| {
                const inst = prog.insts[thread.pc];

                switch (inst.data) {
                    InstData.Char => |ch| {
                        if (pos < inp.len and inp.at(pos) == ch) {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.EmptyMatch => |assertion| {
                        if (pos < inp.len and inp.isEmptyMatch(pos, assertion)) {
                            try clist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.ByteClass => |class| {
                        if (pos < inp.len and class.contains(inp.at(pos))) {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.AnyCharNotNL => {
                        if (pos < inp.len and inp.at(pos) != '\n') {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.Match => {
                        for (thread.slots) |_, i| {
                            // TODO: input slots should be a arraylist instead and extended to required length
                            slots[i] = thread.slots[i];
                            return true;
                        }
                    },
                    InstData.Save => |slot| {
                        // We don't need a deep copy here since we only ever advance forward so
                        // all future captures are valid for any subsequent threads.
                        var new_thread = Thread { .pc = inst.out, .slots = thread.slots };
                        new_thread.slots[slot] = pos;

                        try clist.append(new_thread);
                    },
                    InstData.Jump => {
                        try clist.append(Thread { .pc = inst.out, .slots = thread.slots });
                    },
                    InstData.Split => |split| {
                        // Split pushed first since we want to handle the branch secondary to the
                        // current thread (popped from end).
                        try clist.append(Thread { .pc = split, .slots = thread.slots });
                        try clist.append(Thread { .pc = inst.out, .slots = thread.slots });
                    },
                }
            }

            mem.swap(ArrayList(Thread), &clist, &nlist);
            nlist.shrink(0);
        }

        return false;
    }
};

