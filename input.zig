const Assertion = @import("parse.zig").Assertion;

pub const Input = struct {
    slice: []const u8,
    len: usize,

    pub fn init(slice: []const u8) Input {
        return Input {
            .slice = slice,
            .len = slice.len,
        };
    }

    pub fn at(i: &const Input, n: usize) u8 {
        return i.slice[n];
    }

    fn isWordChar(c: u8) bool {
        return switch (c) {
            '0' ... '9', 'a' ... 'z', 'A' ... 'Z' => true,
            else => false,
        };
    }

    pub fn isEmptyMatch(i: &const Input, n: usize, match: &const Assertion) bool {
        switch (*match) {
            Assertion.None => {
                return true;
            },
            Assertion.BeginLine => {
                return n == 0;
            },
            Assertion.EndLine => {
                return n == i.len - 1;
            },
            Assertion.BeginText => {
                // TODO: Handle different modes.
                return n == 0;
            },
            Assertion.EndText => {
                return n == i.len - 1;
            },
            Assertion.WordBoundaryAscii => {
                const last = (n == 0) or isWordChar(i.slice[n-1]);
                const next = (n == i.len - 1) or isWordChar(i.slice[n+1]);
                return last != next;
            },
            Assertion.NotWordBoundaryAscii => {
                const last = (n == 0) or isWordChar(i.slice[n-1]);
                const next = (n == i.len - 1) or isWordChar(i.slice[n+1]);
                return last == next;
            },
        }
    }
};
