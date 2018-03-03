const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const OutStream = std.io.OutStream;

const parse = @import("parse.zig");
const Parser = parse.Parser;
const Expr = parse.Expr;

// Note: Switch to OutStream
var global_buffer: [2048]u8 = undefined;

const StaticOutStream = struct {
    buffer: []u8,
    last: usize,
    stream: Stream,

    pub const Error = error{OutOfMemory};
    pub const Stream = OutStream(Error);

    pub fn init(buffer: []u8) StaticOutStream {
        return StaticOutStream {
            .buffer = buffer,
            .last = 0,
            .stream = Stream {
                .writeFn = writeFn,
            },
        };
    }

    fn writeFn(out_stream: &Stream, bytes: []const u8) Error!void {
        const self = @fieldParentPtr(StaticOutStream, "stream", out_stream);
        mem.copy(u8, self.buffer[self.last..], bytes);
        self.last += bytes.len;
    }
};

// Return a minimal string representation of the expression tree.
fn repr(e: &Expr) ![]u8 {
    var stream = StaticOutStream.init(global_buffer[0..]);
    try reprIndent(&stream, e, 0);
    return global_buffer[0..stream.last];
}

fn reprIndent(out: &StaticOutStream, e: &Expr, indent: usize) error!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.stream.print(" ");
    }

    switch (*e) {
        Expr.AnyCharNotNL => {
            try out.stream.print("dot\n");
        },
        Expr.EmptyMatch => |assertion| {
            try out.stream.print("empty({})\n", @tagName(assertion));
        },
        Expr.Literal => |lit| {
            try out.stream.print("lit({c})\n", lit);
        },
        Expr.Capture => |subexpr| {
            try out.stream.print("cap\n");
            try reprIndent(out, subexpr, indent + 1);
        },
        Expr.Repeat => |repeat| {
            try out.stream.print("rep(");
            if (repeat.min == 0 and repeat.max == null) {
                try out.stream.print("*");
            } else if (repeat.min == 1 and repeat.max == null) {
                try out.stream.print("+");
            } else if (repeat.min == 0 and repeat.max != null and ??repeat.max == 1) {
                try out.stream.print("?");
            } else {
                try out.stream.print("{{{},", repeat.min);
                if (repeat.max) |ok| {
                    try out.stream.print("{}", ok);
                }
                try out.stream.print("}}");
            }

            if (!repeat.greedy) {
                try out.stream.print("?");
            }
            try out.stream.print(")\n");

            try reprIndent(out, repeat.subexpr, indent + 1);
        },
        Expr.ByteClass => |class| {
            try out.stream.print("bset");
            for (class.ranges.toSliceConst()) |r|
                try out.stream.print("[{}-{}]", r.min, r.max);
            try out.stream.print(")\n");
        },
        // TODO: Can we get better type unification on enum variants with the same type?
        Expr.Concat => |subexprs| {
            try out.stream.print("cat\n");
            for (subexprs.toSliceConst()) |s|
                try reprIndent(out, s, indent + 1);
        },
        Expr.Alternate => |subexprs| {
            try out.stream.print("alt\n");
            for (subexprs.toSliceConst()) |s|
                try reprIndent(out, s, indent + 1);
        },
        // NOTE: Shouldn't occur ever in returned output.
        Expr.PseudoLeftParen => {
            try out.stream.print("{}\n", @tagName(*e));
        },
    }
}

fn check(re: []const u8, expected_ast: []const u8) void {
    var p = Parser.init(debug.global_allocator);
    const expr = p.parse(re) catch unreachable;

    var ast = repr(expr) catch unreachable;

    const spaces = []const u8 { ' ', '\n' };
    const trimmed_ast = mem.trim(u8, ast, spaces);
    const trimmed_expected_ast = mem.trim(u8, expected_ast, spaces);

    if (!mem.eql(u8, trimmed_ast, trimmed_expected_ast)) {
        debug.warn(
            \\
            \\-- expected the following
            \\
            \\{}
            \\
            \\-- but instead got
            \\
            \\{}
            \\
        ,
            trimmed_expected_ast,
            trimmed_ast,
        );

        @panic("assertion failure");
    }
}

test "regex parse tests" {
    // These are taken off rust-regex for the moment.

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

    // TODO: Escaping

    // TODO: Test character classes and escaping

    // TODO: Test error codes
}
