// Supported constructs:
//
// [x] .
// [x] [xyz]
// [ ] [^xyz]
// [x] \d
// [x] \D
// [ ] [[:alpha:]]
// [ ] [[:^alpha:]]
// [ ] unicode
// [x] (axyz)
// [x] xy
// [x] x|y
// [x] x* (?)
// [x] x+ (?)
// [x] x? (?)
// [x] x{n,m} (?)
// [x] x{n,} (?)
// [x] ^
// [x] $
// [x] \A
// [x] \b
// [x] escape sequences

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");
const exec = @import("exec.zig");

const Parser = parse.Parser;
const Expr = parse.Expr;
const Compiler = compile.Compiler;
const Prog = compile.Prog;
const Inst = compile.Inst;

const InputBytes = @import("input.zig").InputBytes;

pub const Regex = struct {
    allocator: &Allocator,
    // Manages the prog state (TODO: Just store allocator in Prog)
    compiler: Compiler,
    // A compiled set of instructions
    compiled: Prog,
    // Capture slots
    slots: ArrayList(?usize),
    // Original regex string
    string: []const u8,

    pub fn compile(a: &Allocator, re: []const u8) !Regex {
        var p = Parser.init(a);
        defer p.deinit();

        const expr = try p.parse(re);

        // Program state is tied to the compiler right now.
        var c = Compiler.init(a);
        errdefer c.deinit();

        return Regex {
            .allocator = a,
            .compiler = c,
            .compiled = try c.compile(expr),
            .slots = ArrayList(?usize).init(a),
            .string = re,
        };
    }

    pub fn mustCompile(a: &Allocator, re: []const u8) Regex {
        var p = Parser.init(a);
        defer p.deinit();

        const expr = p.parse(re) catch unreachable;

        var c = Compiler.init(a);
        errdefer c.deinit();

        const prog = c.compile(expr) catch unreachable;

        return Regex {
            .allocator = a,
            .compiler = c,
            .compiled = prog,
            .slots = ArrayList(?usize).init(a),
            .string = re,
        };
    }

    pub fn deinit(re: &Regex) void {
        re.compiler.deinit();
    }

    // does the regex match the entire input string? simply run through from the first position.
    pub fn match(re: &Regex, input_str: []const u8) !bool {
        var input_bytes = InputBytes.init(input_str);
        return exec.exec(re.allocator, re.compiled, re.compiled.start, &input_bytes.input, &re.slots);
    }

    // does the regexp match any region within the string? memchr to the first byte in the regex
    // (if possible) and then run the matcher from there. this is important.
    pub fn partialMatch(re: &Regex, input_str: []const u8) !bool {
        var input_bytes = InputBytes.init(input_str);
        return exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input_bytes.input, &re.slots);
    }

    // where does the string match in the regex?
    //
    // the 0 capture is the entire match.
    pub fn captures(re: &Regex, input_str: []const u8) !?Captures {
        var input_bytes = InputBytes.init(input_str);
        const is_match = try exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input_bytes.input, &re.slots);

        if (is_match) {
            return Captures.init(input_str, &re.slots);
        } else {
            return null;
        }
    }
};

pub const Span = struct {
    lower: usize,
    upper: usize,
};

// A set of captures of a Regex on an input slice.
pub const Captures = struct {
    const Self = this;

    input: []const u8,
    allocator: &Allocator,
    slots: []const ?usize,

    // Move the slots out of the array list into this capture group.
    pub fn init(input: []const u8, slots: &ArrayList(?usize)) Captures {
        return Captures {
            .input = input,
            .allocator = slots.allocator,
            .slots = slots.toOwnedSlice(),
        };
    }

    pub fn deinit(self: &Self) void {
        self.allocator.free(self.slots);
    }

    pub fn len(self: &const Self) void {
        return self.slots.len / 2;
    }

    // Return the slice of the matching string for the specified capture index.
    // If the index did not participate in the capture group null is returned.
    pub fn sliceAt(self: &const Self, n: usize) ?[]const u8 {
        if (self.boundsAt(n)) |span| {
            return self.input[span.lower..span.upper];
        }

        return null;
    }

    // Return the substring slices of the input directly.
    pub fn boundsAt(self: &const Self, n: usize) ?Span {
        const base = 2 * n;

        if (base < self.slots.len) {
            if (self.slots[base]) |lower| {
                const upper = ??self.slots[base+1];
                return Span {
                    .lower = lower,
                    .upper = upper,
                };
            }
        }

        return null;
    }
};
