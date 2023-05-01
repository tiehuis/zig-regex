const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("regex", .{
        .source_file = .{ .path = "src/regex.zig" },
    });

    // library tests
    const library_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/all_test.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_library_tests = b.addRunArtifact(library_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_library_tests.step);

    // C library
    const lib = b.addStaticLibrary(.{
        .name = "regex",
        .root_source_file = .{ .path = "src/c_regex.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    b.installArtifact(lib);

    // C example
    const c_example = b.addExecutable(.{
        .name = "example",
        .target = target,
        .optimize = optimize,
    });
    c_example.addCSourceFile("example/example.c", &.{});
    c_example.addIncludePath("include");
    c_example.linkLibC();
    c_example.linkLibrary(lib);

    const c_example_step = b.step("c-example", "Example using C API");
    c_example_step.dependOn(&lib.step);
    c_example_step.dependOn(&c_example.step);

    b.default_step.dependOn(test_step);
}
