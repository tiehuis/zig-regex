const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// A single inclusive range (a, b) and a <= b
pub fn Range(comptime T: type) type {
    return struct {
        min: T,
        max: T,

        pub fn new(min: T, max: T) Range(T) {
            // It doesn't matter if the order is inverted as we only check for containment.
            if (min <= max) {
                return Range(T) { .min = min, .max = max };
            } else {
                return Range(T) { .min = max, .max = min };
            }
        }
    };
}

// A contiguous set of ranges which manages merging of sub-ranges and negation of the entire class.
pub fn RangeSet(comptime T: type) type {
    return struct {
        const Self = this;
        const RangeType = Range(T);

        // for any consecutive x, y in ranges, the following hold:
        //  - x.min <= x.max
        //  - x.max < y.min
        ranges: ArrayList(RangeType),

        pub fn init(a: &Allocator) Self {
            return Self {
                .ranges = ArrayList(RangeType).init(a),
            };
        }

        pub fn deinit(self: &const Self) void {
            self.ranges.deinit();
        }

        // Add a range into the current class, preserving the structure invariants.
        pub fn addRange(self: &Self, range: &const RangeType) %void {
            var ranges = &self.ranges;

            if (ranges.len == 0) {
                try ranges.append(range);
                return;
            }

            // Insert range.
            for (ranges.toSlice()) |r, i| {
                if (range.min <= r.min) {
                    try ranges.insert(i, range);
                    break;
                }
            } else {
                try ranges.append(range);
            }

            // Merge overlapping runs.
            var index: usize = 0;
            var merge = ranges.at(0);

            for (ranges.toSlice()[1..]) |r| {
                // Overlap
                if (r.min <= merge.max) {
                    merge.max = math.max(merge.max, r.max);
                }
                // No overlap
                else {
                    ranges.toSlice()[index] = merge;
                    merge = r;
                    index += 1;
                }
            }

            ranges.toSlice()[index] = merge;
            index += 1;
            ranges.shrink(index);
        }

        // Inverting a class means the resulting class the contains method will match
        // the inverted set. i.e. contains(a, byte) == !contains(b, byte) if a == b.negated().
        //
        // The negation is performed in place.
        pub fn negate(self: &Self) %void {
            var ranges = &self.ranges;
            // NOTE: Append to end of array then copy and shrink.
            var negated = ArrayList(RangeType).init(self.ranges.allocator);

            if (ranges.len == 0) {
                try negated.append(RangeType.new(@minValue(T), @maxValue(T)));
                mem.swap(ArrayList(RangeType), ranges, &negated);
                negated.deinit();
                return;
            }

            var low: T = @minValue(T);
            for (ranges.toSliceConst()) |r| {
                // NOTE: Can only occur on first element.
                if (r.min != @minValue(T)) {
                    try negated.append(RangeType.new(low, r.min - 1));
                }

                low = math.add(T, r.max, 1) catch @maxValue(T);
            }

            // Highest segment will be remaining.
            const lastRange = ranges.at(ranges.len - 1);
            if (lastRange.max != @maxValue(T)) {
                try negated.append(RangeType.new(low, @maxValue(T)));
            }

            mem.swap(ArrayList(RangeType), ranges, &negated);
            negated.deinit();
        }

        pub fn contains(self: &const Self, value: T) bool {
            // TODO: Binary search may be useful if many sets since always ordered.
            for (self.ranges.toSliceConst()) |range| {
                if (range.min <= value and value <= range.max) {
                    return true;
                }
            }
            return false;
        }

        fn dump(self: &const Self) void {
            for (self.ranges.toSliceConst()) |r| {
                debug.warn("({} {}) ", r.min, r.max);
            }
            debug.warn("\n");
        }
    };
}

var alloc = debug.global_allocator;

test "class simple" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 54));

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));
}

test "class simple negate" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 54));

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));

    try a.negate();
    // Match the negation

    debug.assert(!a.contains(0));
    debug.assert(!a.contains(23));
    debug.assert(!a.contains(54));
    debug.assert(a.contains(55));
    debug.assert(a.contains(58));

    try a.negate();
    // negate is idempotent

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));
}

test "class multiple" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 20));
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(230, 255));

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));
}

test "class multiple negated" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 20));
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(230, 255));

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));

    try a.negate();

    debug.assert(!a.contains(20));
    debug.assert(a.contains(21));
    debug.assert(a.contains(79));
    debug.assert(!a.contains(80));
    debug.assert(a.contains(229));
    debug.assert(!a.contains(230));
    debug.assert(!a.contains(255));

    try a.negate();

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));
}

test "class out of order" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(20, 30));

    debug.assert(a.contains(80));
    debug.assert(!a.contains(79));
    debug.assert(!a.contains(101));
    debug.assert(!a.contains(45));
    debug.assert(!a.contains(19));
}

test "class merging" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(20, 100));
    try a.addRange(Range(u8).new(50, 80));
    try a.addRange(Range(u8).new(50, 140));

    debug.assert(!a.contains(19));
    debug.assert(a.contains(20));
    debug.assert(a.contains(80));
    debug.assert(a.contains(140));
    debug.assert(!a.contains(141));
}

test "class merging boundary" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(20, 40));
    try a.addRange(Range(u8).new(40, 60));

    debug.assert(a.ranges.len == 1);
}
