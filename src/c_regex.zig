//! C API for the zig-regex library

const std = @import("std");

const regex = @import("regex.zig");
const Regex = regex.Regex;
const Captures = regex.Captures;

const zre_regex = opaque {};
const zre_captures = opaque {};

const zre_captures_span = extern struct {
    lower: usize,
    upper: usize,
};

var allocator = std.heap.c_allocator;

export fn zre_compile(input: ?[*:0]const u8) ?*zre_regex {
    const r = allocator.create(Regex) catch return null;
    r.* = Regex.compile(allocator, std.mem.span(input.?)) catch return null;
    return @ptrCast(r);
}

export fn zre_match(re: ?*zre_regex, input: ?[*:0]const u8) bool {
    var r: *Regex = @ptrCast(@alignCast(re));
    return r.match(std.mem.span(input.?)) catch return false;
}

export fn zre_partial_match(re: ?*zre_regex, input: ?[*:0]const u8) bool {
    var r: *Regex = @ptrCast(@alignCast(re));
    return r.partialMatch(std.mem.span(input.?)) catch return false;
}

export fn zre_deinit(re: ?*zre_regex) void {
    var r: *Regex = @ptrCast(@alignCast(re));
    r.deinit();
    allocator.destroy(r);
}

export fn zre_captures_all(re: ?*zre_regex, input: ?[*:0]const u8) ?*zre_captures {
    var r: *Regex = @ptrCast(@alignCast(re));
    const c = allocator.create(Captures) catch return null;
    c.* = (r.captures(std.mem.span(input.?)) catch return null) orelse return null;
    return @ptrCast(c);
}

export fn zre_captures_len(cap: ?*const zre_captures) usize {
    const c: *const Captures = @ptrCast(@alignCast(cap));
    return c.slots.len / 2;
}

export fn zre_captures_slice_at(cap: ?*const zre_captures, n: usize, len: ?*usize) ?[*]const u8 {
    const c: *const Captures = @ptrCast(@alignCast(cap));
    const slice = c.sliceAt(n) orelse return null;
    if (len) |ln| {
        ln.* = slice.len;
    }
    return slice.ptr;
}

export fn zre_captures_bounds_at(cap: ?*const zre_captures, sp: ?*zre_captures_span, n: usize) bool {
    const c: *const Captures = @ptrCast(@alignCast(cap));
    const span = c.boundsAt(n);
    if (span) |s| {
        sp.?.*.lower = s.lower;
        sp.?.*.upper = s.upper;
        return true;
    }
    return false;
}

export fn zre_captures_deinit(cap: ?*zre_captures) void {
    var c: *Captures = @ptrCast(@alignCast(cap));
    c.deinit();
    allocator.destroy(c);
}
