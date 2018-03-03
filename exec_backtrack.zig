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
const InstData = compile.InstData;
const InputBytes = @import("input.zig").InputBytes;

const SaveRestore = struct {
    // slot position to restore
    slot: usize,
    // position to store in slot
    last_pos: usize,
};

const Thread = struct {
    // instruction pointer
    ip: usize,
    // Current input position
    input: InputBytes,
};

const Job = union(enum) {
    Thread: Thread,
    SaveRestore: SaveRestore,
};

const ExecState = struct {
    // pending jobs
    jobs: ArrayList(Job),

    // cache (we can bound this visited bitset since we bound when we use the backtracking engine.
    visited: [512]u32,

    prog: &const Prog,

    slots: &ArrayList(?usize),
};

// This is bounded and only used for small compiled regexes. It is not quadratic since pre-seen
// nodes are cached across threads.
pub const BacktrackVm = struct {
    const Self = this;

    allocator: &Allocator,

    pub fn init(allocator: &Allocator) Self {
        return Self {
            .allocator = allocator,
        };
    }

    fn shouldExec(prog: &const Prog, input: []const u8) bool {
        return (prog.insts.len + 1) * (input.len + 1) < 512 * 32;
    }

    pub fn exec(self: &Self, prog: &const Prog, prog_start: usize, input: []const u8, slots: &ArrayList(?usize)) !bool {
        // Should never run this without first checking shouldExec and running only if true.
        debug.assert(shouldExec(prog, input));

        var jobs = ArrayList(Job).init(self.allocator);
        defer jobs.deinit();

        var state = ExecState {
            .jobs = jobs,
            .visited = []u32{0} ** 512,
            .prog = prog,
            .slots = slots,
        };

        const t = Job { .Thread = Thread { .ip = prog_start, .input = InputBytes.init(input) }};
        try state.jobs.append(t);

        while (state.jobs.popOrNull()) |job| {
            switch (job) {
                Job.Thread => |thread| {
                    if (try step(&state, &thread)) {
                        return true;
                    }
                },
                Job.SaveRestore => |save| {
                    if (save.slot < state.slots.len) {
                        state.slots.toSlice()[save.slot] = save.last_pos;
                    }
                },
            }
        }

        return false;
    }

    fn step(state: &ExecState, thread: &const Thread) !bool {
        // For linear actions, we can just modify the current thread and avoid pushing new items
        // to the stack.
        var input = thread.input;

        var ip = thread.ip;

        while (true) {
            const inst = state.prog.insts[ip];
            const at = input.current();

            if (!shouldVisit(state, ip, input.byte_pos)) {
                return false;
            }

            switch (inst.data) {
                InstData.Char => |ch| {
                    if (at == null or ??at != ch) {
                        return false;
                    }
                    input.advance();
                },
                InstData.EmptyMatch => |assertion| {
                    if (!input.isEmptyMatch(assertion)) {
                        return false;
                    }
                },
                InstData.ByteClass => |class| {
                    if (at == null or !class.contains(??at)) {
                        return false;
                    }
                    input.advance();
                },
                InstData.AnyCharNotNL => {
                    if (at == null or ??at == '\n') {
                        return false;
                    }
                    input.advance();
                },
                InstData.Save => |slot| {
                    // Our capture array may not be long enough, extend and fill with empty
                    while (state.slots.len <= slot) {
                        // TODO: Can't append null as optional
                        try state.slots.append(0);
                        state.slots.toSlice()[state.slots.len-1] = null;
                    }

                    // We can save an existing match by creating a job which will run on this thread
                    // failing. This will reset to the old match before any subsequent splits in
                    // this thread.
                    if (state.slots.at(slot)) |last_pos| {
                        const job = Job { .SaveRestore = SaveRestore {
                            .slot = slot,
                            .last_pos = last_pos,
                        }};
                        try state.jobs.append(job);
                    }

                    state.slots.toSlice()[slot] = input.byte_pos;
                },
                InstData.Match => {
                    return true;
                },
                InstData.Jump => {
                    // Jump at end of loop
                },
                InstData.Split => |split| {
                    const t = Job { .Thread = Thread { .ip = split, .input = input }};
                    try state.jobs.append(t);
                }
            }

            ip = inst.out;
        }
    }

    // checks if we have visited this specific node and if not, set the bit and return true
    fn shouldVisit(state: &ExecState, ip: usize, at: usize) bool {
        const BitsetType = @typeOf(state.visited).Child;
        const BitsetShiftType = std.math.Log2Int(BitsetType);

        const size = @sizeOf(BitsetType);
        const n = ip * (state.prog.insts.len + 1) + at;
        const bitmask = BitsetType(1) << BitsetShiftType(n & (size - 1));

        if ((state.visited[n/size] & bitmask) != 0) {
            return false;
        }

        state.visited[n/size] |= bitmask;
        return true;
    }
};
