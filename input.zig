const Assertion = @import("parse.zig").Assertion;

pub const InputBytes = struct {
    const Self = this;

    bytes: []const u8,
    byte_pos: usize,

    pub fn init(bytes: []const u8) Self {
        return Self {
            .bytes = bytes,
            .byte_pos= 0,
        };
    }

    pub fn current(self: &InputBytes) u8 {
        if (self.byte_pos < self.bytes.len) {
            return self.bytes[self.byte_pos];
        } else {
            return 0;
        }
    }

    pub fn advance(self: &InputBytes) void {
        self.byte_pos += 1;
    }

    // Note: We extend the range here to one past the end of the input. This is done in order to
    // handle complete matches correctly.
    //
    // Check any length required conditions (those which check current()) against isAtEnd() first).
    pub fn isConsumed(self: &const InputBytes) bool {
        return self.byte_pos > self.bytes.len;
    }

    // We use this function instead of `isConsumed` when we actually need to access the value such
    // as during a character check.
    pub fn isAtEnd(self: &const InputBytes) bool {
        return self.byte_pos >= self.bytes.len;
    }

    fn isWordChar(c: u8) bool {
        return switch (c) {
            '0' ... '9', 'a' ... 'z', 'A' ... 'Z' => true,
            else => false,
        };
    }

    fn isNextWordChar(self: &const Self) bool {
        return (self.byte_pos == 0) or isWordChar(self.bytes[self.byte_pos - 1]);
    }

    fn isPrevWordChar(self: &const Self) bool {
        return (self.byte_pos >= self.bytes.len - 1) or isWordChar(self.bytes[self.byte_pos + 1]);
    }

    pub fn isEmptyMatch(self: &const Self, match: &const Assertion) bool {
        switch (*match) {
            Assertion.None => {
                return true;
            },
            Assertion.BeginLine => {
                return self.byte_pos == 0;
            },
            Assertion.EndLine => {
                return self.byte_pos >= self.bytes.len - 1;
            },
            Assertion.BeginText => {
                // TODO: Handle different modes.
                return self.byte_pos == 0;
            },
            Assertion.EndText => {
                return self.byte_pos >= self.bytes.len - 1;
            },
            Assertion.WordBoundaryAscii => {
                return self.isPrevWordChar() != self.isNextWordChar();
            },
            Assertion.NotWordBoundaryAscii => {
                return self.isPrevWordChar() == self.isNextWordChar();
            },
        }
    }
};
