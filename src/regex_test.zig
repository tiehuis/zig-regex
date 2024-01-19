const Regex = @import("regex.zig").Regex;
const debug = @import("std").debug;
const Parser = @import("parse.zig").Parser;
const re_debug = @import("debug.zig");

const std = @import("std");
const mem = std.mem;

fn check(re_input: []const u8, to_match: []const u8, expected: bool) void {
    var re = Regex.compile(std.testing.allocator, re_input) catch unreachable;
    defer re.deinit();

    if ((re.partialMatch(to_match) catch unreachable) != expected) {
        debug.print(
            \\
            \\ -- Failure! ------------------
            \\
            \\Regex:    '{s}'
            \\String:   '{s}'
            \\Expected: {any}
            \\
        , .{
            re_input,
            to_match,
            expected,
        });

        // Dump expression tree and bytecode
        var p = Parser.init(std.testing.allocator);
        defer p.deinit();
        const expr = p.parse(re_input) catch unreachable;

        debug.print(
            \\
            \\ -- Expression Tree ------------
            \\
        , .{});
        re_debug.dumpExpr(expr.*);

        debug.print(
            \\
            \\ -- Bytecode -------------------
            \\
        , .{});
        re_debug.dumpProgram(re.compiled);

        debug.print(
            \\
            \\ -------------------------------
            \\
        , .{});

        @panic("assertion failure");
    }
}

fn checkCompile(allocator: mem.Allocator, re_input: []const u8) !void {
    var re = try Regex.compile(allocator, re_input);
    re.deinit();
}

test "regex sanity tests" {
    // Taken from tiny-regex-c
    check("\\d", "5", true);
    check("\\w+", "hej", true);
    check("\\s", "\t \n", true);
    check("\\S", "\t \n", false);
    check("[\\s]", "\t \n", true);
    check("[\\S]", "\t \n", false);
    check("\\D", "5", false);
    check("\\W+", "hej", false);
    check("[0-9]+", "12345", true);
    check("\\D", "hej", true);
    check("\\d", "hej", false);
    check("[^\\w]", "\\", true);
    check("[\\W]", "\\", true);
    check("[\\w]", "\\", false);
    check("[^\\d]", "d", true);
    check("[\\d]", "d", false);
    check("[^\\D]", "d", false);
    check("[\\D]", "d", true);
    check("^.*\\\\.*$", "c:\\Tools", true);
    check("^[\\+-]*[\\d]+$", "+27", true);
    check("[abc]", "1c2", true);
    check("[abc]", "1C2", false);
    check("[1-5]+", "0123456789", true);
    check("[.2]", "1C2", true);
    check("a*$", "Xaa", true);
    check("a*$", "Xaa", true);
    check("[a-h]+", "abcdefghxxx", true);
    check("[a-h]+", "ABCDEFGH", false);
    check("[A-H]+", "ABCDEFGH", true);
    check("[A-H]+", "abcdefgh", false);
    check("[^\\s]+", "abc def", true);
    check("[^fc]+", "abc def", true);
    check("[^d\\sf]+", "abc def", true);
    check("\n", "abc\ndef", true);
    //check("b.\\s*\n", "aa\r\nbb\r\ncc\r\n\r\n", true);
    check(".*c", "abcabc", true);
    check(".+c", "abcabc", true);
    check("[b-z].*", "ab", true);
    check("b[k-z]*", "ab", true);
    check("[0-9]", "  - ", false);
    check("[^0-9]", "  - ", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "hello world !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello World !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world!   ", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world  !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "hello World    !", true);
    check("[^\\w][^-1-4]", ")T", true);
    check("[^\\w][^-1-4]", ")^", true);
    check("[^\\w][^-1-4]", "*)", true);
    check("[^\\w][^-1-4]", "!.", true);
    check("[^\\w][^-1-4]", " x", true);
    check("[^\\w][^-1-4]", "$b", true);
    check("a|b", "a", true);
    check("a|b", "b", true);
    check("a|b", "x", false);
    check("[a-b]|[d-f]\\s+", "d ", true);
    check("[a-b]|[d-f]\\s+", "b", true);
    check("[a-b]|[d-f]\\s+", "c", false);
    check("\\bx\\b", "x", true);
    check("\\bx\\b", " x ", true);
    check("\\bx", "Ax", false);
    check("x\\b", "xA", false);
    check("\\Bx\\B", "x", false);
    check("\\Bx\\B", " x ", false);
    check("\\Bx", "Ax", true);
    check("x\\B", "xA", true);
}

test "regex captures" {
    var r = try Regex.compile(std.testing.allocator, "ab(\\d+)");
    defer r.deinit();

    debug.assert(try r.partialMatch("xxxxab0123a"));

    var caps = (try r.captures("xxxxab0123a")).?;
    defer caps.deinit();

    debug.assert(mem.eql(u8, "ab0123", caps.sliceAt(0).?));
    debug.assert(mem.eql(u8, "0123", caps.sliceAt(1).?));
}

test "regex memory leaks" {
    const allocator = std.testing.allocator;

    try checkCompile(allocator, "\\d");
    try checkCompile(allocator, "\\w+");
    try checkCompile(allocator, "\\s");
    try checkCompile(allocator, "\\S");
    try checkCompile(allocator, "[\\s]");
    try checkCompile(allocator, "[\\S]");
    try checkCompile(allocator, "\\D");
    try checkCompile(allocator, "\\W+");
    try checkCompile(allocator, "[0-9]+");
    try checkCompile(allocator, "[^\\w]");
    try checkCompile(allocator, "[\\W]");
    try checkCompile(allocator, "[\\w]");
    try checkCompile(allocator, "[^\\d]");
    try checkCompile(allocator, "[\\d]");
    try checkCompile(allocator, "[^\\D]");
    try checkCompile(allocator, "[\\D]");
    try checkCompile(allocator, "^.*\\\\.*$");
    try checkCompile(allocator, "^[\\+-]*[\\d]+$");
    try checkCompile(allocator, "[abc]");
    try checkCompile(allocator, "[1-5]+");
    try checkCompile(allocator, "[.2]");
    try checkCompile(allocator, "a*$");
    try checkCompile(allocator, "[a-h]+");
    try checkCompile(allocator, "[^\\s]+");
    try checkCompile(allocator, "[^fc]+");
    try checkCompile(allocator, "[^d\\sf]+");
    try checkCompile(allocator, "\n");
    try checkCompile(allocator, "b.\\s*\n");
    try checkCompile(allocator, ".*c");
    try checkCompile(allocator, ".+c");
    try checkCompile(allocator, "[b-z].*");
    try checkCompile(allocator, "b[k-z]*");
    try checkCompile(allocator, "[0-9]");
    try checkCompile(allocator, "[^0-9]");
    try checkCompile(allocator, "a?");
    try checkCompile(allocator, "[Hh]ello [Ww]orld\\s*[!]?");
    try checkCompile(allocator, "[^\\w][^-1-4]");
    try checkCompile(allocator, "[a-b]|[d-f]\\s+");
    try checkCompile(allocator, "x\\b");
    try checkCompile(allocator, "x\\B");
    try checkCompile(allocator, "[0-9]{2,}");
    try checkCompile(allocator, "[0-9]{2,3}");
}
