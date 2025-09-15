const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const parse = @import("parse.zig");
const Parser = parse.Parser;
const Expr = parse.Expr;
const ParseError = parse.ParseError;

// Note: Switch to OutStream
var global_buffer: [2048]u8 = undefined;

const StaticWriter = struct {
    buffer: []u8,
    last: usize,

    pub fn init(buffer: []u8) StaticWriter {
        return StaticWriter{
            .buffer = buffer,
            .last = 0,
        };
    }

    pub fn writeFn(self: *StaticWriter, bytes: []const u8) Error!usize {
        @memcpy(self.buffer[self.last..][0..bytes.len], bytes);
        self.last += bytes.len;
        return bytes.len;
    }

    pub const Error = error{OutOfMemory};
    pub const Writer = std.io.Writer(*StaticWriter, Error, writeFn);

    pub fn writer(self: *StaticWriter) Writer {
        return .{ .context = self };
    }

    pub fn printCharEscaped(self: *StaticWriter, ch: u8) !void {
        switch (ch) {
            '\t' => {
                try self.writer().print("\\t", .{});
            },
            '\r' => {
                try self.writer().print("\\r", .{});
            },
            '\n' => {
                try self.writer().print("\\n", .{});
            },
            // printable characters
            32...126 => {
                try self.writer().print("{c}", .{ch});
            },
            else => {
                try self.writer().print("0x{x}", .{ch});
            },
        }
    }
};

// Return a minimal string representation of the expression tree.
fn repr(e: *Expr) ![]u8 {
    var stream = StaticWriter.init(global_buffer[0..]);
    try reprIndent(&stream, e, 0);
    return global_buffer[0..stream.last];
}

fn reprIndent(out: *StaticWriter, e: *Expr, indent: usize) anyerror!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.writer().print(" ", .{});
    }

    switch (e.*) {
        Expr.AnyCharNotNL => {
            try out.writer().print("dot\n", .{});
        },
        Expr.EmptyMatch => |assertion| {
            try out.writer().print("empty({s})\n", .{@tagName(assertion)});
        },
        Expr.Literal => |lit| {
            try out.writer().print("lit(", .{});
            try out.printCharEscaped(lit);
            try out.writer().print(")\n", .{});
        },
        Expr.Capture => |subexpr| {
            try out.writer().print("cap\n", .{});
            try reprIndent(out, subexpr, indent + 1);
        },
        Expr.Repeat => |repeat| {
            try out.writer().print("rep(", .{});
            if (repeat.min == 0 and repeat.max == null) {
                try out.writer().print("*", .{});
            } else if (repeat.min == 1 and repeat.max == null) {
                try out.writer().print("+", .{});
            } else if (repeat.min == 0 and repeat.max != null and repeat.max.? == 1) {
                try out.writer().print("?", .{});
            } else {
                try out.writer().print("{{{d},", .{repeat.min});
                if (repeat.max) |ok| {
                    try out.writer().print("{d}", .{ok});
                }
                try out.writer().print("}}", .{});
            }

            if (!repeat.greedy) {
                try out.writer().print("?", .{});
            }
            try out.writer().print(")\n", .{});

            try reprIndent(out, repeat.subexpr, indent + 1);
        },
        Expr.ByteClass => |class| {
            try out.writer().print("bset(", .{});
            for (class.ranges.items) |r| {
                try out.writer().print("[", .{});
                try out.printCharEscaped(r.min);
                try out.writer().print("-", .{});
                try out.printCharEscaped(r.max);
                try out.writer().print("]", .{});
            }
            try out.writer().print(")\n", .{});
        },
        // TODO: Can we get better type unification on enum variants with the same type?
        Expr.Concat => |subexprs| {
            try out.writer().print("cat\n", .{});
            for (subexprs.items) |s|
                try reprIndent(out, s, indent + 1);
        },
        Expr.Alternate => |subexprs| {
            try out.writer().print("alt\n", .{});
            for (subexprs.items) |s|
                try reprIndent(out, s, indent + 1);
        },
        // NOTE: Shouldn't occur ever in returned output.
        Expr.PseudoLeftParen => {
            try out.writer().print("{s}\n", .{@tagName(e.*)});
        },
    }
}

fn check(re: []const u8, expected_ast: []const u8) void {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const expr = p.parse(re) catch unreachable;

    const ast = repr(expr) catch unreachable;

    const spaces = [_]u8{ ' ', '\n' };
    const trimmed_ast = mem.trim(u8, ast, &spaces);
    const trimmed_expected_ast = mem.trim(u8, expected_ast, &spaces);

    if (!mem.eql(u8, trimmed_ast, trimmed_expected_ast)) {
        debug.print(
            \\
            \\-- parsed the regex
            \\
            \\{s}
            \\
            \\-- expected the following
            \\
            \\{s}
            \\
            \\-- but instead got
            \\
            \\{s}
            \\
        , .{
            re,
            trimmed_expected_ast,
            trimmed_ast,
        });

        @panic("assertion failure");
    }
}

// These are taken off rust-regex for the moment.
test "parse simple" {
    check(
        \\
    ,
        \\empty(None)
    );

    check(
        \\a
    ,
        \\lit(a)
    );

    check(
        \\ab
    ,
        \\cat
        \\ lit(a)
        \\ lit(b)
    );

    check(
        \\^a
    ,
        \\cat
        \\ empty(BeginLine)
        \\ lit(a)
    );

    check(
        \\a?
    ,
        \\rep(?)
        \\ lit(a)
    );

    check(
        \\ab?
    ,
        \\cat
        \\ lit(a)
        \\ rep(?)
        \\  lit(b)
    );

    check(
        \\a??
    ,
        \\rep(??)
        \\ lit(a)
    );

    check(
        \\a+
    ,
        \\rep(+)
        \\ lit(a)
    );

    check(
        \\a+?
    ,
        \\rep(+?)
        \\ lit(a)
    );

    check(
        \\a*?
    ,
        \\rep(*?)
        \\ lit(a)
    );

    check(
        \\a{5}
    ,
        \\rep({5,5})
        \\ lit(a)
    );

    check(
        \\a{5,}
    ,
        \\rep({5,})
        \\ lit(a)
    );

    check(
        \\a{5,10}
    ,
        \\rep({5,10})
        \\ lit(a)
    );

    check(
        \\a{5}?
    ,
        \\rep({5,5}?)
        \\ lit(a)
    );

    check(
        \\a{5,}?
    ,
        \\rep({5,}?)
        \\ lit(a)
    );

    check(
        \\a{ 5     }
    ,
        \\rep({5,5})
        \\ lit(a)
    );

    check(
        \\(a)
    ,
        \\cap
        \\ lit(a)
    );

    check(
        \\(ab)
    ,
        \\cap
        \\ cat
        \\  lit(a)
        \\  lit(b)
    );

    check(
        \\a|b
    ,
        \\alt
        \\ lit(a)
        \\ lit(b)
    );

    check(
        \\a|b|c
    ,
        \\alt
        \\ lit(a)
        \\ lit(b)
        \\ lit(c)
    );

    check(
        \\(a|b)
    ,
        \\cap
        \\ alt
        \\  lit(a)
        \\  lit(b)
    );

    check(
        \\(a|b|c)
    ,
        \\cap
        \\ alt
        \\  lit(a)
        \\  lit(b)
        \\  lit(c)
    );

    check(
        \\(ab|bc|cd)
    ,
        \\cap
        \\ alt
        \\  cat
        \\   lit(a)
        \\   lit(b)
        \\  cat
        \\   lit(b)
        \\   lit(c)
        \\  cat
        \\   lit(c)
        \\   lit(d)
    );

    check(
        \\(ab|(bc|(cd)))
    ,
        \\cap
        \\ alt
        \\  cat
        \\   lit(a)
        \\   lit(b)
        \\  cap
        \\   alt
        \\    cat
        \\     lit(b)
        \\     lit(c)
        \\    cap
        \\     cat
        \\      lit(c)
        \\      lit(d)
    );

    check(
        \\.
    ,
        \\dot
    );
}

test "parse escape" {
    check(
        \\\a\f\t\n\r\v
    ,
        \\cat
        \\ lit(0x7)
        \\ lit(0xc)
        \\ lit(\t)
        \\ lit(\n)
        \\ lit(\r)
        \\ lit(0xb)
    );

    check(
        \\\\\.\+\*\?\(\)\|\[\]\{\}\^\$
    ,
        \\cat
        \\ lit(\)
        \\ lit(.)
        \\ lit(+)
        \\ lit(*)
        \\ lit(?)
        \\ lit(()
        \\ lit())
        \\ lit(|)
        \\ lit([)
        \\ lit(])
        \\ lit({)
        \\ lit(})
        \\ lit(^)
        \\ lit($)
    );

    check("\\123",
        \\lit(S)
    );

    check("\\1234",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );

    check("\\x53",
        \\lit(S)
    );

    check("\\x534",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );

    check("\\x{53}",
        \\lit(S)
    );

    check("\\x{53}4",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );
}

test "parse character classes" {
    check(
        \\[a]
    ,
        \\bset([a-a])
    );

    check(
        \\[\x00]
    ,
        \\bset([0x0-0x0])
    );

    check(
        \\[\n]
    ,
        \\bset([\n-\n])
    );

    check(
        \\[^a]
    ,
        \\bset([0x0-`][b-0xff])
    );

    check(
        \\[^\x00]
    ,
        \\bset([0x1-0xff])
    );

    check(
        \\[^\n]
    ,
        \\bset([0x0-\t][0xb-0xff])
    );

    check(
        \\[]]
    ,
        \\bset([]-]])
    );

    check(
        \\[]\[]
    ,
        \\bset([[-[][]-]])
    );

    check(
        \\[\[]]
    ,
        \\cat
        \\ bset([[-[])
        \\ lit(])
    );

    check(
        \\[]-]
    ,
        \\bset([---][]-]])
    );

    check(
        \\[-]]
    ,
        \\cat
        \\ bset([---])
        \\ lit(])
    );
}

fn checkError(re: []const u8, expected_err: ParseError) void {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var p = Parser.init(a.allocator());
    const parse_result = p.parse(re);

    if (parse_result) |expr| {
        const ast = repr(expr) catch unreachable;
        const spaces = [_]u8{ ' ', '\n' };
        const trimmed_ast = mem.trim(u8, ast, &spaces);

        debug.print(
            \\
            \\-- parsed the regex
            \\
            \\{s}
            \\
            \\-- expected the following
            \\
            \\{s}
            \\
            \\-- but instead got
            \\
            \\{s}
            \\
            \\
        , .{
            re,
            @errorName(expected_err),
            trimmed_ast,
        });

        @panic("assertion failure");
    } else |found_err| {
        if (found_err != expected_err) {
            debug.print(
                \\
                \\-- parsed the regex
                \\
                \\{s}
                \\
                \\-- expected the following
                \\
                \\{s}
                \\
                \\-- but instead got
                \\
                \\{s}
                \\
                \\
            , .{
                re,
                @errorName(expected_err),
                @errorName(found_err),
            });

            @panic("assertion failure");
        }
    }
}

test "parse errors repeat" {
    checkError(
        \\*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\(*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\({5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a**
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a|*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a*{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a|{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a{}
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{5
    , ParseError.UnclosedRepeat);

    checkError(
        \\a{xyz
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{12,xyz
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{999999999999}
    , ParseError.ExcessiveRepeatCount);

    checkError(
        \\a{1,999999999999}
    , ParseError.ExcessiveRepeatCount);

    checkError(
        \\a{12x}
    , ParseError.UnclosedRepeat);

    checkError(
        \\a{1,12x}
    , ParseError.UnclosedRepeat);
}

test "parse errors alternate" {
    checkError(
        \\|a
    , ParseError.EmptyAlternate);

    checkError(
        \\(|a)
    , ParseError.EmptyAlternate);

    checkError(
        \\a||
    , ParseError.EmptyAlternate);

    checkError(
        \\)
    , ParseError.UnopenedParentheses);

    checkError(
        \\ab)
    , ParseError.UnopenedParentheses);

    checkError(
        \\a|b)
    , ParseError.UnopenedParentheses);

    checkError(
        \\(a|b
    , ParseError.UnclosedParentheses);

    //checkError(
    //    \\(a|)
    //,
    //    ParseError.UnopenedParentheses
    //);

    //checkError(
    //    \\()
    //,
    //    ParseError.UnopenedParentheses
    //);

    checkError(
        \\ab(xy
    , ParseError.UnclosedParentheses);

    //checkError(
    //    \\()
    //,
    //    ParseError.UnopenedParentheses
    //);

    //checkError(
    //    \\a|
    //,
    //    ParseError.UnbalancedParentheses
    //);
}

test "parse errors escape" {
    checkError("\\", ParseError.OpenEscapeCode);

    checkError("\\m", ParseError.UnrecognizedEscapeCode);

    checkError("\\x", ParseError.InvalidHexDigit);

    //checkError(
    //    "\\xA"
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    //checkError(
    //    "\\xAG"
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    checkError("\\x{", ParseError.InvalidHexDigit);

    checkError("\\x{A", ParseError.UnclosedHexCharacterCode);

    checkError("\\x{AG}", ParseError.UnclosedHexCharacterCode);

    checkError("\\x{D800}", ParseError.InvalidHexDigit);

    checkError("\\x{110000}", ParseError.InvalidHexDigit);

    checkError("\\x{99999999999999}", ParseError.InvalidHexDigit);
}

test "parse errors character class" {
    checkError(
        \\[
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^
    , ParseError.UnclosedBrackets);

    checkError(
        \\[a
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^a
    , ParseError.UnclosedBrackets);

    checkError(
        \\[a-
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^a-
    , ParseError.UnclosedBrackets);

    checkError(
        \\[---
    , ParseError.UnclosedBrackets);

    checkError(
        \\[\A]
    , ParseError.UnrecognizedEscapeCode);

    //checkError(
    //    \\[a-\d]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[a-\A]
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    checkError(
        \\[\A-a]
    , ParseError.UnrecognizedEscapeCode);

    //checkError(
    //    \\[z-a]
    //,
    //    ParseError.UnclosedBrackets
    //);

    checkError(
        \\[]
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^]
    , ParseError.UnclosedBrackets);

    //checkError(
    //    \\[^\d\D]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[+--]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[a-a--\xFF]
    //,
    //    ParseError.UnclosedBrackets
    //);
}
