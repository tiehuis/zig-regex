const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const compile = @import("compile.zig");
const Prog = compile.Prog;

const BacktrackVm = @import("exec_backtrack.zig").BacktrackVm;
const PikeVm = @import("exec_pikevm.zig").PikeVm;
const Input = @import("input.zig").Input;

pub fn exec(allocator: &Allocator, prog: &const Prog, prog_start: usize, input: &Input, slots: &ArrayList(?usize)) !bool {
    if (BacktrackVm.shouldExec(prog, input)) {
        var engine = BacktrackVm.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    } else {
        var engine = PikeVm.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    }
}
