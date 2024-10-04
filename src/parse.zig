/// Parses a regular expression into an expression-tree. Uses a stack-based parser to avoid
/// unbounded recursion.
const std = @import("std");
const math = std.math;
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const range_set = @import("range_set.zig");
const ByteClassTemplates = range_set.ByteClassTemplates;

/// A single class range (e.g. [a-z]).
pub const ByteRange = range_set.Range(u8);

/// Multiple class ranges (e.g. [a-z0-9])
pub const ByteClass = range_set.RangeSet(u8);

/// Repeat sequence (e.g. +, *, ?, {m,n})
pub const Repeater = struct {
    // The sub-expression to repeat
    subexpr: *Expr,
    // Lower number of times to match
    min: usize,
    // Upper number of times to match (null -> infinite)
    max: ?usize,
    // Whether this matches greedily
    greedy: bool,
};

/// A specific look-around assertion
pub const Assertion = enum {
    // Always true assertion
    None,
    // ^ anchor, beginning of text (or line depending on mode)
    BeginLine,
    // $ anchor, beginning of text (or line dependening on mode)
    EndLine,
    // \A anchor, beginning of text
    BeginText,
    // \z anchor, end of text
    EndText,
    // \w anchor, word boundary ascii
    WordBoundaryAscii,
    // \W anchor, non-word boundary ascii
    NotWordBoundaryAscii,
};

/// Extra attributes for group expression.
pub const GroupAttributes = struct {
    capturing: bool,
};

/// A single node of an expression tree.
pub const Expr = union(enum) {
    // Empty match (\w assertion)
    EmptyMatch: Assertion,
    // A single character byte to match
    Literal: u8,
    // . character
    AnyCharNotNL,
    // Capture group
    Capture: *Group,
    // *, +, ?
    Repeat: Repeater,
    // Character class [a-z0-9]
    ByteClass: ByteClass,
    // Concatenation
    Concat: ArrayList(*Expr),
    // |
    Alternate: ArrayList(*Expr),
    // Pseudo stack operator to define start of a capture
    PseudoLeftParen: GroupAttributes,

    pub fn isByteClass(re: *const Expr) bool {
        switch (re.*) {
            .Literal,
            .ByteClass,
            .AnyCharNotNL,
            // TODO: Don't keep capture here, but allow on repeat operators.
            .Capture,
            => return true,
            else => return false,
        }
    }

    pub fn clone(re: *Expr) !Expr {
        return switch (re.*) {
            .ByteClass => |*bc| Expr{ .ByteClass = try bc.clone() },
            else => re.*,
        };
    }

    pub fn deinit(re: *Expr) void {
        switch (re.*) {
            .ByteClass => |*bc| bc.deinit(),
        }
    }
};

/// A single node of a group. The group could include different modifiers
/// by Perl flag for further features like non-capturing group.
pub const Group = struct {
    expr: *Expr,
    capturing: bool,
};

// Private in fmt.
fn charToDigit(c: u8, radix: u8) !u8 {
    const value = switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        'a'...'z' => c - 'a' + 10,
        else => return error.InvalidChar,
    };

    if (value >= radix)
        return error.InvalidChar;

    return value;
}

const StringIterator = struct {
    const Self = @This();

    slice: []const u8,
    index: usize,

    pub fn init(s: []const u8) Self {
        return StringIterator{
            .slice = s,
            .index = 0,
        };
    }

    // Advance the stream and return the next token.
    pub fn next(it: *Self) ?u8 {
        if (it.index < it.slice.len) {
            const n = it.index;
            it.index += 1;
            return it.slice[n];
        } else {
            return null;
        }
    }

    // Advance the stream.
    pub fn bump(it: *Self) void {
        if (it.index < it.slice.len) {
            it.index += 1;
        }
    }

    // Reset the stream back one character
    pub fn bumpBack(it: *Self) void {
        if (it.index > 0) {
            it.index -= 1;
        }
    }

    // Look at the nth character in the stream without advancing.
    fn peekAhead(it: *const Self, comptime n: usize) ?u8 {
        if (it.index + n < it.slice.len) {
            return it.slice[it.index + n];
        } else {
            return null;
        }
    }

    // Return true if the next character in the stream is `ch`.
    pub fn peekNextIs(it: *const Self, ch: u8) bool {
        if (it.peekAhead(1)) |ok_ch| {
            return ok_ch == ch;
        } else {
            return false;
        }
    }

    // Look at the next character in the stream without advancing.
    pub fn peek(it: *const Self) ?u8 {
        return it.peekAhead(0);
    }

    // Return true if the next character in the stream is `ch`.
    pub fn peekIs(it: *const Self, ch: u8) bool {
        if (it.peek()) |ok_ch| {
            return ok_ch == ch;
        } else {
            return false;
        }
    }

    // Read an integer from the stream. Any non-digit characters stops the parsing chain.
    //
    // Error if no digits were read.
    //
    // TODO: Non character word-boundary instead?
    pub fn readInt(it: *Self, comptime T: type, comptime radix: u8) !T {
        return it.readIntN(T, radix, math.maxInt(usize));
    }

    // Read an integer from the stream, limiting the read to N characters at most.
    pub fn readIntN(it: *Self, comptime T: type, comptime radix: u8, comptime N: usize) !T {
        const start = it.index;

        var i: usize = 0;
        while (it.peek()) |ch| : (i += 1) {
            if (i >= N) {
                break;
            }

            if (charToDigit(ch, radix)) |_| {
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

    pub fn skipSpaces(it: *Self) void {
        while (it.peek()) |ok| {
            if (ok != ' ')
                return;

            it.bump();
        }
    }
};

pub const ParseError = error{
    MissingRepeatOperand,
    MissingRepeatArgument,
    InvalidRepeatArgument,
    EmptyAlternate,
    UnbalancedParentheses,
    UnopenedParentheses,
    UnclosedParentheses,
    EmptyCaptureGroup,
    UnmatchedByteClass,
    StackUnderflow,
    InvalidRepeatRange,
    UnclosedRepeat,
    UnclosedBrackets,
    ExcessiveRepeatCount,
    OpenEscapeCode,
    UnclosedHexCharacterCode,
    InvalidHexDigit,
    InvalidOctalDigit,
    UnrecognizedEscapeCode,
    UnimplementedModifier,
};

pub const ParserOptions = struct {
    // Upper limit on values allowed in a bounded expression (e.g. {500,1000}).
    // This must be bounded as these are unrolled by the engine into individual branches and
    // otherwise are a vector for memory exhaustion attacks.
    max_repeat_length: usize,

    pub fn default() ParserOptions {
        return ParserOptions{ .max_repeat_length = 1000 };
    }
};

/// Parser manages the parsing state and converts a regular expression string into an expression tree.
///
/// The resulting expression is tied to the Parser which generated it.
pub const Parser = struct {
    // Parse expression stack
    stack: ArrayList(*Expr),
    // ArenaAllocator for generating all expression nodes
    arena: ArenaAllocator,
    // Allocator for temporary lists/items
    allocator: Allocator,
    // Configurable parser options
    options: ParserOptions,
    // Internal execution state.
    it: StringIterator,

    pub fn init(a: Allocator) Parser {
        return initWithOptions(a, ParserOptions.default());
    }

    pub fn initWithOptions(a: Allocator, options: ParserOptions) Parser {
        return Parser{
            .stack = ArrayList(*Expr).init(a),
            .arena = ArenaAllocator.init(a),
            .allocator = a,
            .options = options,
            .it = undefined,
        };
    }

    pub fn deinit(p: *Parser) void {
        p.stack.deinit();
        p.arena.deinit();
    }

    pub fn reset(p: *Parser) void {
        p.stack.shrink(0);

        // Note: A shrink or reset on the ArenaAllocator would be nice.
        p.arena.deinit();
        p.arena = ArenaAllocator.init(p.allocator);
    }

    fn popStack(p: *Parser) !*Expr {
        if (p.stack.items.len == 0) {
            return error.StackUnderflow;
        }

        return p.stack.pop();
    }

    fn popByteClass(p: *Parser) !*Expr {
        const re1 = try p.popStack();
        if (re1.isByteClass()) {
            return re1;
        } else {
            return error.MissingRepeatOperand;
        }
    }

    fn isPunctuation(c: u8) bool {
        return switch (c) {
            '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '-' => true,
            else => false,
        };
    }

    fn createExpr(p: *Parser) !*Expr {
        return try p.arena.allocator().create(Expr);
    }

    fn createGroup(p: *Parser) !*Group {
        return try p.arena.allocator().create(Group);
    }

    pub fn parse(p: *Parser, re: []const u8) !*Expr {
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

                    const min = it.readInt(usize, 10) catch return error.InvalidRepeatArgument;
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
                            max = it.readInt(usize, 10) catch return error.InvalidRepeatArgument;

                            if (max.? < min) {
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
                    const limit = p.options.max_repeat_length;
                    if (min > limit or max != null and max.? > limit) {
                        return error.ExcessiveRepeatCount;
                    }

                    try p.parseRepeat(min, max);
                },
                '.' => {
                    const r = try p.createExpr();
                    r.* = Expr{ .AnyCharNotNL = undefined };
                    try p.stack.append(r);
                },
                '[' => {
                    try p.parseCharClass();
                },
                // Don't handle alternation just yet, parentheses group together arguments into
                // a sub-expression only.
                '(' => {
                    var capturing = true;
                    if (it.peekIs('?')) {
                        // Advance and discard
                        _ = it.next();
                        if (it.peekIs(':')) {
                            // Advance and discard
                            _ = it.next();
                            capturing = false;
                        } else {
                            // NOTE: Other modifiers are considered not implemented
                            return error.UnimplementedModifier;
                        }
                    }

                    const r = try p.createExpr();
                    r.* = Expr{ .PseudoLeftParen = .{
                        .capturing = capturing,
                    } };
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
                    var concat = ArrayList(*Expr).init(p.arena.allocator());

                    while (true) {
                        // would underflow, push a new alternation
                        if (p.stack.items.len == 0) {
                            return error.UnopenedParentheses;
                        }

                        const e = p.stack.pop();
                        switch (e.*) {
                            // Existing alternation
                            .Alternate => {
                                mem.reverse(*Expr, concat.items);

                                const ra = try p.createExpr();
                                if (concat.items.len == 1) {
                                    ra.* = concat.items[0].*;
                                } else {
                                    ra.* = Expr{ .Concat = concat };
                                }

                                // append to the alternation stack
                                try e.Alternate.append(ra);

                                if (p.stack.items.len == 0) {
                                    return error.UnopenedParentheses;
                                }

                                const next_e = p.stack.pop().*;
                                var capturing: bool = undefined;
                                switch (next_e) {
                                    // pop the left parentheses that must now exist
                                    .PseudoLeftParen => |e_paren| {
                                        capturing = e_paren.capturing;
                                    },
                                    else => unreachable,
                                }

                                const group = try p.createGroup();
                                group.* = Group{
                                    .expr = e,
                                    .capturing = capturing,
                                };

                                const r = try p.createExpr();
                                r.* = Expr{ .Capture = group };
                                try p.stack.append(r);
                                break;
                            },
                            // Existing parentheses, push new alternation
                            .PseudoLeftParen => |e_paren| {
                                mem.reverse(*Expr, concat.items);

                                const ra = try p.createExpr();
                                ra.* = Expr{ .Concat = concat };

                                if (concat.items.len == 0) {
                                    return error.EmptyCaptureGroup;
                                } else if (concat.items.len == 1) {
                                    ra.* = concat.items[0].*;
                                } else {
                                    ra.* = Expr{ .Concat = concat };
                                }

                                const group = try p.createGroup();
                                group.* = Group{
                                    .expr = ra,
                                    .capturing = e_paren.capturing,
                                };

                                const r = try p.createExpr();
                                r.* = Expr{ .Capture = group };
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
                    var concat = ArrayList(*Expr).init(p.arena.allocator());

                    if (p.stack.items.len == 0 or !p.stack.items[p.stack.items.len - 1].isByteClass()) {
                        return error.EmptyAlternate;
                    }

                    while (true) {
                        // would underflow, push a new alternation
                        if (p.stack.items.len == 0) {
                            // We need to create a single expr node for the alternation.
                            const ra = try p.createExpr();
                            mem.reverse(*Expr, concat.items);

                            if (concat.items.len == 1) {
                                ra.* = concat.items[0].*;
                            } else {
                                ra.* = Expr{ .Concat = concat };
                            }

                            var r = try p.createExpr();
                            r.* = Expr{ .Alternate = ArrayList(*Expr).init(p.arena.allocator()) };
                            try r.Alternate.append(ra);
                            try p.stack.append(r);
                            break;
                        }

                        const e = p.stack.pop();
                        switch (e.*) {
                            // Existing alternation, combine
                            .Alternate => {
                                mem.reverse(*Expr, concat.items);

                                const ra = try p.createExpr();
                                if (concat.items.len == 1) {
                                    ra.* = concat.items[0].*;
                                } else {
                                    ra.* = Expr{ .Concat = concat };
                                }

                                // use the expression itself
                                try e.Alternate.append(ra);

                                try p.stack.append(e);
                                break;
                            },
                            // Existing parentheses, push new alternation
                            .PseudoLeftParen => {
                                // re-push parentheses marker
                                try p.stack.append(e);

                                mem.reverse(*Expr, concat.items);

                                const ra = try p.createExpr();
                                if (concat.items.len == 1) {
                                    ra.* = concat.items[0].*;
                                } else {
                                    ra.* = Expr{ .Concat = concat };
                                }

                                var r = try p.createExpr();
                                r.* = Expr{ .Alternate = ArrayList(*Expr).init(p.arena.allocator()) };
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
                    const r = try p.parseEscape();
                    try p.stack.append(r);
                },
                '^' => {
                    const r = try p.createExpr();
                    r.* = Expr{ .EmptyMatch = Assertion.BeginLine };
                    try p.stack.append(r);
                },
                '$' => {
                    const r = try p.createExpr();
                    r.* = Expr{ .EmptyMatch = Assertion.EndLine };
                    try p.stack.append(r);
                },
                else => {
                    try p.parseLiteral(ch);
                },
            }
        }

        // special case empty item
        if (p.stack.items.len == 0) {
            const r = try p.createExpr();
            r.* = Expr{ .EmptyMatch = Assertion.None };
            return r;
        }

        // special case single item to avoid top-level concat for simple.
        if (p.stack.items.len == 1) {
            return p.stack.pop();
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
        var concat = ArrayList(*Expr).init(p.arena.allocator());

        while (true) {
            if (p.stack.items.len == 0) {
                // concat the items in reverse order and return
                mem.reverse(*Expr, concat.items);

                const r = try p.createExpr();
                if (concat.items.len == 1) {
                    r.* = concat.items[0].*;
                } else {
                    r.* = Expr{ .Concat = concat };
                }
                return r;
            }

            // pop an item, check if it is an alternate and not a pseudo left paren
            const e = p.stack.pop();
            switch (e.*) {
                .PseudoLeftParen => {
                    return error.UnclosedParentheses;
                },
                // Alternation at top-level, push concat and return
                .Alternate => {
                    mem.reverse(*Expr, concat.items);

                    const ra = try p.createExpr();
                    if (concat.items.len == 1) {
                        ra.* = concat.items[0].*;
                    } else {
                        ra.* = Expr{ .Concat = concat };
                    }

                    // use the expression itself
                    try e.Alternate.append(ra);

                    // if stack is not empty, this is an error
                    if (p.stack.items.len != 0) {
                        switch (p.stack.pop().*) {
                            .PseudoLeftParen => return error.UnclosedParentheses,
                            else => unreachable,
                        }
                    }

                    return e;
                },
                // New expression, push onto concat stack
                else => {
                    try concat.append(e);
                },
            }
        }
    }

    fn parseLiteral(p: *Parser, ch: u8) !void {
        const r = try p.createExpr();
        r.* = Expr{ .Literal = ch };
        try p.stack.append(r);
    }

    fn parseRepeat(p: *Parser, min: usize, max: ?usize) !void {
        var greedy = true;
        if (p.it.peekIs('?')) {
            p.it.bump();
            greedy = false;
        }

        const sub_expr = p.popByteClass() catch return error.MissingRepeatOperand;

        const repeat = Repeater{
            .subexpr = sub_expr,
            .min = min,
            .max = max,
            .greedy = greedy,
        };

        const r = try p.createExpr();
        r.* = Expr{ .Repeat = repeat };
        try p.stack.append(r);
    }

    // NOTE: We don't handle needed character classes.
    fn parseCharClass(p: *Parser) !void {
        var it = &p.it;

        var class = ByteClass.init(p.arena.allocator());
        errdefer class.deinit();

        var negate = false;
        if (it.peekIs('^')) {
            it.bump();
            negate = true;
        }

        // First '[' in a multi-class is always treated as a literal. This disallows
        // the empty byte-set '[]'.
        if (it.peekIs(']')) {
            it.bump();

            const range = ByteRange{ .min = ']', .max = ']' };
            try class.addRange(range);
        }

        while (!it.peekIs(']')) : (it.bump()) {
            if (it.peek() == null) {
                return error.UnclosedBrackets;
            }

            const chp = it.peek().?;

            // If this is a byte-class escape, we cannot expect an '-' range after it.
            // Accept the following - as a literal (may be bad behaviour).
            //
            // If it is not, then we can and it is fine.
            var range: ByteRange = undefined;

            if (chp == '\\') {
                it.bump();

                // parseEscape returns a literal or byteclass so reformat
                const r = try p.parseEscape();
                // NOTE: this is bumped on loop
                it.index -= 1;
                switch (r.*) {
                    .Literal => |value| {
                        range = ByteRange{ .min = value, .max = value };
                    },
                    .ByteClass => |*vv| {
                        defer vv.deinit();
                        // '-' doesn't make sense following this, merge class here
                        // and continue next.
                        try class.mergeClass(vv.*);
                        continue;
                    },
                    else => unreachable,
                }
            } else {
                range = ByteRange{ .min = chp, .max = chp };
            }

            // is this a range?
            if (it.peekNextIs('-')) {
                it.bump();
                it.bump();

                if (it.peek() == null) {
                    return error.UnclosedBrackets;
                } else if (it.peekIs(']')) {
                    // treat the '-' as a literal instead
                    it.index -= 1;
                } else {
                    range.max = it.peek().?;
                }
            }

            try class.addRange(range);
        }
        it.bump();

        if (negate) {
            try class.negate();
        }

        const r = try p.createExpr();
        r.* = Expr{ .ByteClass = class };
        try p.stack.append(r);
    }

    fn parseEscape(p: *Parser) !*Expr {
        const ch = p.it.next() orelse return error.OpenEscapeCode;

        if (isPunctuation(ch)) {
            const r = try p.createExpr();
            r.* = Expr{ .Literal = ch };
            return r;
        }

        switch (ch) {
            // escape chars
            'a' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\x07' };
                return r;
            },
            'f' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\x0c' };
                return r;
            },
            'n' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\n' };
                return r;
            },
            'r' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\r' };
                return r;
            },
            't' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\t' };
                return r;
            },
            'v' => {
                const r = try p.createExpr();
                r.* = Expr{ .Literal = '\x0b' };
                return r;
            },
            // perl codes
            's' => {
                const s = try ByteClassTemplates.Whitespace(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            'S' => {
                const s = try ByteClassTemplates.NonWhitespace(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            'w' => {
                const s = try ByteClassTemplates.AlphaNumeric(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            'W' => {
                const s = try ByteClassTemplates.NonAlphaNumeric(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            'd' => {
                const s = try ByteClassTemplates.Digits(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            'D' => {
                const s = try ByteClassTemplates.NonDigits(p.arena.allocator());
                const r = try p.createExpr();
                r.* = Expr{ .ByteClass = s };
                return r;
            },
            '0'...'9' => {
                p.it.bumpBack();

                // octal integer up to 3 digits, always succeeds since we have at least one digit
                // TODO: u32 codepoint and not u8
                const value = p.it.readIntN(u8, 8, 3) catch return error.InvalidOctalDigit;
                const r = try p.createExpr();
                r.* = Expr{ .Literal = value };
                return r;
            },
            'x' => {
                p.it.skipSpaces();

                // '\x{2423}
                if (p.it.peekIs('{')) {
                    p.it.bump();

                    // TODO: u32 codepoint and not u8
                    const value = p.it.readInt(u8, 16) catch return error.InvalidHexDigit;

                    // TODO: Check range as well and if valid unicode codepoint
                    if (!p.it.peekIs('}')) {
                        return error.UnclosedHexCharacterCode;
                    }
                    p.it.bump();

                    const r = try p.createExpr();
                    r.* = Expr{ .Literal = value };
                    return r;
                }
                // '\x23
                else {
                    const value = p.it.readIntN(u8, 16, 2) catch return error.InvalidHexDigit;
                    const r = try p.createExpr();
                    r.* = Expr{ .Literal = value };
                    return r;
                }
            },
            'b' => {
                const r = try p.createExpr();
                r.* = Expr{ .EmptyMatch = Assertion.WordBoundaryAscii };
                return r;
            },
            'B' => {
                const r = try p.createExpr();
                r.* = Expr{ .EmptyMatch = Assertion.NotWordBoundaryAscii };
                return r;
            },
            else => {
                return error.UnrecognizedEscapeCode;
            },
        }
    }
};
