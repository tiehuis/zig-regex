const Builder = @import("std").build.Builder;

pub fn build(b: &Builder) void {
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run all tests");

    const test_files = [][]const u8 {
        "range_set.zig",
        "parse_test.zig",
        "exec_test.zig",
        "regex_test.zig",
    };

    for (test_files) |test_file| {
        const this_test = b.addTest(test_file);
        test_step.dependOn(&this_test.step);
    }

    const build_lib_step = b.addStaticLibrary("regex", "regex.zig");

    b.default_step.dependOn(test_step);
}
