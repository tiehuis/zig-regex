const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    //const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addTest("src/all_test.zig").step);

    const build_lib_step = b.step("library", "Build static library");
    const build_lib = b.addStaticLibrary("regex", "src/c_regex.zig");
    build_lib.linkLibC();
    build_lib_step.dependOn(&build_lib.step);

    const c_example_step = b.step("c-example", "Example using C API");
    const c_example = b.addExecutable("example", "example/example.c");
    c_example.addIncludeDir("include");
    c_example.linkLibC();
    c_example.linkLibrary(build_lib);
    c_example_step.dependOn(&build_lib.step);
    c_example_step.dependOn(&c_example.step);

    b.default_step.dependOn(test_step);
}
