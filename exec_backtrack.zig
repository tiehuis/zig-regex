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
const Input = @import("input.zig").Input;

const SaveRestore = struct {
    // slot position to restore
    slot: usize,
    // position to store in slot
    last_pos: usize,
};

const Thread = struct {
    // instruction pointer
    ip: usize,
    // position in input string
    pos: usize,
};

const Job = union(enum) {
    Thread: Thread,
    SaveRestore: SaveRestore,
};

// This is bounded and only used for small compiled regexes. It is not quadratic since pre-seen
// nodes are cached across threads.
pub const VmBacktrack = struct {
    const Self = this;

    // pending jobs
    jobs: ArrayList(Job),

    // cache (we can bound this visited bitset since we bound when we use the backtracking engine.
    visited: [512]u32,
    // end is the last index of the input and sets our strides for the bitset
    end: usize,

    // cached entries across invocation
    prog: &const Prog,
    input: []const u8,
    slots: []?usize,

    pub fn init(allocator: &Allocator) Self {
        return Self {
            .jobs = ArrayList(Job).init(allocator),
            .visited = undefined,
            .end = undefined,
            .prog = undefined,
            .input = undefined,
            .slots = undefined,
        };
    }

    fn shouldExec(prog: &const Prog, input: []const u8) bool {
        return (prog.insts.len + 1) * (input.len + 1) < 512 * 32;
    }

    pub fn exec(self: &Self, prog: &const Prog, prog_start: usize, input: []const u8, slots: []?usize) !bool {
        // we enforce this by never choosing this engine in the case we exceed this requirement
        debug.assert(shouldExec(prog, input));

        self.end = input.len;
        self.prog = prog;
        self.input = input;
        // saved capture locations
        self.slots = slots;

        // reset the visited bitset
        mem.set(u32, self.visited[0..], 0);

        const t = Job { .Thread = Thread { .ip = prog_start, .pos = 0 }};
        try self.jobs.append(t);

        while (self.jobs.popOrNull()) |job| {
            switch (job) {
                Job.Thread => |thread| {
                    if (try self.step(thread.ip, thread.pos)) {
                        return true;
                    }
                },
                Job.SaveRestore => |save| {
                    if (save.slot < self.slots.len) {
                        self.slots[save.slot] = save.last_pos;
                    }
                },
            }
        }

        return false;
    }

    // step through the current active thread at the specific position
    fn step(self: &Self, ip_: usize, pos_: usize) !bool {
        // We don't need to create threads for linear actions (i.e. match) and can get by with
        // just modifying the pc. We only need to create threads on the actual splits.
        var ip = ip_;
        var pos = pos_;
        var inp = Input.init(self.input);

        while (true) {
            if (!self.shouldVisit(ip, pos)) {
                return false;
            }

            switch (self.prog.insts[ip]) {
                Inst.Char => |ch| {
                    if (pos >= inp.len or ch.c != inp.at(pos)) {
                        return false;
                    }
                    ip = ch.goto1;
                    pos += 1;
                },
                Inst.EmptyMatch => |em| {
                    if (pos >= inp.len or !inp.isEmptyMatch(pos, em.assertion)) {
                        return false;
                    }
                    ip = em.goto1;
                },
                Inst.ByteClass => |inst| {
                    if (pos >= inp.len or !inst.class.contains(inp.at(pos))) {
                        return false;
                    }
                    ip = inst.goto1;
                    pos += 1;
                },
                Inst.AnyCharNotNL => |c| {
                    if (pos >= inp.len or inp.at(pos) == '\n') {
                        return false;
                    }
                    ip = c.goto1;
                    pos += 1;
                },
                Inst.Save => |slot| {
                    // We can save an existing match by creating a job which will run on this thread
                    // failing. This will reset to the old match before any subsequent splits in
                    // this thread.
                    if (self.slots[slot.index]) |last_pos| {
                        const job = Job { .SaveRestore = SaveRestore {
                            .slot = slot.index,
                            .last_pos = last_pos,
                        }};
                        try self.jobs.append(job);
                    }

                    self.slots[slot.index] = pos;
                    ip = slot.goto1;
                },
                Inst.Match => {
                    return true;
                },
                Inst.Jump => |to| {
                    ip = to;
                },
                Inst.Split => |split| {
                    const t = Job { .Thread = Thread { .ip = split.goto2, .pos = pos }};
                    try self.jobs.append(t);

                    ip = split.goto1;
                }
            }
        }
    }

    // checks if we have visited this specific node and if not, set the bit and return true
    fn shouldVisit(self: &Self, pc: usize, at: usize) bool {
        const n = pc * (self.end + 1) + at;
        const size = 32;

        const bitmask = u32(1) << u5(n & (size - 1));

        if ((self.visited[n/size] & bitmask) != 0) {
            return false;
        }

        self.visited[n/size] |= bitmask;
        return true;
    }
};
