const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (@hasDecl(std.Build, "CreateModuleOptions")) {
        // Zig 0.11
        _ = b.addModule("regex", .{
            .source_file = .{ .path = "src/regex.zig" },
        });
    } else {
        // Zig 0.12-dev.2159
        _ = b.addModule("regex", .{
            .root_source_file = path(b, "src/regex.zig"),
        });
    }

    // library tests
    const library_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = path(b, "src/all_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_library_tests = b.addRunArtifact(library_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_library_tests.step);

    // C library
    const staticLib = b.addLibrary(.{
        .name = "regex",
        .root_module = b.createModule(.{
            .root_source_file = path(b, "src/c_regex.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });

    b.installArtifact(staticLib);

    const sharedLib = b.addLibrary(.{
        .name = "regex",
        .root_module = b.createModule(.{
            .root_source_file = path(b, "src/c_regex.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });

    b.installArtifact(sharedLib);

    // C example
    const c_example_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_example = b.addExecutable(.{
        .name = "example",
        .root_module = c_example_module,
    });
    c_example.root_module.addCSourceFile(.{
        .file = path(b, "example/example.c"),
        .flags = &.{"-Wall"},
    });
    c_example.root_module.addIncludePath(path(b, "include"));
    c_example.root_module.linkLibrary(staticLib);

    const c_example_step = b.step("c-example", "Example using C API");
    c_example_step.dependOn(&staticLib.step);
    c_example_step.dependOn(&c_example.step);

    b.default_step.dependOn(test_step);
}

fn path(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    if (@hasDecl(std.Build, "path")) {
        // Zig 0.13-dev.267
        return b.path(sub_path);
    } else {
        return .{ .path = sub_path };
    }
}
