const Allocator = @import("std").mem.Allocator;
const compile = @import("compile.zig");
const Prog = compile.Prog;

const BacktrackVm = @import("exec_backtrack.zig").BacktrackVm;
const PikeVm = @import("exec_pikevm.zig").PikeVm;

pub fn exec(allocator: &Allocator, prog: &const Prog, prog_start: usize, input: []const u8, slots: []?usize) !bool {
    if (BacktrackVm.shouldExec(prog, input)) {
        var engine = BacktrackVm.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    } else {
        var engine = PikeVm.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    }
}
