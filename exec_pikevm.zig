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
const InputBytes = @import("input.zig").InputBytes;

const Thread = struct {
    pc: usize,
    slots: &ArrayList(?usize),
};

pub const PikeVm = struct {
    const Self = this;

    allocator: &Allocator,

    pub fn init(allocator: &Allocator) Self {
        return Self {
            .allocator = allocator,
        };
    }

    pub fn exec(self: &Self, prog: &const Prog, prog_start: usize, re_input: []const u8, slots: &ArrayList(?usize)) !bool {
        var clist = ArrayList(Thread).init(self.allocator);
        defer clist.deinit();

        var nlist = ArrayList(Thread).init(self.allocator);
        defer nlist.deinit();

        // We can share a single array-list across all threads as we only move forward.
        slots.shrink(0);

        const t = Thread { .pc = prog_start, .slots = slots };
        try clist.append(t);

        var input = InputBytes.init(re_input);

        while (!input.isConsumed()) : (input.advance()) {
            while (clist.popOrNull()) |thread| {
                const inst = prog.insts[thread.pc];

                switch (inst.data) {
                    InstData.Char => |ch| {
                        if (input.current() == ch) {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.EmptyMatch => |assertion| {
                        if (input.isEmptyMatch(assertion)) {
                            try clist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.ByteClass => |class| {
                        if (class.contains(input.current())) {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.AnyCharNotNL => {
                        if (input.current() != '\n') {
                            try nlist.append(Thread { .pc = inst.out, .slots = thread.slots });
                        }
                    },
                    InstData.Match => {
                        slots.shrink(0);
                        try slots.appendSlice(thread.slots.toSliceConst());
                        return true;
                    },
                    InstData.Save => |slot| {
                        // We don't need a deep copy here since we only ever advance forward so
                        // all future captures are valid for any subsequent threads.
                        var new_thread = Thread { .pc = inst.out, .slots = thread.slots };

                        try new_thread.slots.ensureCapacity(slot);
                        new_thread.slots.toSlice()[slot] = input.byte_pos;

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

