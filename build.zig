const Builder = @import("std").build.Builder;

pub fn build(b: &Builder) void {
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run all tests");

    const test_files = [][]const u8 {
        "parse_test.zig",
        "exec_test.zig",
        "regex_test.zig",
    };

    inline for (test_files) |test_file| {
        const this_test = b.addTest("src/" ++ test_file);
        test_step.dependOn(&this_test.step);
    }

    const build_lib_step = b.step("library", "Build static library");

    const build_lib = b.addStaticLibrary("regex", "src/regex.zig");
    build_lib_step.dependOn(&build_lib.step);

    b.default_step.dependOn(test_step);
}
