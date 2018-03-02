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

pub const Regex = struct {
    allocator: &Allocator,
    // Manages the prog state (TODO: Just store allocator in Prog)
    compiler: Compiler,
    // A compiled set of instructions
    compiled: Prog,
    // Capture slots (20 max right now)
    slots: ArrayList(?usize),

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
        };
    }

    pub fn deinit(re: &Regex) void {
        re.compiler.deinit();
    }

    // does the regex match the entire input string? simply run through from the first position.
    pub fn match(re: &Regex, input: []const u8) !bool {
        return exec.exec(re.allocator, re.compiled, re.compiled.start, input, &re.slots);
    }

    // does the regexp match any region within the string? memchr to the first byte in the regex
    // (if possible) and then run the matcher from there. this is important.
    pub fn partialMatch(re: &Regex, input: []const u8) !bool {
        return exec.exec(re.allocator, re.compiled, re.compiled.find_start, input, &re.slots);
    }

    // where does the string match in the regex?
    //
    // the 0 capture is the entire match.
    pub fn captures(re: &Regex, input: []const u8) !?ArrayList([]const u8) {
        const is_match = try exec.exec(re.allocator, re.compiled, re.compiled.find_start, input, &re.slots);

        if (!is_match) {
            return null;
        }

        // Transform the raw slot indices into slice matches. Every [2*k, 2*k+1] set should either be
        // both non-null or null.
        var matches = ArrayList([]const u8).init(re.allocator);
        errdefer matches.deinit();

        var i: usize = 0;
        while (i < re.slots.len) : (i += 2) {
            if (re.slots.at(i)) |start_index| {
                debug.assert(re.slots.at(i+1) != null);
                const end_index = ??re.slots.at(i+1);
                try matches.append(input[start_index..end_index]);
            }
        }

        return matches;
    }
};
