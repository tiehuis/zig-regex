const Builder = @import("std").build.Builder;

pub fn build(b: &Builder) void {
    const mode = b.standardReleaseOptions();

    var lib = b.addStaticLibrary("regex", "regex.zig");
    b.default_step.dependOn(&lib.step);
}
