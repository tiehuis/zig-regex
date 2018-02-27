const Allocator = @import("std").mem.Allocator;
const compile = @import("compile.zig");
const Prog = compile.Prog;

const VmBacktrack = @import("exec_backtrack.zig").VmBacktrack;

pub fn exec(allocator: &Allocator, prog: &const Prog, prog_start: usize, input: []const u8, slots: []?usize) !bool {
    if (VmBacktrack.shouldExec(prog, input)) {
        var engine = VmBacktrack.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    } else {
        @panic("no generic regex engine: compiled program is too long");
    }
}
