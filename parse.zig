const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const range_set = @import("range_set.zig");
const ByteClassTemplates = range_set.ByteClassTemplates;

/// A single class range (e.g. [a-z]).
pub const ByteRange = range_set.Range(u8);

/// A number of class ranges (e.g. [a-z0-9])
pub const ByteClass = range_set.RangeSet(u8);

/// Repeat sequence (i.e. +, *, ?, {m,n})
pub const Repeater = struct {
    // The sub-expression to repeat
    subexpr: &Expr,
    // Lower number of times to match
    min: usize,
    // Upper number of times to match (null => infinite)
    max: ?usize,
    // Whether we match greedily
    greedy: bool,
};

/// Represents a single node in an AST.
pub const Expr = union(enum) {
    // A single character byte to match
    Literal: u8,
    // . character
    AnyCharNotNL,
    // ^ anchor
    BeginLine,
    // $ anchor
    EndLine,
    // Capture group
    Capture: &Expr,
    // *, +, ?
    Repeat: Repeater,
    // Character class [a-z&&0-9]
    // NOTE: We don't handle the && union just yet.
    ByteClass: ByteClass,
    // Concatenation
    Concat: ArrayList(&Expr),
    // |
    Alternate: ArrayList(&Expr),
    // Pseudo stack operator to define start of a capture
    PseudoLeftParen,

    pub fn isByteClass(re: &const Expr) bool {
        switch (*re) {
            Expr.Literal,
            Expr.ByteClass,
            Expr.AnyCharNotNL,
            // TODO: Don't keep capture here, but allow on repeat operators.
            Expr.Capture,
                => return true,
            else
                => return false,
        }
    }

    pub fn dump(e: &const Expr) void {
        e.dumpIndent(0);
    }

    fn dumpIndent(e: &const Expr, indent: usize) void {
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            debug.warn(" ");
        }

        switch (*e) {
            Expr.AnyCharNotNL, Expr.BeginLine, Expr.EndLine => {
                debug.warn("{}\n", @tagName(*e));
            },
            Expr.Literal => |lit| {
                debug.warn("{}({c})\n", @tagName(*e), lit);
            },
            Expr.Capture => |subexpr| {
                debug.warn("{}\n", @tagName(*e));
                subexpr.dumpIndent(indent + 1);
            },
            Expr.Repeat => |repeat| {
                debug.warn("{}(min={}, max={}, greedy={})\n",
                    @tagName(*e), repeat.min, repeat.max, repeat.greedy);
                repeat.subexpr.dumpIndent(indent + 1);
            },
            Expr.ByteClass => |class| {
                debug.warn("{}(", @tagName(*e));
                for (class.ranges.toSliceConst()) |r|
                    debug.warn("[{}-{}]", r.min, r.max);
                debug.warn(")\n");
            },
            // TODO: Can we get better type unification on enum variants with the same type?
            Expr.Concat => |subexprs| {
                debug.warn("{}\n", @tagName(*e));
                for (subexprs.toSliceConst()) |s|
                    s.dumpIndent(indent + 1);
            },
            Expr.Alternate => |subexprs| {
                debug.warn("{}\n", @tagName(*e));
                for (subexprs.toSliceConst()) |s|
                    s.dumpIndent(indent + 1);
            },
            // NOTE: Shouldn't occur ever in returned output.
            Expr.PseudoLeftParen => {
                debug.warn("{}\n", @tagName(*e));
            },
        }
    }
};

// Private in fmt.
fn charToDigit(c: u8, radix: u8) !u8 {
    const value = switch (c) {
        '0' ... '9' => c - '0',
        'A' ... 'Z' => c - 'A' + 10,
        'a' ... 'z' => c - 'a' + 10,
        else => return error.InvalidChar,
    };

    if (value >= radix)
        return error.InvalidChar;

    return value;
}

const StringIterator = struct {
    const Self = this;

    slice: []const u8,
    index: usize,

    pub fn init(s: []const u8) Self {
        return StringIterator {
            .slice = s,
            .index = 0,
        };
    }

    // Advance the stream and return the next token.
    pub fn next(it: &Self) ?u8 {
        if (it.index < it.slice.len) {
            const n = it.index;
            it.index += 1;
            return it.slice[n];
        } else {
            return null;
        }
    }

    // Advance the stream.
    pub fn bump(it: &Self) void {
        if (it.index < it.slice.len) {
            it.index += 1;
        }
    }

    // Look at the nth character in the stream without advancing.
    fn peekAhead(it: &const Self, comptime n: usize) ?u8 {
        if (it.index + n < it.slice.len) {
            return it.slice[it.index + n];
        } else {
            return null;
        }
    }

    // Look at the next character in the stream without advancing.
    pub fn peek(it: &const Self) ?u8 {
        return it.peekAhead(0);
    }

    // Return true if the next character in the stream is `ch`.
    pub fn peekIs(it: &const Self, ch: u8) bool {
        if (it.peek()) |ok_ch| {
            return ok_ch == ch;
        } else {
            return false;
        }
    }

    // Read an integer from the stream. Any non-digit characters stops the parsing chain.
    //
    // Error if no digits were read.
    // TODO: Non character word-boundary instead?
    pub fn readInt(it: &Self, comptime T: type, comptime radix: u8) !T {
        const start = it.index;

        while (it.peek()) |ch| {
            if (charToDigit(ch, radix)) |is_valid| {
                it.bump();
            } else |_| {
                break;
            }
        }

        if (start != it.index) {
            return try fmt.parseUnsigned(T, it.slice[start..it.index], radix);
        } else {
            return error.NoIntegerRead;
        }
    }

    pub fn skipSpaces(it: &Self) void {
        while (it.peek()) |ok| {
            if (ok != ' ')
                return;

            it.bump();
        }
    }
};

pub const ParseError = error {
    InvalidRepeatOperand,
    MissingRepeatArgument,
    UnbalancedParentheses,
    UnopenedParentheses,
    EmptyCaptureGroup,
    UnmatchedByteClass,
    StackUnderflow,
    InvalidRepeatRange,
    UnclosedRepeat,
    ExcessiveRepeatCount,
};

const repeat_max_length = 1000;

/// Parser manages the parsing state and converts a regular expression string into an expression tree.
///
/// The resulting expression is tied to the parsing state.
pub const Parser = struct {
    // Parse expression stack
    stack: ArrayList(&Expr),
    // List of references to actual allocate nodes
    node_list: ArrayList(&Expr),
    // Allocator for lists/node generation
    allocator: &Allocator,

    // Internal parse state.
    it: StringIterator,

    pub fn init(a: &Allocator) Parser {
        return Parser {
            .stack = ArrayList(&Expr).init(a),
            .node_list = ArrayList(&Expr).init(a),
            .allocator = a,
            .it = undefined,
        };
    }

    pub fn deinit(p: &Parser) void {
        p.stack.deinit();

        for (p.node_list.toSliceConst()) |node| {
            p.allocator.destroy(node);
        }
    }

    pub fn reset(p: &Parser) void {
        p.stack.shrink(0);

        for (p.node_list) |node| {
            p.allocator.destroy(node);
        }
        p.node_list.shrink(0);
    }

    fn popStack(p: &Parser) !&Expr {
        if (p.stack.len == 0) {
            return error.StackUnderflow;
        }

        return p.stack.pop();
    }

    fn popByteClass(p: &Parser) !&Expr {
        const re1 = try p.popStack();
        if (re1.isByteClass()) {
            return re1;
        } else {
            return error.MissingRepeatArgument;
        }
    }

    fn createExpr(p: &Parser) !&Expr {
        const r = try p.allocator.create(Expr);
        try p.node_list.append(r);
        return r;
    }

    pub fn parse(p: &Parser, re: []const u8) !&Expr {
        p.it = StringIterator.init(re);
        // Shorter alias
        var it = &p.it;

        while (it.next()) |ch| {
            // TODO: Consolidate some of the same common patterns.
            switch (ch) {
                '*' => {
                    try p.parseRepeat(0, null);
                },
                '+' => {
                    try p.parseRepeat(1, null);
                },
                '?' => {
                    try p.parseRepeat(0, 1);
                },
                '{' => {
                    it.skipSpaces();

                    const min = try it.readInt(usize, 10);
                    var max: ?usize = min;

                    it.skipSpaces();

                    if (it.peekIs(',')) {
                        it.bump();
                        it.skipSpaces();

                        // {m,} case with infinite upper bound
                        if (it.peekIs('}')) {
                            max = null;
                        }
                        // {m,n} case with explicit bounds
                        else {
                            max = try it.readInt(usize, 10);

                            if (??max < min) {
                                return error.InvalidRepeatRange;
                            }
                        }
                    }

                    it.skipSpaces();
                    if (!it.peekIs('}')) {
                        return error.UnclosedRepeat;
                    }
                    it.bump();

                    // We limit repeat counts to overoad arbitrary memory blowup during compilation
                    if (min > repeat_max_length or max != null and ??max > repeat_max_length) {
                        return error.ExcessiveRepeatCount;
                    }

                    try p.parseRepeat(min, max);
                },
                '.' => {
                    var r = try p.createExpr();
                    *r = Expr.AnyCharNotNL;
                    try p.stack.append(r);
                },
                '[' => {
                    var class = ByteClass.init(p.allocator);

                    var negate = false;
                    if (it.peekIs('^')) {
                        it.bump();
                        negate = true;
                    }

                    while (!it.peekIs(']')) : (it.bump()) {
                        // read character, duplicate into a single char range
                        var range = ByteRange { .min = ??it.peek(), .max = ??it.peek() };
                        it.bump();

                        // is this a range?
                        if (it.peekIs('-')) {
                            it.bump();
                            if (it.peekIs(']')) {
                                return error.UnmatchedByteClass;
                            }

                            range.max = ??it.peek();
                        }

                        try class.addRange(range);
                    }
                    it.bump();

                    if (negate) {
                        try class.negate();
                    }

                    var r = try p.createExpr();
                    *r = Expr { .ByteClass = class };
                    try p.stack.append(r);
                },
                // Don't handle alternation just yet, parentheses group together arguments into
                // a sub-expression only.
                '(' => {
                    var r = try p.createExpr();
                    *r = Expr.PseudoLeftParen;
                    try p.stack.append(r);
                },
                ')' => {
                    // Pop the stack until.
                    //
                    // - Empty, error unopened parenthesis.
                    // - ( pseudo operator, push a group expression of the concat
                    // - '|' pop and add the concat to the alternation list. Pop one more item
                    //   after which must be a opening parenthesis.
                    //
                    // '|' ensures there will be only one alternation on the stack here.
                    var concat = ArrayList(&Expr).init(p.allocator);

                    while (true) {
                        // would underflow, push a new alternation
                        if (p.stack.len == 0) {
                            return error.UnopenedParentheses;
                        }

                        const e = p.stack.pop();
                        switch (*e) {
                            // Existing alternation
                            Expr.Alternate => {
                                var ra = try p.createExpr();
                                mem.reverse(&Expr, concat.toSlice());
                                *ra = Expr { .Concat = concat };

                                // append to the alternation stack
                                try e.Alternate.append(ra);

                                if (p.stack.len == 0) {
                                    return error.UnopenedParentheses;
                                }

                                // pop the left parentheses that must now exist
                                debug.assert(*p.stack.pop() == Expr.PseudoLeftParen);

                                var r = try p.createExpr();
                                *r = Expr { .Capture = e };

                                try p.stack.append(r);
                                break;
                            },
                            // Existing parentheses, push new alternation
                            Expr.PseudoLeftParen => {
                                var ra = try p.createExpr();
                                mem.reverse(&Expr, concat.toSlice());
                                *ra = Expr { .Concat = concat };

                                var r = try p.createExpr();
                                *r = Expr { .Capture = ra };

                                try p.stack.append(r);
                                break;
                            },
                            // New expression, push onto concat stack
                            else => {
                                try concat.append(e);
                            },
                        }
                    }

                },
                '|' => {
                    // Pop the stack until.
                    //
                    // - Empty, then push the sub-expression as a concat.
                    // - ( pseudo operator, leave '(' and push concat.
                    // - '|' is found, pop the existing and add a new alternation to the array.

                    var concat = ArrayList(&Expr).init(p.allocator);

                    // TODO: Handle the empty alternation (||) case?
                    // TODO: Special-case length one.
                    while (true) {
                        // would underflow, push a new alternation
                        if (p.stack.len == 0) {
                            // We need to create a single expr node for the alternation.
                            var ra = try p.createExpr();
                            mem.reverse(&Expr, concat.toSlice());
                            *ra = Expr { .Concat = concat };

                            var r = try p.createExpr();
                            *r = Expr { .Alternate = ArrayList(&Expr).init(p.allocator) };
                            try r.Alternate.append(ra);

                            try p.stack.append(r);
                            break;
                        }

                        const e = p.stack.pop();
                        switch (*e) {
                            // Existing alternation, combine
                            Expr.Alternate => {
                                var ra = try p.createExpr();
                                mem.reverse(&Expr, concat.toSlice());
                                *ra = Expr { .Concat = concat };

                                // use the expression itself
                                try e.Alternate.append(ra);

                                try p.stack.append(e);
                                break;
                            },
                            // Existing parentheses, push new alternation
                            Expr.PseudoLeftParen => {
                                // re-push parentheses marker
                                try p.stack.append(e);

                                var ra = try p.createExpr();
                                mem.reverse(&Expr, concat.toSlice());
                                *ra = Expr { .Concat = concat };

                                var r = try p.createExpr();
                                *r = Expr { .Alternate = ArrayList(&Expr).init(p.allocator) };
                                try r.Alternate.append(ra);

                                try p.stack.append(r);
                                break;
                            },
                            // New expression, push onto concat stack
                            else => {
                                try concat.append(e);
                            },
                        }
                    }
                },
                '\\' => {
                    try p.parseEscape();
                },
                '^' => {
                    var r = try p.createExpr();
                    *r = Expr.BeginLine;
                    try p.stack.append(r);
                },
                '$' => {
                    var r = try p.createExpr();
                    *r = Expr.EndLine;
                    try p.stack.append(r);
                },
                else => {
                    try p.parseLiteral(ch);
                },
            }
        }

        // finish a concatenation result
        //
        // This pops items off the stack and concatenates them until:
        //
        // - The stack is empty (the items are concat and pushed and the single result is returned).
        // - An alternation is seen, this is popped and the current concat state is pushed as an
        //   alternation item.
        //
        // After any of these cases, the stack must be empty.
        //
        // There can be no parentheses left on the stack during this popping.
        var concat = ArrayList(&Expr).init(p.allocator);

        while (true) {
            if (p.stack.len == 0) {
                // concat the items in reverse order and return
                var r = try p.createExpr();
                mem.reverse(&Expr, concat.toSlice());
                *r = Expr { .Concat = concat };
                return r;
            }

            // pop an item, check if it is an alternate and not a pseudo left paren
            const e = p.stack.pop();
            switch (*e) {
                Expr.PseudoLeftParen => {
                    return error.UnbalancedParentheses;
                },
                // Alternation at top-level, push concat and return
                Expr.Alternate => {
                    var ra = try p.createExpr();
                    mem.reverse(&Expr, concat.toSlice());
                    *ra = Expr { .Concat = concat };

                    // use the expression itself
                    try e.Alternate.append(ra);

                    return e;
                },
                // New expression, push onto concat stack
                else => {
                    try concat.append(e);
                },
            }
        }
    }

    fn parseLiteral(p: &Parser, ch: u8) !void {
        var r = try p.createExpr();
        *r = Expr { .Literal = ch };
        try p.stack.append(r);
    }

    fn parseRepeat(p: &Parser, min: usize, max: ?usize) !void {
        var greedy = true;
        if (p.it.peekIs('?')) {
            p.it.bump();
            greedy = false;
        }

        const repeat = Repeater {
            .subexpr = try p.popByteClass(),
            .min = min,
            .max = max,
            .greedy = greedy,
        };

        var r = try p.createExpr();
        *r = Expr { .Repeat = repeat };
        try p.stack.append(r);
    }

    fn parseEscape(p: &Parser) !void {
        p.it.bump();

        switch (??p.it.next()) {
            // escape chars
            'a' => try p.parseLiteral('\x07'),
            'f' => try p.parseLiteral('\x0c'),
            'n' => try p.parseLiteral('\n'),
            'r' => try p.parseLiteral('\r'),
            't' => try p.parseLiteral('\t'),
            'v' => try p.parseLiteral('\x0b'),
            // perl codes
            's' => {
                var s = try ByteClassTemplates.Whitespace(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            'S' => {
                var s = try ByteClassTemplates.NonWhitespace(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            'w' => {
                var s = try ByteClassTemplates.AlphaNumeric(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            'W' => {
                var s = try ByteClassTemplates.NonAlphaNumeric(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            'd' => {
                var s = try ByteClassTemplates.Digits(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            'D' => {
                var s = try ByteClassTemplates.NonDigits(p.allocator);

                var r = try p.createExpr();
                *r = Expr { .ByteClass = s };
                try p.stack.append(r);
            },
            else => @panic("unknown escape code"),
        }
    }
};

test "parse" {
    var p = Parser.init(debug.global_allocator);
    const a = \\^abc(def)[a-e0-9](asd|er)+a{5}b{90,}c{90,1000}?\\s\\S$
            ;

    const expr = try p.parse(a);

    expr.dump();

    debug.warn("\n");
    debug.warn("{}\n\n", a);
}
