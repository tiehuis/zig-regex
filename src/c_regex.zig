//! C API for the zig-regex library

const std = @import("std");

const regex = @import("regex.zig");
const Regex = regex.Regex;

const zre_regex = opaque {};

var allocator = std.heap.c_allocator;

export fn zre_compile(input: ?[*:0]const u8) ?*zre_regex {
    var r = allocator.create(Regex) catch return null;
    r.* = Regex.compile(allocator, std.mem.spanZ(input.?)) catch return null;
    return @ptrCast(?*zre_regex, r);
}

export fn zre_match(re: ?*zre_regex, input: ?[*:0]const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    return r.match(std.mem.spanZ(input.?)) catch return false;
}

export fn zre_partial_match(re: ?*zre_regex, input: ?[*:0]const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    return r.partialMatch(std.mem.spanZ(input.?)) catch return false;
}

export fn zre_deinit(re: ?*zre_regex) void {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    r.deinit();
}
