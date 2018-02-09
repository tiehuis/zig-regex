// Supported constructs:
//
// [x] .
// [x] [xyz]
// [ ] [^xyz]
// [ ] \d
// [ ] \D
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
// [ ] \A
// [ ] \b
// [ ] escape sequences


const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = std.debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");
const exec = @import("exec.zig");

const Parser = parse.Parser;
const Expr = parse.Expr;
const Compiler = compile.Compiler;
const Prog = compile.Prog;
const Inst = compile.Inst;
const VmBacktrack = exec.VmBacktrack;

pub const Regex = struct {
    // Manages the prog state (TODO: Just store allocator in Prog)
    compiler: Compiler,
    // A compiled set of instructions
    compiled: Prog,
    // Which engine we are using, have a literal matcher engine too
    engine: VmBacktrack,

    pub fn compile(a: &Allocator, re: []const u8) !Regex {
        var p = Parser.init(a);
        defer p.deinit();

        const expr = try p.parse(re);

        // Program state is tied to the compiler right now.
        var c = Compiler.init(a);
        errdefer c.deinit();

        return Regex {
            .compiler = c,
            .compiled = try c.compile(expr),
            .engine = VmBacktrack{},
        };
    }

    pub fn mustCompile(a: &Allocator, re: []const u8) Regex {
        var p = Parser.init(a);
        defer p.deinit();

        const expr = p.parse(re) catch unreachable;

        var c = Compiler.init(a);
        errdefer c.deinit();

        return Regex {
            .compiler = c,
            .compiled = c.compile(expr) catch unreachable,
            .engine = VmBacktrack{},
        };
    }

    pub fn deinit(re: &Regex) void {
        re.compiler.deinit();
    }

    // does the regex match the entire input string? simply run through from the first position.
    pub fn match(re: &const Regex, input: []const u8) !bool {
        // TODO: Need to specify $ on trailing?
        return re.engine.exec(re.compiled, input);
    }

    // does the regexp match any region within the string? memchr to the first byte in the regex
    // (if possible) and then run the matcher from there. this is important.
    pub fn partialMatch(re: &const Regex, input: []const u8) !bool {
        // TODO: Prepend .* before and bail early on complete match
        return re.engine.exec(re.compiled, input);
    }

    // where does the string match?
    // TODO: Requires capture support.
};

test "regex" {
    var alloc = debug.global_allocator;

    var re = Regex.mustCompile(alloc, "ab{1}c+d+.?");

    debug.assert((try re.match("abcd")) == true);
    debug.assert((try re.match("abcccccd")) == true);
    debug.assert((try re.match("abcdddddZ")) == true);
    debug.assert((try re.match("abd")) == false);
}
