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
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

/// A character class (e.g. [a-z] or [0-9]).
pub const ClassRange = struct {
    // Lower range in class (min <= max)
    min: u8,
    // Upper range in class
    max: u8,
};

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
    CharClass: ArrayList(ClassRange),
    // Concatenation
    Concat: ArrayList(&Expr),
    // |
    Alternate: ArrayList(&Expr),
    // Pseudo stack operator to define start of a capture
    PseudoLeftParen,

    pub fn isCharClass(re: &const Expr) bool {
        switch (*re) {
            Expr.Literal,
            Expr.CharClass,
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
            Expr.CharClass => |ranges| {
                debug.warn("{}(", @tagName(*e));
                for (ranges.toSliceConst()) |r|
                    debug.warn("[{c}-{c}]", r.min, r.max);
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

error InvalidRepeatOperand;
error MissingRepeatArgument;
error UnbalancedParentheses;
error UnopenedParentheses;
error EmptyCaptureGroup;
error UnmatchedCharClass;
error StackUnderflow;
error InvalidRepeatRange;
error UnclosedRepeat;
error ExcessiveRepeatCount;

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

    pub fn init(a: &Allocator) Parser {
        return Parser {
            .stack = ArrayList(&Expr).init(a),
            .node_list = ArrayList(&Expr).init(a),
            .allocator = a,
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

    fn popStack(p: &Parser) %&Expr {
        if (p.stack.len == 0) {
            return error.StackUnderflow;
        }

        return p.stack.pop();
    }

    fn popCharClass(p: &Parser) %&Expr {
        const re1 = try p.popStack();
        if (re1.isCharClass()) {
            return re1;
        } else {
            return error.MissingRepeatArgument;
        }
    }

    fn createExpr(p: &Parser) %&Expr {
        const r = try p.allocator.create(Expr);
        try p.node_list.append(r);
        return r;
    }

    pub fn parse(p: &Parser, re: []const u8) %&Expr {
        var i: usize = 0;

        while (i < re.len) : (i += 1) {
            switch (re[i]) {
                '*' => {
                    var greedy = true;
                    if (i + 1 < re.len and re[i + 1] == '?') {
                        greedy = false;
                        i += 1;
                    }

                    const repeat = Repeater {
                        .subexpr = try p.popCharClass(),
                        .min = 0,
                        .max = null,
                        .greedy = greedy,
                    };

                    var r = try p.createExpr();
                    *r = Expr { .Repeat = repeat };
                    try p.stack.append(r);
                },
                '+' => {
                    var greedy = true;
                    if (i + 1 < re.len and re[i + 1] == '?') {
                        greedy = false;
                        i += 1;
                    }

                    const repeat = Repeater {
                        .subexpr = try p.popCharClass(),
                        .min = 1,
                        .max = null,
                        .greedy = greedy,
                    };

                    var r = try p.createExpr();
                    *r = Expr { .Repeat = repeat };
                    try p.stack.append(r);
                },
                '?' => {
                    var greedy = true;
                    if (i + 1 < re.len and re[i + 1] == '?') {
                        greedy = false;
                        i += 1;
                    }

                    const repeat = Repeater {
                        .subexpr = try p.popCharClass(),
                        .min = 0,
                        .max = 1,
                        .greedy = greedy,
                    };

                    var r = try p.createExpr();
                    *r = Expr { .Repeat = repeat };
                    try p.stack.append(r);
                },
                // TODO: Add some parsing/iteration helpers as this is ugly and does not
                // handle early ending strings.
                '{' => {
                    i += 1;
                    while (re[i] == ' ') i += 1;

                    const start = i;
                    while ('0' <= re[i] and re[i] <= '9') i += 1;

                    const min = try fmt.parseUnsigned(usize, re[start..i], 10);
                    var max: ?usize = min;

                    while (re[i] == ' ') i += 1;
                    if (re[i] == ',') {
                        i += 1;
                        while (re[i] == ' ') i += 1;

                        // {m,} case with infinite upper bound
                        if (re[i] == '}') {
                            max = null;
                        }
                        // {m,n} case with explicit bounds
                        else {
                            const start2 = i;
                            while ('0' <= re[i] and re[i] <= '9') i += 1;
                            max = try fmt.parseUnsigned(usize, re[start2..i], 10);

                            if (??max < min) {
                                return error.InvalidRepeatRange;
                            }
                        }
                    }

                    while (re[i] == ' ') i += 1;
                    if (re[i] != '}') {
                        return error.UnclosedRepeat;
                    }

                    // We limit repeat counts to overoad arbitrary memory blowup during compilation
                    if (min > repeat_max_length or max != null and ??max > repeat_max_length) {
                        return error.ExcessiveRepeatCount;
                    }

                    var greedy = true;
                    if (i + 1 < re.len and re[i + 1] == '?') {
                        greedy = false;
                        i += 1;
                    }

                    // construct the repeat
                    const repeat = Repeater {
                        .subexpr = try p.popCharClass(),
                        .min = min,
                        .max = max,
                        .greedy = greedy,
                    };

                    var r = try p.createExpr();
                    *r = Expr { .Repeat = repeat };
                    try p.stack.append(r);
                },
                '.' => {
                    var r = try p.createExpr();
                    *r = Expr.AnyCharNotNL;
                    try p.stack.append(r);
                },
                '[' => {
                    var r = try p.createExpr();
                    *r = Expr { .CharClass = ArrayList(ClassRange).init(p.allocator) };

                    i += 1;

                    // TODO: Invert and merging of ranges.
                    // TODO: Keep in sorted order so we can binary search.

                    while (re[i] != ']') : (i += 1) {
                        // read character, duplicate into a single char range
                        var range = ClassRange { .min = re[i], .max = re[i] };
                        i += 1;

                        // is this a range?
                        if (re[i] == '-') {
                            i += 1;
                            if (re[i] == ']') {
                                return error.UnmatchedCharClass;
                            }

                            range.max = re[i];
                        }

                        try r.CharClass.append(range);
                    }

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
                                debug.warn("pseudo operator\n");
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
                    var r = try p.createExpr();
                    *r = Expr { .Literal = re[i] };
                    try p.stack.append(r);
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
};

test "parse" {
    var p = Parser.init(debug.global_allocator);
    const a = "^abc(def)[a-e0-9](asd|er)+a{5}b{90,}c{90,1000}?$";
    const expr = try p.parse(a);

    debug.warn("\n");
    debug.warn("{}\n\n", a);
    expr.dump();
}
