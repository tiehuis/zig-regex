//! C API for the zig-regex library

const std = @import("std");

const regex = @import("regex.zig");
const Regex = regex.Regex;
const Captures = regex.Captures;

const zre_regex_t = opaque {};
const zre_captures_t = opaque {};

const zre_captures_span_t = extern struct {
    lower: usize,
    upper: usize,
};

var allocator = std.heap.c_allocator;

export fn zre_compile(input: ?[*:0]const u8) ?*zre_regex_t {
    var r = allocator.create(Regex) catch return null;
    r.* = Regex.compile(allocator, std.mem.span(input.?)) catch return null;
    return @ptrCast(?*zre_regex_t, r);
}

export fn zre_match(re: ?*zre_regex_t, input: ?[*:0]const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    return r.match(std.mem.span(input.?)) catch return false;
}

export fn zre_partial_match(re: ?*zre_regex_t, input: ?[*:0]const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    return r.partialMatch(std.mem.span(input.?)) catch return false;
}

export fn zre_deinit(re: ?*zre_regex_t) void {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    r.deinit();
}

export fn zre_captures(re: ?*zre_regex_t, input: ?[*:0]const u8) ?*zre_captures_t {
    var r = @ptrCast(*Regex, @alignCast(8, re));
    var c = allocator.create(Captures) catch return null;
    c.* = (r.captures(std.mem.span(input.?)) catch return null) orelse return null;
    return @ptrCast(?*zre_captures_t, c);
    
}

export fn zre_captures_len(cap: ?*const zre_captures_t) usize {
    const c = @ptrCast(*const Captures, @alignCast(8, cap));
    return c.slots.len / 2;
}

export fn zre_captures_slice_at(cap: ?*const zre_captures_t, n: usize) ?[*]const u8 {
    const c = @ptrCast(*const Captures, @alignCast(8, cap));
    var slice = c.sliceAt(n) orelse return null;
    return slice.ptr;
}

export fn zre_captures_bounds_at(cap: ?*const zre_captures_t, n: usize, is_null: ?*bool) zre_captures_span_t {
    const c = @ptrCast(*const Captures, @alignCast(8, cap));
    var span = c.boundsAt(n);
    if (span) |s| {
        is_null.?.* = false;
        return zre_captures_span_t {
            .lower = s.lower,
            .upper = s.upper,
        };
    }
    is_null.?.* = true;
    return zre_captures_span_t {
        .lower = 0,
        .upper = 0,
    };
}

export fn zre_captures_deinit(cap: ?*zre_captures_t) void {
    var c = @ptrCast(*Captures, @alignCast(8, cap));
    c.deinit();
}

