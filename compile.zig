const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const parser = @import("parse.zig");
const Parser = parser.Parser;
const ClassRange = parser.ClassRange;
const Expr = parser.Expr;

const InstSplit = struct {
    goto1: usize,
    goto2: usize,
};

const InstChar = struct {
    goto1: usize,
    c: u8,
};

const InstRange = struct {
    goto1: usize,
    ranges: ArrayList(ClassRange),
};

const InstJump = struct {
    goto1: usize,
};

// Represents instructions for the VM.
pub const Inst = union(enum) {
    // Match the specified character.
    Char: InstChar,

    // Match the specified character ranges.
    CharRange: InstRange,

    // Matches the AnyChar special cases
    AnyCharNotNL: InstJump,

    // Stop the thread, found a match
    Match,

    // Jump to the instruction at address x
    Jump: usize,

    // Split execution, spawing a new thread and continuing in lockstep
    Split: InstSplit,

    pub fn dump(s: &const Inst) void {
        switch (*s) {
            Inst.Char => |x| {
                debug.warn("char {}, '{c}'\n", x.goto1, x.c);
            },
            Inst.CharRange => |x| {
                debug.warn("range {}, ", x.goto1);
                for (x.ranges.toSliceConst()) |r|
                    debug.warn("[{c}-{c}]", r.min, r.max);
                debug.warn("\n");
            },
            Inst.AnyCharNotNL => |x| {
                debug.warn("anychar {}\n", x.goto1);
            },
            Inst.Match => {
                debug.warn("match\n");
            },
            Inst.Jump => |x| {
                debug.warn("jump {}\n", x);
            },
            Inst.Split => |x| {
                debug.warn("split {}, {}\n", x.goto1, x.goto2);
            },
        }
    }
};

// Represents an instruction with unpatched holes.
const InstHole = union(enum) {
    // Match with an unfilled output
    Char: u8,
    // Match a character class range
    Range: ArrayList(ClassRange),
    // Match any character
    AnyCharNotNL,
    // Split with no unfilled branch
    Split,
    // Split with a filled first branch
    Split1: usize,
    // Split with a filled second branch
    Split2: usize,

    pub fn dump(s: &const InstHole) void {
        debug.warn("{}", @tagName(*s));
        switch (*s) {
            InstHole.Char => |ch| {
                debug.warn("('{c}')\n", ch);
            },
            InstHole.Range => |rs| {
                debug.warn("(");
                for (rs.toSliceConst()) |r|
                    debug.warn("[{c}-{c}]", r.min, r.max);
                debug.warn(")\n");
            },
            InstHole.AnyCharNotNL, InstHole.Split => {
                debug.warn("\n");
            },
            InstHole.Split1 => |x| {
                debug.warn("({})\n", x);
            },
            InstHole.Split2 => |x| {
                debug.warn("({})\n", x);
            },
        }
    }
};

// Represents a partial instruction. During compilation the instructions will be a mix of compiled
// and un-compiled. All instructions must be in the compiled state when we finish processing.
const PartialInst = union(enum) {
    // A completely compiled instruction
    Compiled: Inst,

    // A partially compiled instruction, the back-links are not yet filled
    Uncompiled: InstHole,

    // Modify the current instruction to point to the specified instruction.
    pub fn fill(s: &PartialInst, i: InstPtr) void {
        switch (*s) {
            PartialInst.Uncompiled => |ih| {
                var comp: Inst = undefined;

                // Generate the corresponding compiled instruction. All simply goto the specified
                // instruction, except for the dual split case, in which both outgoing pointers
                // go to the same place.
                switch (ih) {
                    InstHole.Char => |ch| {
                        comp = Inst { .Char = InstChar { .goto1 = i, .c = ch }};
                    },
                    InstHole.AnyCharNotNL => {
                        comp = Inst { .AnyCharNotNL = InstJump { .goto1 = i }};
                    },
                    InstHole.Range => |ranges| {
                        comp = Inst { .CharRange = InstRange { .goto1 = i, .ranges = ranges }};
                    },
                    InstHole.Split => {
                        comp = Inst { .Split = InstSplit { .goto1 = i, .goto2 = i }};
                    },
                    // 1st was already filled
                    InstHole.Split1 => |split| {
                        comp = Inst { .Split = InstSplit { .goto1 = split, .goto2 = i }};
                    },
                    // 2nd was already filled
                    InstHole.Split2 => |split| {
                        comp = Inst { .Split = InstSplit { .goto1 = i, .goto2 = split }};
                    },
                }

                *s = PartialInst { .Compiled = comp };
            },
            PartialInst.Compiled => {
                // nothing to do, already filled
            },
        }
    }
};

// A program represents the compiled bytecode of an NFA.
pub const Prog = struct {
    // Sequence of instructions representing an NFA
    insts: []const Inst,
    // Start instruction
    start: InstPtr,

    pub fn init(a: []const Inst) Prog {
        return Prog {
            .insts = a,
            .start = 0,
        };
    }

    pub fn dump(s: &const Prog) void {
        debug.warn("start: {}\n\n", s.start);
        for (s.insts) |inst, i| {
            debug.warn("L{}: ", i);
            inst.dump();
        }
    }
};

// A pointer to a specific instruction.
const InstPtr = usize;

// A Hole represents the outgoing node of a partially compiled Fragment.
//
// If None, the Hole needs to be back-patched as we do not yet know which instruction this
// points to yet.
const Hole = union(enum) {
    None,
    One: InstPtr,
    Many: ArrayList(Hole),
};

// A patch represents an unpatched output for a contigious sequence of instructions.
const Patch = struct {
    // The address of the first instruction
    entry: InstPtr,
    // The output hole of this instruction (to be filled to an actual address/es)
    hole: Hole,
};

// A Compiler compiles a regex expression into a bytecode representation of the NFA.
pub const Compiler = struct {
    // Stores all partial instructions
    insts: ArrayList(PartialInst),
    allocator: &Allocator,

    pub fn init(a: &Allocator) Compiler {
        return Compiler {
            .insts = ArrayList(PartialInst).init(a),
            .allocator = a,
        };
    }

    // Compile the regex expression
    pub fn compile(c: &Compiler, expr: &const Expr) %Prog {
        const patch = try c.compile_internal(expr);
        // fill any holes to end at the next instruction which will be a match
        c.fill_to_next(patch.hole);
        try c.insts.append(PartialInst { .Compiled = Inst.Match } );

        var p = ArrayList(Inst).init(c.allocator);
        defer p.deinit();

        for (c.insts.toSliceConst()) |e| {
            switch (e) {
                PartialInst.Compiled => |x| {
                    try p.append(x);
                },
                else => {
                    debug.warn("Uncompiled instruction: ");
                    e.Uncompiled.dump();
                    @panic("uncompiled instruction encountered during compilation");
                }
            }
        }

        return Prog.init(p.toOwnedSlice());
    }

    fn compile_internal(c: &Compiler, expr: &const Expr) %Patch {
        switch (*expr) {
            Expr.Literal => |lit| {
                const h = try c.push_hole(InstHole { .Char = lit });
                return Patch { .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.CharClass => |classes| {
                // Similar, we use a special instruction.
                const h = try c.push_hole(InstHole { .Range = classes });
                return Patch { .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.AnyCharNotNL => {
                const h = try c.push_hole(InstHole.AnyCharNotNL);
                return Patch { .hole = h, .entry = c.insts.len - 1 };
            },
            // TODO: Have an assert instruction (empty-match) which does the check and doesn't
            // advance the thread if it fails.
            Expr.BeginLine, Expr.EndLine => {
                @panic("unhandled");
            },
            Expr.Repeat => |repeat| {
                // Case 1: *
                if (repeat.min == 0 and repeat.max == null) {
                    // 1: split 2, 4
                    // 2: subexpr
                    // 3: jmp 1
                    // 4: ...

                    // We do not know where the second branch in this split will go (unsure yet of
                    // the length of the following subexpr. Need a hole.

                    // Create a partial instruction with a hole outgoing at the current location.
                    const entry = c.insts.len;

                    // * or *? variant, simply switch the branches, the matcher manages precedence
                    // of the executing threads.
                    const partial_inst =
                        if (repeat.greedy)
                            InstHole { .Split1 = c.insts.len + 1 }
                        else
                            InstHole { .Split2 = c.insts.len + 1 }
                        ;

                    const h = try c.push_hole(partial_inst);

                    // compile the subexpression
                    const p = try c.compile_internal(repeat.subexpr);

                    // sub-expression to jump
                    c.fill_to_next(p.hole);

                    // Jump back to the entry split
                    try c.push_compiled(Inst { .Jump = entry });

                    // Return a filled patch set to the first split instruction.
                    return Patch { .hole = h, .entry = entry };
                }
                // Case 2: +
                else if (repeat.min == 1 and repeat.max == null) {
                    // 1: subexpr
                    // 2: split 1, 3
                    // 3: ...
                    //
                    // NOTE: We can do a lookahead on non-greedy here to improve performance.
                    const p = try c.compile_internal(repeat.subexpr);

                    // Create the next expression in place
                    c.fill_to_next(p.hole);

                    // split 3, 1 (non-greedy)
                    // Point back to the upcoming next instruction (will always be filled).
                    const partial_inst =
                        if (repeat.greedy)
                            InstHole { .Split1 = p.entry }
                        else
                            InstHole { .Split2 = p.entry }
                        ;

                    const h = try c.push_hole(partial_inst);

                    // split to the next instruction
                    return Patch { .hole = h, .entry = p.entry };
                }
                // Case 3: ?
                else if (repeat.min == 0 and repeat.max != null and (??repeat.max) == 1) {
                    // 1: split 2, 3
                    // 2: subexpr
                    // 3: ...

                    // Create a partial instruction with a hole outgoing at the current location.
                    const partial_inst =
                        if (repeat.greedy)
                            InstHole { .Split1 = c.insts.len + 1 }
                        else
                            InstHole { .Split2 = c.insts.len + 1 }
                        ;

                    const h = try c.push_hole(partial_inst);

                    // compile the subexpression
                    const p = try c.compile_internal(repeat.subexpr);

                    var holes = ArrayList(Hole).init(c.allocator);
                    errdefer holes.deinit();
                    try holes.append(h);
                    try holes.append(p.hole);

                    // Return a filled patch set to the first split instruction.
                    return Patch { .hole = Hole { .Many = holes }, .entry = p.entry - 1 };
                }
                // Case 3: {m,n} etc
                else {
                    @panic("unimplemented {m,n} case");
                }
            },
            Expr.Concat => |subexprs| {
                // Compile each item in the sub-expression
                var f = subexprs.toSliceConst()[0];

                // First patch
                const p = try c.compile_internal(f);
                var hole = p.hole;
                const entry = p.entry;

                // tie together patches from concat arguments
                for (subexprs.toSliceConst()[1..]) |e| {
                    const ep = try c.compile_internal(e);
                    // fill the previous patch hole to the current entry
                    c.fill(hole, ep.entry);
                    // current hole is now the next fragment
                    hole = ep.hole;
                }

                return Patch { .hole = hole, .entry = entry };
            },
            Expr.Capture => |subexpr| {
                // TODO: save instruction
                return c.compile_internal(subexpr);
            },
            Expr.Alternate => |subexprs| {
                // Alternation with one path does not make sense
                debug.assert(subexprs.len >= 2);

                // Alternates are simply a series of splits into the sub-expressions, with each
                // subexpr having the same output hole (after the final subexpr).
                //
                // 1: split 2, 4
                // 2: subexpr1
                // 3: jmp 8
                // 4: split 5, 7
                // 5: subexpr2
                // 6: jmp 8
                // 7: subexpr3
                // 8: ...

                const entry = c.insts.len;
                var holes = ArrayList(Hole).init(c.allocator);
                errdefer holes.deinit();

                // TODO: Why does this need to be dynamically allocated?
                var last_hole = try c.allocator.create(Hole);
                defer c.allocator.destroy(last_hole);
                *last_hole = Hole.None;

                // This compiles one branch of the split at a time.
                for (subexprs.toSliceConst()[0..subexprs.len-1]) |subexpr| {
                    c.fill_to_next(last_hole);

                    // next entry will be a sub-expression
                    //
                    // We fill the second part of this hole on the next sub-expression.
                    *last_hole = try c.push_hole(InstHole { .Split1 = c.insts.len + 1 });

                    // compile the subexpression
                    const p = try c.compile_internal(subexpr);

                    // store outgoing hole for the subexpression
                    try holes.append(p.hole);
                }

                // one entry left, push a sub-expression so we end with a double-subexpression.
                const p = try c.compile_internal(subexprs.toSliceConst()[subexprs.len-1]);
                c.fill(last_hole, p.entry);

                // push the last sub-expression hole
                try holes.append(p.hole);

                // return many holes which are all to be filled to the next instruction
                return Patch { .hole = Hole { .Many = holes }, .entry = entry };
            },
            Expr.PseudoLeftParen => {
                @panic("internal error, encountered PseudoLeftParen");
            },
        }

        return Patch { .hole = Hole.None, .entry = c.insts.len };
    }

    ////////////////////
    // Instruction Helpers

    // Push a compiled instruction directly onto the stack.
    fn push_compiled(c: &Compiler, i: &const Inst) %void {
        try c.insts.append(PartialInst { .Compiled = *i });
    }

    // Push a instruction with a hole onto the set
    fn push_hole(c: &Compiler, i: &const InstHole) %Hole {
        const h = c.insts.len;
        try c.insts.append(PartialInst { .Uncompiled = *i });
        return Hole { .One = h };
    }

    ////////////////////
    // Patch filling

    // Patch an individual hole with the specified output address.
    fn fill(c: &Compiler, hole: &const Hole, goto1: InstPtr) void {
        switch (*hole) {
            Hole.None => {},
            Hole.One => |pc| c.insts.toSlice()[pc].fill(goto1),
            Hole.Many => |holes| {
                for (holes.toSliceConst()) |hole1|
                    c.fill(hole1, goto1);
            },
        }
    }

    // Patch a hole to point to the next instruction
    fn fill_to_next(c: &Compiler, hole: &const Hole) void {
        c.fill(hole, c.insts.len);
    }
};

test "compile" {
    const a = "abc+de+.ab*(cc|de)";
    debug.warn("\n{}\n", a);

    var p = Parser.init(debug.global_allocator);
    const expr = try p.parse(a);

    expr.dump();

    var c = Compiler.init(debug.global_allocator);
    const bytecode = try c.compile(expr);

    bytecode.dump();

    // Run it on an appropriate vm!
}
