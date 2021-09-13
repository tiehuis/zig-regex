const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    //const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addTest("src/all_test.zig").step);

    const build_lib_step = b.step("library", "Build static library");
    const build_lib = b.addStaticLibrary("regex", "src/regex.zig");
    build_lib_step.dependOn(&build_lib.step);

    b.default_step.dependOn(test_step);
}
